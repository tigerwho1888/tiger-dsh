import Foundation
import Observation
import UIKit

/// Everything the chat list needs, kept live by three host streams: `workspace/follow` (projects, pins,
/// archive), `session/control` (per-chat projections such as titles), and `$events` (running state,
/// new and removed chats, approvals and questions).
@MainActor @Observable
final class AppModel {
    enum Auth { case signedOut, ok, expired }

    var auth: Auth = DSHClient.shared.isSignedIn ? .ok : .signedOut
    var conn: ConnState = .connecting
    /// The four inputs `groups()` is built from. Each one drops the grouped-list cache on the way past, so a body
    /// that read the list through `chats()` can never be shown an answer built from state it no longer has — the
    /// hole the C14 audit found in the drawer when only `archived` did this.
    var rows: [String: SessionRow] = [:] { didSet { groupsCache = [:] } }
    var workspaces: [Workspace] = [] { didSet { groupsCache = [:] } }
    var pinned: Set<String> = [] { didSet { groupsCache = [:] } }
    var archived: Set<String> = [] { didSet { groupsCache = [:] } }
    var listReady = false
    var listAt: Double = 0
    var liveAt: Double = 0
    var lastError = ""
    var capabilities: [String: Bool] = [:]
    var capReady = false
    /// What a message sent while the agent is busy does: "queue" waits for the turn to end, "steer" goes into the
    /// running turn. The Mac's own Settings choice (`ui-conversation.busyEnter`), read so the phone does what the
    /// desktop does; queue until it has been read, which is the host's own default.
    var busyEnter = "queue"
    var clientId: String?
    /// The running app. The Live Activity's own Approve and Reject buttons are a `LiveActivityIntent`, which runs in
    /// THIS process, and the answer they send is the app's own approval path — the one that keeps a request on screen
    /// when the connection drops instead of losing it.
    @MainActor static weak var live: AppModel?
    var toast: Toast?
    /// How many sheets are up. The message capsule is drawn on the topmost one only: the screen's own capsule sits
    /// under any sheet, where a failed action looked like nothing happened (Codex r60).
    var sheetDepth = 0

    /// Pending approval requests (`approval/request` waterfalls), oldest first.
    var approvals: [JSON] = []
    /// Live questions delivered as `user-questions/request` waterfalls, keyed by event id.
    var waterQuestions: [String: JSON] = [:]
    /// When each waiting request arrived (ms), keyed by eventId. The run list only speaks for requests older than
    /// itself: a run that started while the phone was away is not in a list fetched before it (Codex r18 P1).
    var pendingSeen: [String: Double] = [:]

    /// Parent chat id -> its subagent catalog, so a child chat knows whether it can be messaged.
    var subagentCatalogs: [String: JSON] = [:]
    func subagentMode(parent: String, child: String) -> String {
        subagentCatalogs[parent]?.array.first { $0["id"].str == child }?["mode"].string ?? "unknown"
    }

    let mux = Mux()
    weak var currentChat: ChatModel?

