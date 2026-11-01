import Foundation
import Observation

enum Block: Codable, Equatable, Sendable {
    case text(String)
    case think(String)
    case tool(callId: String, name: String, args: String)

    var isTool: Bool { if case .tool = self { return true }; return false }
    var text: String? { if case .text(let t) = self { return t }; return nil }
}

struct WFMember: Codable, Equatable, Sendable { var seq: Int; var label: String; var phase: String?; var childId: String; var outcome: String? }

/// One row of the conversation. `v` bumps whenever the row's look changes, so the list redraws only that row.
struct ChatItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case user, pending, assistant, live, error, retry, changes, workflow, note, deliverables, group }
    var key: String
    var kind: Kind
    var seq: Int = 0
    var time: Double = 0
    var v: Int = 1
    var text: String = ""
    var messageId: String = ""
    var turn: Int = 0
    var step: Int = 0
    var blocks: [Block] = []
    var images: Int = 0
    var files: [String] = []
    var rpc: String = ""
    var state: String = ""          // pending: sending/failed; retry: scheduled/started/cancelled
    var attemptError = false
    var retry = 0, maxRetries: Int? = nil, delayMs = 0.0
    var runId = ""
    var name = ""
    var members: [WFMember] = []
    var stopReason: String? = nil
    var interrupted = false
    var deliverables: [Deliverable] = []
    var groupId: String = ""        // set on members of a folded process group
    var groupLive = false
    var groupMembers: [String] = []

    var id: String { key }

    struct Deliverable: Codable, Equatable, Sendable { var path: String; var description: String }
}

struct ToolResult: Codable, Equatable, Sendable { var text: String; var isError: Bool }

/// The open conversation. Built from `session/follow`: a snapshot of recent records, then live events and
/// the assistant's token stream. The reducer mirrors the web app's, which mirrored the desktop's.
@MainActor @Observable
final class ChatModel: Identifiable {
    let id: String              // the chat (or the parent, for a subagent)
    let child: String           // subagent child id, or ""
    var sid: String { child.isEmpty ? id : child }

    var items: [ChatItem] = []
    var results: [String: ToolResult] = [:]
    var ends: [Int: Int] = [:]          // turn -> seq of turn/end
    var starts: [Int: Int] = [:]
    var deliverables: [ChatItem.Deliverable] = []
    var proj: [String: JSON] = [:]
    /// The reply as it streams. Its words reach the screen through the live row's own view, which reads this; the
    /// row LIST only changes with `liveShape`, so a streamed flush no longer rebuilds every row of a long chat.
    var stream: [Block]? = nil {
        didSet { displayStream = stream; let s = Self.liveShape(stream); if s != liveShape { liveShape = s } }
    }
    /// `stream` unobserved, for the row list's rebuild: reading `stream` there made the chat screen's body depend on
    /// every streamed flush again (r166).
    @ObservationIgnored private var displayStream: [Block]?
    /// What the row list needs to know about the stream, and nothing more: none, started but empty, process-only
    /// (folds into the step group above it), or carrying an answer. It changes a few times a turn, where `stream`
    /// changes up to 25 times a second — and each of those used to copy and fold the whole conversation and run the
    /// chat screen's body over every row, which is the stutter scrolling a long running chat (operator, 2026-10-14).
    private(set) var liveShape = 0
    var streamError = ""
    var streamVersion = 0
    var pending: [ChatItem] = [] { didSet { pendingVersion &+= 1 } }
    var hasMore = false
    var cursor = -1
    var firstSeq = Int.max
    /// How many event records this model has been handed. A page's `items` can be empty while the page still carries
    /// state — `turn/start`, `turn/end` and `tool/result` fill `starts`, `ends` and `results` without pushing a row —
    /// so this, and not `items.count`, is what says whether a fetched page held anything at all (Codex R6 P2).
    private(set) var events = 0
    var loading = true
    var stale = false
    var error = ""
    var running = false
    var turnStart: Date?
    var policy = ""
    var header: JSON = .null
    var feedback: [String: JSON] = [:]
    var changes: [Int: JSON] = [:]      // seq -> summary, or .string("err") / .string("wait")
    /// Bumped by every snapshot. A snapshot empties `changes`, but a change chip keeps its row and so never runs its
    /// load again: it keys its load on this, or it says "Checking changes…" for good after the next reconnect.
    private(set) var snapshots = 0
    var mode = ""                       // subagent mode
    var draft: String
    var loadingMore = false

    /// Bumped by every write to `items` — appending a record, a row's in-place update (`bump`), a removal, and the
    /// two paging inserts. It is what invalidates `display`, and it is read only for that: the version and not the
    /// array, so a body pass that changes nothing is not O(rows) any more.
    private var itemsVersion = 0
    /// The same thing for `pending`, whose every write (`append`, an element's state, `removeAll`) is a `didSet`.
    private var pendingVersion = 0
    /// The last row list and the signature that produced it. The invalidation, and nothing else, is `displayKey`.
    @ObservationIgnored private var displayCache: (key: String, rows: [ChatItem])?

    @ObservationIgnored private var calls: [String: String] = [:]
    @ObservationIgnored private var callItem: [String: String] = [:]   // callId -> item key
    @ObservationIgnored private var retries: [String: String] = [:]    // retryId -> item key
    @ObservationIgnored private var workflows: [String: String] = [:]  // runId -> item key
    @ObservationIgnored private var curTurn = 0
    @ObservationIgnored private var turnErr = false
    /// How many failed-attempt cards the list holds. Almost always zero, and `dropAttemptErrors` runs for every
    /// request and reply a snapshot replays, so the count lets it skip a pass over every row: on a chat of thousands of
    /// rows those passes made opening it quadratic.
    @ObservationIgnored private var attemptErrs = 0
    @ObservationIgnored private var liveBuf: [Block]? = nil
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored var address: JSON = .null

    /// `app` is optional so a model can be built without the app behind it: the page models `fetchBatch` reduces are
    /// throwaways that never speak to the app, and the paging unit tests build the same shape without one.
    init(id: String, child: String = "", app: AppModel? = nil) {
        self.id = id; self.child = child; self.app = app
        draft = UserDefaults.standard.string(forKey: "draft." + (child.isEmpty ? id : child)) ?? ""
        running = app?.rows[child.isEmpty ? id : child]?.running ?? false
    }

    // MARK: open / close

    func enter() {
        guard let app else { return }
        if !child.isEmpty { mode = app.subagentMode(parent: id, child: child) }
        address = child.isEmpty
            ? ["kind": "session", "sessionId": .string(id)]
            : ["kind": "subagent", "parentSessionId": .string(id), "childSessionId": .string(child), "mode": .string(mode)]
        app.currentChat = self
        // A model kept while away missed the status frames: the list row is the latest word on whether it runs (r142).
        rowSync()
        // Reopening the chat that was already picked does not change `currentChatID`, whose setter is what marks it read.
        app.doneUnseen.remove(sid)
        app.syncRunActivity()
        app.mux.sub("chat", "session/follow", ["request": ["address": address, "assistantStream": true, "maxMessages": 24]],
                    onError: { [weak self] e in self?.streamFailed(e) }) { [weak self] f in self?.frame(f) }
        if app.can("feedback") { Task { await loadFeedback() } }
    }

