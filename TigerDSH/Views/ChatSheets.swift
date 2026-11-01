import SwiftUI
import ImageIO
import QuickLook

struct ChatSheetView: View {
    let sheet: ChatSheet
    let chat: ChatModel
    @Binding var present: ChatSheet?

    var body: some View {
        switch sheet {
        case .menu: ChatMenuSheet(chat: chat, present: $present)
        case .model: NavigationStack { ModelSheet(chat: chat) }
        case .permissions: NavigationStack { PermissionsSheet(chat: chat) }.presentationDetents([.medium, .large])
        case .commands: NavigationStack { CommandsSheet(chat: chat) }
        case .todos: NavigationStack { TodosSheet(chat: chat) }.presentationDetents([.medium, .large])
        case .goal: NavigationStack { GoalSheet(chat: chat) }
        case .jobs: NavigationStack { JobsSheet(chat: chat) }
        case .subagents: NavigationStack { SubagentsSheet(chat: chat) }.presentationDetents([.medium, .large])
        case .files(let p): NavigationStack { FilesSheet(chat: chat, path: p) }
        case .file(let p): NavigationStack { FileViewer(chat: chat, path: p) }
        case .changesList: NavigationStack { ChangesListSheet(chat: chat) }.presentationDetents([.medium, .large])
        case .changes(let s): NavigationStack { ChangedFilesSheet(chat: chat, seq: s) }
        case .diff(let s, let i): NavigationStack { DiffView(chat: chat, seq: s, index: i) }
        case .team: NavigationStack { TeamSheet(chat: chat) }
        case .feedback(let mid, let r): NavigationStack { FeedbackSheet(chat: chat, messageId: mid, rating: r) }.presentationDetents([.medium, .large])
        case .edit(let k): NavigationStack { EditMessageSheet(chat: chat, key: k) }
        case .rename: NavigationStack { RenameSheet(chat: chat) }.presentationDetents([.height(220), .medium])
        case .deliverables: NavigationStack { DeliverablesSheet(chat: chat) }.presentationDetents([.medium, .large])
        case .usage: UsageSheet(chat: chat)
        case .transcript: TranscriptSheet(chat: chat)
        case .turns: TurnsSheet(chat: chat)
        case .quote(let t): NavigationStack { QuoteSheet(chat: chat, text: t) }.presentationDetents([.medium, .large])
        }
    }
}

/// Quote part of a message: select the words, then Quote puts just them in the reply as a "> " quote.
struct QuoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    let text: String
    @State private var picked = ""

    var body: some View {
        SelectableText(text: text, picked: $picked)
            .padding(.horizontal, Tok.sp3)
            .navigationTitle(picked.isEmpty ? "Select text to quote" : "Quote selection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Quote") { chat.quote(picked); dismiss() }.bold().disabled(picked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
    }
}

/// A read-only text view whose selection is reported back; SwiftUI's own `Text` selection cannot be read.
struct SelectableText: UIViewRepresentable {
    let text: String
    @Binding var picked: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false; v.isSelectable = true
        v.font = .preferredFont(forTextStyle: .body); v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear; v.text = text; v.delegate = context.coordinator
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) { if v.text != text { v.text = text } }
    func makeCoordinator() -> Coordinator { Coordinator(picked: $picked) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let picked: Binding<String>
        init(picked: Binding<String>) { self.picked = picked }
        func textViewDidChangeSelection(_ v: UITextView) {
            picked.wrappedValue = v.selectedTextRange.flatMap { v.text(in: $0) } ?? ""
        }
    }
}

struct DoneButton: ToolbarContent {
    @Environment(\.dismiss) private var dismiss
    var body: some ToolbarContent { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.bold() } }
}

