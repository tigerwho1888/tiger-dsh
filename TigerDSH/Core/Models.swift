import Foundation

struct ModelChoice: Codable, Equatable, Hashable, Sendable {
    var provider: String
    var model: String
    var effort: String

    init(provider: String, model: String, effort: String) { self.provider = provider; self.model = model; self.effort = effort }

    /// `{next, lastUsed}` on the session's `modelSelection` projection.
    init?(selection v: JSON) {
        let x = v["next"].isObject ? v["next"] : v["lastUsed"]
        guard x.isObject else { return nil }
        provider = x["provider"].str; model = x["model"].str; effort = x["reasoningEffort"].str
    }

    var short: String {
        var m = model
        // The provider's own prefix never belongs in the pill: a catalogue id like "deepseek/deepseek-v4.1-flash"
        // reads as "v4.1-flash", which is what the reference's pill shows (C seq 23368).
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        if m.hasPrefix("deepseek-") { m.removeFirst(9) }
        if m.hasPrefix("minimax-") { m = "minimax " + m.dropFirst(8) }
        return m
    }
    var label: String { effort.isEmpty ? short : "\(short) · \(effort)" }
}

/// One chat in the list. Everything else the host sends about a session is ignored here.
struct SessionRow: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var updated: Double
    var running: Bool
    var blank: Bool
    var isSub: Bool
    var cwd: String
    var title: String
    var questions: Int
    var model: ModelChoice?
    var snippet: String

    var displayTitle: String { title.isEmpty || title == id ? "Untitled" : title }

    /// The one-line snippet a chat row shows: markdown out, whitespace collapsed, 120 VISIBLE characters.
    ///
    /// A scanner rather than three regex passes over a growing prefix of the reply. The prefix version finalized
    /// whatever its bound had cut through: a link label that ran past the piece came out as "[" plus as much of the
    /// label as fitted, so the row read "[xxxx…" where the reply said "xxxx…" (Codex R8 P3). The scanner holds the
    /// token state instead — a label is only visible once its closing `]` is in hand, and the destination behind `](`
    /// is skipped without being counted — and it stops as soon as the hundred-and-twentieth visible character is in
    /// hand, so a normal reply is walked to roughly that character and no further. The regexes it replaces ran over
    /// every byte of the head in growing pieces — measured in-process at 1.05 ms for a 30 KB reply against 0.11 ms
    /// for a 3 KB one (R8) — once per session on every `session/control` frame, on the main actor, exactly while a
    /// chat list lands.
    static func plain(_ t: String) -> String {
        strippedPrefix(t, limit: 120)
    }

    /// What the snippet strips, as one set: the emphasis, heading, quote, table and strikethrough marks the old
    /// `[#*_`>|~]+` pass removed. Code spans are not special-cased — their backticks are in here, which is all the
    /// old pass did. Characters, not scalars: a mark is one character either way, and a character is what the limit
    /// counts.
    private static let marks: Set<Character> = Set("#*_`>|~")

    /// The first `limit` visible characters of `t`, with markdown out and whitespace runs collapsed to one space.
    ///
    /// States, in one pass: ordinary text is emitted as it is read; a `[` opens a label, whose characters are emitted
    /// as the label's text; a `]` closes it, and a `(` right behind the `]` opens a destination that is skipped
    /// whole. A label that never closes keeps its "[" — the literal reading a markdown renderer would show — and a
    /// newline inside one ends it the same way, because the old pattern could not cross a line either. The limit is
    /// only checked OUTSIDE a token, so a label the bound cuts through is read to its closing bracket before the
    /// snippet is finalized.
    ///
    /// The walk is by `Character` — one user-perceived character, which is what `String.count` counts and what the
    /// limit means — so the bound can never fall inside one: appending scalars and checking the count after each cut
    /// the combining accent off "e\u{301}" and left a lone 👩 where a ZWJ family belongs (Codex R9 P3).
    private static func strippedPrefix(_ t: String, limit: Int) -> String {
        var out = ""
        // Where the current link's label opened in `out`, for the "[" an unfinished one needs back — and whether a
        // space was pending then, because that space is emitted with the bracket if no visible character of the label
        // ever resolved it.
        var labelAt: Int?
        var labelSpace = false
        /// Whether any visible character of the current label has been emitted: that is what resolves the space the
        /// label opened behind, and a space still pending after it is a different one (the label's own trailing run).
        var labelEmitted = false
        var inDestination = false
        // A whitespace run is pending: it becomes one space if any visible character follows it.
        var space = false
        var i = t.startIndex
        func openLabel() {
            labelAt = out.count
            labelSpace = space && !out.isEmpty
            labelEmitted = false
        }
        // An unfinished (or newline-cancelled) label keeps its "[" — the literal reading a markdown renderer shows.
        // It goes before the pending space if that space was never resolved, and after it if it was.
        func restoreBracket() {
            guard let at = labelAt else { return }
            let unresolved = labelSpace && !labelEmitted
            let text = unresolved ? " [" : "["
            let place = min(at + (labelSpace && labelEmitted ? 1 : 0), out.count)
            if unresolved { space = false }
            out.insert(contentsOf: text, at: out.index(out.startIndex, offsetBy: place))
            labelAt = nil
            labelSpace = false
            labelEmitted = false
        }
        while i < t.endIndex {
            let c = t[i]
            i = t.index(after: i)
            if inDestination {
                // A destination is skipped whole and never counted. A `)` ends it; a newline says the `(` was not a
                // link's destination after all, and what follows is ordinary prose.
                if c == ")" { inDestination = false } else if c == "\n" { inDestination = false; space = true }
                continue
            }
            if c == "]", labelAt != nil {
                // Complete: what has already been emitted IS the label, and its "[" was never written.
                labelAt = nil
                labelSpace = false
                labelEmitted = false
                if i < t.endIndex, t[i] == "(" { inDestination = true; i = t.index(after: i) }
            } else if c == "[", labelAt == nil {
                openLabel()
            } else if c == "!", labelAt == nil, i < t.endIndex, t[i] == "[" {
                i = t.index(after: i)
                openLabel()
            } else if c == "\n" {
                restoreBracket()
                space = true
            } else if c.isWhitespace {
                space = true
            } else if !marks.contains(c) {
                if space, !out.isEmpty { out.append(" ") }
                space = false
                if labelAt != nil { labelEmitted = true }
                out.append(c)
            }
            if labelAt == nil, !inDestination, out.count >= limit { break }
        }
        restoreBracket()
        return String(out.prefix(limit))
    }

    init(id: String, updated: Double = Date().timeIntervalSince1970 * 1000, running: Bool = false, blank: Bool = false, isSub: Bool = false,
         cwd: String = "", title: String = "", questions: Int = 0, model: ModelChoice? = nil, snippet: String = "") {
        self.id = id; self.updated = updated; self.running = running; self.blank = blank; self.isSub = isSub
        self.cwd = cwd; self.title = title; self.questions = questions; self.model = model; self.snippet = snippet
    }

    /// From a loosely typed list item (events such as `api-session/added`).
    init(item it: JSON) {
        let v = it["projections"]["values"]
        let lt = v["turnOutline"].array.last
        self.init(id: it["sessionId"].str, updated: it["updatedAt"].double ?? 0, running: it["running"].truthy, blank: it["blank"].truthy,
                  isSub: it["origin"].str == "subagent" || it["parentSessionId"].truthy, cwd: it["cwd"].str, title: v["title"].str,
                  questions: v["userQuestions"]["active"].array.count, model: ModelChoice(selection: v["modelSelection"]),
                  snippet: lt.map { SessionRow.plain($0["response"].string.flatMap { $0.isEmpty ? nil : $0 } ?? $0["prompt"].str) } ?? "")
    }

    mutating func apply(projection key: String, value: JSON) {
        switch key {
        case "title": title = value.str
        case "userQuestions": questions = value["active"].array.count
        case "modelSelection": model = ModelChoice(selection: value)
        case "sessionListMetadata": blank = value["blank"].truthy
        case "turnOutline":
            // #639's temporary wire marker lived here: it serialized every turnOutline projection and wrote it to the
            // signpost log to prove the shape before the readers were fixed. The readers below read it, so the marker
            // is gone — it cost a JSON encode per projection on the main actor (0.04 ms, R8) and filled the very log
            // this project measures itself with.
            if let lt = value.array.last { snippet = SessionRow.plain(lt["response"].string.flatMap { $0.isEmpty ? nil : $0 } ?? lt["prompt"].str) } else { snippet = "" }
        default: break
        }
    }
}

