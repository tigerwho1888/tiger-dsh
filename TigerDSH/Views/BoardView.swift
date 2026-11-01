import SwiftUI

/// The task board, when the Mac has one. It belongs to an optional plugin rather than the host, so its entry point
/// only appears while `GET /api/task-board/state` answers. Read-only on purpose (advisor/operator ruling
/// 2026-10-06): phone actions on the production pipeline cards are parked for a v2 the operator approves;
/// the verified action contract is parked in .tmp/task-board-actions-v2.md.
struct BoardView: View {
    @State private var state: JSON = .null
    @State private var error = ""

    private var tasks: [JSON] { state["tasks"].array }
    private let order = ["running", "todo", "backlog", "failed", "done"]

    var body: some View {
        List {
            if !error.isEmpty {
                Section { Text(error).foregroundStyle(.secondary) }
            } else if !state.isObject {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Section {
                    LabeledContent("Working now", value: "\(state["power"]["runningSessions"].int ?? 0)")
                    LabeledContent("Armed schedules", value: "\(state["power"]["armedSchedules"].int ?? 0)")
                    LabeledContent("Time zone", value: state["scheduler"]["timeZone"].str)
                } header: { Text("Board") }
                ForEach(order, id: \.self) { st in
                    let cards = tasks.filter { $0["status"].str == st }
                    if !cards.isEmpty {
                        Section("\(title(st)) · \(cards.count)") {
                            ForEach(cards.indices, id: \.self) { i in row(cards[i]) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Task board")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder private func row(_ t: JSON) -> some View {
        let ex = t["latestExecution"] ?? .null
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(t["title"].str).font(.body.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 4)
            }
            if !t["tags"].array.isEmpty {
                Text(t["tags"].array.map { $0["name"].str }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(summary(t, ex)).font(.caption).foregroundStyle(ex["result"].str == "failed" ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)  // whole: a confirmation request comes last (Codex r160)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("board.card")
    }

    private func title(_ status: String) -> String {
        switch status {
        case "running": return "Running"
        case "todo": return "To do"
        case "backlog": return "Backlog"
        case "failed": return "Failed"
        case "done": return "Done"
        default: return status.capitalized
        }
    }

    /// The schedule, the last outcome and anything the board wants a person for.
    private func summary(_ t: JSON, _ ex: JSON) -> String {
        var parts: [String] = []
        let s = t["schedule"] ?? .null
        if s["enabled"].truthy, let cron = s["cron"].string, !cron.isEmpty { parts.append("every " + cron) }
        if let n = t["executionCount"].int, n > 0 { parts.append("\(n) run\(n == 1 ? "" : "s")") }
        if let r = ex["result"].string, !r.isEmpty { parts.append("last: " + r) }
        if t["permissionPending"].truthy { parts.append("needs your confirmation on the Mac") }
        if t["awaitingSubtasks"].truthy { parts.append("waiting on its subtasks") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            state = try await DSHClient.shared.getJSON("/api/task-board/state", timeout: 20)
            error = ""
        } catch let e as RPCError where e.kind == .missing {
            error = "This Mac has no task board."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