    func leave() {
        guard let app else { return }
        if app.currentChat === self {
            app.mux.unsub("chat"); app.currentChat = nil
            // Only when this chat was the one on screen: a swap leaves the new chat's own `enter` to speak, and the
            // old model must not end an activity the new one just started.
            app.syncRunActivity()
        }
        // Cleared, not only cancelled: a model entered again would otherwise hold back its live text (Codex r142).
        flushTask?.cancel(); flushTask = nil
        if pending.contains(where: { $0.state != "sent" }) { app.parked[child.isEmpty ? id : id + "/" + child] = self }
    }

    private func streamFailed(_ e: JSON) {
        loading = false
        let m = e["message"].string ?? "Could not open this chat"
        error = (e["code"].str + m).range(of: "not.found|missing", options: [.regularExpression, .caseInsensitive]) != nil
            ? "This chat no longer exists on the Mac." : m
        // The head row sits above the loaded messages, out of view at the bottom of a long chat.
        if !items.isEmpty { app?.say(error) }
    }

    // MARK: frames

    private func frame(_ f: JSON) {
        Trace.mark("chat.frame", f["type"].str)
        switch f["type"].str {
        case "snapshot":
            Trace.mark("chat.snapshot", "\(f["records"].array.count) records")
            resetState()
            header = f["header"]; cursor = f["cursor"].int ?? -1; hasMore = f["hasMore"].truthy
            for rec in f["records"].array where rec["event"].isObject { reduce(rec["event"], live: false) }
            cursor = max(cursor, f["cursor"].int ?? 0)
            stream = nil; liveBuf = nil; loading = false; stale = false; error = ""
            pending.removeAll { $0.state == "sent" }
            for (k, v) in f["projections"]["values"].object { setProj(k, v) }
            let att = f["assistantStream"]["activeAttempt"]
            if att.isObject {
                var blocks: [Block] = []
                for rec in att["stream"].array { Self.applyRecord(&blocks, rec, err: &streamError) }
                stream = blocks; liveBuf = blocks
            }
            var ts: Double?
            for rec in f["records"].array { let e = rec["event"]; if e["type"].str == "turn/start" { ts = e["time"].double } else if e["type"].str == "turn/end" { ts = nil } }
            if let ts { turnStart = Date(timeIntervalSince1970: ts / 1000) } else if !running { turnStart = nil }
            // The snapshot carries the run's own start and the projections the island's title and step are read
            // from, so it is a change to what the island shows like any other.
            app?.syncRunActivity()
        case "event":
            // The durable half of the stream: `session/follow` sends one of these per committed event, the same shape
            // the snapshot's records carry (SessionFollowFrame = snapshot | event | assistant-stream). Without this
            // branch a reply vanished when its stream ended, and user messages, tool results, errors and deliverables
            // never entered the transcript at all until the chat was reopened.
            // One the snapshot already carried is skipped: reducing it twice pushes a second row under the same key.
            if let s = f["event"]["seq"].int, s > 0, s <= cursor { break }
            reduce(f["event"], live: true)
            app?.syncRunActivity()
        case "assistant-stream":
            streamFrame(f["frame"])
        default: break
        }
    }

    func resetState() {
        snapshots &+= 1
        items = []; results = [:]; ends = [:]; starts = [:]; deliverables = []; changes = [:]
        calls = [:]; callItem = [:]; retries = [:]; workflows = [:]; firstSeq = .max; events = 0; turnErr = false; attemptErrs = 0
        itemsVersion &+= 1
    }

    // MARK: assistant token stream (throttled: at most ~10 redraws a second — each one re-lays the live answer out, and
    // fewer of them is less of the per-frame work the 10-14/15 crashes died in)

    private func streamFrame(_ fr: JSON) {
        switch fr["type"].str {
        case "start":
            liveBuf = []; streamError = ""; publishLive(now: true)
        case "chunk":
            if liveBuf == nil { liveBuf = [] }
            Self.applyChunk(&liveBuf!, fr["chunk"], err: &streamError)
            publishLive(now: false)
        case "end":
            liveBuf = nil; publishLive(now: true)
        default: break
        }
    }

    /// The one-line answer to "what is it doing", for the Live Activity. The last live block's kind, said the way a
    /// reader would say it.
    var activityStep: String {
        guard let b = stream?.last else { return "Working" }
        switch b {
        case .think: return "Thinking"
        case .text: return "Writing"
        case .tool(_, let name, _): return "Running \(name)"
        }
    }

