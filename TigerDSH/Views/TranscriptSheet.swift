import SwiftUI

/// Saves the chat's own transcript — the zip the host builds for `session.export` — and hands it to the share
/// sheet, so a conversation can leave the phone the same way the desktop's log export does.
struct TranscriptSheet: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel

    @State private var file: URL?
    @State private var error = ""
    @State private var busy = true

    var body: some View {
        NavigationStack {
            Group {
                if let file {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.zipper").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text(chat.title).font(.headline).multilineTextAlignment(.center)
                        Text(byteText).font(.caption).foregroundStyle(.secondary)
                        ShareLink(item: file) {
                            Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if !error.isEmpty {
                    ContentUnavailableView(error, systemImage: "doc.questionmark")
                } else {
                    VStack(spacing: 10) { ProgressView(); Text("Building the transcript on your Mac…").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Share transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DoneButton() }
            .task { await fetch() }
        }
    }

    private var byteText: String {
        let size = (try? FileManager.default.attributesOfItem(atPath: file?.path ?? ""))?[.size] as? Int ?? 0
        return Fmt.bytes(Double(size)) + " zip, the chat's own log"
    }

    /// The Mac flushes a live session's log before it streams the zip, and on a big chat that gap outlasts an idle
    /// connection. The export is a pure read, so a drop is retried rather than shown — and the bytes go straight to
    /// a file, because a large session's export carries every attachment it ever made and holding all of that in
    /// memory is the other half of why sharing a large chat's transcript failed.
    private func fetch() async {
        defer { busy = false }
        for attempt in 0..<3 {
            do {
                let tmp = try await DSHClient.shared.getFile("/api/session.export?sessionId=\(chat.sid.urlQuery)")
                let name = chat.title.isEmpty ? "transcript" : chat.title
                let safe = name.replacingOccurrences(of: "/", with: "-").prefix(60)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).zip")
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
                file = url
                return
            } catch let e as RPCError where e.kind == .missing {
                error = "This DSH version does not export a transcript."
                return
            } catch is URLError where attempt < 2 {
                try? await Task.sleep(for: .milliseconds(800))
                continue
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
    }
}
