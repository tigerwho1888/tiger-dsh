import SwiftUI

/// The chat's turns, newest first: tapping one takes the reader back to it, loading earlier pages when the turn is
/// not in the loaded window. This is what the desktop's trajectory list is for — finding your way into a long chat.
struct TurnsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chat: ChatModel

    private var turns: [JSON] { chat.proj["turnOutline"]?.array ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if turns.isEmpty {
                    Text("No turns yet.").foregroundStyle(.secondary)
                }
                ForEach(turns.indices.reversed(), id: \.self) { i in
                    let t = turns[i]
                    Button {
                        Trace.mark("jump.tap", "turn=\(t["turn"].int ?? i + 1) seq=\(t["seq"].int ?? -1)")
                        NotificationCenter.default.post(name: .jumpToTurn, object: t["seq"].int)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Turn \(t["turn"].int ?? i + 1)").font(.subheadline.weight(.semibold))
                            let asked = SessionRow.plain(t["prompt"].str)
                            let answered = SessionRow.plain(t["response"].str)
                            if !asked.isEmpty { Text(asked).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            if !answered.isEmpty { Text(answered).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Turns")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton() }
        }
    }
}

extension Notification.Name { static let jumpToTurn = Notification.Name("jumpToTurn") }
