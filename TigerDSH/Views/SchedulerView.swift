import SwiftUI

/// Scheduled tasks (the host's Schedule catalog, as the desktop Automation page uses it), including
/// changing a task's time and repeat rule, which the web app could not do.
struct SchedulerView: View {
    @Environment(AppModel.self) private var app
    @Binding var path: [Route]
    @State private var rows: [JSON]?
    @State private var error = ""

    var body: some View {
        List {
            Loading(value: rows, error: error) { rows in
                let active = rows.filter { $0["status"].str == "active" }
                let ended = rows.filter { $0["status"].str != "active" }
                if rows.isEmpty {
                    Text("No scheduled tasks yet. Ask the assistant in a chat to remind you or to run something later, and it will appear here.").foregroundStyle(.secondary)
                }
                if !active.isEmpty { Section("Active · \(active.count)") { ForEach(active.indices, id: \.self) { i in row(active[i]) } } }
                if !ended.isEmpty { Section("Ended · \(ended.count)") { ForEach(ended.indices, id: \.self) { i in row(ended[i]) } } }
            }
        }
        .navigationTitle("Scheduled tasks")
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ r: JSON) -> some View {
        NavigationLink { ScheduleTaskView(record: r, path: $path, reload: { await load() }) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(r["title"].string ?? "Untitled task").font(.body.weight(.medium))
                Text(Schedule.timing(r) + (r["status"].str == "active" ? " · next " + Fmt.when(r["scheduledAt"].str) : " · ended"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func load() async {
        do { rows = try await DSHClient.shared.rpc("schedule/catalog").array; error = "" }
        catch {
            self.error = (error as? RPCError)?.kind == .missing ? "The Scheduler plugin is not loaded on this Mac." : error.localizedDescription
            // A list already on screen hides the error row; say it, so old rows are not taken for fresh ones.
            if rows != nil { app.say(self.error) }
        }
    }
}

enum Schedule {
    static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static func every(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        if m % 1440 == 0 { return "\(m / 1440) day\(m == 1440 ? "" : "s")" }
        if m % 60 == 0 { return "\(m / 60) hour\(m == 60 ? "" : "s")" }
        return "\(m) minutes"
    }

    static func timing(_ r: JSON) -> String {
        let t = String(r["time"].str.prefix(5))
        switch r["kind"].str {
        case "after", "at": return "Once"
        case "every": return "Every " + every(r["everySeconds"].double ?? 0)
        case "daily": return "Daily at \(t)"
        case "weekly": return r["weekdays"].array.compactMap { $0.int }.map { weekdays[max(0, min(6, $0 - 1))] }.joined(separator: ", ") + " at \(t)"
        case "cron": return "Cron " + r["expression"].str
        default: return r["kind"].str
        }
    }

    /// The record exactly as observed, minus fields the host adds around it.
    static func expected(_ r: JSON) -> JSON {
        var o = r.object
        o["sessionId"] = nil; o["status"] = nil; o["lastDelivery"] = nil
        return .object(o)
    }
}

struct ScheduleTaskView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var record: JSON
    @Binding var path: [Route]
    let reload: () async -> Void
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        let r = record
        let active = r["status"].str == "active"
        List {
            Section {
                LabeledContent("Status", value: active ? "Active" : "Ended")
                LabeledContent("Repeats", value: Schedule.timing(r))
                LabeledContent(active ? "Next run" : "Last run", value: Fmt.when(r["scheduledAt"].str))
                if r["lastDelivery"].isObject { LabeledContent("Last delivered", value: Fmt.when(r["lastDelivery"]["deliveredAt"].str)) }
                if let tz = r["timeZone"].string { LabeledContent("Time zone", value: tz) }
            }
            Section("Instruction") { Text(r["prompt"].str).textSelection(.enabled) }
            Section {
                if active { Button("Edit task") { editing = true } }
                NavigationLink("Delivery history") { DeliveryHistoryView(record: r) }
                Button("Open the conversation") {
                    // The chat opens in the main window; the screens that were on top of it go away there.
                    NotificationCenter.default.post(name: .openChat, object: r["sessionId"].str)
                }
                Button("Delete task", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(r["title"].string ?? "Task")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            NavigationStack { ScheduleEditor(record: r) { new in record = new; Task { await reload() } } }
        }
        .confirmationDialog("Delete \(r["title"].string ?? "this task")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete task", role: .destructive) {
                Task {
                    do {
                        let v = try await DSHClient.shared.rpc("schedule/delete", ["request": ["sessionId": r["sessionId"], "id": r["id"]]])
                        app.say(v["deleted"].truthy ? "Task deleted" : "It was already gone")
                    } catch { app.say(error.localizedDescription); return }
                    await reload(); dismiss()
                }
            }
        } message: { Text("It will not run again. Its past deliveries stay in the chat.") }
    }
}

/// Name, instruction, and timing. The host re-checks the whole record, so an edit made on the Mac
/// meanwhile is reported instead of overwritten.
struct ScheduleEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let record: JSON
    let saved: (JSON) -> Void

    enum Kind: String, CaseIterable, Identifiable { case once = "Once", every = "Every", daily = "Daily", weekly = "Weekly", cron = "Cron"; var id: String { rawValue } }

    @State private var title = ""
    @State private var prompt = ""
    @State private var kind: Kind = .daily
    @State private var date = Date()
    @State private var time = Date()
    @State private var everyValue = 1
    @State private var everyUnit = 60          // seconds per unit: 60 minutes, 3600 hours, 86400 days
    @State private var weekdays: Set<Int> = [1]
    @State private var cron = ""
    @State private var timeZone = TimeZone.current.identifier
    @State private var timingChanged = false
    @State private var saving = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Name") { TextField("Task name", text: $title) }
            Section("Instruction") { TextField("What should the assistant do?", text: $prompt, axis: .vertical).lineLimit(3...10) }
            Section {
                Picker("Repeat", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                switch kind {
                case .once:
                    DatePicker("Runs at", selection: $date, in: Date()...)
                case .every:
                    Stepper("Every \(everyValue)", value: $everyValue, in: 1...999)
                    Picker("Unit", selection: $everyUnit) { Text("Minutes").tag(60); Text("Hours").tag(3600); Text("Days").tag(86400) }
                case .daily:
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                case .weekly:
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { d in
                            let on = weekdays.contains(d)
                            Button(String(Schedule.weekdays[d - 1].prefix(2))) { if on { if weekdays.count > 1 { weekdays.remove(d) } } else { weekdays.insert(d) } }
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
                                .foregroundStyle(on ? .white : .primary)
                                .buttonStyle(.plain)
                        }
                    }
                case .cron:
                    TextField("minute hour day month weekday", text: $cron).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if kind != .every && kind != .once {
                    LabeledContent("Time zone", value: timeZone)
                }
            } header: { Text("When") } footer: { Text(timingChanged ? "The new timing replaces the old one when you save." : "Leave as it is to keep the current timing.") }
        }
        .navigationTitle("Edit task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("Save").bold() } }
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        // Filling the fields must not count as the user editing them, so the flag that the change handlers watch
        // flips after this update, not inside it.
        .onAppear { if !loaded { fill(); Task { loaded = true } } }
        .onChange(of: kind) { _, _ in if loaded { timingChanged = true } }
        .onChange(of: date) { _, _ in if loaded { timingChanged = true } }
        .onChange(of: time) { _, _ in if loaded { timingChanged = true } }
        .onChange(of: everyValue) { _, _ in if loaded { timingChanged = true } }
        .onChange(of: everyUnit) { _, _ in if loaded { timingChanged = true } }
        .onChange(of: weekdays) { _, _ in if loaded { timingChanged = true } }
        .onChange(of: cron) { _, _ in if loaded { timingChanged = true } }
    }

    private func fill() {
        let r = record
        title = r["title"].str; prompt = r["prompt"].str
        if let tz = r["timeZone"].string, !tz.isEmpty { timeZone = tz }
        let hm = r["time"].str.split(separator: ":").compactMap { Int($0) }
        if hm.count >= 2, let t = Calendar.current.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: Date()) { time = t }
        switch r["kind"].str {
        case "after", "at": kind = .once; date = Fmt.parseISO(r["scheduledAt"].str) ?? Date().addingTimeInterval(3600)
        case "every":
            kind = .every
            let s = Int(r["everySeconds"].double ?? 3600)
            if s % 86400 == 0 { everyUnit = 86400; everyValue = s / 86400 } else if s % 3600 == 0 { everyUnit = 3600; everyValue = s / 3600 } else { everyUnit = 60; everyValue = max(1, s / 60) }
        case "daily": kind = .daily
        case "weekly": kind = .weekly; weekdays = Set(r["weekdays"].array.compactMap { $0.int })
        case "cron": kind = .cron; cron = r["expression"].str
        default: break
        }
    }

    private var hhmmss: String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d:00", c.hour ?? 0, c.minute ?? 0)
    }