/// Typed decoding of `session/list`, which on a busy Mac is 10+ MB: only the fields above are kept.
struct SessionListValue: Decodable, Sendable {
    let rows: [SessionRow]

    private struct Item: Decodable {
        let sessionId: String
        let updatedAt: Double?
        let running: Bool?
        let blank: Bool?
        let origin: String?
        let parentSessionId: String?
        let cwd: String?
        let projections: Proj?
        struct Proj: Decodable { let values: Vals? }
        struct Vals: Decodable {
            let title: String?
            let userQuestions: UQ?
            let modelSelection: MS?
            let turnOutline: LastTurn?
        }
        struct UQ: Decodable { let active: [Ignored]? }
        struct Ignored: Decodable { init(from decoder: Decoder) throws {} }
        struct Sel: Decodable { let provider: String?; let model: String?; let reasoningEffort: String? }
        struct MS: Decodable { let next: Sel?; let lastUsed: Sel? }
        struct Turn: Decodable { let prompt: String?; let response: String? }
        /// Only the last turn feeds the snippet: the earlier ones are stepped over without building their prompt and
        /// response strings, which across 3,800 chats were most of what the list decoded.
        struct LastTurn: Decodable {
            let turn: Turn?
            init(from decoder: Decoder) throws {
                var a = try decoder.unkeyedContainer()
                guard let n = a.count, n > 0 else { turn = nil; return }
                for _ in 1..<n { _ = try a.decode(Ignored.self) }
                turn = try a.decode(Turn.self)
            }
        }
    }