    /// The chat the main window is showing, and the child when a subagent or a team member is open. The app opens to
    /// the last one; the drawer swaps it by identity. Never a push: a push between two chats ran the interactive pop
    /// transition the operator's freeze lived in, and there is no pop left now.
    var currentChatID: String = UserDefaults.standard.string(forKey: "chat.current") ?? "" { didSet { doneUnseen.remove(currentChatID) } }
    /// Chats whose run finished while the reader was elsewhere: the drawer marks them with a green dot until opened
    /// (operator, 2026-10-13: "green dot means task done"; a running chat shows a spinner instead).
    var doneUnseen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "chat.doneUnseen") ?? []) {
        didSet { UserDefaults.standard.set(Array(doneUnseen), forKey: "chat.doneUnseen"); groupsCache = [:] }
    }
    var currentChild: String = ""
    /// The chat's identity for the view layer: changing it rebuilds the chat, so the old one leaves and the new one
    /// enters exactly as a push used to.
    var chatKey: String { currentChild.isEmpty ? currentChatID : currentChatID + "/" + currentChild }

    func swapChat(_ id: String, child: String = "") {
        guard !id.isEmpty, id != currentChatID || child != currentChild else { return }
        currentChatID = id
        currentChild = child
        UserDefaults.standard.set(id, forKey: "chat.current")
    }

    private var questionClaims: [String: String] = [:]
    /// Attachments picked in a chat's composer and not yet sent, by chat: in memory only, like a photo in Messages'
    /// field, and gone when the app is.
    var draftAttachments: [String: [Attachment]] = [:]
    /// The process and tool sections the reader opened, by chat (a subagent apart from its parent): a chat is rebuilt
    /// each time it is opened, so a fold kept on the screen closed again on a trip to another chat and back.
    @ObservationIgnored private var foldStore: [String: FoldState] = [:]
    /// Chats left with a message still unsent: a new model on return started with no pending list, and the message
    /// and its Retry were gone (Codex r140). Taken back by the chat's next screen.
    @ObservationIgnored var parked: [String: ChatModel] = [:]
    func folds(_ key: String) -> FoldState {
        if let f = foldStore[key] { return f }
        let f = FoldState(); foldStore[key] = f; return f
    }
    @ObservationIgnored private var listTask: Task<Void, Never>?
    /// True while `refreshList`'s own task is running, so a connection change does not ask for the same 14.6 MB list
    /// a second time. `listGen` is what makes the flag survive a cancelled fetch.
    @ObservationIgnored private var listInFlight = false
    /// Chats the live events changed while a list was downloading: the list speaks for the moment it was asked, so
    /// for these the live row is newer and is kept (Codex r57 — a finished run came back as running).
    @ObservationIgnored private var touchedDuringList: Set<String> = []
    @ObservationIgnored private var listGen = 0
    /// The connection on which the slim list route last failed. That Mac does not serve it (the plugin is not loaded),
    /// and asking again on every refresh only adds a round trip before the full list; a new sign-in asks once more.
    @ObservationIgnored private var slimListMissingConn = -1
    /// The connection generation, bumped when a connection ends (sign-out, a refused sign-in). A request that was
    /// already in flight for the host that just went away must not write its answer into the state of the next one:
    /// the list, the capability sweep, the board/digest probes and the speech catalog all outlive their connection.
    @ObservationIgnored private var connGen = 0

    /// True while `gen` is still the generation in force. Checked after every await, before results are applied —
    /// and before an error is shown, because a stale failure is as wrong as a stale success.
    private func stillCurrent(_ gen: Int) -> Bool { gen == connGen }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The last grouped list, kept for the body passes that follow the one that built it. Its key names the three
    /// arguments that are not model state; the model state is what the `didSet`s above invalidate on.
    /// A few entries, not one: the drawer (all chats) and the Chats page (its own search or filter) are both mounted
    /// and asked in turn, and a single slot made each evict the other's (Codex r164).
    @ObservationIgnored private var groupsCache: [String: [Group]] = [:]

    struct Toast: Identifiable, Equatable { let id = UUID(); let text: String }

    init() {
        // The Mac pushes the island's updates while the app is closed; it needs the activity's own token for that.
        RunActivity.onPushToken = { sid, token, title, started in
            #if DEBUG
            let env = "sandbox"
            #else
            let env = "production"
            #endif
            Task { await DSHClient.shared.post("/tigerdsh/activity-token", ["sessionId": .string(sid), "token": .string(token), "env": .string(env),
                                                                           "title": .string(title), "startedAt": .number(started.timeIntervalSince1970)]) }
        }
        DSHClient.shared.onAuthLost = { [weak self] in self?.authLost() }
        mux.onState = { [weak self] s in self?.connChanged(s) }
        loadCache()
    }

    func say(_ text: String) { toast = Toast(text: text) }

    // MARK: lifecycle

    func start() {
        guard auth == .ok else { return }
        mux.sub("ws", "workspace/follow") { [weak self] f in self?.wsFrame(f) }
        mux.sub("ctl", "session/control") { [weak self] f in self?.ctlFrame(f) }
        mux.sub("ev", "$events", onReset: { [weak self] in self?.clientId = nil }) { [weak self] f in self?.evFrame(f) }
        mux.connect()
        mux.startBeat { [weak self] in self?.auth == .ok && UIApplication.shared.applicationState == .active }
        // Voice input goes first and on its own: behind the fifty-probe sweep one network hiccup left the mic
        // missing for the rest of the session, and nothing retried it.
        Task { await loadSpeech() }
        // The board probe is one quick request, so it goes first: its entry point is in a menu the reader may open
        // before the capability sweep (fifty-odd calls) has finished.
        Task { await probeBoard(); await probeDigestWatch(); await probeCapabilities() }
        Task { await loadBusyEnter() }
    }

    func loadBusyEnter() async {
        // The smoke tests pin it: the queued card they drive only exists when a busy send queues.
        if let v = ProcessInfo.processInfo.environment["DSH_BUSY_ENTER"] { busyEnter = v; return }
        guard let d = try? await DSHClient.shared.rpc("settings/describe") else { return }
        if let v = d["namespaces"].array.first(where: { $0["ns"].str == "ui-conversation" })?["value"]["busyEnter"].string,
           v == "queue" || v == "steer" { busyEnter = v }
    }

    func signedIn() {
        auth = .ok
        rows = [:]; workspaces = []; listReady = false
        resetHostState()
        // The fetch is asked for here rather than left to the connection's own state change. Mux.stop() keeps the
        // state it had, so signing in again after a sign-out produced no change for the fetch to hang on and the list
        // stayed empty; and listAt survives a sign-out, so the freshness guard could swallow it even when the state
        // did change. session/list is one HTTP call and needs no socket.
        listAt = 0
        liveAt = 0
        start()
        refreshList()
    }

    func signOut() {
        mux.stop()
        DSHClient.shared.signOut()
        clearCache()
        endConnectionState()
        auth = .signedOut
    }

    func authLost() {
        guard auth == .ok else { return }
        mux.stop()
        endConnectionState()
        auth = .expired
    }

    /// Everything that belongs to the connection that just ended. The requests in flight are the dangerous part: an
    /// approval sheet is presented from `approvals` with `interactiveDismissDisabled`, so it outlived a sign-out as a
    /// sheet the reader could not close, and its event id would have been sent to the next host under that host's
    /// client id, which cannot resolve it. The Live Activity goes with them — it belongs to a run on that Mac.
    private func endConnectionState() {
        // Everything asked for on this connection is now suspect, including the requests still in flight.
        connGen += 1
        approvals.removeAll()
        waterQuestions.removeAll()
        questionClaims.removeAll()
        clientId = nil
        RunActivity.reconcile(hostRunning: false)
    }

    /// The caches the host filled, dropped when a sign-in begins: the new host is probed again by `start()`, and
    /// nothing on screen should be answered from the previous one's capabilities, catalog or project list.
    private func resetHostState() {
        capabilities = [:]; capReady = false
        subagentCatalogs = [:]
        boardReady = nil; digestWatch = nil
        speech = nil; pluginCache = []
        catalogCache = nil; catalogAt = .distantPast
        pinned = []; archived = []
        // The open chat belongs to the host that listed it. A sign-in to the same Mac keeps the reader's place; a
        // sign-in to another one starts at the list rather than on a chat id that host has never heard of.
        let host = DSHClient.shared.baseURL?.absoluteString ?? ""
        if UserDefaults.standard.string(forKey: "state.host") != host {
            UserDefaults.standard.set(host, forKey: "state.host")
            currentChatID = ""; currentChild = ""
            UserDefaults.standard.removeObject(forKey: "chat.current")
        }
    }

    private var backgroundAt: Date?
    func scenePhase(active: Bool) {
        // The first step away counts: a return passes background → inactive → active, and restamping on that inactive
        // made every absence look a split second long, so the dead socket was never replaced (Codex r168).
        if !active { if backgroundAt == nil { backgroundAt = Date() }; saveNow(); return }
        let away = backgroundAt
        backgroundAt = nil
        guard auth == .ok else { return }
        if let away, Date().timeIntervalSince(away) > 4 { mux.recycle() }
        // Whatever the phone missed while it was away, the island must not still be asking for it: a question
        // answered on the Mac while the app was suspended leaves no frame here to say so.
        Task { await resyncPending() }
        // The choice can change on the Mac while the phone is away.
        Task { await loadBusyEnter() }
    }

    private func connChanged(_ s: ConnState) {
        conn = s
        // The list is 14.6 MB on this Mac (1,719 sessions) and the app already holds it: a reconnect, a return to
        // the foreground or a mux recycle must not re-download it every time. Pull-to-refresh always fetches.
        if s == .live {
            liveAt = Date().timeIntervalSince1970 * 1000
            // A socket that came back may have missed the cancel of a question the Mac answered meanwhile. This runs
            // before the freshness guard below, which returns early on a list that is still warm.
            Task { await resyncPending() }
            // Five minutes, not one. A reader who spends a minute in a chat and then slides back was re-downloading
            // the whole list exactly as the pop animation ran — the freeze the operator can reproduce every time.
            // Except when a chat is shown as running: its finish may have been sent while the socket was down, and
            // nothing else would ever stop its spinner (Codex r57).
            let anyRunning = rows.values.contains { $0.running }
            guard anyRunning || liveAt - listAt > 300_000 else { return }
            // And never inside a transition: the fetch waits for the pop to finish, so the animation owns the frames
            // and the work starts on a screen that is standing still.
            let live = liveAt
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self else { return }
                if anyRunning {
                    // A list under ten seconds old waits out the rest instead of giving up: one fetched just before a
                    // short trip to the background predates the finish, and nothing else would stop the spinner (Codex
                    // r132). A list asked for after this reconnect already carries it.
                    let wait = 10_000 - (Date().timeIntervalSince1970 * 1000 - self.listAt)
                    if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait))) }
                    // A download asked for before the drop may still be running, and predates the finish too: it is
                    // waited out — its own timeout ends it — not taken as the answer (Codex r133, r135).
                    while self.listInFlight { try? await Task.sleep(for: .milliseconds(500)) }
                    guard !self.listInFlight, self.listAt < live else { return }
                } else {
                    // Freshness is rechecked here as well as in-flight status: sign-in's own fetch can finish inside
                    // these 700 ms, and then `listInFlight` is false again and the same 14.6 MB list would be pulled
                    // a second time for nothing.
                    guard !self.listInFlight, Date().timeIntervalSince1970 * 1000 - self.listAt > 300_000 else { return }
                }
                self.refreshList()
            }
        }
    }

    // MARK: capabilities

    static let contract: [String: [String]] = [
        "model": ["session/modelCatalog", "session/selectModel"],
        "permissions": ["permissionPresets/catalog", "commands/execute"],
        "commands": ["commands/list", "commands/execute"],
        "skills": ["skills/list"],
        "refs": ["fileReferences/list", "sessionReferenceResolver/candidates"],
        "attachments": ["fileUploads/upload"],
        "feedback": ["messageFeedback/list", "messageFeedback/put", "messageFeedback/delete"],
        "questions": ["userQuestions/answer"],
        "queue": ["session/updateQueue"],
        "goals": ["goals/create", "goals/edit", "goals/pause", "goals/resume", "goals/complete", "goals/clear"],
        "jobs": ["job/list", "job/follow", "job/kill"],
        "files": ["workspaceFiles/list", "workspaceFiles/read", "workspaceFiles/readBytes"],
        "workspace": ["workspace/archiveSession", "workspace/unarchiveSession", "workspace/pinSession", "workspace/unpinSession"],
        "rename": ["session/rename"],
        "fork": ["session/fork"],
        "search": ["session/search"],
        "presets": ["agentPresets/list"],
        "subagents": ["subagents/prompt"],
        "speech": ["speech/catalog", "speech/transcribe", "speech/prepare"],
        "plugins": ["pluginManager/listBundles", "pluginManager/setBundleEnabled"],
        "pluginsinstall": ["pluginManager/inspect", "pluginManager/installBundle", "pluginManager/removeBundle"],
        "providers": ["llm/listConfigurableProviders", "settings/describe", "settings/mutate", "credentials/describe", "credentials/set", "credentials/unset"],
        "schedule": ["schedule/catalog", "schedule/delete", "schedule/update", "schedule/history"],
    ]

    func can(_ group: String) -> Bool { capabilities[group] != false }

    func probeCapabilities() async {
        let gen = connGen
        await withTaskGroup(of: (String, Bool?).self) { g in
            for (group, methods) in Self.contract {
                g.addTask {
                    for m in methods {
                        let r = await DSHClient.shared.probe(m)
                        if r == false { return (group, false) }
                        if r == nil { return (group, nil) }
                    }
                    return (group, true)
                }
            }
            for await (group, ok) in g { if let ok, stillCurrent(gen) { capabilities[group] = ok } }
        }
        guard stillCurrent(gen) else { return }
        capReady = true
    }

    /// The task board belongs to an optional plugin rather than the host, so it is probed by its own route and its
    /// entry point only appears when that route answers.
    private(set) var boardReady: Bool?

    func probeBoard() async {
        guard auth == .ok else { return }
        let gen = connGen
        let v = try? await DSHClient.shared.getJSON("/api/task-board/state", timeout: 10)
        guard stillCurrent(gen) else { return }
        boardReady = (v?.isObject ?? false)
    }

    /// The digest watch, when the reader's Mac has the plugin that serves it. Optional by design: a 404 means the
    /// plugin is not installed, and then nothing about it appears anywhere — no empty card, no menu entry. The route
    /// is the same shape as the task board's, so a host that has neither simply answers 404 twice.
    private(set) var digestWatch: JSON?

    func probeDigestWatch() async {
        guard auth == .ok else { return }
        let gen = connGen
        let v = try? await DSHClient.shared.getJSON("/api/digest-watch/state", timeout: 10)
        guard stillCurrent(gen) else { return }
        digestWatch = (v?.isObject ?? false) ? v : nil
    }

    // MARK: list

    /// Returns the fetch so pull-to-refresh can hold its spinner until the rows are in, rather than for a fixed 600 ms
    /// that ended long before a 14.6 MB list did.
    @discardableResult
    func refreshList() -> Task<Void, Never>? {
        guard auth == .ok else { return nil }
        listTask?.cancel()
        // The generation makes the flag safe against the cancellation above: the task being cancelled clears it only
        // if it is still the current fetch, so a fetch that starts while an old one is winding down is not mistaken
        // for finished. It is what lets a connection change skip a list that is already on its way.
        listGen += 1
        let gen = listGen
        let conn = connGen
        listInFlight = true
        touchedDuringList = []
        // The list speaks for the moment it was asked, not the moment it landed: a question that arrives while 14.6 MB
        // downloads is newer than what the list says, and `prunePendingNotRunning` compares against this (Codex r19).
        let askedAt = Date().timeIntervalSince1970 * 1000
        listTask = Task {
            defer { if listGen == gen { listInFlight = false } }
            do {
                // The Mac's own plugin serves the same rows with only the fields this app reads (tigerdsh-push.js
                // /tigerdsh/list): `session/list` was 61 MB for 3,800 chats, every byte of it parsed here. A Mac
                // without the plugin answers 405 from its static server, which decodes as nothing: any failure but a
                // lost sign-in falls back to the full list.
                var slim: SessionListValue?
                if slimListMissingConn != conn {
                    do {
                        slim = try await DSHClient.shared.rpcDecode("session/list", ["_request": [:]], as: SessionListValue.self, timeout: 90,
                                                                    path: "/tigerdsh/list")
                    } catch let e as RPCError where e.kind == .auth {
                        throw e
                    } catch {
                        guard !Task.isCancelled else { return }
                        if stillCurrent(conn) { slimListMissingConn = conn }
                    }
                }
                let v: SessionListValue
                if let slim { v = slim } else {
                    v = try await DSHClient.shared.rpcDecode("session/list", ["_request": [:]], as: SessionListValue.self, timeout: 90)
                }
                // Superseded by a newer fetch, cancelled, or asked for on a connection that has since ended: the rows
                // belong to none of those. `rpcDecode` parses off the main actor, so a cancelled fetch can arrive
                // here long after sign-out.
                guard gen == listGen, stillCurrent(conn), !Task.isCancelled else { return }
                var m: [String: SessionRow] = [:]
                m.reserveCapacity(v.rows.count)
                for r in v.rows { m[r.id] = r }
                // keep live state the events already told us about
                for (id, old) in rows where m[id] == nil && old.running { m[id] = old }
                for id in touchedDuringList { if let old = rows[id] { m[id] = old } }
                touchedDuringList = []
                // A run that finished while the socket was down sent its finish to no one: the list is the only word
                // of it, and without this the chat lost its "Ready to read" dot (Codex r174).
                for (id, old) in rows where old.running && m[id]?.running == false && id != currentChat?.sid { doneUnseen.insert(id) }
                listReady = true; listAt = askedAt; lastError = ""
                // An unchanged list is the common refresh: leaving `rows` alone keeps the drawer from regrouping and
                // the cache from being re-encoded and rewritten for nothing.
                if m != rows { rows = m; scheduleSave() }
                currentChat?.rowSync()
                prunePendingNotRunning()
                // `rowSync` is a change to what the island reads like any other: a chat restored from cache gets its
                // snapshot before the list arrives, and the list is where its running state comes from. Without this
                // the activity would not start until some later frame happened to sync.
                syncRunActivity()
            } catch {
                // A stale failure is as wrong as a stale success: it would put the previous host's error on screen.
                guard stillCurrent(conn), !Task.isCancelled else { return }
                if (error as? RPCError)?.kind != .auth { lastError = error.localizedDescription }
            }
        }
        return listTask
    }

    private func wsFrame(_ f: JSON) {
        switch f["type"].str {
        case "baseline":
            workspaces = f["value"]["items"].array.map(Workspace.init)
            archived = Set(f["value"]["archivedSessionIds"].array.compactMap(\.string))
            pinned = Set(f["value"]["pinnedSessionIds"].array.compactMap(\.string))
        case "upsert":
            let w = Workspace(f["workspace"])
            if let i = workspaces.firstIndex(where: { $0.id == w.id }) { workspaces[i] = w } else { workspaces.append(w) }
        case "remove":
            workspaces.removeAll { $0.id == f["workspaceId"].str }
        case "order":
            let pos = Dictionary(f["workspaceIds"].array.compactMap(\.string).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            workspaces.sort { (pos[$0.id] ?? .max) < (pos[$1.id] ?? .max) }
        case "archived": archived = Set(f["archivedSessionIds"].array.compactMap(\.string))
        case "pinned": pinned = Set(f["pinnedSessionIds"].array.compactMap(\.string))
        default: break
        }
        scheduleSave()
    }

    private func touched(_ id: String) { if listInFlight { touchedDuringList.insert(id) } }

    private func ctlFrame(_ f: JSON) {
        switch f["type"].str {
        case "baseline":
            for (id, b) in f["value"]["projections"].object {
                let vals = b["values"].object
                if var r = rows[id] { for (k, v) in vals { r.apply(projection: k, value: v) }; rows[id] = r }
                currentChat?.projectionsFromControl(sessionId: id, values: vals)
            }
        case "projection":
            let id = f["sessionId"].str, key = f["key"].str, value = f["value"]
            if var r = rows[id] { r.apply(projection: key, value: value); rows[id] = r; touched(id) }
            currentChat?.projectionFromControl(sessionId: id, key: key, value: value)
        default: break
        }
    }

    private func evFrame(_ f: JSON) {
        switch f["type"].str {
        case "ready": clientId = f["clientId"].string
        case "emit":
            let a = f["args"][0], b = f["args"][1]
            switch f["event"].str {
            case "api-session/status":
                let id = a.str
                touched(id)
                // The chat on screen, not the last one picked: a reply that finished while the reader was on Home or
                // the Chats page was never marked unread (Codex r138).
                if rows[id]?.running == true, !b.truthy, id != currentChat?.sid { doneUnseen.insert(id) }
                rows[id]?.running = b.truthy
                currentChat?.runSync(id: id, running: b.truthy)
                // A run that has ended cannot still be waiting on an answer, and the host sends no cancel for a
                // request that died with it: the island would keep asking for it for as long as the entry lived.
                if !b.truthy { clearPending(id) }
                // The island's own input just changed. An approval usually stops token production, so the token-flush
                // callback cannot be relied on to notice a run that started or finished.
                syncRunActivity()
            case "api-session/activity":
                if let t = b.double { rows[a.str]?.updated = t; touched(a.str) }
            case "api-session/added":
                guard a.isObject else { break }
                var r = SessionRow(item: a)
                if let old = rows[r.id] { if r.snippet.isEmpty { r.snippet = old.snippet }; if r.title.isEmpty { r.title = old.title } }
                rows[r.id] = r; touched(r.id)
            case "api-session/removed":
                rows[a.str] = nil
                // The chat is gone from the host's list: whatever it was waiting on is gone with it.
                clearPending(a.str)
                syncRunActivity()
            case "api-session/error":
                if currentChat?.id == a.str { currentChat?.hostError(b.str) }
            default: break
            }
        case "waterfall": waterfall(f)
        case "cancel": waterfallCancelled(f["eventId"].str)
        default: break
        }
    }

    // MARK: approvals and questions

    private func waterfall(_ f: JSON) {
        switch f["event"].str {
        case "user-questions/request":
            waterQuestions[f["eventId"].str] = f
            pendingSeen[f["eventId"].str] = Date().timeIntervalSince1970 * 1000
            let w = f["request"]["wait"]
            if w["timed"].truthy, let call = w["callId"].string {
                let key = "qw" + f["eventId"].str
                questionClaims[f["eventId"].str] = key
                mux.sub(key, "userQuestions/attachWait", ["agentId": f["agentId"], "callId": .string(call)], reopen: false) { _ in }
            }
            Notifier.needsYou(title: "A chat is asking you something", body: title(of: f["agentId"].str), id: f["eventId"].str, chat: f["agentId"].str)
            // The question is the thing worth waking a locked phone for, and it has to be on the island the moment it
            // arrives — waiting for the next token or status frame would leave the island saying "Working" instead.
            syncRunActivity()
        case "approval/request":
            approvals.append(f)
            pendingSeen[f["eventId"].str] = Date().timeIntervalSince1970 * 1000
            Notifier.needsYou(title: "A chat needs your approval", body: title(of: f["agentId"].str), id: f["eventId"].str, chat: f["agentId"].str)
            syncRunActivity()
        default:
            Task { await respond(f["eventId"].str, ["kind": "next"]) }
        }
    }

    // MARK: the Live Activity

    /// The island follows what the reader is waiting on. An approval or a question wins — that is the thing worth
    /// waking a locked phone for — then the open chat while it runs. Nothing waiting and nothing running ends it, so
    /// a leftover never sits on the lock screen. Called from the frames that change any of those.
    func syncRunActivity() {
        let open = currentChat.map {
            (sid: $0.sid, title: $0.title, running: $0.running, turnStart: $0.turnStart, step: $0.activityStep)
        }
        let plan = Self.islandPlan(questions: waterQuestions, approvals: approvals, open: open, title: { self.title(of: $0) })
        // Only once the list is here can it say which chats are running.
        if listReady, !rows.isEmpty {
            RunActivity.endLeftovers { sid in sid == plan?.sid || self.rows[sid]?.running == true }
        }
        guard let p = plan else {
            RunActivity.reconcile(hostRunning: false)
            return
        }
        RunActivity.show(sessionID: p.sid, state: RunActivityAttributes.ContentState(
            phase: p.phase, title: p.title, step: p.step, detail: p.detail, approvalId: p.approvalId,
            startedAt: p.startedAt ?? Date()))
    }

    /// What the island should show, as a value: the request the reader is owed first — the open chat's, then any
    /// other — and the open chat's own run when nothing waits.
    ///
    /// Pure, so the choice can be asserted without ActivityKit, which does not run in a unit test. Two waiting chats
    /// used to be decided by `waterQuestions.values.first`, and a dictionary has no order: the island could flip
    /// between them from one frame to the next. Questions are ordered by their event id instead.
    struct IslandPlan: Equatable {
        var sid: String
        var phase: RunPhase
        var title: String
        var step: String
        var detail: String?
        var approvalId: String?
        var startedAt: Date?
    }

    static func islandPlan(questions: [String: JSON], approvals: [JSON],
                           open: (sid: String, title: String, running: Bool, turnStart: Date?, step: String)?,
                           title: (String) -> String) -> IslandPlan? {
        // An approval first within its chat: the run cannot go on without one, and the island carries its buttons.
        var waiting: [(sid: String, approval: JSON?, question: JSON?)] = approvals.map { ($0["agentId"].str, $0, nil) }
        waiting += questions.sorted { $0.key < $1.key }.map { ($0.value["agentId"].str, nil, $0.value) }
        let chosen = open.flatMap { o in waiting.first { $0.sid == o.sid } } ?? waiting.first
        if let a = chosen?.approval {
            return IslandPlan(sid: a["agentId"].str, phase: .needsApproval, title: title(a["agentId"].str),
                              step: "Waiting for approval",
                              detail: a["summary"].string ?? a["request"]["command"].string,
                              approvalId: a["eventId"].str, startedAt: open?.turnStart)
        }
        if let q = chosen?.question {
            let sid = q["agentId"].str
            return IslandPlan(sid: sid, phase: .needsYou, title: title(sid), step: "Waiting for your answer",
                              detail: q["request"]["questions"].array.first?["question"].string, approvalId: nil,
                              // The clock is the run's, and only the open chat has one to hand.
                              startedAt: open?.sid == sid ? open?.turnStart : nil)
        }
        guard let o = open, o.running else { return nil }
        return IslandPlan(sid: o.sid, phase: .running, title: o.title, step: o.step, detail: nil, approvalId: nil,
                          startedAt: o.turnStart)
    }

    private func title(of sessionId: String) -> String {
        let t = rows[sessionId]?.displayTitle ?? ""
        return t.isEmpty || t == "Untitled" ? "Open the app to answer." : t
    }

    private func waterfallCancelled(_ id: String) {
        waterQuestions[id] = nil
        if let k = questionClaims.removeValue(forKey: id) { mux.unsub(k) }
        approvals.removeAll { $0["eventId"].str == id }
        // The host withdrew the request (answered from the Mac, or timed out): the island must stop asking for it.
        syncRunActivity()
    }

    /// The reader answered a question on the card, and the host took it.
    ///
    /// `userQuestions/answer` is the other door to the request a `user-questions/request` waterfall carries, and the
    /// host sends no `cancel` for an answer the phone gave itself: left behind, the entry outlives the answer, and
    /// every later `syncRunActivity` puts "Waiting for your answer" back on the island — the operator's screenshot of
    /// 2026-10-13, still asking after the answer had been given.
    ///
    /// `callId` is the request's own id as the card knows it. An answer that carries none (a waterfall frame with no
    /// `wait.callId`) clears every question the chat has waiting: nothing could be matched against it, and a stranded
    /// entry is the lie this exists to prevent.
    func questionAnswered(sid: String, callId: String?) {
        for (eventId, f) in waterQuestions where f["agentId"].str == sid {
            guard callId == nil || f["request"]["wait"]["callId"].string == callId else { continue }
            waterQuestions[eventId] = nil
            if let k = questionClaims.removeValue(forKey: eventId) { mux.unsub(k) }
        }
        answeredTick += 1
        syncRunActivity()
    }

    /// A run that ended, was stopped or was archived takes its waiting requests with it.
    ///
    /// The host sends a `cancel` for a request it withdrew itself, but not for one that died with the run: a stop or
    /// an archive can end the turn with the question still on the wire, and a request left in these lists is what
    /// keeps the island asking for an answer nobody can give any more.
    func pendingDropped(sid: String) {
        clearPending(sid)
        syncRunActivity()
    }

    /// The entries alone, for the callers that end in a `syncRunActivity()` of their own.
    private func clearPending(_ sid: String) {
        for (eventId, f) in waterQuestions where f["agentId"].str == sid {
            waterQuestions[eventId] = nil
            if let k = questionClaims.removeValue(forKey: eventId) { mux.unsub(k) }
        }
        approvals.removeAll { $0["agentId"].str == sid }
    }

    /// Rebuild what the island is asking for from the host.
    ///
    /// The phone can miss the `cancel` that ends a question — a suspension, a socket the app recycled, a question the
    /// Mac answered while the app was away — and an entry left in `waterQuestions` keeps the island asking for an
    /// answer that was already given. No host call lists every pending request, so the run list is the authority for
    /// the chats that are not open: a chat the host no longer reports as running has nothing pending. The open chat is
    /// asked by name — `session/projections` answers with the same `userQuestions` block the control stream pushes,
    /// and that says exactly which of its questions are still waiting.
    func resyncPending() async {
        guard auth == .ok else { return }
        prunePendingNotRunning()
        // Only a question already on screen can be stale; with none, the host round trip would just compete with the
        // chat's own snapshot on the way back in (Codex r152).
        if let sid = currentChat?.sid, !sid.isEmpty, waterQuestions.values.contains(where: { $0["agentId"].str == sid }) {
            await reconcileOpenChatQuestions(sid: sid)
        }
        syncRunActivity()
    }

    /// Drop every waiting request whose chat the host no longer reports as running. Host-free and synchronous, so the
    /// rule can be asserted in a unit test.
    func prunePendingNotRunning() {
        // An empty or not-yet-loaded list says nothing about any chat, and dropping on it would wipe a question that
        // had just arrived: the run list is only an authority once it is here.
        guard listReady, !rows.isEmpty else { return }
        let running = Set(rows.filter { $0.value.running }.keys)
        // A list older than the request cannot say its run has ended; the next list fetch prunes it if so.
        let stale = { (f: JSON) in !running.contains(f["agentId"].str) && (self.pendingSeen[f["eventId"].str] ?? 0) <= self.listAt }
        for (eventId, f) in waterQuestions where stale(f) {
            waterQuestions[eventId] = nil
            if let k = questionClaims.removeValue(forKey: eventId) { mux.unsub(k) }
        }
        approvals.removeAll(where: stale)
    }

    /// What the host says is still waiting in this chat: `active` is what the reader can still answer, `settled` is
    /// what has been answered. Only the host's own word drops an entry — it lists the call as settled, or it lists
    /// what is still waiting and this is not among them.
    private func reconcileOpenChatQuestions(sid: String) async {
        let gen = connGen
        let askedAt = Date().timeIntervalSince1970 * 1000
        guard let r = try? await DSHClient.shared.rpc("session/projections", ["request": ["sessionId": .string(sid)]]),
              stillCurrent(gen) else { return }
        let values = r["values"].isObject ? r["values"] : r
        guard values["userQuestions"].isObject else { return }
        let uq = values["userQuestions"]
        // A list the host sent is its word even when empty: an empty one used to keep a question whose cancel was
        // missed on screen (and the island on "Waiting for your answer") until the app was relaunched.
        let listed: Bool = { if case .array = uq["active"] { return true }; return false }()
        let active = Set(uq["active"].array.map { $0["callId"].str })
        let settled = Set(uq["settled"].array.map { $0["callId"].str })
        for (eventId, f) in waterQuestions where f["agentId"].str == sid {
            guard let call = f["request"]["wait"]["callId"].string else { continue }
            // A question that arrived after the read began is newer than the answer, which cannot speak for it.
            guard (pendingSeen[eventId] ?? 0) <= askedAt else { continue }
            guard settled.contains(call) || (listed && !active.contains(call)) else { continue }
            waterQuestions[eventId] = nil
            if let k = questionClaims.removeValue(forKey: eventId) { mux.unsub(k) }
        }
    }

    /// Returns whether the host took the answer. A dropped connection must not lose the request: the caller keeps it
    /// on screen so the user can try again, because the run on the Mac waits for it.
    @discardableResult
    func respond(_ eventId: String, _ outcome: JSON) async -> Bool {
        do {
            try await DSHClient.shared.rpc("$events/result", ["clientId": .str(clientId), "eventId": .string(eventId), "outcome": outcome])
            return true
        } catch {
            say("Could not send the answer: \(error.localizedDescription)")
            return false
        }
    }

    func answerApproval(_ f: JSON, allow: Bool) async {
        let id = f["eventId"].str
        guard await respond(id, ["kind": "result", "value": allow ? "allowed-once" : "rejected"]) else { return }
        approvals.removeAll { $0["eventId"].str == id }
        answeredTick += 1
        syncRunActivity()
    }

    @discardableResult
    func answerWaterfallQuestion(eventId: String, answers: JSON) async -> Bool {
        guard await respond(eventId, ["kind": "result", "value": ["answers": answers]]) else { return false }
        waterQuestions[eventId] = nil
        if let k = questionClaims.removeValue(forKey: eventId) { mux.unsub(k) }
        answeredTick += 1
        syncRunActivity()
        return true
    }

    /// Bumped when an answer or an approval actually leaves the phone. The chat screen watches it for the one
    /// success haptic the two decisions share (D6); a refused send leaves it alone, so nothing is celebrated that
    /// did not happen.
    var answeredTick = 0

    /// Last plugin list from `pluginManager/listBundles`.
    var pluginCache: [JSON] = []

    // MARK: model catalog (cached for a minute, like the web app)

    @ObservationIgnored var catalogCache: JSON?
    @ObservationIgnored var catalogAt = Date.distantPast

    func modelCatalog(force: Bool) async throws -> JSON {
        if !force, let c = catalogCache, Date().timeIntervalSince(catalogAt) < 60 { return c }
        let gen = connGen
        let c = try await DSHClient.shared.rpc("session/modelCatalog")
        // A catalog from the previous host must not become this one's, so it is returned to the caller but not kept.
        guard stillCurrent(gen) else { return c }
        catalogCache = c; catalogAt = Date()
        return c
    }

    // MARK: voice input (DSH's local speech-to-text on the Mac)

    var speech: JSON?
    var showVoiceSetup = false

    func loadSpeech() async {
        guard can("speech") else { speech = nil; return }
        let gen = connGen
        let v = try? await DSHClient.shared.rpc("speech/catalog")
        guard stillCurrent(gen) else { return }
        speech = v
        if speech?.isNull == true { speech = nil }
    }

    var speechProvider: JSON? {
        guard let sp = speech else { return nil }
        return sp["providers"].array.first { $0["id"].str == sp["selection"]["providerId"].str }
    }
    var speechUsable: Bool { ["ready", "standby", "waking"].contains(speechProvider?["preparation"]["phase"].str ?? "") }

    // MARK: grouping (the desktop's order)

    enum Filter: String, CaseIterable { case all = "All", working = "Working", answer = "Answer", unread = "Unread", archived = "Archived" }

    struct Group: Identifiable { let id: String; let label: String; let path: String; let total: Int; let rows: [SessionRow] }

    func visible(_ r: SessionRow, filter: Filter, current: String?) -> Bool {
        if r.isSub { return false }
        if r.blank && r.id != current { return false }
        return filter == .archived ? archived.contains(r.id) : !archived.contains(r.id)
    }

    func groups(filter: Filter, query: String, current: String? = nil) -> [Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let key = "\(filter.rawValue)|\(q)|\(current ?? "")"
        if let c = groupsCache[key] { return c }
        func match(_ r: SessionRow, _ label: String) -> Bool {
            if filter == .working && !r.running { return false }
            if filter == .answer && r.questions == 0 { return false }
            if filter == .unread && (r.running || !doneUnseen.contains(r.id)) { return false }
            if !q.isEmpty && !(r.displayTitle.lowercased().contains(q) || label.lowercased().contains(q)) { return false }
            return true
        }
        var out: [Group] = []
        var seen = Set<String>()
        for w in workspaces {
            var all: [SessionRow] = []
            for id in w.sessionIds { guard let r = rows[id] else { continue }; seen.insert(id); if visible(r, filter: filter, current: current) { all.append(r) } }
            let isPin: (SessionRow) -> Bool = { self.pinned.contains($0.id) && !self.archived.contains($0.id) }
            let ordered = all.filter(isPin) + all.filter { !isPin($0) }
            out.append(Group(id: w.id, label: w.label, path: w.path, total: all.count, rows: ordered.filter { match($0, w.label) }))
        }
        let stray = rows.values.filter { !seen.contains($0.id) && visible($0, filter: filter, current: current) }.sorted { $0.updated > $1.updated }
        if !stray.isEmpty { out.append(Group(id: "_other", label: "Other chats", path: "", total: stray.count, rows: stray.filter { match($0, "Other chats") })) }
        let filtering = filter != .all || !q.isEmpty
        let result = filtering ? out.filter { !$0.rows.isEmpty } : out
        if groupsCache.count >= 4 { groupsCache.removeAll() }
        groupsCache[key] = result
        return result
    }

    /// The project a chat belongs to: what its second line names, and where a new chat in the same place is made.
    /// `workspace/follow` is the only thing that knows this — a row carries a cwd, not a project.
    func workspace(of sessionId: String) -> Workspace? {
        workspaces.first { $0.sessionIds.contains(sessionId) }
    }

    /// The project a new chat starts in, picked the way the desktop picks it: the one whose newest chat was updated
    /// last, and a project with no chats of its own counts from the day it was made.
    func defaultProject() -> Workspace? {
        func newest(_ w: Workspace) -> Double {
            if let t = w.sessionIds.compactMap({ rows[$0]?.updated }).max() { return t }
            return (Fmt.parseISO(w.createdAt)?.timeIntervalSince1970 ?? 0) * 1000
        }
        return workspaces.max { newest($0) < newest($1) }
    }

    /// The chats as one flat, newest-first list. The drawer's Recents and the Chats page both read this, and it
    /// rides the cache the grouped list already keeps.
    func chats(filter: Filter = .all, query: String = "", workspace: String? = nil, limit: Int = .max) -> [SessionRow] {
        var flat = groups(filter: filter, query: query).flatMap(\.rows)
        // One set, not a roster search per chat: that was O(chats x project size) before the first paint (Codex r164).
        if let workspace {
            // First match wins, as in `workspace(of:)`: a chat an earlier project also lists is that project's (r165).
            var claimed = Set<String>(), ids = Set<String>()
            for w in workspaces {
                if w.id == workspace { ids = Set(w.sessionIds).subtracting(claimed); break }
                claimed.formUnion(w.sessionIds)
            }
            flat = flat.filter { ids.contains($0.id) }
        }
        return Array(flat.sorted { $0.updated > $1.updated }.prefix(limit))
    }

    /// The drawer's chats, grouped under the project they belong to: each project's newest `perProject` chats, the
    /// projects ordered by the chat they lead with, and no more of them than `projects`. Pinned chats are not here —
    /// the drawer's own Pinned section is theirs, above this list — and a project left with nothing after them is
    /// dropped rather than drawn as a header over no rows. "Other chats" sorts last, and is the one group the cap
    /// can therefore push off the bottom: a chat with no project is the exception, not a project.
    ///
    /// Read through `groups`, which owns the one cache: a second cached copy of the list would be a second thing to
    /// invalidate on every `session/control` frame that moves a row.
    func recentGroups(perProject: Int = 5, projects: Int = 6) -> [Group] {
        var out: [Group] = []
        for g in groups(filter: .all, query: "") {
            let rows = g.rows
                .filter { !(pinned.contains($0.id) && !archived.contains($0.id)) }
                .sorted { $0.updated > $1.updated }
            guard !rows.isEmpty else { continue }
            out.append(Group(id: g.id, label: g.label, path: g.path, total: rows.count,
                             rows: Array(rows.prefix(perProject))))
        }
        // Newest project first, by the chat it leads with; the stray group is filed behind them whatever its date.
        let byDate = out.filter { $0.id != "_other" }.sorted { ($0.rows.first?.updated ?? 0) > ($1.rows.first?.updated ?? 0) }
        return Array((byDate + out.filter { $0.id == "_other" }).prefix(projects))
    }

    struct Counts { var all = 0, working = 0, answer = 0, archived = 0 }
    var counts: Counts {
        var c = Counts()
        for r in rows.values where !r.isSub && !r.blank {
            if archived.contains(r.id) { c.archived += 1 } else { c.all += 1; if r.running { c.working += 1 }; if r.questions > 0 { c.answer += 1 } }
        }
        return c
    }

    // MARK: chats: rename, pin, archive, branch

    /// The reader's own title for a chat. The id goes over exactly as `session/list` gives it, `session-` prefix and
    /// all — the bare uuid answers session/not-found. The reply carries the durable seq; the row is updated here so
    /// the list changes under the reader's finger rather than a frame later.
    /// Whether the Mac took the new name: the rename sheet keeps itself, and the old title, when it did not.
    @discardableResult
    func rename(_ id: String, _ title: String) async -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        do {
            let v = try await DSHClient.shared.rpc("session/rename", ["request": ["sessionId": .string(id), "title": .string(t)]])
            rows[id]?.apply(projection: "title", value: .string(v["title"].string ?? t))
            return true
        } catch {
            say("Could not rename the chat: \(error.localizedDescription)")
            return false
        }
    }

    /// Pin ahead of the unpinned chats, or take the pin back. Both are idempotent host-side, so a lost race with
    /// another surface is a no-op rather than an error to report.
    func togglePin(_ id: String) async {
        let on = !pinned.contains(id)
        do {
            _ = try await DSHClient.shared.rpc(on ? "workspace/pinSession" : "workspace/unpinSession",
                                               ["request": ["sessionId": .string(id)]])
        } catch {
            say("Could not \(on ? "pin" : "unpin") the chat: \(error.localizedDescription)")
        }
    }

    /// Archive a chat, or bring it back. The answer is nil when the host took it, "active" when the chat has work in
    /// flight — the host refuses that as `workspace/session-active` unless `stop` says to stop the work first, and
    /// "active" is what makes the drawer ask before it stops anything — and "error" when the call itself failed,
    /// which has already been said on screen.
    @discardableResult
    func setArchived(_ id: String, _ on: Bool, stop: Bool = false) async -> String? {
        do {
            // `stopActivity` is a field of the archive request and nothing else: unarchiving takes the id alone.
            let req: JSON = on ? ["sessionId": .string(id), "stopActivity": .bool(stop)] : ["sessionId": .string(id)]
            _ = try await DSHClient.shared.rpc(on ? "workspace/archiveSession" : "workspace/unarchiveSession",
                                               ["request": req])
            // An archived chat is not on screen anywhere, and the host does not withdraw the requests of a run it
            // archived: they go with it, or the island keeps asking about a chat the reader has put away.
            if on { clearPending(id); syncRunActivity() }
            return nil
        } catch let e as RPCError where e.code == "workspace/session-active" {
            return "active"
        } catch {
            say("Could not \(on ? "archive" : "unarchive") the chat: \(error.localizedDescription)")
            return "error"
        }
    }

    /// Branch a chat from just before one turn: the host copies the session up to `atSeq` and hands back the new
    /// id, which is what the caller then opens. A nil `atSeq` asks for the latest completed turn — what the chat's
    /// own menu means by "Fork this chat".
    func fork(_ id: String, atSeq: Int? = nil) async -> String? {
        do {
            var req: JSON = ["sessionId": .string(id)]
            if let atSeq { req = ["sessionId": .string(id), "atSeq": .number(Double(atSeq))] }
            let v = try await DSHClient.shared.rpc("session/fork", ["request": req])
            guard let nid = v["sessionId"].string, !nid.isEmpty else { say("The branch came back without a chat"); return nil }
            refreshList()
            return nid
        } catch {
            say("Could not branch this chat: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: the list on disk

    /// The list the reader last saw, kept between launches: the 14.6 MB fetch is what the app opens with otherwise,
    /// and this is the screen that has to be there first. `v` is the shape's version — a cache written by an older
    /// build is dropped rather than decoded into the wrong fields.
    private struct Cache: Codable {
        var v: Int
        var rows: [SessionRow]
        var ws: [Workspace]
        var arch: [String]
        var pin: [String]
        var at: Double
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("list.json")
    }

    private func saveNow() {
        guard auth == .ok else { return }
        let c = Cache(v: 3, rows: Array(rows.values), ws: workspaces, arch: Array(archived), pin: Array(pinned), at: listAt)
        guard let d = try? JSONEncoder().encode(c) else { return }
        try? d.write(to: cacheURL, options: .atomic)
    }

    /// A list frame is followed by a burst of others: the write waits for the burst to settle so a stream of frames
    /// costs one file write rather than one each.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func loadCache() {
        guard auth == .ok, let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d), c.v == 3 else { return }
        for r in c.rows { rows[r.id] = r }
        workspaces = c.ws; archived = Set(c.arch); pinned = Set(c.pin); listAt = c.at; liveAt = c.at
    }

    func clearCache() {
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: cacheURL)
        ChatCache.clearAll()
        // `listAt` too: a refresh that fails here would otherwise leave the emptied list looking fresh (Codex r145).
        rows = [:]; listReady = false; listAt = 0
        say("Cached data cleared")
        if auth == .ok { refreshList() }
    }
}