    private func publishLive(now: Bool) {
        if now { flushTask?.cancel(); flushTask = nil; stream = liveBuf; streamVersion &+= 1; app?.syncRunActivity(); return }
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.stream = self.liveBuf; self.streamVersion &+= 1
            self.app?.syncRunActivity()
        }
    }

    static func applyRecord(_ blocks: inout [Block], _ rec: JSON, err: inout String) {
        switch rec["type"].str {
        case "text-chunks": blocks.append(.text(rec["texts"].array.map(\.str).joined()))
        case "reasoning-chunks": blocks.append(.think(rec["texts"].array.map(\.str).joined()))
        case "tool-call-chunks": blocks.append(.tool(callId: rec["id"].str, name: rec["name"].str, args: rec["args"].array.map(\.str).joined()))
        case "chunk": applyChunk(&blocks, rec["chunk"], err: &err)
        default: break
        }
    }

    static func applyChunk(_ blocks: inout [Block], _ ch: JSON, err: inout String) {
        switch ch["type"].str {
        case "text-delta":
            if case .text(let t)? = blocks.last { blocks[blocks.count - 1] = .text(t + ch["text"].str) } else { blocks.append(.text(ch["text"].str)) }
        case "reasoning-delta":
            if case .think(let t)? = blocks.last { blocks[blocks.count - 1] = .think(t + ch["text"].str) } else { blocks.append(.think(ch["text"].str)) }
        case "tool-call-delta":
            let cid = ch["id"].str
            if let i = blocks.lastIndex(where: { if case .tool(let c, _, _) = $0 { return c == cid }; return false }),
               case .tool(_, let name, let args) = blocks[i] {
                blocks[i] = .tool(callId: cid, name: ch["name"].string ?? name, args: args + ch["argumentsDelta"].str)
            } else {
                blocks.append(.tool(callId: cid, name: ch["name"].str, args: ch["argumentsDelta"].str))
            }
        case "finish":
            if ch["reason"]["kind"].str == "error" { err = ch["reason"]["failure"]["message"].string ?? "The model call failed" }
        default: break
        }
    }

    // MARK: reducer

    private func idx(_ key: String) -> Int? { items.lastIndex { $0.key == key } }
    private func bump(_ key: String, _ f: (inout ChatItem) -> Void) {
        if let i = idx(key) { f(&items[i]); items[i].v += 1; itemsVersion &+= 1 }
    }

    static func plainText(_ content: JSON) -> String { content.array.filter { $0["type"].str == "text" }.map { $0["text"].str }.joined(separator: "\n") }

    /// Drops the failed-attempt cards and retry rows `match` picks: a later endpoint in the fallback chain answered, so
    /// none of them was the run's last word (operator, 2026-10-15: "Reveal them all together when all end points in the
    /// chain fail" — until the turn ends on a failure they stay hidden, see `display`).
    private func dropAttemptErrors(_ match: (ChatItem) -> Bool) {
        guard attemptErrs > 0 else { return }
        let n = items.count
        items.removeAll { $0.attemptError && match($0) }
        guard items.count != n else { return }
        itemsVersion &+= 1; attemptErrs = max(0, attemptErrs - (n - items.count))
        turnErr = items.contains { $0.kind == .error && $0.attemptError && $0.turn == curTurn }
    }

    func reduce(_ ev: JSON, live: Bool) {
        let d = ev["data"]
        let seq = ev["seq"].int ?? 0
        events += 1
        firstSeq = min(firstSeq, seq)
        cursor = max(cursor, seq)
        func push(_ it: ChatItem) { var it = it; it.seq = seq; it.time = ev["time"].double ?? 0; items.append(it); itemsVersion &+= 1 }
        switch ev["type"].str {
        case "user/message":
            let src = d["source"]
            guard src["kind"].str == "user" else { break }
            let text = Self.plainText(d["content"])
            let imgs = d["content"].array.filter { $0["type"].str == "image" }.count
            let files = d["content"].array.filter { $0["type"].str == "file" }.map { $0["attachment"]["name"].string ?? $0["attachment"]["fileName"].string ?? "File" }
            if live, let i = pending.firstIndex(where: { $0.rpc == src["rpcId"].str }) { pending.remove(at: i) }
            if text.range(of: #"^\s*<goal_round[\s>]"#, options: [.regularExpression, .caseInsensitive]) != nil {
                push(ChatItem(key: "u\(seq)", kind: .note, text: "Goal round")); break
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imgs > 0 || !files.isEmpty else { break }
            proj["todos"] = .null   // a new request from the person ends the carried task list (see setProj)
            push(ChatItem(key: "u\(seq)", kind: .user, text: text, messageId: d["id"].str, turn: curTurn, images: imgs, files: files, rpc: src["rpcId"].str))
        case "request/header":
            // Provider fallback (chat 21d3b032, 2026-10-13): a 429 attempt, then at once a new request to the next
            // provider in the same turn. Its card waits, hidden, for the answer that drops it or the end that shows it.
            break
        case "assistant/message":
            let msg = d["message"]
            dropAttemptErrors { $0.turn == (d["turn"].int ?? -1) && $0.step == (d["step"].int ?? -1) }
            var blocks: [Block] = []
            for b in msg["content"].array {
                switch b["type"].str {
                case "text": blocks.append(.text(b["text"].str))
                case "reasoning": blocks.append(.think(b["text"].str))
                case "tool-call": blocks.append(.tool(callId: b["id"].str, name: b["name"].str, args: b["arguments"].string ?? b["arguments"].compact))
                default: break
                }
            }
            let key = "a\(seq)"
            push(ChatItem(key: key, kind: .assistant, messageId: msg["id"].str, turn: d["turn"].int ?? curTurn, blocks: blocks))
            for b in blocks { if case .tool(let cid, _, _) = b { callItem[cid] = key } }
            if live { liveBuf = nil; stream = nil; streamVersion &+= 1 }
        case "assistant/attempt":
            var e = ""
            for rec in d["stream"].array where rec["type"].str == "chunk" {
                let ch = rec["chunk"]; if ch["type"].str == "finish" && ch["reason"]["kind"].str == "error" { e = ch["reason"]["failure"]["message"].string ?? "The model call failed" }
            }
            if !e.isEmpty { turnErr = true; attemptErrs += 1; push(ChatItem(key: "e\(seq)", kind: .error, text: e, turn: d["turn"].int ?? 0, step: d["step"].int ?? 0, attemptError: true)) }
        case "llm/retry":
            let turn = d["turn"].int ?? 0, step = d["step"].int ?? 0
            let rid = d["retryId"].str
            if let k = retries[rid] {
                bump(k) { $0.retry = d["retry"].int ?? 0; $0.maxRetries = d["maxRetries"].int; $0.delayMs = d["delayMs"].double ?? 0; $0.text = d["failure"]["message"].str; $0.state = "scheduled" }
            } else {
                attemptErrs += 1
                push(ChatItem(key: "r" + rid, kind: .retry, text: d["failure"]["message"].str, turn: turn, step: step, state: "scheduled", attemptError: true, retry: d["retry"].int ?? 0, maxRetries: d["maxRetries"].int, delayMs: d["delayMs"].double ?? 0))
                retries[rid] = "r" + rid
            }
        case "llm/retry-started":
            if let k = retries[d["retryId"].str] { bump(k) { $0.state = "started" } }
        case "workspace/changes":
            push(ChatItem(key: "g\(seq)", kind: .changes, turn: d["turn"].int ?? 0))
        case "tool-workflow/run-start":
            let rid = d["runId"].str
            push(ChatItem(key: "w" + rid, kind: .workflow, turn: curTurn, runId: rid, name: d["name"].str))
            workflows[rid] = "w" + rid
        case "tool-workflow/agent-start":
            if let k = workflows[d["runId"].str] {
                bump(k) { $0.members.append(WFMember(seq: d["seq"].int ?? 0, label: d["label"].str, phase: d["phase"].string, childId: d["childId"].str, outcome: nil)) }
            }
        case "tool-workflow/agent-end":
            if let k = workflows[d["runId"].str] { bump(k) { it in if let i = it.members.firstIndex(where: { $0.seq == d["seq"].int }) { it.members[i].outcome = d["outcome"].string } } }
        case "tool-workflow/run-end":
            if let k = workflows[d["runId"].str] { bump(k) { $0.stopReason = d["stopReason"].string } }
        case "tool/call":
            calls[d["callId"].str] = d["name"].str
        case "tool/result":
            let m = d["message"]
            let cid = m["toolCallId"].str
            results[cid] = ToolResult(text: Self.plainText(m["content"]), isError: m["isError"].truthy)
            if let k = callItem[cid] { bump(k) { _ in } }
        case "turn/start":
            curTurn = d["turn"].int ?? curTurn
            starts[curTurn] = seq
            if live { turnStart = Date(timeIntervalSince1970: (ev["time"].double ?? Date().timeIntervalSince1970 * 1000) / 1000); running = true; turnErr = false }
        case "turn/end":
            if live { turnStart = nil; running = false }
            let r = d["reason"]
            // Only a turn that ends on a failure shows the endpoints' failures; one that answered or was stopped drops them.
            if r["kind"].str != "error" { let t = d["turn"].int ?? curTurn; dropAttemptErrors { $0.turn == t } }
            if r["kind"].str == "aborted" { proj["todos"] = .null }
            if r["kind"].str == "error" && !turnErr { push(ChatItem(key: "e\(seq)", kind: .error, text: r["error"]["message"].string ?? "The turn failed")) }
            else if r["kind"].str == "aborted" { push(ChatItem(key: "n\(seq)", kind: .note, text: "Stopped")) }
            let turn = d["turn"].int ?? 0
            ends[turn] = seq
            for (_, k) in retries { if let i = idx(k), items[i].turn == turn, items[i].state == "scheduled" { items[i].state = "cancelled"; items[i].v += 1; itemsVersion &+= 1 } }
            for (_, k) in workflows { if let i = idx(k), items[i].turn == turn, items[i].stopReason == nil, !items[i].interrupted { items[i].interrupted = true; items[i].v += 1; itemsVersion &+= 1 } }
            turnErr = false
        case "deliverables/presented":
            let files = d["files"].array.filter { $0["path"].string != nil }.map { ChatItem.Deliverable(path: $0["path"].str, description: $0["description"].str) }
            if !files.isEmpty { deliverables.append(contentsOf: files); push(ChatItem(key: "d\(seq)", kind: .deliverables, deliverables: files)) }
        case "approval/policy":
            policy = d["policy"].str
        case "todo/write":
            // Replayed ones too: the host empties its list when a turn starts, so on reopening a chat the last list
            // the loaded history carries is the one still being worked through.
            setProj("todos", d["todos"])
        default: break
        }
    }

    // MARK: projections

    /// Bumped by every write to `inbox` and by every inbox read that starts. `refreshInbox` is the only write that
    /// happens after an `await`, so it is the only one that can land out of order: the number it was asked under is
    /// compared with the number in force when the reply arrives, and a reply that a push or a newer read has
    /// overtaken is dropped (Codex R15 P1).
    private var inboxRev = 0

    func setProj(_ key: String, _ value: JSON) {
        // The host blanks the task list whenever a turn starts — a finished background job starts one mid-task, and the
        // list vanished with work still open. Unfinished, it stays until the agent writes the next, the person sends a
        // new message, or the run is stopped (`reduce`).
        if key == "todos", value == .null, todos.contains(where: { $0["status"].str != "completed" }) { return }
        proj[key] = value
        if key == "inbox" { inboxRev &+= 1 }
        if key == "subagentCatalog" { app?.subagentCatalogs[sid] = value }
    }

    func projectionsFromControl(sessionId: String, values: [String: JSON]) {
        if sessionId == sid { for (k, v) in values { setProj(k, v) } }
        else if !child.isEmpty && sessionId == id, let cat = values["subagentCatalog"] { app?.subagentCatalogs[id] = cat; refreshChildMode() }
    }

    func projectionFromControl(sessionId: String, key: String, value: JSON) {
        if sessionId == sid { setProj(key, value) }
        else if !child.isEmpty && sessionId == id && key == "subagentCatalog" { app?.subagentCatalogs[id] = value; refreshChildMode() }
    }

    /// Read this session's `inbox` from the host, once.
    ///
    /// The queued card is drawn from the `inbox` projection and the host pushes it like any other, but a message
    /// waits there only until the running turn ends: the card's window is seconds (t13: nine of them, and nothing on
    /// screen through them). A push missed inside that window — the app busy behind a long answer, a reopened socket,
    /// a frame dropped — leaves a message that was really queued with no card and no Send now, which is the one thing
    /// the reader is owed here. `deliver` calls this the moment the host accepts a prompt, which is when the app
    /// KNOWS there is something to draw: it asks instead of hoping.
    ///
    /// Only `inbox` is taken. A whole-projection snapshot read a beat after a push could write an older value over a
    /// newer one for every other key, and the queue card is the only thing that has to be certain.
    ///
    /// The read is revision-guarded, because its reply is written after an `await` and the host is pushing `inbox` the
    /// whole time. A removal pushed while the read is in flight — the running turn ended and the host spliced the
    /// message out — must not be undone by a reply that describes the inbox as it was BEFORE that push, and two
    /// overlapping reads must not let the older answer land on top of the newer one. Every push and every read that
    /// starts bumps `inboxRev`; a reply is applied only if it is still the number in force (Codex R15 P1).
    func refreshInbox() async {
        guard !sid.isEmpty else { return }
        inboxRev &+= 1
        let asked = inboxRev
        do {
            let r = try await DSHClient.shared.rpc("session/projections", ["request": ["sessionId": .string(sid)]])
            // `{kind, asOfSeq, values}` from a live session, the same block the control stream pushes per session; a
            // host that answers with the values directly is read the same way.
            let values = r["values"].isObject ? r["values"] : r
            if inboxRev == asked, values["inbox"].isObject { setProj("inbox", values["inbox"]) }
        } catch {
            // A host too old for `session/projections`, or one that is unreachable: the push is still how the card
            // normally arrives, and a read that came back with nothing has nothing to say.
        }
    }

    private func refreshChildMode() {
        guard let app, !child.isEmpty else { return }
        let m = app.subagentMode(parent: id, child: child)
        if m != mode { mode = m }
    }

    func runSync(id rid: String, running r: Bool) {
        // Only the session this model is showing. For a subagent chat `id` is the PARENT and `sid` is the child, so
        // accepting `id` as well let the parent's start or finish show or hide the child's working bar and reset its
        // timer, whatever the child was actually doing. The host sends this per agent
        // (`api-session/status(sessionId, running)`, dsh-api-session-controller/lib/index.js:2912), and a child agent
        // has an id of its own — that is `sid`.
        guard rid == sid else { return }
        running = r
        if r && turnStart == nil { turnStart = Date() }
        if !r { turnStart = nil }
    }

    func rowSync() { if let r = app?.rows[sid] { running = r.running } }
    func hostError(_ m: String) { if !m.isEmpty { app?.say(String(m.prefix(160))) } }

    var model: ModelChoice? { ModelChoice(selection: proj["modelSelection"] ?? .null) }
    var title: String {
        if !child.isEmpty {
            let cat = app?.subagentCatalogs[id] ?? .null
            return cat.array.first { $0["id"].str == child }?["label"].string ?? "Subagent"
        }
        if let t = proj["title"]?.string, !t.isEmpty { return t }
        return app?.rows[sid]?.displayTitle ?? "Untitled"
    }
    var subtitle: String {
        let ws = app?.workspace(of: sid)?.label ?? Fmt.base(header["cwd"].string ?? app?.rows[sid]?.cwd ?? "")
        return [ws, model?.label ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var readOnly: Bool { !child.isEmpty && mode != "continuable" }
    var todos: [JSON] { proj["todos"]?.array ?? [] }
    var permission: String { proj["permissions"]?["currentValue"].str ?? "" }
    var autoApproved: Bool { !policy.isEmpty && policy != "ask" }

    // MARK: display list (pending, live, folded process groups)

    private static func liveShape(_ s: [Block]?) -> Int {
        guard let s else { return 0 }
        if s.isEmpty { return 1 }
        return processOnly(ChatItem(key: "live", kind: .live, blocks: s)) ? 2 : 3
    }

    /// Any non-blank character, without copying the text the way `trimmingCharacters` does (r166).
    static func hasInk(_ t: String) -> Bool { t.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) } }

    static func processOnly(_ it: ChatItem) -> Bool {
        guard it.kind == .assistant || it.kind == .live else { return false }
        let hasAnswer = it.blocks.contains { b in
            switch b { case .text(let t): return Self.hasInk(t)
            case .tool(_, let n, _): return n == "ask_user_question"
            default: return false }
        }
        let hasProcess = it.blocks.contains { b in
            switch b { case .tool: return true
            case .think(let t): return Self.hasInk(t)
            default: return false }
        }
        return !hasAnswer && hasProcess
    }

    /// The signature `display` is a pure function of: the items' own version, the pending list's, the live stream,
    /// the fold's liveness — plus the inbox, which is read here as well because the queued list is what hides a
    /// pending card the host has taken over.
    ///
    /// It is the whole invalidation: every one of these is a value the model mutates ON PURPOSE, so a body pass that
    /// changed none of them re-reads the cache instead of rebuilding the row list.
    private func displayKey() -> String {
        let inbox = proj["inbox"] ?? .null
        let queued = (inbox["next-turn"].array + inbox["next-step"].array).map { $0["source"]["rpcId"].str }.joined(separator: ",")
        return "\(itemsVersion)|\(pendingVersion)|\(liveShape)|\(streamError)|\(running)|\(queued)"
    }

    /// What the list shows: history, unsent messages, the live reply; runs of tool-only steps fold into one row.
    ///
    /// Cached, because this was the list's hot spot: a chat with thousands of rows paid a full copy and fold on EVERY
    /// body pass — and a body pass runs on each streamed token, each scroll frame and each `items` write — while the
    /// answer only changes when one of `displayKey`'s inputs does. The row list is the same array for every reader in
    /// between, which is what makes a pass that changed nothing O(1).
    var display: [ChatItem] {
        let key = displayKey()
        if let c = displayCache, c.key == key { return c.rows }
        let began = CFAbsoluteTimeGetCurrent()
        // A failed attempt in the turn still running waits: the host's fallback sends the next provider's request a
        // few ms later, and showing the card in between is the 429 flash (operator, 2026-10-13). The turn's end
        // shows it if nothing replaced it.
        var out = running ? items.filter { !($0.attemptError && $0.turn == curTurn) } : items
        let inbox = proj["inbox"] ?? .null
        let queued = Set((inbox["next-turn"].array + inbox["next-step"].array).map { $0["source"]["rpcId"].str })
        for p in pending where p.state != "sent" || !queued.contains(p.rpc) { out.append(p) }
        // The live row's blocks are a snapshot from the last shape change, there for the fold below; its view draws
        // `stream` itself (AssistantMessageView, ProcessGroupHeader).
        if let s = displayStream, !s.isEmpty { out.append(ChatItem(key: "live", kind: .live, blocks: s)) }
        if !streamError.isEmpty && liveShape != 0 && !running { out.append(ChatItem(key: "liveerr", kind: .error, text: streamError)) }
        // fold
        var res: [ChatItem] = []
        var groupIndex: Int? = nil
        var prevKey = "start"
        // The list's ForEach is keyed on these: two rows with one key is undefined layout, a suspect in the scroll-gate
        // freeze (t27), so the first of any repeat is the one kept.
        var seen = Set<String>()
        for it in out {
            guard seen.insert(it.key).inserted else { continue }
            if Self.processOnly(it) {
                if groupIndex == nil {
                    res.append(ChatItem(key: "gh" + prevKey, kind: .group, groupId: prevKey))
                    groupIndex = res.count - 1
                }
                res[groupIndex!].groupMembers.append(it.key)
                res[groupIndex!].v &+= it.v
                var m = it; m.groupId = res[groupIndex!].groupId
                res.append(m)
            } else {
                groupIndex = nil
                res.append(it)
                prevKey = it.key
            }
        }
        if let g = groupIndex { res[g].groupLive = running || liveShape != 0 }
        Trace.rebuilt("display")
        Trace.rebuildCost((CFAbsoluteTimeGetCurrent() - began) * 1000)
        displayCache = (key: key, rows: res)
        return res
    }

    // MARK: earlier messages

    /// One page of history, reduced into a model of its own that the walk merges. `nil` is "no records came back",
    /// which is what advancing to the unseen side of the page is keyed on.
    ///
    /// `throughSeq` is inclusive and `beforeSeq` exclusive in the host's own `paginate`
    /// (dsh-api-session-controller lib/index.js:1654), so the window the two name is exactly what comes back.
    private func fetchBatch(through: Int, before: Int?) async throws -> ChatModel? {
        let v = try await pageCall(through, before)
        Trace.mark("chat.page", "through=\(through) before=\(before.map(String.init) ?? "-") recs=\(v["records"].array.count) hasMore=\(v["hasMore"].truthy)")
        return page(from: v)
    }

    /// The one `session/page` request.
    ///
    /// `#if DEBUG` lets a unit test stand in for the host: two of the interleavings Codex R7 P2 named — a fetch
    /// suspended while several waiters arrive, and a fetch cancelled mid-flight — cannot be asked of a real host on
    /// cue. The shipping build always talks to the host.
    private func pageCall(_ through: Int, _ before: Int?) async throws -> JSON {
        #if DEBUG
        if let stub = fetchPage { return try await stub(through, before) }
        #endif
        // `beforeSeq` is dropped when it is nil — `JSON.obj` leaves an optional field out — and that is what the
        // host's own default (`throughSeq + 1`) reads as "the one record at the cursor".
        return try await DSHClient.shared.rpc("session/page", ["request": .obj([
            ("address", address),
            ("throughSeq", .number(Double(through))),
            ("beforeSeq", before.map { .number(Double($0)) }),
            ("maxMessages", .number(40))])])
    }

    #if DEBUG
    /// Where `pageCall` goes instead of the host, in a Debug build only.
    @ObservationIgnored var fetchPage: (@MainActor (Int, Int?) async throws -> JSON)?
    #endif

    /// Reduce one `session/page` reply into a page model. `nil` means the reply carried no event records AT ALL,
    /// which is what "the history does not continue below this" looks like.
    ///
    /// A page of nothing but metadata is not nothing. `turn/start`, `turn/end` and `tool/result` update `starts`,
    /// `ends` and `results` without adding a display row, so such a page has an empty `items` and is still a page:
    /// the old `!items.isEmpty` guard dropped it, which lost that state and the page's frontier, ended the walk in
    /// the middle of the history, and made `loadEarlier` ask for the same window again (Codex R6 P2). The frontier a
    /// walk advances by is `firstSeq`, the minimum over every event record — rows or not.
    func page(from v: JSON) -> ChatModel? {
        let older = ChatModel(id: id, child: child, app: app)
        older.resetState()
        for rec in v["records"].array where rec["event"].isObject { older.reduce(rec["event"], live: false) }
        guard older.events > 0 else { return nil }
        older.hasMore = v["hasMore"].truthy
        return older
    }

    /// Everything a gesture's fetched pages carry into this model, in ONE mutation, however many pages there are.
    ///
    /// The pages arrive newest-first and are contiguous, so they go in front of the rows already here from the
    /// OLDEST page up: one array write, one `itemsVersion` bump, one row list for the list to diff. The version this
    /// replaces merged page by page, which is one mutation, one diff and one list rebuild per page — twenty of them
    /// for a jump the old code paged out in a loop.
    ///
    /// The rows are ACCUMULATED and assigned once, which is what keeps the order right. Merging each page into
    /// `items` as the walk reached it put every newer page in front of the older pages it had just landed, so a
    /// three-page jump came out `[80,81,60,61,40,41,…]` instead of `[40,41,60,61,80,81,…]` (Codex R6 P1); the same
    /// mistake reversed the deliverables. `prefix` is built oldest page first and sorted by sequence — the
    /// transcript is read top-down, so the order of the pages as the host handed them over is not the order on
    /// screen.
    func merge(_ batches: [ChatModel]) {
        guard !batches.isEmpty else { return }
        var seen = Set(items.lazy.map(\.key))
        var prefix: [ChatItem] = []
        var earlier: [ChatItem.Deliverable] = []
        for older in batches.reversed() {
            for it in older.items where seen.insert(it.key).inserted { prefix.append(it) }
            results.merge(older.results) { a, _ in a }
            calls.merge(older.calls) { a, _ in a }
            callItem.merge(older.callItem) { a, _ in a }
            ends.merge(older.ends) { a, _ in a }
            starts.merge(older.starts) { a, _ in a }
            retries.merge(older.retries) { a, _ in a }
            workflows.merge(older.workflows) { a, _ in a }
            earlier.append(contentsOf: older.deliverables)
            firstSeq = min(firstSeq, older.firstSeq)
        }
        prefix.sort { $0.seq < $1.seq }
        items = prefix + items
        attemptErrs += prefix.filter(\.attemptError).count
        deliverables = earlier + deliverables
        // Whether there is more below depends on where the walk STOPPED, which is the OLDEST page's own frontier —
        // not `batches.first`'s, which only says the history continued below the page nearest the reader. That
        // distinction is the difference between a list that can still pull and one that has decided it cannot.
        hasMore = batches.last?.hasMore ?? hasMore
        itemsVersion &+= 1
    }

    /// The page before the oldest record on screen. `beforeSeq` is passed explicitly because the host's default
    /// (`throughSeq + 1`) names an EMPTY window when the two are adjacent, which is exactly the old code's state.
    func loadEarlier() async {
        guard hasMore, firstSeq > 0 else { return }
        // A page already on its way lands first — it moves the frontier, and the pull has to ask for the window below
        // the frontier the model has NOW, not the one it had when the reader lifted their finger. `loadingMore` is
        // the registered walk's own flag (see `runWalk`), so the wait is covered by it.
        await settlePaging()
        // The walk that was in flight may have reached the beginning of the history. Asking the same question again
        // after the wait is what keeps a pull from fetching a window below a frontier that is already gone.
        guard hasMore, firstSeq > 0 else { return }
        _ = await runWalk { [weak self] in
            guard let self, self.hasMore, self.firstSeq > 0 else { return Walk(pages: [], end: .historyEnded) }
            do {
                let before = self.firstSeq
                guard let older = try await self.fetchBatch(through: before - 1, before: before) else {
                    return Walk(pages: [], end: .historyEnded)
                }
                return Walk(pages: [older], end: .target)
            } catch {
                // A cancelled pull says nothing: replacing a jump cancels its request, and "No connection to the Mac"
                // over the newer selection would be a lie about a walk nobody is waiting for (Codex R7 P2).
                if Task.isCancelled { return Walk(pages: [], end: .cancelled) }
                self.app?.say(error.localizedDescription)
                return Walk(pages: [], end: .failed)
            }
        }
    }

    /// Load exactly the history a jump needs: the pages that reach `seq`, and no more. The old jump called
    /// `loadEarlier` in a loop — up to twenty page requests, twenty inserts and twenty list rebuilds on the way to a
    /// turn a few thousand rows back, and the main thread never came back inside XCUITest's 60 s idle window
    /// (`.tmp/list-speed-proposal.md`). The pages are fetched with `seq` as the upper bound — so nothing newer than
    /// the turn is lost — and all of them are merged in ONE insert at the end.
    ///
    /// The walk is longer than one page only when the turn sits under a page the host cut short by its own message
    /// budget; each further page is cut below the one before it, so the events between two pages are the next page
    /// rather than a gap.
    ///
    /// A page fetch already in flight — a pull, or the jump before this one — is AWAITED first, and the turn is
    /// looked for again in what it left behind: answering from the state that predates it is what made a jump report
    /// a loadable turn as gone (Codex R6 P2). The outcome says which of the four things happened; only `exhausted`
    /// may be read as "the turn is no longer in this chat".
    @discardableResult
    func loadThrough(_ seq: Int) async -> JumpOutcome {
        guard seq >= 0 else { return .failed }
        // Already replaced before the walk began: this jump belongs to a turn the reader has moved on from.
        guard !Task.isCancelled else { return .interrupted }
        await settlePaging()
        if starts.values.contains(seq) { return .found }
        // Settling can be where a replaced jump stops: the walk it waited for is not this jump's walk, and neither
        // is the fetch it would start next.
        guard !Task.isCancelled else { return .interrupted }
        let start = walkStart(for: seq)
        let w = await runWalk { [weak self] in
            guard let self else { return Walk(pages: [], end: .failed) }
            return await self.pageChain(through: start.through, before: start.before) { [weak self] sofar in
                // The frames already here plus the pages fetched on this jump's own way. Each page is reduced on its
                // own, so the turn can be in a page that has not been merged yet — asking the merged state alone
                // would answer "not loaded" until the end and page the whole history (the first version did that).
                guard let self else { return true }
                return self.starts.values.contains(seq) || sofar.contains { $0.starts.values.contains(seq) }
            }
        }
        // A newer jump cancels this task (the view's task is keyed by the turn). Nothing it found may be reported:
        // the reader is looking at a different turn by now. The merge is the walk's own (see `runWalk`), so what is
        // asked here is the state the walk left behind, not the state before it.
        if Task.isCancelled { return .interrupted }
        if starts.values.contains(seq) { return .found }
        switch w.end {
        case .historyEnded: return .exhausted
        case .cancelled: return .interrupted
        case .target, .capped, .failed: return .failed
        }
    }

    /// Where a jump's walk starts. The turn is either inside what is already loaded — `starts` answers for it and no
    /// walk runs — or below the oldest event on screen, and then the window that reaches it is the one just under
    /// the frontier: `throughSeq: firstSeq - 1` with `beforeSeq: firstSeq` as its exclusive boundary.
    ///
    /// Starting at the cursor instead is what made the retry the cap advertises useless: the cap stopped the walk,
    /// its pages merged and moved the frontier down, and the next tap asked for the SAME window again — above
    /// everything the first walk had loaded, so a target beyond the cap could never be reached (Codex R7 P2). The
    /// cursor stays as the fallback for a model with no frontier yet, where the first page is the one it names.
    private func walkStart(for seq: Int) -> (through: Int, before: Int?) {
        if firstSeq != .max && firstSeq > 0 && seq < firstSeq { return (firstSeq - 1, firstSeq) }
        return (max(seq, cursor), nil)
    }

    // MARK: the one page walk

    /// Where a page walk stopped. The last three are why a jump's outcome is not a Boolean: only `historyEnded` means
    /// the turn really is not in this chat, while the cap, a cancelled task and a failed request all leave it
    /// possibly one page further down (Codex R6 P2).
    enum WalkEnd { case target, historyEnded, capped, cancelled, failed }

    /// What a walk fetched, and why it stopped.
    struct Walk { var pages: [ChatModel]; var end: WalkEnd }

    /// What a turn jump got back. The four are four different things on screen: `found` scrolls to the turn,
    /// `exhausted` is the only one that may say the turn is gone, `interrupted` says nothing at all (a newer jump
    /// owns the screen), and `failed` is retryable — a pull, or another tap, can still reach the turn.
    enum JumpOutcome: String {
        case found, exhausted, interrupted, failed

        /// What to tell the reader, if anything. The sentence "that turn is no longer in this chat" belongs to ONE
        /// outcome: an exhausted history, the only case where the walk reached the beginning and the turn was not
        /// there. A cap or a request that did not come back leaves the turn possibly one page further down, and an
        /// interrupted jump is not this jump's news to report (Codex R6 P2).
        var message: String? {
            switch self {
            case .found, .interrupted: return nil
            case .exhausted: return "That turn is no longer in this chat."
            case .failed: return "Could not load that turn. Pull down to load more of this chat, or try again."
            }
        }
    }

    /// The page walk in flight, if any, and the generation that owns it. Pulls and jumps are serialized through it:
    /// a caller that arrives while one is running awaits it (see `settlePaging`) instead of being refused, which is
    /// what `loadingMore` alone could only do — refuse — and a refusal is what reported a loadable turn as gone.
    @ObservationIgnored private var pageTask: Task<Walk, Never>?
    @ObservationIgnored private var pageGen = 0

    /// Await every walk already in flight: what it fetched and merged is part of the state the caller's own question
    /// has to be asked against.
    ///
    /// The loop is not decoration. A waiter that resumes from one walk can find ANOTHER waiter's walk registered
    /// behind it — each waiter registers its own once it is through — and its question has to be asked against that
    /// one too. A cancelled waiter stops waiting: it belongs to a jump the reader has replaced, and settling behind
    /// a newer walk would only delay an answer nobody is waiting for (Codex R7 P2).
    private func settlePaging() async {
        while let t = pageTask {
            _ = await t.value
            guard !Task.isCancelled else { return }
        }
    }

    /// Register `body` as the one walk in flight, and await it.
    ///
    /// The REGISTERED TASK owns the whole gesture: the fetch, the merge, and the `loadingMore` flag that says a page
    /// is on its way. The version this replaces merged in the caller, so the task completed and unregistered before
    /// its pages were in the model — a waiting jump then rechecked state that was still stale, and two waiters
    /// resuming from the same task could each register a walk, overwriting the registration and letting the two
    /// merge over each other (Codex R7 P2).
    ///
    /// The walk is its own task — that is what makes it awaitable by the caller that arrives next — so the caller's
    /// cancellation has to be carried into it by hand: a jump the reader has replaced must stop fetching, not run to
    /// the end of the history for a turn nobody is looking at. The task clears the registration and the loading flag
    /// only if no newer walk has taken them over, so a finished walk is never left registered.
    ///
    /// The wait for a walk already in flight is repeated HERE, immediately before the registration, and there is no
    /// suspension between the two: a caller that waited in `settlePaging` and then found the slot taken again cannot
    /// slip its own walk in over the one that took it. Two walks that both believed the slot was theirs would fetch
    /// twice, merge over each other and leave the loading flag to whoever finished last (Codex R7 P2).
    private func runWalk(_ body: @escaping @MainActor () async -> Walk) async -> Walk {
        while let t = pageTask {
            _ = await t.value
            if Task.isCancelled { return Walk(pages: [], end: .cancelled) }
        }
        pageGen += 1
        let gen = pageGen
        let snapshot = snapshots
        loadingMore = true
        let t = Task { @MainActor [weak self] () -> Walk in
            let w = await body()
            guard let self else { return w }
            if self.pageGen == gen { self.pageTask = nil; self.loadingMore = false }
            // A reconnect's snapshot reset the history while this page was on its way: merged onto the fresh one it
            // would leave a gap that "Load earlier" then skips (Codex r174).
            guard self.snapshots == snapshot else { return Walk(pages: [], end: .cancelled) }
            self.merge(w.pages)
            return w
        }
        pageTask = t
        return await withTaskCancellationHandler {
            await t.value
        } onCancel: {
            t.cancel()
        }
    }

    /// The pages that reach `until`, newest first and made contiguous: each further request ends just below the one
    /// before it, so the events in between are the next page rather than a gap. Stops when `until` says the turn is
    /// here, when the host says the history ended, when a reply carries no records at all, when the task is
    /// cancelled, or at the cap.
    ///
    /// `until` is handed the pages fetched SO FAR by this call, so it can answer for a turn that is on its way.
    ///
    /// `before` is the FIRST page's exclusive boundary; nil leaves it to the host's own default. Every page after it
    /// is cut below the one before, so a walk never asks for a window it has already been given.
    ///
    /// The cap is 80 rather than the old loop's 20 because the loop's own stop was WRONG: it stopped while the
    /// history still had more, and a jump to a turn it had not reached reported "that turn is no longer in this
    /// chat". 80 requests is ~3200 messages — longer than the log of any chat this host holds (the longest here is
    /// 3885 events, whose whole history the old loop needed 20 pages to walk) — and a page that comes back empty or
    /// says `hasMore: false` ends the walk long before it, so the cap is a backstop, not a policy.
    private static let pageCap = 80
    private func pageChain(through: Int, before initialBefore: Int?, until: @escaping ([ChatModel]) -> Bool) async -> Walk {
        var chain: [ChatModel] = []
        while !until(chain) {
            guard chain.count < Self.pageCap else { return Walk(pages: chain, end: .capped) }
            // A newer jump cancels this task before it can finish: stop fetching rather than walk the rest of the
            // history for a reader who has moved on. What was fetched is still returned — it is real history.
            guard !Task.isCancelled else { return Walk(pages: chain, end: .cancelled) }
            // The same window a pull uses, one page further down: everything up to the record just below the
            // oldest one fetched so far, bounded by the host's own message budget. The FIRST page's boundary is the
            // caller's (`walkStart`) — a jump that starts under the loaded frontier passes it, and one that starts
            // from the cursor leaves `beforeSeq` out entirely: passing 0 makes this host return an EMPTY page
            // (measured on HEAD — `recs=0 hasMore=false`, so the jump did nothing at all).
            let below = chain.last.map { $0.firstSeq - 1 } ?? through
            let before = chain.isEmpty ? initialBefore : below + 1
            do {
                guard let page = try await fetchBatch(through: below, before: before) else {
                    // No records at all is the one answer that ends a walk: the history does not continue below it.
                    return Walk(pages: chain, end: .historyEnded)
                }
                chain.append(page)
                if !page.hasMore { return Walk(pages: chain, end: .historyEnded) }
            } catch {
                // A cancelled walk is not news: replacing a jump cancels its request, and an error banner over the
                // newer selection would be a lie about a turn nobody is looking at (Codex R7 P2).
                if Task.isCancelled { return Walk(pages: chain, end: .cancelled) }
                app?.say(error.localizedDescription)
                return Walk(pages: chain, end: .failed)
            }
        }
        return Walk(pages: chain, end: .target)
    }

    // MARK: sending

    func send(text: String, attachments: [Attachment]) {
        let p = ChatItem(key: "p" + UUID().uuidString, kind: .pending, time: Date().timeIntervalSince1970 * 1000, text: text,
                         images: attachments.filter(\.isImage).count, files: attachments.filter { !$0.isImage }.map(\.name),
                         rpc: UUID().uuidString, state: "sending")
        pending.append(p)
        Task { await deliver(p.rpc, text: text, attachments: attachments) }
    }

    @ObservationIgnored private var pendingAttachments: [String: [Attachment]] = [:]

    func deliver(_ rpc: String, text: String, attachments: [Attachment]) async {
        pendingAttachments[rpc] = attachments
        setPending(rpc, "sending")
        do {
            var content: [JSON] = []
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content.append(["type": "text", "text": .string(text)]) }
            for a in attachments {
                if a.isImage {
                    content.append(["type": "image", "mediaType": .string(a.mediaType), "data": .string(a.data.base64EncodedString()), "name": .string(a.name)])
                } else {
                    let r = try await DSHClient.shared.rpc("fileUploads/upload", ["agentId": .string(sid), "request": ["data": .string(a.data.base64EncodedString()), "name": .string(a.name)]], timeout: 120)
                    content.append(["type": "file", "receiptId": r["receiptId"]])
                }
            }
            if !child.isEmpty {
                // A subagent prompt takes text and images only, so a file is named instead of sent: it was uploaded
                // already, and passing a "file" part made the host reject the whole message.
                var childContent = content.filter { $0["type"].str != "file" }
                let names = attachments.filter { !$0.isImage }.map(\.name)
                if !names.isEmpty { childContent.append(["type": "text", "text": .string("Attached to this chat: " + names.joined(separator: ", "))]) }
                try await DSHClient.shared.rpc("subagents/prompt", ["request": ["requestId": .string(rpc), "parentSessionId": .string(id), "childSessionId": .string(child),
                                                                               "mode": "continuable", "delivery": "queue", "content": .array(childContent)]])
            } else {
                // While the agent works, the Mac's own busy-send choice decides: steer goes into the running turn. A
                // steer that misses the turn's window is queued by the host itself, so it can never be lost.
                let mode = running && app?.busyEnter == "steer" ? "steer" : "queue"
                try await DSHClient.shared.rpc("session/prompt", ["request": ["requestId": .string(rpc), "sessionId": .string(sid), "mode": .string(mode),
                                                                             "content": .array(content), "clientTimeZone": .string(TimeZone.current.identifier)]])
            }
            setPending(rpc, "sent")
            pendingAttachments[rpc] = nil
            // A chat kept only for this message lets go once it is delivered (r142).
            if let app, !pending.contains(where: { $0.state != "sent" }) {
                let k = child.isEmpty ? id : id + "/" + child
                if app.parked[k] === self { app.parked[k] = nil }
            }
            // A message sent while the chat is working goes into the host's `inbox`, and the card that offers Send
            // now is drawn from that projection. The window it describes is SHORT — the host splices the message out
            // the moment the running turn ends and the next one starts — so a push missed inside it (the app busy
            // behind a long answer, a reopened socket, a frame dropped) leaves the reader with a message that was
            // queued and no card to act on. Reading the session's own projections here, right after the host accepted
            // the prompt, takes that window out of the app's path: the app asks instead of hoping. One small call per
            // sent message, and the reply is the same block the control stream pushes.
            await refreshInbox()
        } catch let e as RPCError where e.kind == .auth {
            // Sign-in asks again; the message waits with its Retry rather than "sending" forever (Codex r143).
            setPending(rpc, "failed")
        } catch {
            setPending(rpc, "failed")
        }
    }

    private func setPending(_ rpc: String, _ state: String) {
        if let i = pending.firstIndex(where: { $0.rpc == rpc }) { pending[i].state = state; pending[i].v += 1 }
    }

    func retrySend(_ rpc: String) {
        guard let p = pending.first(where: { $0.rpc == rpc }) else { return }
        Task { await deliver(rpc, text: p.text, attachments: pendingAttachments[rpc] ?? []) }
    }
    func dropSend(_ rpc: String) { pending.removeAll { $0.rpc == rpc }; pendingAttachments[rpc] = nil }

    func saveDraft() {
        let k = "draft." + sid
        if draft.isEmpty { UserDefaults.standard.removeObject(forKey: k) } else { UserDefaults.standard.set(draft, forKey: k) }
    }

    func stop() async {
        do {
            try await DSHClient.shared.rpc("session/cancel", ["request": ["sessionId": .string(sid)]])
            app?.say("Stopping…")
            // A stopped run takes its waiting question or approval with it: the host sends no cancel for a request
            // that dies with the run, and the island would go on asking for an answer nothing is waiting for.
            app?.pendingDropped(sid: sid)
        } catch { app?.say(error.localizedDescription) }
    }

    /// Add `text` to the draft as a "> " quote, after anything already typed.
    func quote(_ text: String) {
        let q = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        draft = (draft.isEmpty ? "" : draft + "\n\n") + q + "\n\n"
    }

    /// Try again: send the last prompt once more.
    func tryAgain() {
        guard let u = items.last(where: { $0.kind == .user }), !u.text.isEmpty || u.images > 0 || !u.files.isEmpty else { app?.say("Nothing to send again"); return }
        // The phone keeps no copy of what was attached, so a resend without it would be a different prompt.
        guard u.images == 0 && u.files.isEmpty else { app?.say("That message had attachments: add them again and send"); return }
        send(text: u.text, attachments: [])
    }

    func isLastError(_ it: ChatItem) -> Bool { child.isEmpty && !running && items.last?.key == it.key }

    // MARK: feedback

    func loadFeedback() async {
        guard let r = try? await DSHClient.shared.rpc("messageFeedback/list", ["request": ["sessionId": .string(sid)]]) else { return }
        let v = r["ok"].bool == true ? r["value"] : r
        for x in v["items"].array { feedback[x["messageId"].str] = x }
    }

    func putFeedback(messageId: String, rating: String, note: String) async -> Bool {
        func put(_ ifVersion: JSON) async throws -> JSON {
            let r = try await DSHClient.shared.rpc("messageFeedback/put", ["request": .obj([("sessionId", .string(sid)), ("messageId", .string(messageId)), ("rating", .string(rating)),
                                                                                         ("note", note.isEmpty ? nil : .string(note)), ("ifVersion", ifVersion)])])
            return r["ok"].bool != nil ? r : ["ok": true, "value": r]
        }
        do {
            var r = try await put(feedback[messageId]?["version"] ?? .null)
            if r["ok"].bool == false && r["error"]["code"].str == "version-conflict" { r = try await put(r["error"]["current"]["version"]) }
            guard r["ok"].bool == true else { app?.say("Could not save: \(r["error"]["code"].string ?? "error")"); return false }
            feedback[messageId] = r["value"]
            app?.say("Thanks for the feedback")
            return true
        } catch { app?.say(error.localizedDescription); return false }
    }

    func deleteFeedback(messageId: String) async {
        guard let cur = feedback[messageId] else { return }
        do { try await DSHClient.shared.rpc("messageFeedback/delete", ["request": ["sessionId": .string(sid), "messageId": .string(messageId), "ifVersion": cur["version"]]]); feedback[messageId] = nil }
        catch { app?.say(error.localizedDescription) }
    }

    // MARK: code changes (read-only GET routes)

    /// The summary read itself, swapped out by the unit tests.
    @ObservationIgnored var fetchChanges: @Sendable (String, Int) async throws -> JSON = { sid, seq in
        try await DSHClient.shared.getJSON("/api/changes.summary?sessionId=\(sid.urlQuery)&seq=\(seq)")
    }

    func loadChanges(_ seq: Int) async {
        // A failed read is asked again on the next look; only a summary or one already on its way is kept.
        guard changes[seq] == nil || changes[seq]?.string == "err" else { return }
        changes[seq] = "wait"
        // The read runs on its own, so a chip leaving the screen cannot cut it short and strand the "wait" another
        // view is showing; an answer that lands after a snapshot is dropped, since the snapshot re-asks for it.
        let gen = snapshots, sid = sid, fetch = fetchChanges
        let r = await Task { try await fetch(sid, seq) }.result
        guard gen == snapshots else { return }
        switch r {
        case .success(let v): changes[seq] = v
        case .failure: changes[seq] = "err"
        }
    }
}

struct Attachment: Identifiable, Sendable {
    let id = UUID()
    var name: String
    var mediaType: String
    var data: Data
    var isImage: Bool { mediaType.hasPrefix("image/") }
}

extension String {
    var urlQuery: String { addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? self }
}

/// The phone used to keep the last thirty rows of recent chats on disk so they opened at once. Every crash of
/// 10-14 (four, on two builds, objc_release in an autorelease pool pop) happened while that cache was being saved,
/// with JSONEncoder over the model's own strings; the cache was removed and only its cleanup remains, for the files
/// older builds left behind.
enum ChatCache {
    static func clearAll() {
        try? FileManager.default.removeItem(at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chats", isDirectory: true))
    }
}