    private enum K: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        var arr = try c.nestedUnkeyedContainer(forKey: .items)
        var out: [SessionRow] = []
        if let n = arr.count { out.reserveCapacity(n) }
        while !arr.isAtEnd {
            guard let it = try? arr.decode(Item.self) else { _ = try? arr.decode(Item.Ignored.self); continue }
            let v = it.projections?.values
            let sel = v?.modelSelection.flatMap { $0.next ?? $0.lastUsed }
            let lt = v?.turnOutline?.turn
            let snippetSrc = (lt?.response).flatMap { $0.isEmpty ? nil : $0 } ?? lt?.prompt ?? ""
            out.append(SessionRow(id: it.sessionId, updated: it.updatedAt ?? 0, running: it.running ?? false, blank: it.blank ?? false,
                                  isSub: it.origin == "subagent" || (it.parentSessionId?.isEmpty == false), cwd: it.cwd ?? "",
                                  title: v?.title ?? "", questions: v?.userQuestions?.active?.count ?? 0,
                                  model: sel.map { ModelChoice(provider: $0.provider ?? "", model: $0.model ?? "", effort: $0.reasoningEffort ?? "") },
                                  snippet: SessionRow.plain(snippetSrc)))
        }
        rows = out
    }
}

struct Workspace: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var path: String
    var createdAt: String
    var sessionIds: [String]

    init(_ j: JSON) {
        id = j["workspaceId"].str; title = j["title"].str; path = j["path"].str; createdAt = j["createdAt"].str
        sessionIds = j["sessionIds"].array.compactMap { $0.string }
    }

    var label: String {
        if title == "default-workspace" { return "Default" }
        if !title.isEmpty { return title }
        return (path as NSString).lastPathComponent
    }
}

enum Fmt {
    /// Token counts read as "980", "145.8k", "1.3M".
    static func count(_ n: Double) -> String {
        if n < 1000 { return String(Int(n)) }
        if n < 1_000_000 { return String(format: n < 10_000 ? "%.1fk" : "%.0fk", n / 1000) }
        return String(format: "%.1fM", n / 1_000_000)
    }

    static func ago(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let s = max(0, Date().timeIntervalSince1970 - ms / 1000)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 86400 * 7 { return "\(Int(s / 86400))d" }
        return Date(timeIntervalSince1970: ms / 1000).formatted(.dateTime.month(.abbreviated).day())
    }
    /// The long form the Chats page's rows use, the way the reference writes it: "2 minutes ago", "3 hours ago",
    /// then a date once a week has passed.
    static func agoLong(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        let s = max(0, Date().timeIntervalSince1970 - ms / 1000)
        if s < 60 { return "just now" }
        if s < 3600 { let n = Int(s / 60); return "\(n) minute\(n == 1 ? "" : "s") ago" }
        if s < 86400 { let n = Int(s / 3600); return "\(n) hour\(n == 1 ? "" : "s") ago" }
        if s < 86400 * 7 { let n = Int(s / 86400); return "\(n) day\(n == 1 ? "" : "s") ago" }
        return Date(timeIntervalSince1970: ms / 1000).formatted(.dateTime.month(.abbreviated).day())
    }

    static func agoISO(_ iso: String) -> String {
        guard let d = parseISO(iso) else { return "" }
        let a = ago(d.timeIntervalSince1970 * 1000)
        return a == "now" ? "just now" : a + " ago"
    }
    // Built once each: this is called per row for job and session timestamps, and a fresh
    // ISO8601DateFormatter per call was pure waste. ISO8601DateFormatter parses on any thread, which is all these
    // are used for.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func parseISO(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds)); let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
    }
    static func hhmm(_ ms: Double) -> String {
        guard ms > 0 else { return "" }
        // A format style, not a new DateFormatter per row (Codex r164).
        return Date(timeIntervalSince1970: ms / 1000).formatted(date: .omitted, time: .shortened)
    }
    static func bytes(_ n: Double) -> String {
        n < 1024 ? "\(Int(n)) B" : n < 1048576 ? "\(Int(n / 1024)) KB" : String(format: "%.1f MB", n / 1048576)
    }
    static func when(_ iso: String) -> String {
        guard let d = parseISO(iso) else { return iso }
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE MMM d h:mm a")
        return f.string(from: d)
    }
    static func base(_ p: String) -> String { (p as NSString).lastPathComponent }
}
