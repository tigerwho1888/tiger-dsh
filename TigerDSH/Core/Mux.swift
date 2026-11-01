import Foundation
import Observation

enum ConnState: String { case connecting, live, reconnecting, offline }

/// One WebSocket carrying many host streams (`{type:"open", streamId, endpoint, payload:{args}}` →
/// `item` / `end` / `error`). Streams survive reconnects: every subscription is re-opened on a new socket,
/// and a stream the host ends is re-opened after a short pause unless it was cancelled.
@MainActor
final class Mux {
    final class Sub {
        let key: String
        let endpoint: String
        let args: JSON
        let onItem: (JSON) -> Void
        let onReset: (() -> Void)?
        let onError: ((JSON) -> Void)?
        var reopen = true
        var id: String?
        var dead = false
        init(key: String, endpoint: String, args: JSON, onItem: @escaping (JSON) -> Void, onReset: (() -> Void)?, onError: ((JSON) -> Void)?) {
            self.key = key; self.endpoint = endpoint; self.args = args; self.onItem = onItem; self.onReset = onReset; self.onError = onError
        }
    }

    private var task: URLSessionWebSocketTask?
    private var gen = 0
    private var subs: [String: Sub] = [:]
    private var byId: [String: Sub] = [:]
    private var n = 0
    private var fails = 0
    private var retryTask: Task<Void, Never>?
    private var beatTask: Task<Void, Never>?
    private var beatFails = 0
    private var provenGen = 0
    private(set) var opened = 0
    private(set) var closed = 0
    var onState: ((ConnState) -> Void)?
    private(set) var state: ConnState = .connecting { didSet { if oldValue != state { onState?(state) } } }

    /// A socket whose ping came back. Streams are asked for only then: sent earlier, a snapshot of several megabytes
    /// queued ahead of the pong, and the 6 s deadline below dropped sockets that were busy delivering (operator:
    /// build 1601 reconnected slower; Codex r154).
    private var proven: Bool { task != nil && provenGen == gen }

    @discardableResult
    func sub(_ key: String, _ endpoint: String, _ args: JSON = [:], reopen: Bool = true,
             onReset: (() -> Void)? = nil, onError: ((JSON) -> Void)? = nil, onItem: @escaping (JSON) -> Void) -> String {
        unsub(key)
        let s = Sub(key: key, endpoint: endpoint, args: args, onItem: onItem, onReset: onReset, onError: onError)
        s.reopen = reopen
        subs[key] = s
        if proven { open(s) }
        return key
    }

    func unsub(_ key: String) {
        guard let s = subs.removeValue(forKey: key) else { return }
        s.dead = true
        if let id = s.id { byId[id] = nil; send(["type": "cancel", "streamId": .string(id)]); s.id = nil }
    }

    private func open(_ s: Sub) {
        n += 1
        let id = "s\(n)"
        s.id = id; byId[id] = s
        s.onReset?()
        send(["type": "open", "streamId": .string(id), "endpoint": .string(s.endpoint), "payload": ["args": s.args]])
    }

    private func send(_ o: JSON) {
        guard let t = task else { return }
        t.send(.string(o.compact)) { _ in }
    }

