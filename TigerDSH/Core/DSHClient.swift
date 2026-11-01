import Foundation

struct RPCError: LocalizedError, Sendable {
    enum Kind: Sendable { case network, timeout, auth, missing, bad, host }
    let kind: Kind
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Talks to a DSH host the same way its own web page does: `POST /api/<method>` for calls, one multiplexed
/// WebSocket (`/api/remote.mux`) for streams. The sign-in is DSH's own: the one-time link `dsh web` prints
/// (`https://<host>/?token=…`) is exchanged once for the host's year-long sign-in cookie.
final class DSHClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = DSHClient()

    private var base: URL?
    private var ck: String?
    private var session: URLSession!
    private var counter = 0
    private let lock = NSLock()

    /// The host and the sign-in cookie are written on the main actor but read from background work too (the
    /// capability probes), so both go through the lock rather than being plain properties on a `@unchecked Sendable`.
    private(set) var baseURL: URL? {
        get { lock.withLock { base } }
        set { lock.withLock { base = newValue } }
    }
    private(set) var cookie: String? {
        get { lock.withLock { ck } }
        set { lock.withLock { ck = newValue } }
    }

    /// The credential generation: bumped whenever the sign-in changes — a successful sign-in, a sign-out. Every
    /// request is tagged with the generation of the cookie it actually carries, so a 401 from a request made before
    /// that change cannot end the sign-in that replaced it (see `authLost(requestGeneration:)`).
    private var credGen = 0

    /// The generation in force, for the main-actor recheck. Read under the same lock as the credential itself.
    var credentialGeneration: Int { lock.withLock { credGen } }

    #if DEBUG
    /// Where `rpc` goes instead of the host, in a Debug build only — the same door `ChatModel.pageCall` has for
    /// `session/page`. A unit test can then hold a flow that needs a host answer (the queue's own projections) with
    /// no host behind it; the shipping build has no such entry point to read.
    var rpcStub: ((String, JSON) async throws -> JSON)? {
        get { lock.withLock { stub } }
        set { lock.withLock { stub = newValue } }
    }
    private var stub: ((String, JSON) async throws -> JSON)?
    #endif

