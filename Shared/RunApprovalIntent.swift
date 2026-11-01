import AppIntents
import Foundation

/// The island's own Approve and Reject. A `LiveActivityIntent` runs in the APP's process — not in the widget's — which
/// is the whole point: the approval goes over the connection the app already has, with the sign-in it already holds,
/// and the run on the Mac stops waiting without the reader having to open anything.
struct RunApprovalIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Answer the run" }
    /// Tapping the island must not pull the reader into the app; the answer is the whole interaction.
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Approval") var approvalId: String
    @Parameter(title: "Allow") var allow: Bool

    init() {}

    init(approvalId: String, allow: Bool) {
        self.approvalId = approvalId
        self.allow = allow
    }

    func perform() async throws -> some IntentResult {
        #if TIGERDSH_APP
        // This body exists only in the app's copy of the type, and a LiveActivityIntent runs in the app's process:
        // the widget's copy is there so its buttons can name the intent, and never runs.
        //
        // The app may have been launched by this very tap, in which case it is still signing in and the host has not
        // handed out the client id the answer needs. Wait for it — briefly, and only while the app is coming up.
        for _ in 0..<40 {
            if let app = await AppModel.live, await app.clientId != nil {
                await app.answerApproval(["eventId": .string(approvalId)], allow: allow)
                break
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        #endif
        return .result()
    }
}