    func connect() {
        if let t = task, t.state == .running { return }
        retryTask?.cancel()
        guard let req = try? DSHClient.shared.webSocketRequest() else { return }
        gen += 1
        let g = gen
        let t = DSHClient.shared.urlSession.webSocketTask(with: req)
        t.maximumMessageSize = 64 << 20
        task = t
        t.resume()
        // URLSessionWebSocketTask has no "open" callback; the first successful ping proves the socket.
        t.sendPing { [weak self] err in
            Task { @MainActor in
                // `task` too: the 6 s deadline below can drop this socket while a late pong is still on its way.
                guard let self, g == self.gen, self.task != nil else { return }
                if err != nil { self.dropped(g) } else { self.didOpen(g) }
            }
        }
        receive(t, g)
        // An attempt made while the network is still waking can hang for the request's whole 20 s. One that has not
        // answered in 6 s is dropped for a fresh one, which usually finds the network ready.
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled, g == self.gen, self.provenGen != g else { return }
            self.dropped(g)
        }
    }

    private func didOpen(_ g: Int) {
        guard provenGen != g else { return }
        opened += 1; fails = 0; provenGen = g; state = .live
        // Every stream, on this socket only: ids an earlier socket handed out mean nothing here (Codex r150). The open
        // chat's goes first, so its snapshot is not queued behind the others' baselines (Codex r152).
        byId.removeAll()
        for s in subs.values { s.id = nil }
        if let chat = subs["chat"] { open(chat) }
        for (k, s) in subs where k != "chat" { open(s) }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ g: Int) {
        t.receive { [weak self] result in
            switch result {
            case .failure:
                Task { @MainActor in
                    guard let self, g == self.gen else { return }
                    self.dropped(g)
                }
            case .success(let msg):
                let data: Data
                switch msg { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: data = Data() }
                // Parsed here, on the socket's own queue, and not on the main actor: a session snapshot can be
                // tens of megabytes and decoding it on the main thread was the largest single main-actor cost in
                // the app. The parsed frame is Sendable, so only the cheap handling hops over — and the next
                // receive is still issued after this frame is handled, so frames keep their order.
                let frame = try? JSON.parse(data)
                Task { @MainActor in
                    // `task` too: a frame already in flight when the socket was dropped must not keep reading it.
                    guard let self, g == self.gen, self.task === t else { return }
                    if let frame { self.handle(frame) }
                    self.receive(t, g)
                }
            }
        }
    }

    private func handle(_ f: JSON) {
        guard let sid = f["streamId"].string, let s = byId[sid] else { return }
        switch f["type"].str {
        case "item": s.onItem(f["value"])
        case "error":
            byId[sid] = nil; s.id = nil
            // A stream with no handler of its own (the global ones) has nobody to show the error to, and was left
            // closed on a socket that still looked live — running chats kept spinning (Codex r132). It retries, slower
            // than after an `end` so a stream that keeps failing does not spin.
            if let h = s.onError { h(f["error"]) } else { reopenLater(s, ms: 5000) }
        case "end":
            byId[sid] = nil; s.id = nil
            reopenLater(s, ms: 800)
        default: break
        }
    }

    private func reopenLater(_ s: Sub, ms: Int) {
        guard !s.dead && s.reopen else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard let self, !s.dead, s.id == nil, self.proven, self.subs[s.key] === s else { return }
            self.open(s)
        }
    }

    private func dropped(_ g: Int) {
        // Once per socket: its failed receive and failed ping both land here, and counting both doubled the backoff.
        guard g == gen, task != nil else { return }
        closed += 1
        task?.cancel(with: .goingAway, reason: nil); task = nil
        for s in subs.values { if let id = s.id { byId[id] = nil }; s.id = nil }
        fails += 1
        retry()
    }

    private func retry() {
        state = fails >= 3 ? .offline : .reconnecting
        retryTask?.cancel()
        // The first retry goes at once: a socket that dies is usually just stale, and the next one connects.
        let wait = fails <= 1 ? 0 : min(8.0, 0.4 * pow(1.7, Double(fails))) * Double.random(in: 0.8...1.2)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    /// iOS can leave a dead socket behind after sleep; drop it and reconnect at once.
    func recycle() {
        gen += 1
        task?.cancel(with: .goingAway, reason: nil); task = nil
        for s in subs.values { if let id = s.id { byId[id] = nil }; s.id = nil }
        fails = 0; state = .reconnecting
        connect()
    }

    func stop() {
        gen += 1
        retryTask?.cancel(); beatTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil); task = nil
        for s in subs.values { s.dead = true }
        subs.removeAll(); byId.removeAll()
        // A stopped mux is not live. Leaving the last state behind meant the next connect() was not a change, so
        // nothing that waits on a state change — the chat list's fetch above all — ever heard that the socket was up.
        state = .offline
    }

    /// The mux carries streams only, so liveness is checked with a cheap HTTP call every 8 s.
    func startBeat(active: @escaping @MainActor () -> Bool) {
        beatTask?.cancel()
        beatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled else { return }
                guard active() else { continue }
                do {
                    try await DSHClient.shared.rpc("session/canOpenWorkspacePath", [:], timeout: 6)
                    self.beatFails = 0
                    if self.task == nil || self.task?.state != .running { self.fails = 0; self.connect() }
                    else if self.state == .offline { self.state = .live }
                } catch let e as RPCError where e.kind == .auth {
                    continue
                } catch let e as RPCError where e.kind == .host {
                    self.beatFails = 0  // the host answered; an arguments error is still a live host
                    if self.task == nil { self.fails = 0; self.connect() }
                } catch let e as RPCError where e.kind == .missing {
                    self.beatFails = 0  // a 404 means the host answered too: it simply lacks this call
                    if self.task == nil { self.fails = 0; self.connect() }
                } catch {
                    self.beatFails += 1
                    if self.beatFails >= 2 { self.state = .offline; if self.task != nil { self.recycle() } }
                }
            }
        }
    }
}