    private var change: JSON? {
        guard timingChanged else { return nil }
        switch kind {
        case .once: return ["kind": "at", "at": .string(ISO8601DateFormatter().string(from: date))]
        case .every: return ["kind": "every", "every_seconds": .number(Double(everyValue * everyUnit))]
        case .daily: return ["kind": "daily", "daily": ["time": .string(hhmmss), "time_zone": .string(timeZone)]]
        case .weekly: return ["kind": "weekly", "weekly": ["time": .string(hhmmss), "time_zone": .string(timeZone), "weekdays": .array(weekdays.sorted().map { .number(Double($0)) })]]
        case .cron: return ["kind": "cron", "cron": ["expression": .string(cron.trimmingCharacters(in: .whitespaces)), "time_zone": .string(timeZone)]]
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let r = record
        do {
            let v = try await DSHClient.shared.rpc("schedule/update", ["request": .obj([
                ("sessionId", r["sessionId"]), ("id", r["id"]), ("expected", Schedule.expected(r)),
                ("title", .string(title.trimmingCharacters(in: .whitespaces))), ("prompt", .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines))),
                ("change", change),
            ])])
            // The answer is the saved record (directly or under `record`), or a miss with a `code`.
            if v["record"].isObject || (v["code"].isNull && v["kind"].string != nil) {
                var rec = v["record"].isObject ? v["record"] : v
                if case .object(var o) = rec { o["sessionId"] = r["sessionId"]; o["status"] = o["status"] ?? r["status"]; rec = .object(o) }
                app.say("Saved"); saved(rec); dismiss()
            } else {
                let code = v["code"].str
                app.say(code == "schedule_conflict" ? "It changed on the Mac. Close and open it again." : code == "schedule_ended" ? "That task has ended." : v["message"].string ?? (code.isEmpty ? "Could not save" : code))
            }
        } catch { app.say(error.localizedDescription) }
    }
}

struct DeliveryHistoryView: View {
    let record: JSON
    @State private var v: JSON?
    @State private var error = ""
    var body: some View {
        List {
            Loading(value: v, error: error) { v in
                let recs = v["records"].array
                Section(footer: Text(v["earlierRecordsPruned"].truthy ? "Older records were removed by the Mac's retention limit." : "")) {
                    if recs.isEmpty { Text("Nothing has been delivered yet.").foregroundStyle(.secondary) }
                    ForEach(recs.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.when(recs[i]["deliveredAt"].str))
                            if let p = recs[i]["prompt"].string { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Delivery history")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { v = try await DSHClient.shared.rpc("schedule/history", ["request": ["sessionId": record["sessionId"], "id": record["id"], "limit": 30]]) }
            catch { self.error = error.localizedDescription }
        }
    }
}
