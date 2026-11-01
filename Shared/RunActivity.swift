import ActivityKit
import Foundation
import SwiftUI

/// The Live Activity the app and its widget share. Kept deliberately small: the island shows a glyph and a timer, and
/// the card shows the title, one quiet phase line and the step — nothing that needs a bigger payload, and nothing
/// that costs more than a few bytes on every update the app sends.
struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: RunPhase
        /// The conversation's title, which the host may rename mid-run.
        var title: String
        /// What it is doing right now: "Thinking", "Running bash", "Writing".
        var step: String
        /// The command or question, when there is one worth showing in mono.
        var detail: String?
        /// The approval event this run is waiting on, when it is waiting on one: the island's own Approve and Reject
        /// buttons carry it back to the app, which sends the answer over the connection it already has.
        var approvalId: String?
        var startedAt: Date
        /// When this state was last refreshed. A finished run shows its duration from `startedAt` to here rather than
        /// a timer that keeps ticking, and the callers that only care about "now" leave it at its default.
        var updatedAt: Date = Date()
    }

    let sessionID: String
}

/// The phases the island and the card render. `needsYou` and `needsApproval` are the two the operator is meant to
/// notice from a locked phone; `done` and `failed` are the two that say the run is over.
enum RunPhase: String, Codable, Hashable {
    case running
    case needsYou
    case needsApproval
    case done
    case failed

    var label: String {
        switch self {
        case .running: return "Working"
        case .needsYou: return "Waiting for your answer"
        case .needsApproval: return "Needs approval"
        case .done: return "Orca Orca!"   // the app's sign-off for a finished run (operator, 2026-10-15)
        case .failed: return "Stopped with an error"
        }
    }

    /// One glyph per phase, drawn by the system; while running, RunBadge draws the orca cub in its place.
    var glyph: String {
        switch self {
        case .running: return "sparkle"
        case .needsYou: return "questionmark.circle.fill"
        case .needsApproval: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isFinished: Bool { self == .done || self == .failed }
}

/// Starts, updates and ends the one activity for the run the reader is watching. Updates are coalesced: the mux
/// streams many frames a second and ActivityKit has an update budget, so a state whose words are the same as the last
/// one is dropped — a change of phase is never dropped, because that is the moment the island stops asking for an
/// answer and the moment the reader looks at it.
@MainActor
enum RunActivity {
    /// ActivityKit's `Activity` is not Sendable in this SDK, and every call here hands it to an async update or end.
    /// The box states the promise the controller already keeps: it is main-actor bound and only this type touches it.
    private struct Box: @unchecked Sendable { let activity: Activity<RunActivityAttributes> }

    private static var current: Box?
    /// ActivityKit's update and end run off the main actor, so each `Task` used to put its own call in flight beside
    /// the others — several updates a second while a reply streams, and an end racing them. The chain runs one call
    /// at a time, in the order they were asked (one suspect of the 10-14 crashes, and an older update can no longer
    /// land after a newer one either).
    private static var chain: Task<Void, Never>?

    private static func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task {
            if let previous { await waitAtMost(seconds: 10, for: previous) }
            await operation()
        }
    }

    /// One ActivityKit call that never returns must not hold every later one, the end included, forever: after the
    /// bound the queue moves on without it (and never waits for it again).
    private static func waitAtMost(seconds: Double, for task: Task<Void, Never>) async {
        @MainActor final class Once { var c: CheckedContinuation<Void, Never>? }
        let once = Once()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            once.c = c
            Task { @MainActor in await task.value; once.c?.resume(); once.c = nil }
            Task { @MainActor in try? await Task.sleep(for: .seconds(seconds)); once.c?.resume(); once.c = nil }
        }
    }
    /// Activities whose end is queued but not yet done: still `.active` until it lands, so neither taken over nor
    /// ended a second time meanwhile (Codex r110).
    private static var ending: Set<String> = []

    private static func endLater(_ box: Box, _ content: ActivityContent<RunActivityAttributes.ContentState>?,
                                 _ policy: ActivityUIDismissalPolicy) {
        let id = box.activity.id
        guard ending.insert(id).inserted else { return }
        enqueue { await box.activity.end(content, dismissalPolicy: policy); ending.remove(id) }
    }

    private static var lastSent: RunActivityAttributes.ContentState?
    private static var lastAt = Date.distantPast

    static var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Hands the activity's push token to the Mac, which keeps the island moving through Apple's push service while
    /// the app is closed (session id, hex token, title, start). Set by the app; the widget never starts an activity.
    static var onPushToken: ((String, String, String, Date) -> Void)?