    /// Called on the main actor when the host refuses the stored sign-in.
    var onAuthLost: (@MainActor () -> Void)?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        if let s = UserDefaults.standard.string(forKey: "dsh.base"), let u = URL(string: s) { baseURL = u }
        cookie = Keychain.get("dsh.cookie")
    }

    var isSignedIn: Bool { baseURL != nil && cookie != nil }
    var hostLabel: String { baseURL?.host() ?? "" }

    // Never follow the sign-in redirect: the cookie is on the 303 itself.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    // MARK: sign-in

    /// Accepts the full link (`https://host/?token=…`), or a host address plus a separate token.
    func signIn(link: String, token explicitToken: String = "") async throws {
        var raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let comps = URLComponents(string: raw), let host = comps.host, !host.isEmpty else {
            throw RPCError(kind: .bad, code: "link", message: "That does not look like a DSH address.")
        }
        let token = explicitToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (comps.queryItems?.first(where: { $0.name == "token" })?.value ?? "")
            : explicitToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw RPCError(kind: .bad, code: "token", message: "The link has no sign-in token. Copy the whole link that `dsh web` prints on your Mac.") }
        var b = URLComponents()
        b.scheme = comps.scheme ?? "https"; b.host = host; b.port = comps.port
        guard let base = b.url else { throw RPCError(kind: .bad, code: "link", message: "That does not look like a DSH address.") }
        var q = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        q.path = "/"; q.queryItems = [URLQueryItem(name: "token", value: token)]
        var req = URLRequest(url: q.url!)
        req.timeoutInterval = 15
        let resp: URLResponse
        do { (_, resp) = try await session.data(for: req) } catch {
            // iOS refuses plain http; saying so is the difference between a fixable typo and a dead end.
            if base.scheme == "http" {
                throw RPCError(kind: .network, code: "insecure", message: "That link starts with http://, which iOS blocks. Use the https:// link dsh web prints.")
            }
            throw RPCError(kind: .network, code: "network", message: "Could not reach \(host). Check that Tailscale is on, on this phone and on the Mac.")
        }
        guard let http = resp as? HTTPURLResponse else { throw RPCError(kind: .bad, code: "bad", message: "Unexpected answer from the Mac.") }
        let setCookies = (http.value(forHTTPHeaderField: "Set-Cookie") ?? "")
        let pairs = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookies], for: base)
            .filter { $0.name.hasPrefix("dsh-auth") }
            .map { "\($0.name)=\($0.value)" }
        guard !pairs.isEmpty else {
            throw RPCError(kind: .auth, code: "auth", message: http.statusCode == 401
                ? "The Mac refused that link. It changes each time DSH restarts: copy the newest one."
                : "The Mac did not sign this phone in (answer \(http.statusCode)).")
        }
        let ck = pairs.joined(separator: "; ")
        // The credential and its generation move together, under one lock: a request built from here on is tagged
        // with the new sign-in, and everything still in flight from the old one is stale from this moment.
        lock.withLock { self.base = base; self.ck = ck; credGen += 1 }
        UserDefaults.standard.set(base.absoluteString, forKey: "dsh.base")
        Keychain.set(ck, for: "dsh.cookie")
    }

    func signOut() {
        // Same order, same reason: the generation moves with the credential it belongs to.
        lock.withLock { credGen += 1; ck = nil }
        Keychain.delete("dsh.cookie")
    }

    // MARK: calls

    private func nextId() -> String { lock.lock(); defer { lock.unlock() }; counter += 1; return "i\(counter)-\(Int.random(in: 1000...99999))" }

    /// The request, with the credential generation it was made under. Handing the generation back with the request is
    /// what makes a 401 impossible to check against the wrong sign-in: every call site has to take it.
    private func request(path: String, method: String = "POST", body: Data? = nil, timeout: TimeInterval) throws -> (URLRequest, Int) {
        // The credential and its generation are read in ONE lock acquisition: a request must be tagged with the
        // generation of the cookie it actually sends, never with one that changed in between.
        let (base, ck, gen) = lock.withLock { (self.base, self.ck, credGen) }
        guard let base, let ck else { throw RPCError(kind: .auth, code: "auth", message: "Not signed in") }
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue(ck, forHTTPHeaderField: "Cookie")
        // Market plugins fence their own routes behind a "same-origin browser" check, which a plain client fails:
        // with the sign-in's own authority as Origin, those routes answer instead of 403.
        r.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        return (r, gen)
    }

    /// A 401 ends the sign-in only if the request that got it was made under the sign-in still in force. A request
    /// from before a sign-out can come back 401 while the reader is already signed in again, and ending THAT sign-in
    /// — stopping its streams, dismissing its approvals — is exactly what the generation is here to prevent. The
    /// check is repeated on the main actor, because the credential can change while this hops over.
    private func authLost(requestGeneration gen: Int) {
        Task { @MainActor in
            guard gen == self.credentialGeneration else { return }
            self.onAuthLost?()
        }
    }

    @discardableResult
    func rpc(_ method: String, _ args: JSON = [:], timeout: TimeInterval = 25) async throws -> JSON {
        #if DEBUG
        // A unit test's own door to a host answer, the same shape `ChatModel.pageCall` has for `session/page`: the
        // flows that only break when a reply arrives late (the queued card's own inbox) cannot be asked of a real Mac
        // on cue. Behind the same lock as the credential, because `rpc` is called from the main actor and from the
        // background probes both.
        if let stub = rpcStub { return try await stub(method, args) }
        #endif
        let body: JSON = ["type": "client-request", "rpcId": .string(nextId()), "method": .string(method), "payload": ["args": args]]
        let (req, gen) = try request(path: "/api/" + method, body: body.data(), timeout: timeout)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch let e as URLError {
            throw RPCError(kind: e.code == .timedOut ? .timeout : .network, code: "network",
                           message: e.code == .timedOut ? "The request timed out" : "No connection to the Mac")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { authLost(requestGeneration: gen); throw RPCError(kind: .auth, code: "auth", message: "Signed out") }
        if status == 404 { throw RPCError(kind: .missing, code: "missing", message: "Not available in this DSH version") }
        let j: JSON
        do { j = try await Task.detached(priority: .userInitiated) { try JSON.parse(data) }.value } catch {
            throw RPCError(kind: .bad, code: "bad", message: "Unexpected reply from the Mac")
        }
        let res = j["result"]
        guard res["ok"].bool == true else {
            throw RPCError(kind: .host, code: res["error"]["code"].str, message: res["error"]["message"].string ?? "The request failed")
        }
        return res["value"]
    }

    /// For the few calls whose reply is large: parse straight into a typed value off the main thread.
    func rpcDecode<T: Decodable & Sendable>(_ method: String, _ args: JSON = [:], as: T.Type, timeout: TimeInterval = 90,
                                            path: String? = nil) async throws -> T {
        let body: JSON = ["type": "client-request", "rpcId": .string(nextId()), "method": .string(method), "payload": ["args": args]]
        let (req, gen) = try request(path: path ?? "/api/" + method, body: body.data(), timeout: timeout)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw RPCError(kind: .network, code: "network", message: "No connection to the Mac")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { authLost(requestGeneration: gen); throw RPCError(kind: .auth, code: "auth", message: "Signed out") }
        if status == 404 { throw RPCError(kind: .missing, code: "missing", message: "Not available in this DSH version") }
        return try await Task.detached(priority: .userInitiated) {
            let e = try JSONDecoder().decode(RPCEnvelope<T>.self, from: data)
            guard e.result.ok, let v = e.result.value else { throw RPCError(kind: .host, code: "host", message: "The request failed") }
            return v
        }.value
    }

    /// Does this host know the method? 404 means no; anything else (usually an arguments error) means yes.
    func probe(_ method: String) async -> Bool? {
        let body: JSON = ["type": "client-request", "rpcId": "probe", "method": .string(method), "payload": ["args": [:]]]
        guard let (req, gen) = try? request(path: "/api/" + method, body: body.data(), timeout: 10),
              let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 { authLost(requestGeneration: gen); return nil }
        return http.statusCode != 404
    }

    /// Plain GET of a JSON route served by the host or a plugin (for example `/provider-quota/status.json`).
    func getJSON(_ path: String, timeout: TimeInterval = 20) async throws -> JSON {
        let (req, gen) = try request(path: path, method: "GET", timeout: timeout)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { authLost(requestGeneration: gen); throw RPCError(kind: .auth, code: "auth", message: "Signed out") }
        guard (200..<300).contains(status) else {
            throw RPCError(kind: status == 404 ? .missing : .host, code: "\(status)", message: status == 404 ? "Not published on this Mac" : "The Mac answered \(status)")
        }
        return try JSON.parse(data)
    }

    /// A document route that answers bytes rather than JSON — the session export is a zip.
    func getData(_ path: String, timeout: TimeInterval = 120) async throws -> Data {
        let (req, gen) = try request(path: path, method: "GET", timeout: timeout)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { authLost(requestGeneration: gen); throw RPCError(kind: .auth, code: "auth", message: "Signed out") }
        guard (200..<300).contains(status) else {
            throw RPCError(kind: status == 404 ? .missing : .host, code: "\(status)", message: status == 404 ? "Not published on this Mac" : "The Mac answered \(status)")
        }
        return data
    }

    /// The same route, but the bytes land in a file as they arrive instead of being held in memory: a big session's
    /// export carries every attachment it ever made, and asking for all of that as one Data is what a large chat's
    /// transcript was failing on.
    func getFile(_ path: String, timeout: TimeInterval = 300) async throws -> URL {
        let (req, gen) = try request(path: path, method: "GET", timeout: timeout)
        let (tmp, resp) = try await session.download(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { authLost(requestGeneration: gen); throw RPCError(kind: .auth, code: "auth", message: "Signed out") }
        guard (200..<300).contains(status) else {
            throw RPCError(kind: status == 404 ? .missing : .host, code: "\(status)", message: status == 404 ? "Not published on this Mac" : "The Mac answered \(status)")
        }
        return tmp
    }

    /// A plugin's own JSON route: `POST` with a plain body, answering plain JSON.
    func postJSON(_ path: String, body: JSON, timeout: TimeInterval = 20) async throws -> JSON {
        let (req, gen) = try request(path: path, method: "POST", body: body.data(), timeout: timeout)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { authLost(requestGeneration: gen); throw RPCError(kind: .auth, code: "auth", message: "Signed out") }
        let j = (try? JSON.parse(data)) ?? .null
        guard (200..<300).contains(status), j["ok"].bool != false else {
            let why = j["error"].string ?? "The Mac answered \(status)"
            throw RPCError(kind: status == 404 ? .missing : .host, code: j["error"].string ?? "\(status)", message: why)
        }
        return j
    }

    /// `workspaceFiles/readBytes` answers multipart/form-data; return the first binary part.
    /// `maxBytes` stops a download that would not fit in memory: the answer's declared length is checked before any
    /// body is read, and the body stops at the cap, so a huge file is refused as `too-large` instead of crashing the app.
    func readBytes(scope: String, path: String, maxBytes: Int? = nil) async throws -> Data {
        let args: JSON = ["workspaceFileScopeId": .string(scope), "path": .string(path), "options": [:]]
        let body: JSON = ["type": "client-request", "rpcId": .string(nextId()), "method": "workspaceFiles/readBytes", "payload": ["args": args]]
        let (req, gen) = try request(path: "/api/workspaceFiles/readBytes", body: body.data(), timeout: 60)
        let data: Data, resp: URLResponse
        if let maxBytes {
            let tooLarge = RPCError(kind: .host, code: "too-large", message: "This file is too large to preview")
            let (stream, r) = try await session.bytes(for: req)
            if r.expectedContentLength > Int64(maxBytes) { stream.task.cancel(); throw tooLarge }
            var buf = Data(); buf.reserveCapacity(Int(max(r.expectedContentLength, 0)))
            for try await byte in stream {
                buf.append(byte)
                if buf.count > maxBytes { stream.task.cancel(); throw tooLarge }
            }
            (data, resp) = (buf, r)
        } else {
            (data, resp) = try await session.data(for: req)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // This route used to read a refused sign-in as "Could not read the file"; it takes the same 401 path as the
        // other document routes, generation and all.
        if status == 401 { authLost(requestGeneration: gen); throw RPCError(kind: .auth, code: "auth", message: "Signed out") }
        guard let http = resp as? HTTPURLResponse, status == 200 else { throw RPCError(kind: .host, code: "bytes", message: "Could not read the file") }
        let ctype = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard let bRange = ctype.range(of: "boundary=") else { return data }
        let boundary = ctype[bRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard let part = Multipart.parts(data, boundary: boundary).first(where: { $0.name.hasPrefix("bytes") }) else {
            throw RPCError(kind: .host, code: "bytes", message: "The file came back empty")
        }
        return part.body
    }

    /// A fire-and-forget POST to one of the Mac's local plugin routes (the Live Activity push token).
    /// Whether the Mac took it: a 2xx answer.
    @discardableResult
    func post(_ path: String, _ body: JSON) async -> Bool {
        guard let (req, _) = try? request(path: path, body: body.data(), timeout: 15),
              let (_, resp) = try? await session.data(for: req) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
    }

    func webSocketRequest() throws -> URLRequest {
        guard let base = baseURL else { throw RPCError(kind: .auth, code: "auth", message: "Not signed in") }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.scheme = base.scheme == "https" ? "wss" : "ws"
        c.path = "/api/remote.mux"
        var r = URLRequest(url: c.url!)
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.timeoutInterval = 20
        return r
    }

    var urlSession: URLSession { session }
}

struct RPCEnvelope<T: Decodable>: Decodable {
    struct R: Decodable { let ok: Bool; let value: T? }
    let result: R
}

enum Multipart {
    struct Part { let name: String; let body: Data }
    static func parts(_ data: Data, boundary: String) -> [Part] {
        let delim = Data(("--" + boundary).utf8)
        var out: [Part] = []
        var ranges: [Range<Data.Index>] = []
        var search = data.startIndex..<data.endIndex
        while let r = data.range(of: delim, in: search) { ranges.append(r); search = r.upperBound..<data.endIndex }
        for i in 0..<max(0, ranges.count - 1) {
            var chunk = data[ranges[i].upperBound..<ranges[i + 1].lowerBound]
            if chunk.starts(with: Data("\r\n".utf8)) { chunk = chunk.dropFirst(2) }
            guard let hdrEnd = chunk.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: chunk[chunk.startIndex..<hdrEnd.lowerBound], as: UTF8.self)
            var body = chunk[hdrEnd.upperBound...]
            if body.suffix(2) == Data("\r\n".utf8) { body = body.dropLast(2) }
            var name = ""
            if let r = head.range(of: "name=\"") { name = String(head[r.upperBound...].prefix { $0 != "\"" }) }
            out.append(Part(name: name, body: Data(body)))
        }
        return out
    }
}
