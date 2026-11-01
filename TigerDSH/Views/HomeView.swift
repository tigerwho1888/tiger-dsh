import SwiftUI

/// The pieces of the old home screen that are still used now that the chat list is a drawer and a page: the
/// connection strip the chat wears, the first message a new chat carries, and the digest card Settings shows.

/// The connection strip: an overlay wherever it is worn, never an inset, so it can never resize a safe area.
struct ConnBanner: View {
    @Environment(AppModel.self) private var app
    // A reconnect that is over within a second — the usual return from another app — shows no strip at all; the
    // strip flashing up and away on every return read as the app being slow (operator, 2026-10-16).
    @State private var slow = false
    var body: some View {
        Group {
            switch app.conn {
            case .reconnecting where slow:
                Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.15)).foregroundStyle(.orange)
            case .offline:
                HStack {
                    Text("Offline · showing data from \(agoText)").font(.footnote.weight(.medium))
                    Spacer()
                    Button("Retry") { app.mux.recycle() }.font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.orange.opacity(0.15)).foregroundStyle(.orange)
            default: EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.conn)
        .animation(.easeInOut(duration: 0.2), value: slow)
        .task(id: app.conn) {
            slow = false
            guard app.conn == .reconnecting else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { slow = true }
        }
    }
    private var agoText: String {
        let a = Fmt.ago(app.liveAt > 0 ? app.liveAt : app.listAt)
        return a == "now" || a.isEmpty ? "just now" : a + " ago"
    }
}

/// A first message typed in the New chat sheet, sent as soon as the new chat opens.
@MainActor final class PendingOpen {
    static let shared = PendingOpen()
    private var map: [String: String] = [:]
    func set(_ id: String, _ text: String) { map[id] = text }
    func take(_ id: String) -> String? { map.removeValue(forKey: id) }
}

/// The digest watch, when the reader's Mac has the plugin that serves it. It is hidden entirely when it does not:
/// the probe answers 404 and `app.digestWatch` stays nil, so no empty card and no menu entry appear anywhere. The
/// payload is read loosely — a summary line, and a list of what is being watched — because the plugin's own shape
/// belongs to the plugin, not to this app. It lives in Settings now, not in the drawer.
struct DigestWatchCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var open = false

    var body: some View {
        if let w = app.digestWatch {
            Button { open = true } label: {
                HStack(spacing: Tok.sp2) {
                    Image(systemName: "clock.arrow.circlepath").font(.footnote).foregroundStyle(Tok.actionTint(scheme))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Digest watch").font(Tok.heading)
                        Text(line(w)).font(Tok.meta).foregroundStyle(Tok.secondaryText(scheme)).lineLimit(1)
                    }
                    Spacer(minLength: Tok.sp1)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Tok.secondaryText(scheme).opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("digest.watch")
            .sheet(isPresented: $open) { sheet(w) }
        }
    }

    /// One line: whatever the plugin calls its summary, else how much it is watching.
    private func line(_ w: JSON) -> String {
        if let s = w["summary"].string, !s.isEmpty { return s }
        if let s = w["status"].string, !s.isEmpty { return s }
        let n = watched(w).count
        return n == 0 ? "Installed" : "\(n) watched"
    }

    private func watched(_ w: JSON) -> [JSON] {
        w["items"].array.isEmpty ? w["watches"].array : w["items"].array
    }

    @ViewBuilder private func sheet(_ w: JSON) -> some View {
        let items = watched(w)
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("Nothing is being watched.").foregroundStyle(Tok.secondaryText(scheme))
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it["title"].string ?? it["name"].string ?? "Watched").font(Tok.body)
                        let sub = [it["status"].string ?? it["state"].string, it["when"].string ?? it["next"].string]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        if !sub.isEmpty { Text(sub).font(Tok.meta).foregroundStyle(Tok.secondaryText(scheme)) }
                    }
                }
            }
            .navigationTitle("Digest watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton() }
        }
        .sheetCanvas()
    }
}