    /// `staleDate` is what stops the island lying when the app can no longer update it: after this long without a
    /// word the system dims it and may end it.
    private static let staleAfter: TimeInterval = 90

    static func start(sessionID: String, state: RunActivityAttributes.ContentState) {
        guard isSupported else { return }
        lastSent = state
        lastAt = Date()
        if let box = current {
            enqueue { await box.activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))) }
            return
        }
        // An island left from before the app was closed, which the Mac kept moving, is this run's own: take it over
        // rather than put a second one beside it.
        if let a = Activity<RunActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID && $0.activityState == .active && !ending.contains($0.id)
        }) {
            let box = Box(activity: a)
            current = box
            enqueue { await box.activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))) }
            // Its push token can have changed while the app was closed, and the Mac needs the live one (Codex r111).
            if let data = a.pushToken { onPushToken?(sessionID, data.map { String(format: "%02x", $0) }.joined(), state.title, state.startedAt) }
            watchToken(box, sessionID: sessionID, state: state)
            return
        }
        let attributes = RunActivityAttributes(sessionID: sessionID)
        guard let a = try? Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter)),
                                            pushType: .token) else { return }
        let box = Box(activity: a)
        current = box
        watchToken(box, sessionID: sessionID, state: state)
    }

    private static func watchToken(_ box: Box, sessionID: String, state: RunActivityAttributes.ContentState) {
        Task {
            for await data in box.activity.pushTokenUpdates {
                onPushToken?(sessionID, data.map { String(format: "%02x", $0) }.joined(), state.title, state.startedAt)
            }
        }
    }

    /// What the app shows on the island: creates the activity when there is none, and updates it otherwise, at the
    /// budget below. `start` is the same thing without the budget, for the design-review hooks that mean "now".
    static func show(sessionID: String, state: RunActivityAttributes.ContentState) {
        guard isSupported else { return }
        guard let box = current else { return start(sessionID: sessionID, state: state) }
        // `shouldSend` answers for the words; the floor is for a run that says nothing for a long time. `staleDate`
        // is 90 s, and one tool call can outlast it — the system would dim an island whose run is fine.
        guard shouldSend(state, after: lastSent) || Date().timeIntervalSince(lastAt) > 45 else { return }
        lastSent = state
        lastAt = Date()
        enqueue { await box.activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))) }
    }

    /// Whether this state has to go out. A PHASE change always does — the island must stop saying "Waiting for your
    /// answer" the moment it is answered, and that is the moment the reader is looking at it — while a state whose
    /// words are unchanged is dropped: the mux hands `syncRunActivity` many frames a second and ActivityKit has an
    /// update budget.
    static func shouldSend(_ state: RunActivityAttributes.ContentState,
                           after last: RunActivityAttributes.ContentState?) -> Bool {
        guard let last else { return true }
        return state.phase != last.phase || !sameWords(state, last)
    }

    /// The parts of a state the reader sees as words — the approval's id among them, because the island's own
    /// buttons carry it, so a second approval has to reach them even though the phase has not moved. The two dates
    /// are not words: the callers leave `updatedAt` at its default `Date()`, so counting it would send every frame.
    static func sameWords(_ a: RunActivityAttributes.ContentState, _ b: RunActivityAttributes.ContentState) -> Bool {
        a.title == b.title && a.step == b.step && a.detail == b.detail && a.approvalId == b.approvalId
    }

    /// The run is over: the island keeps the result for a minute so a glance from the lock screen still reads it,
    /// then the system takes it away.
    static func end(_ state: RunActivityAttributes.ContentState) {
        guard let box = current else { return }
        current = nil
        lastSent = nil
        endLater(box, ActivityContent(state: state, staleDate: nil), .after(Date().addingTimeInterval(60)))
    }

    /// Called when the app comes up and whenever the session list refreshes: an activity whose session the host no
    /// longer reports as running is a leftover, and it goes.
    static func reconcile(hostRunning: Bool) {
        guard !hostRunning, let box = current else { return }
        current = nil
        lastSent = nil
        endLater(box, nil, .immediate)
    }

    /// Islands this launch did not start — from before the app was closed, kept moving by the Mac — are never
    /// `current`, and when the Mac's own end did not arrive one said "Running bash" long after its chat had finished
    /// (2026-10-15). Any whose chat is not running goes; `running` answers from the host's chat list.
    static func endLeftovers(running: (String) -> Bool) {
        for a in Activity<RunActivityAttributes>.activities
        where a.id != current?.activity.id && !ending.contains(a.id)
            && (a.activityState == .active || a.activityState == .stale) && !running(a.attributes.sessionID) {
            endLater(Box(activity: a), nil, .immediate)
        }
    }
}