struct CheckRow: View {
    let title: String
    var sub: String? = nil
    let on: Bool
    let act: () -> Void
    var body: some View {
        Button(action: act) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let sub, !sub.isEmpty { Text(sub).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
    }
}

struct NavRow: View {
    let title: String
    let icon: String
    var value: String = ""
    let act: () -> Void
    var body: some View {
        Button(action: act) {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(.primary)
                Spacer()
                Text(value).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        // A stable name per row, so a test can address the row it wants rather than the first one it sees.
        .accessibilityIdentifier("menu." + title.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

/// Small helper for screens that load once: spinner, error, or content.
struct Loading<T, Content: View>: View {
    let value: T?
    let error: String
    @ViewBuilder let content: (T) -> Content
    var body: some View {
        if let value { content(value) }
        else if !error.isEmpty { Text(error).foregroundStyle(.secondary) }
        else { HStack { Spacer(); ProgressView(); Spacer() } }
    }
}

// MARK: menu

struct ChatMenuSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    @Binding var present: ChatSheet?
    @State private var confirmArchive = false
    @State private var archiveActive = false

    /// How full the context window is, for the menu row's value.
    private var contextValue: String {
        let p = chat.proj["contextPressure"] ?? .null
        guard let used = p["pressureTokens"].double, let size = p["contextWindow"].double, size > 0 else { return "" }
        return String(format: "%.0f%%", min(100, used / size * 100))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if app.can("model") { NavRow(title: "Model", icon: "cpu", value: chat.model?.label ?? "") { present = .model } }
                    if app.can("permissions") { NavRow(title: "Permissions", icon: "lock.shield", value: PermissionsSheet.names[chat.permission]?.0 ?? chat.permission) { present = .permissions } }
                    if app.can("commands") { NavRow(title: "Commands", icon: "command") { present = .commands } }
                    NavRow(title: "Context & usage", icon: "chart.bar", value: contextValue) { present = .usage }
                }
                Section {
                    if !chat.todos.isEmpty { NavRow(title: "Tasks", icon: "checklist", value: "\(chat.todos.filter { $0["status"].str == "completed" }.count)/\(chat.todos.count)") { present = .todos } }
                    if app.can("goals") && chat.child.isEmpty { NavRow(title: "Goal", icon: "target", value: chat.proj["goal"]?["goal"]["phase"].string?.capitalized ?? "None") { present = .goal } }
                    if app.can("jobs") { NavRow(title: "Background jobs", icon: "gearshape.2") { present = .jobs } }
                    let subs = chat.proj["subagentCatalog"]?.array.count ?? 0
                    NavRow(title: "Subagents", icon: "person.2", value: subs > 0 ? "\(subs)" : "None") { present = .subagents }
                    if app.can("files") { NavRow(title: "Files", icon: "folder") { present = .files(".") } }
                    let ch = chat.items.filter { $0.kind == .changes }.count
                    if ch > 0 { NavRow(title: "Changes", icon: "doc.badge.ellipsis", value: "\(ch)") { present = .changesList } }
                    let team = chat.proj["agentTeam"] ?? .null
                    if team["members"].array.count > 1 || !team["tasks"].array.isEmpty { NavRow(title: "Agent team", icon: "person.3", value: "\(team["members"].array.count)") { present = .team } }
                    if !chat.deliverables.isEmpty { NavRow(title: "Files from this chat", icon: "doc.on.doc", value: "\(chat.deliverables.count)") { present = .deliverables } }
                    NavRow(title: "Share transcript", icon: "square.and.arrow.up") { present = .transcript }
                    let turns = chat.proj["turnOutline"]?.array.count ?? 0
                    if turns > 1 { NavRow(title: "Turns", icon: "list.number", value: "\(turns)") { present = .turns } }
                }
                if chat.child.isEmpty {
                    Section {
                        NavRow(title: "Rename", icon: "pencil") { present = .rename }
                        if app.can("workspace") {
                            Button { Task { await app.togglePin(chat.sid) }; dismiss() } label: { Label(app.pinned.contains(chat.sid) ? "Unpin" : "Pin", systemImage: "pin") }
                        }
                        if app.can("fork") {
                            Button { dismiss(); Task { if let nid = await app.fork(chat.sid) { app.say("Forked"); app.swapChat(nid) } } } label: { Label("Fork this chat", systemImage: "arrow.triangle.branch") }
                        }
                        if app.can("workspace") {
                            let arch = app.archived.contains(chat.sid)
                            Button(role: arch ? nil : .destructive) {
                                if arch { Task { _ = await app.setArchived(chat.sid, false) }; dismiss() } else { confirmArchive = true }
                            } label: { Label(arch ? "Unarchive" : "Archive", systemImage: "archivebox") }
                        }
                    }
                }
                Section { Text(chat.sid).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .navigationTitle(chat.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton() }
            .confirmationDialog("Archive this chat?", isPresented: $confirmArchive, titleVisibility: .visible) {
                Button("Archive", role: .destructive) {
                    Task {
                        let r = await app.setArchived(chat.sid, true)
                        if r == "active" { archiveActive = true } else if r == nil { dismiss(); NotificationCenter.default.post(name: .openDrawer, object: nil) }
                    }
                }
            } message: { Text("It moves out of your chat list. You can find it under Archived.") }
            .confirmationDialog("This chat is still working", isPresented: $archiveActive, titleVisibility: .visible) {
                Button("Stop and archive", role: .destructive) { Task { if await app.setArchived(chat.sid, true, stop: true) == nil { dismiss(); NotificationCenter.default.post(name: .openDrawer, object: nil) } } }
            } message: { Text("Archive it and stop its work?") }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: model

enum Catalog {
    static func find(_ cat: JSON, _ provider: String, _ model: String) -> JSON? {
        for g in cat["groups"].array where g["id"].str == provider { if let m = g["models"].array.first(where: { $0["id"].str == model }) { return m } }
        return nil
    }
}

struct ModelSheet: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    @State private var catalog: JSON?
    @State private var error = ""
    // One choice at a time: an effort tapped while a model change is still on its way carried the old model with it
    // and switched the chat back (Codex r137).
    @State private var applying = false

    var body: some View {
        List {
            Loading(value: catalog, error: error) { cat in
                let cur = chat.model ?? ModelChoice(provider: cat["default"]["provider"].str, model: cat["default"]["model"].str, effort: cat["default"]["reasoningEffort"].str)
                let m = Catalog.find(cat, cur.provider, cur.model)
                let effs = m?["reasoning"]["efforts"].array ?? []
                let curEff = cur.effort.isEmpty ? (m?["reasoning"]["defaultEffort"].str ?? "") : cur.effort
                if !effs.isEmpty {
                    Section("Effort · \(m?["name"].str ?? "")") {
                        ForEach(effs.indices, id: \.self) { i in
                            CheckRow(title: effs[i]["name"].str, sub: effs[i]["description"].string, on: effs[i]["id"].str == curEff) { Task { await apply(cur.provider, cur.model, effs[i]["id"].str) } }
                        }
                    }
                }
                ForEach(cat["groups"].array.indices, id: \.self) { gi in
                    let g = cat["groups"].array[gi]
                    Section(g["name"].str) {
                        ForEach(g["models"].array.indices, id: \.self) { mi in
                            let x = g["models"].array[mi]
                            CheckRow(title: x["name"].str, sub: x["description"].string, on: g["id"].str == cur.provider && x["id"].str == cur.model) {
                                Task { await apply(g["id"].str, x["id"].str, nil) }
                            }
                        }
                    }
                }
                ForEach(cat["failures"].array.indices, id: \.self) { i in
                    Text("\(cat["failures"].array[i]["name"].str): models could not be loaded.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(applying)
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
        .task { do { catalog = try await app.modelCatalog(force: false) } catch { self.error = error.localizedDescription } }
    }

    private func apply(_ provider: String, _ model: String, _ effort: String?) async {
        guard let cat = catalog, !applying else { return }
        applying = true
        defer { applying = false }
        let m = Catalog.find(cat, provider, model)
        var eff = effort
        if eff == nil {
            let cur = chat.model
            let ok = cur.map { c in m?["reasoning"]["efforts"].array.contains { $0["id"].str == c.effort } ?? false } ?? false
            eff = ok ? cur?.effort : m?["reasoning"]["defaultEffort"].string
        }
        do {
            let r = try await DSHClient.shared.rpc("session/selectModel", ["request": .obj([("sessionId", .string(chat.sid)), ("provider", .string(provider)), ("model", .string(model)), ("reasoningEffort", eff.map { .string($0) })])])
            let sel = r["selected"].isObject ? r["selected"] : .obj([("provider", .string(provider)), ("model", .string(model)), ("reasoningEffort", eff.map { .string($0) })])
            chat.proj["modelSelection"] = ["lastUsed": chat.proj["modelSelection"]?["lastUsed"] ?? .null, "next": sel]
            app.say("Model updated for this chat")
        } catch { app.say(error.localizedDescription) }
    }
}

// MARK: permissions

struct PermissionsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    @State private var options: [JSON]?
    @State private var error = ""
    @State private var confirm: String?

    static let names: [String: (String, String)] = [
        "read-only": ("Read only", "Can look, cannot change files"),
        "workspace-write": ("Can edit this folder", "Can change files in this project folder"),
        "auto": ("Automatic", "A reviewer decides what is safe"),
        "danger-full-access": ("Full access", "Can change anything on the Mac"),
    ]
    static let rank = ["read-only": 0, "workspace-write": 1, "auto": 2, "danger-full-access": 3]

    var body: some View {
        List {
            Loading(value: options, error: error) { options in
                ForEach(options.indices, id: \.self) { i in
                    let v = options[i]["value"].str
                    let n = Self.names[v] ?? (options[i]["name"].str, "")
                    CheckRow(title: n.0, sub: n.1, on: v == chat.permission) {
                        guard v != chat.permission else { return }
                        if (Self.rank[v] ?? 9) > (Self.rank[chat.permission] ?? 0) { confirm = v } else { Task { await set(v) } }
                    }
                }
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
        .task { do { options = try await DSHClient.shared.rpc("permissionPresets/catalog")["options"].array } catch { self.error = error.localizedDescription } }
        .confirmationDialog("Allow more access?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("Allow", role: confirm == "danger-full-access" ? .destructive : nil) { if let v = confirm { Task { await set(v) } } }
        } message: { Text(confirm.map { "\(Self.names[$0]?.0 ?? $0): \(Self.names[$0]?.1 ?? ""). The assistant can then do more without asking." } ?? "") }
    }

    private func set(_ v: String) async {
        do {
            let r = try await DSHClient.shared.rpc("commands/execute", ["agentId": .string(chat.sid), "line": .string("/permission " + v), "submittedAttachments": []])
            // A refusal comes back inside a successful call; it was announced as "updated" (Codex r148).
            guard r["result"]["kind"].str != "error" else { app.say(r["result"]["text"].string ?? "Permissions unchanged"); return }
            app.say("Permissions updated"); dismiss()
        } catch { app.say(error.localizedDescription) }
    }
}

// MARK: commands

struct CommandsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    @State private var cmds: [JSON]?
    @State private var skills: [JSON] = []
    @State private var error = ""

    var body: some View {
        List {
            Loading(value: cmds, error: error) { cmds in
                Section(footer: Text("Tap a command to put it in the message box.")) {
                    if cmds.isEmpty { Text("No commands").foregroundStyle(.secondary) }
                    ForEach(cmds.indices, id: \.self) { i in pickRow(cmds[i]) }
                }
                if !skills.isEmpty { Section("Skills") { ForEach(skills.indices, id: \.self) { i in pickRow(skills[i]) } } }
            }
        }
        .navigationTitle("Commands")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
        .task {
            do {
                cmds = try await DSHClient.shared.rpc("commands/list", ["agentId": .string(chat.sid)]).array
                skills = (try? await DSHClient.shared.rpc("skills/list", ["request": ["sessionId": .string(chat.sid)]]))?["skills"].array ?? []
            } catch { self.error = error.localizedDescription }
        }
    }

    private func pickRow(_ x: JSON) -> some View {
        Button {
            // The words already typed become the command's arguments instead of being thrown away; a command already
            // at the front is the one replaced (Codex r140).
            var rest = Substring(chat.draft)
            // Only a name this menu lists: a draft that starts with a path such as `/Users/…` keeps it (Codex r141).
            let first = rest.prefix { !$0.isWhitespace }
            if ((cmds ?? []) + skills).contains(where: { "/" + $0["name"].str == first }) { rest = rest.dropFirst(first.count) }
            chat.draft = "/" + x["name"].str + " " + rest.drop { $0.isWhitespace }
            chat.saveDraft()
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("/" + x["name"].str).font(.body.monospaced()).foregroundStyle(.primary)
                if !x["description"].str.isEmpty { Text(x["description"].str).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: tasks, goal

struct TodosSheet: View {
    let chat: ChatModel
    var body: some View {
        List {
            if chat.todos.isEmpty { Text("No tasks").foregroundStyle(.secondary) }
            ForEach(chat.todos.indices, id: \.self) { i in
                let t = chat.todos[i]; let st = t["status"].str
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: st == "completed" ? "checkmark.circle.fill" : st == "in_progress" ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(st == "in_progress" ? Color.green : Color.secondary)
                    Text(t["content"].str).strikethrough(st == "completed").foregroundStyle(st == "completed" ? .secondary : .primary)
                }
            }
        }
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
    }
}

struct GoalSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    @State private var objective = ""
    @State private var maxRounds = ""
    @State private var loaded = false

    var body: some View {
        let pj = chat.proj["goal"] ?? .null
        let g = pj["goal"]
        Form {
            if g.isObject {
                Section {
                    LabeledContent("Status", value: g["phase"].str.capitalized)
                    LabeledContent("Rounds", value: "\(pj["roundsStarted"].int ?? 0) of \(g["maxGoalRounds"].int ?? 0)")
                } footer: { if let r = g["blockedReason"]["message"].string { Text(r) } }
                Section("Objective") { TextField("Objective", text: $objective, axis: .vertical).lineLimit(3...10) }
                Section {
                    if g["phase"].str == "paused" { Button("Resume") { act("resume") } }
                    else if g["phase"].str != "complete" { Button("Pause") { act("pause") } }
                    if g["phase"].str != "complete" { Button("Mark done") { act("complete") } }
                    Button("Clear goal", role: .destructive) { act("clear") }
                }
            } else {
                Section { TextField("What should be achieved?", text: $objective, axis: .vertical).lineLimit(3...10) } header: { Text("Objective") } footer: { Text("A goal keeps the assistant working across rounds until it is done.") }
                Section { TextField("Maximum rounds (optional)", text: $maxRounds).keyboardType(.numberPad) }
            }
        }
        .navigationTitle("Goal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(g.isObject ? "Save" : "Start") { act(g.isObject ? "edit" : "create") }.bold()
                    .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { if !loaded { objective = g["objective"].str; loaded = true } }
    }

    private func act(_ kind: String) {
        let g = chat.proj["goal"]?["goal"] ?? .null
        let obj = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if kind == "create" {
                    let mx = Int(maxRounds) ?? 0
                    try await DSHClient.shared.rpc("goals/create", ["agentId": .string(chat.sid), "request": .obj([("objective", .string(obj)), ("maxGoalRounds", mx > 0 ? .number(Double(mx)) : nil)])])
                } else {
                    let ref: JSON = ["id": g["id"], "revision": g["revision"]]
                    if kind == "edit" { try await DSHClient.shared.rpc("goals/edit", ["agentId": .string(chat.sid), "ref": ref, "request": ["objective": .string(obj)]]) }
                    else { try await DSHClient.shared.rpc("goals/" + kind, ["agentId": .string(chat.sid), "ref": ref]) }
                }
                app.say("Goal updated"); dismiss()
            } catch { app.say(error.localizedDescription) }
        }
    }
}

// MARK: background jobs

struct JobsSheet: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    @State private var jobs: [JSON]?
    @State private var error = ""

    var body: some View {
        List {
            Loading(value: jobs, error: error) { jobs in
                if jobs.isEmpty { Text("No background jobs").foregroundStyle(.secondary) }
                ForEach(jobs.indices, id: \.self) { i in
                    let j = jobs[i]
                    NavigationLink { JobOutputView(chat: chat, job: j) } label: {
                        HStack {
                            Circle().fill(j["status"].str == "running" ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(j["label"].string ?? j["id"].str).lineLimit(1)
                                Text(j["status"].str + (j["progress"].string.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Fmt.ago(j["startedAt"].double ?? 0)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Background jobs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
        .onAppear {
            app.mux.sub("jobs", "job/list", ["request": ["sessionId": .string(chat.sid)]], reopen: false, onError: { e in error = e["message"].string ?? "Jobs are not available" }) { f in
                if f["type"].str == "rows" { jobs = f["jobs"].array }
            }
        }
        .onDisappear { app.mux.unsub("jobs") }
    }
}

struct JobOutputView: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    let job: JSON
    @State private var out = ""
    @State private var status = ""
    /// True while the reader is at the bottom: new output follows only then, so scrolling up to read stays put.
    @State private var follow = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(out.isEmpty ? "(no output yet)" : out)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("end")
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                // The visible bottom counts the top inset, as ScrollGeom does: without it a scroll to the end can
                // read as "not at the bottom" and stop the following.
                g.contentOffset.y + g.containerSize.height + g.contentInsets.top >= g.contentSize.height - 40
            } action: { _, atEnd in follow = atEnd }
            .onChange(of: out) { _, _ in if follow { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .navigationTitle(job["label"].string ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if (status.isEmpty ? job["status"].str : status) == "running" {
                ToolbarItem(placement: .bottomBar) {
                    Button("Stop this job", role: .destructive) {
                        Task { do { try await DSHClient.shared.rpc("job/kill", ["request": ["sessionId": .string(chat.sid), "jobId": job["id"]]]); app.say("Stop requested") } catch { app.say(error.localizedDescription) } }
                    }
                }
            }
        }
        .onAppear {
            app.mux.sub("jobf", "job/follow", ["request": ["sessionId": .string(chat.sid), "jobId": job["id"], "from": 0]], reopen: false,
                        // Every open (a reconnect included) replays the log from the start, so start the screen over.
                        onReset: { out = ""; status = ""; follow = true }) { f in
                if f["type"].str == "output" { out += f["chunks"].array.map { $0["text"].str }.joined(); if out.count > 60000 { out = String(out.suffix(60000)) } }
                if let s = f["job"]["status"].string { status = s }
            }
        }
        .onDisappear { app.mux.unsub("jobf") }
    }
}

// MARK: subagents, team

struct SubagentsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel

    var body: some View {
        let list = chat.proj["subagentCatalog"]?.array ?? []
        List {
            if list.isEmpty { Text("No subagents in this chat").foregroundStyle(.secondary) }
            ForEach(list.indices, id: \.self) { i in
                let x = list[i]
                Button { dismiss(); app.swapChat(chat.sid, child: x["id"].str) } label: {
                    HStack {
                        Circle().fill(app.rows[x["id"].str]?.running == true ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(x["label"].string ?? "Subagent").foregroundStyle(.primary)
                            Text(x["mode"].str).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.ago(x["createdAt"].double ?? (Fmt.parseISO(x["createdAt"].str)?.timeIntervalSince1970 ?? 0) * 1000)).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Subagents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
    }
}

struct TeamSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    @State private var openTask: Set<String> = []

    var body: some View {
        let t = chat.proj["agentTeam"] ?? .null
        let phase = ["active": "Running", "inactive": "Inactive", "provisioning": "Preparing", "failed": "Failed"]
        let st = ["pending": "Pending", "in_progress": "In progress", "completed": "Completed"]
        List {
            if let f = t["failure"].string { Text("Invalid persisted Team record: \(f)").foregroundStyle(.red) }
            Section("Members · \(t["members"].array.count)") {
                ForEach(t["members"].array.indices, id: \.self) { i in
                    let m = t["members"].array[i]
                    Button {
                        dismiss()
                        if m["id"].str != chat.id { app.swapChat(chat.id, child: m["id"].str) }
                    } label: {
                        HStack {
                            Circle().fill(m["phase"].str == "active" ? Color.green : m["phase"].str == "failed" ? Color.red : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m["name"].str + (m["role"].str == "lead" && m["name"].str != "lead" ? " · lead" : "")).foregroundStyle(.primary)
                                Text((phase[m["phase"].str] ?? m["phase"].str) + (m["error"].string.map { " · " + $0 } ?? "") + (m["id"].str == chat.id ? " · this chat" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Shared tasks · \(t["tasks"].array.count)") {
                if t["tasks"].array.isEmpty { Text("No shared tasks yet. Create them through the conversation.").foregroundStyle(.secondary) }
                ForEach(t["tasks"].array.indices, id: \.self) { i in
                    let k = t["tasks"].array[i]
                    let open = openTask.contains(k["id"].str)
                    Button { if open { openTask.remove(k["id"].str) } else { openTask.insert(k["id"].str) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(k["subject"].str).foregroundStyle(.primary)
                            Text("\(st[k["status"].str] ?? k["status"].str) · \(k["ownerName"].string.map { "Owner " + $0 } ?? "Unowned") · \(k["status"].str == "completed" ? "Done" : k["ready"].truthy ? "Ready" : "Blocked by dependencies")")
                                .font(.caption).foregroundStyle(.secondary)
                            if open {
                                Text(k["description"].str).font(.footnote).foregroundStyle(.secondary)
                                if !k["blockedBy"].array.isEmpty { Text("Blocked by " + k["blockedBy"].array.map(\.str).joined(separator: ", ")).font(.caption) }
                                if !k["writeScopes"].array.isEmpty { Text("Write scopes: " + k["writeScopes"].array.map(\.str).joined(separator: ", ")).font(.caption) }
                                ForEach(k["writeScopeWarnings"].array.indices, id: \.self) { w in Text(k["writeScopeWarnings"].array[w].str).font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Agent team")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
    }
}

// MARK: files

struct FilesSheet: View {
    let chat: ChatModel
    let path: String
    @State private var entries: [JSON]?
    @State private var truncated = false
    @State private var error = ""

    var body: some View {
        List {
            Loading(value: entries, error: error) { entries in
                if entries.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
                ForEach(entries.indices, id: \.self) { i in
                    let e = entries[i]
                    let p = path == "." ? e["name"].str : path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + e["name"].str
                    let dir = e["type"].str == "directory"
                    NavigationLink {
                        if dir { FilesSheet(chat: chat, path: p) } else { FileViewer(chat: chat, path: p) }
                    } label: {
                        HStack {
                            Image(systemName: dir ? "folder.fill" : "doc").foregroundStyle(dir ? Color.accentColor : .secondary)
                            Text(e["name"].str).lineLimit(1)
                            Spacer()
                            if let s = e["size"].double { Text(Fmt.bytes(s)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if truncated { Text("Only the first entries are shown.").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(path == "." ? "Files" : Fmt.base(path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
        .task {
            do {
                let v = try await DSHClient.shared.rpc("workspaceFiles/list", ["workspaceFileScopeId": .string(chat.sid), "path": .string(path)])
                entries = v["entries"].array.sorted { a, b in
                    let da = a["type"].str == "directory", db = b["type"].str == "directory"
                    return da != db ? da : a["name"].str.localizedStandardCompare(b["name"].str) == .orderedAscending
                }
                truncated = v["truncated"].truthy
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct FileViewer: View {
    let chat: ChatModel
    let path: String
    @State private var text: String?
    @State private var image: UIImage?
    @State private var doc: URL?
    /// The local copy a document was saved to: kept after the system previewer closes, so the sheet shows the file
    /// with an Open button instead of a spinner that never ends.
    @State private var saved: URL?
    @State private var info = ""
    @State private var error = ""
    /// A failed download or a dropped connection can be tried again; a file that is too large or missing cannot.
    @State private var retryable = false
    /// Lines asked for; a long file grows by one page each time Show more is tapped.
    @State private var limit = 1500
    @State private var more = false
    @State private var loadingMore = false

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
            } else if let text {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if path.lowercased().hasSuffix(".md") && text.count <= Self.markdownCap { MarkdownView(text: text) }
                        else {
                            ScrollView(.horizontal) {
                                Text(Self.clipLines(text)).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        Text(info).font(.caption).foregroundStyle(.secondary)
                        if more {
                            Button { Task { loadingMore = true; limit += 1500; await load(); loadingMore = false } } label: {
                                HStack(spacing: Tok.sp2) {
                                    if loadingMore { ProgressView() }
                                    Text(loadingMore ? "Loading…" : "Show more")
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered).disabled(loadingMore)
                            .accessibilityLabel("Show more of this file")
                            .accessibilityIdentifier("file.more")
                        }
                    }
                    .padding()
                }
            } else if let saved {
                ContentUnavailableView {
                    Label(Fmt.base(path), systemImage: "doc.richtext")
                } actions: {
                    Button("Open") { doc = saved }.buttonStyle(.borderedProminent)
                }
            } else if !error.isEmpty {
                ContentUnavailableView {
                    Label(error, systemImage: "doc.questionmark")
                } actions: {
                    if retryable { Button("Try again") { error = ""; Task { await load() } }.buttonStyle(.bordered) }
                }
            } else { ProgressView() }
        }
        .navigationTitle(Fmt.base(path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            DoneButton()
            // Every kind of file can leave the app, not only text: a picture or a PDF goes out as itself.
            if let text { ToolbarItem(placement: .topBarLeading) { ShareLink(item: text) } }
            else if image != nil, let saved { ToolbarItem(placement: .topBarLeading) { ShareLink(item: saved, preview: SharePreview(Fmt.base(path), image: Image(uiImage: image!))) } }
            else if let saved { ToolbarItem(placement: .topBarLeading) { ShareLink(item: saved) } }
        }
        .task { await load() }
        .quickLookPreview($doc)
    }

    static let byteCap = 60_000_000, textCap = 400_000, lineCap = 15_000, markdownCap = 120_000, lineWidthCap = 2_000

    /// One line of minified code can be megabytes wide; past a screenful of characters it is cut with an ellipsis.
    static func clipLines(_ t: String) -> String {
        guard t.split(separator: "\n", omittingEmptySubsequences: false).contains(where: { $0.count > lineWidthCap }) else { return t }
        return t.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.count > lineWidthCap ? $0.prefix(lineWidthCap) + "…" : String($0) }.joined(separator: "\n")
    }

    /// A camera photo decoded at full size can take hundreds of megabytes; decode it straight to at most 3000 px on
    /// the long side instead, which is still sharper than the screen at 2x zoom.
    static func downsample(_ data: Data, maxPixel: Int = 3000) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func load() async {
        do {
            let v = try await DSHClient.shared.rpc("workspaceFiles/read", ["workspaceFileScopeId": .string(chat.sid), "path": .string(path), "range": ["offset": 1, "limit": .number(Double(limit))]])
            // A huge file must not take the app down: the text shown is capped, and so is how far Show more grows.
            let t = v["text"].str
            text = t.count > Self.textCap ? String(t.prefix(Self.textCap)) : t
            more = !v["eof"].truthy && t.count <= Self.textCap && limit < Self.lineCap
            info = (v["eof"].truthy && t.count <= Self.textCap ? "" : "Showing the start of the file. ") + Fmt.bytes(v["bytes"].double ?? 0) + " · " + v["absolutePath"].str
        } catch let e as RPCError {
            if text != nil { chat.app?.say("Could not load more of this file"); return }
            if e.code.contains("not-text") {
                // One download, capped so a huge file is refused rather than filling memory; a picture is decoded
                // small, anything else goes to the system's own previewer (PDF, Word, Excel, slides), which is what
                // the desktop's document pane does with a browser renderer.
                do {
                    let d = try await DSHClient.shared.readBytes(scope: chat.sid, path: path, maxBytes: Self.byteCap)
                    // The original bytes go to a local copy either way, so Share sends the real file, not the
                    // smaller picture decoded for the screen.
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(Fmt.base(path))
                    let wrote = (try? d.write(to: url, options: .atomic)) != nil
                    if path.range(of: #"\.(png|jpe?g|gif|webp|heic)$"#, options: [.regularExpression, .caseInsensitive]) != nil,
                       let img = Self.downsample(d) { image = img; if wrote { saved = url }; return }
                    if wrote { saved = url; doc = url; return }
                } catch let b as RPCError where b.code == "too-large" {
                    error = "This file is too large to preview."; retryable = false; return
                } catch {
                    self.error = "Couldn't load this file."; retryable = true; return
                }
            }
            error = e.code.contains("not-text") ? "This file is not text, so it cannot be previewed here."
                : e.code.contains("outside") ? "This file is outside the project folder."
                : e.code.contains("not-found") ? "This file no longer exists."
                : e.code.contains("too-large") ? "This file is too large to preview." : "Couldn't load this file."
            retryable = !["not-text", "outside", "not-found", "too-large"].contains { e.code.contains($0) }
        } catch {
            if text != nil { chat.app?.say("Could not load more of this file"); return }
            self.error = "Couldn't load this file."; retryable = true
        }
    }
}

/// A picture that pinches to zoom and double-taps between fit and 2x, the way Photos does.
struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    var body: some View {
        // Fit is measured against the sheet itself, width and height, so a tall picture is whole on screen at 1x and a
        // narrow sheet (iPad, split view) never cuts the picture off.
        GeometryReader { geo in
            let fit = min(geo.size.width / max(image.size.width, 1), geo.size.height / max(image.size.height, 1))
            let w = image.size.width * fit * scale, h = image.size.height * fit * scale
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image).resizable().interpolation(.high)
                    .frame(width: w, height: h)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .defaultScrollAnchor(.center)
        }
        .gesture(MagnifyGesture()
            .onChanged { scale = min(max(base * $0.magnification, 1), 6) }
            .onEnded { _ in base = scale })
        .onTapGesture(count: 2) { withAnimation(.snappy) { set(scale > 1 ? 1 : 2) } }
        .accessibilityElement()
        .accessibilityLabel("Picture")
        .accessibilityValue("\(Int((scale * 100).rounded())) percent")
        .accessibilityAction(named: "Zoom in") { set(min(scale * 2, 6)) }
        .accessibilityAction(named: "Zoom out") { set(max(scale / 2, 1)) }
        .accessibilityAction(named: "Reset zoom") { set(1) }
    }
    private func set(_ s: CGFloat) { scale = s; base = s }
}

struct DeliverablesSheet: View {
    let chat: ChatModel
    var body: some View {
        List {
            ForEach(Array(chat.deliverables.enumerated()), id: \.offset) { _, f in
                NavigationLink { FileViewer(chat: chat, path: f.path) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.base(f.path)).font(.body.weight(.medium))
                        Text(f.description.isEmpty ? f.path : f.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle("Files from this chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
    }
}

// MARK: code changes

struct ChangesListSheet: View {
    let chat: ChatModel
    var body: some View {
        let gs = Array(chat.items.filter { $0.kind == .changes }.reversed())
        List {
            ForEach(gs, id: \.key) { g in
                let sm = chat.changes[g.seq]
                NavigationLink { ChangedFilesSheet(chat: chat, seq: g.seq) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Turn \(g.turn)")
                        if let sm, sm.isObject { Text("\(sm["total"].int ?? 0) files · +\(sm["added"].int ?? 0) −\(sm["deleted"].int ?? 0)").font(.caption).foregroundStyle(.secondary) }
                        else { Text(sm?.string == "err" ? "Changes unavailable" : "Checking…").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .task(id: chat.snapshots) { await chat.loadChanges(g.seq) }
            }
        }
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
    }
}

struct ChangedFilesSheet: View {
    let chat: ChatModel
    let seq: Int
    var body: some View {
        let sm = chat.changes[seq]
        List {
            if let sm, sm.isObject {
                Section {
                    ForEach(sm["files"].array.indices, id: \.self) { i in
                        let f = sm["files"].array[i]
                        NavigationLink { DiffView(chat: chat, seq: seq, index: i) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f["display"].str).font(.subheadline.monospaced()).lineLimit(2).truncationMode(.middle)
                                Group {
                                    if f["binary"].truthy { Text("Binary file") }
                                    else if f["oversized"].truthy { Text("Too large to compare") }
                                    else { Text("+\(f["added"].int ?? 0)").foregroundColor(.green) + Text(" −\(f["deleted"].int ?? 0)").foregroundColor(.red) }
                                }
                                .font(.caption)
                            }
                        }
                    }
                } header: { Text("\(sm["total"].int ?? 0) file\(sm["total"].int == 1 ? "" : "s") · +\(sm["added"].int ?? 0) −\(sm["deleted"].int ?? 0) · read only") }
            } else if sm?.string == "err" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The changes for this turn could not be loaded.")
                    Button("Try again") { Task { await chat.loadChanges(seq) } }
                }
            } else { ProgressView() }
        }
        .navigationTitle("Changed files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
        .task(id: chat.snapshots) { await chat.loadChanges(seq) }
    }
}

struct DiffView: View {
    let chat: ChatModel
    let seq: Int
    let index: Int
    @State private var d: JSON?
    @State private var error = ""

    var body: some View {
        Group {
            if let d {
                if d["kind"].str != "text" {
                    ContentUnavailableView(d["display"].str, systemImage: "doc", description: Text(d["kind"].str == "binary" ? "A binary file, no text comparison." : "Too large to compare here."))
                } else {
                    // Lines wrap at the screen's width. A sideways scroll gave the lazy stack no width to wrap at, so
                    // a prose file's diff came out one word per line in a thin strip (operator screenshot, 10-16).
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Text(d["before"].isNull ? "New file" : d["after"].isNull ? "Deleted file" : "Edited").font(.caption.weight(.bold)).padding(8)
                            ForEach(Array(d["hunks"].array.prefix(200).enumerated()), id: \.offset) { _, h in
                                Text("@@ −\(h["oldStart"].int ?? 0),\(h["oldLines"].int ?? 0) +\(h["newStart"].int ?? 0),\(h["newLines"].int ?? 0) @@")
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.08))
                                ForEach(Array(h["lines"].array.prefix(2000).enumerated()), id: \.offset) { _, l in
                                    let ln = l.str
                                    let t = ln.first
                                    Text((t == "+" ? "+ " : t == "-" ? "− " : "  ") + ln.dropFirst())
                                        .font(.system(.caption, design: .monospaced))
                                        .padding(.horizontal, 8).padding(.vertical, 1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(t == "+" ? Color.green.opacity(0.14) : t == "-" ? Color.red.opacity(0.14) : Color.clear)
                                }
                                // The caps keep the view fast; saying so keeps a cut diff from passing for the whole one (Codex r156).
                                if h["lines"].array.count > 2000 { DiffCut(n: h["lines"].array.count - 2000, what: "lines") }
                            }
                            if d["hunks"].array.count > 200 { DiffCut(n: d["hunks"].array.count - 200, what: "changed sections") }
                        }
                        .textSelection(.enabled)
                    }
                }
            } else if !error.isEmpty { Text(error) } else { ProgressView() }
        }
        .navigationTitle(d?["display"].string.map(Fmt.base) ?? "Diff")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DoneButton() }
        .task {
            do { d = try await DSHClient.shared.getJSON("/api/changes.diff?sessionId=\(chat.sid.urlQuery)&seq=\(seq)&index=\(index)") }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct DiffCut: View {
    let n: Int
    let what: String
    var body: some View {
        Text("\(n) more \(what) not shown").font(.caption.italic()).foregroundStyle(.secondary).padding(8)
    }
}

// MARK: feedback, rename, edit

struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    let messageId: String
    @State var rating: String
    @State private var note = ""

    var body: some View {
        Form {
            Section("Rating") {
                CheckRow(title: "Good answer", on: rating == "positive") { rating = "positive" }
                CheckRow(title: "Bad answer", on: rating == "negative") { rating = "negative" }
            }
            Section("Note") { TextField("What was good or bad? (optional)", text: $note, axis: .vertical).lineLimit(2...6) }
            if chat.feedback[messageId] != nil {
                Section { Button("Remove my rating", role: .destructive) { Task { await chat.deleteFeedback(messageId: messageId); dismiss() } } }
            }
        }
        .navigationTitle("Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { if await chat.putFeedback(messageId: messageId, rating: rating, note: note.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() } } }.bold() }
        }
        .onAppear { note = chat.feedback[messageId]?["note"].str ?? "" }
    }
}

struct RenameSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    @State private var name = ""
    var body: some View {
        Form { TextField("Chat name", text: $name) }
            .navigationTitle("Rename chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { let t = name.trimmingCharacters(in: .whitespaces); Task { if await app.rename(chat.sid, t) { chat.proj["title"] = .string(t); dismiss() } } }
                        .bold().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { name = chat.title == "Untitled" ? "" : chat.title }
    }
}

/// Editing a past message makes a branch: a copy of the chat from just before it.
struct EditMessageSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel
    let key: String
    @State private var text = ""

    var body: some View {
        Form {
            Section { TextField("Message", text: $text, axis: .vertical).lineLimit(4...14) } header: { Text("Message") } footer: {
                Text("Editing makes a branch: a copy of this chat from just before this message. The original chat stays as it is.")
            }
            Section { Button("Regenerate the reply (same words)") { Task { await branch(edited: nil) } } }
        }
        .navigationTitle("Edit message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Branch") { Task { await branch(edited: text) } }.bold().disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .onAppear { text = chat.items.first { $0.key == key }?.text ?? "" }
    }

    private func branch(edited: String?) async {
        guard let it = chat.items.first(where: { $0.key == key }) else { return }
        let msg = (edited ?? it.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { app.say("The message cannot be empty"); return }
        // The phone keeps no copy of what was attached, so the same words alone would be a different prompt.
        let attached = it.images > 0 || !it.files.isEmpty
        if edited == nil && attached { app.say("That message had attachments: use Edit and add them again"); return }
        let prev = chat.ends.filter { $0.key < it.turn }.max { $0.key < $1.key }
        if prev == nil && it.turn > 1 && chat.hasMore { app.say("Load earlier messages first"); return }
        var nid: String?
        if let prev { nid = await app.fork(chat.sid, atSeq: prev.value) }
        else {
            let w = app.workspace(of: chat.sid)
            let req: JSON = w.map { ["workspaceId": .string($0.id)] } ?? ["cwd": .string(chat.header["cwd"].str)]
            do { nid = try await DSHClient.shared.rpc("session/create", ["request": req])["sessionId"].string }
            catch { app.say(error.localizedDescription); return }
            guard nid?.isEmpty == false else { app.say("The branch came back without a chat"); return }
            app.refreshList()
        }
        guard let nid else { return }
        if edited == nil { PendingOpen.shared.set(nid, msg) } else { UserDefaults.standard.set(msg, forKey: "draft." + nid) }
        dismiss()
        app.swapChat(nid)
        app.say(edited == nil ? "Branch started" : attached ? "Branch ready: add the attachments again, then send" : "Branch ready: review and send")
    }
}

// MARK: approvals

struct ApprovalSheet: View {
    @Environment(AppModel.self) private var app
    let frame: JSON
    /// Set on the first tap and held until the Mac answers: a second tap — or the other button — would send a
    /// second, contradictory decision for the same request.
    @State private var deciding = false

    var body: some View {
        let r = frame["request"]
        let reason = r["displayReason"]["en"].string ?? r["displayReason"].object.values.first?.string ?? r["reason"].str
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill").font(.system(size: 34)).foregroundStyle(.orange).padding(.top, 24)
            Text("Approval needed").font(.title3.bold())
            // Which chat is asking: the sheet comes up over whatever chat is open, and a request from another one read
            // as this one's (Codex r162).
            if let row = app.rows[frame["agentId"].str] {
                Text(row.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
            (Text("The assistant wants to use ") + Text(r["toolName"].string ?? "a tool").bold() + Text("."))
                .multilineTextAlignment(.center)
            if !reason.isEmpty {
                ScrollView { Text(reason).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if app.approvals.count > 1 { Text("\(app.approvals.count - 1) more waiting").font(.footnote).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button { decide(true) } label: { Text("Allow once").bold().frame(maxWidth: .infinity).frame(minHeight: 44) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("approval.allow")
                Button(role: .destructive) { decide(false) } label: { Text("Reject").frame(maxWidth: .infinity).frame(minHeight: 44) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("approval.reject")
            }
            .disabled(deciding)
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private func decide(_ allow: Bool) {
        guard !deciding else { return }
        deciding = true
        Task {
            await app.answerApproval(frame, allow: allow)
            deciding = false
        }
    }
}
