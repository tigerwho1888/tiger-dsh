import ActivityKit
import SwiftUI

/// The run's own colours: the app's `Tok` lives in the app target, so the shared views carry the values they need —
/// the same numbers, in one place both targets compile. They are the app's dark palette (`Tok.navy`, `navyRaised`,
/// `paper`): the card used to be a cold navy with a bright blue accent the app had already left behind, and the
/// operator's lock screen read as another app's (2026-10-13).
enum RunPalette {
    static let accent = Color(red: 0.965, green: 0.961, blue: 0.945)   // Tok.paper — the app's action ink in the dark
    static let navy = Color(red: 0.122, green: 0.118, blue: 0.110)     // Tok.navy, warm charcoal
    static let navyRaised = Color(red: 0.200, green: 0.195, blue: 0.186) // Tok.composerFill (dark)
    static let text = accent
    static let quiet = accent.opacity(0.58)
    static let hairline = accent.opacity(0.10)
    static let ok = Color(red: 0.18, green: 0.72, blue: 0.36)
    static let warn = Color(red: 0.94, green: 0.49, blue: 0.08)
    static let danger = Color(red: 0.86, green: 0.24, blue: 0.24)

    /// One status colour per phase: the paper ink while it works, amber when it wants the reader, green when it is
    /// done, red when it stopped badly. Nothing else on screen is coloured.
    static func status(_ phase: RunPhase) -> Color {
        switch phase {
        case .running: return accent
        case .needsYou, .needsApproval: return warn
        case .done: return ok
        case .failed: return danger
        }
    }
}

/// The lock-screen card and the island's expanded body are the same content on two surfaces, which is how the
/// reference does it and why it reads as one design rather than two.
enum RunSurface { case lockScreen, island }

/// The run's mark: its phase glyph on a disc of its own status colour. It leads every surface — the card, the
/// expanded island and the compact pill — the way the apps the operator holds up lead with one round badge rather
/// than a bare symbol floating in black (2026-10-14).
struct RunBadge: View {
    let phase: RunPhase
    var size: CGFloat = 34

    var body: some View {
        Group {
            // While it works the badge is the app's own orca cub, not a generic sparkle (operator, 2026-10-15). Both
            // the app and the widget ship a "Mascot" image, so the preview and the lock screen draw the same picture.
            if phase == .running {
                Image("Mascot").resizable().scaledToFit().padding(size * 0.1)
            } else {
                Image(systemName: phase.glyph)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(RunPalette.status(phase))
            }
        }
        .frame(width: size, height: size)
        .background(RunPalette.status(phase).opacity(0.18), in: Circle())
    }
}

/// The clock as the card's one big figure, with the phase in its colour under it: one primary signal per state.
struct RunClock: View {
    let state: RunActivityAttributes.ContentState
    var size: CGFloat = 22
    /// The island's clock goes without it: the words under it already say what is happening.
    var showsLabel: Bool = true

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            RunElapsed(state: state)
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(RunPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: size * 3.4, alignment: .trailing)
            // Not when the step underneath already says the same word ("Working" twice on the operator's phone).
            if showsLabel && state.step != state.phase.label {
                Text(state.phase.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RunPalette.status(state.phase))
                    .lineLimit(1)
            }
        }
    }
}

struct RunCard: View {
    let state: RunActivityAttributes.ContentState
    var surface: RunSurface = .lockScreen
    /// The island's bottom region is already inside the island's own mask, so it carries no outer padding.
    var showsFooter: Bool = true

    private var foreground: Color { RunPalette.text }
    private var dimmed: Color { RunPalette.quiet }
    private var tile: Color { RunPalette.navyRaised }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if surface == .lockScreen {
                HStack(alignment: .center, spacing: 12) {
                    RunBadge(phase: state.phase)
                    words
                    Spacer(minLength: 8)
                    RunClock(state: state)
                }
            } else {
                // The island's own leading and trailing regions carry the badge and the clock.
                words
            }
            if state.phase == .needsApproval, let approval = state.approvalId {
                operation
                actions(approval)
            } else if Self.showsOperation(state) {
                operation
            }
            if showsFooter && surface == .lockScreen && state.phase == .needsYou { footer }
        }
        .padding(.horizontal, surface == .island ? 0 : 16)
        .padding(.vertical, surface == .island ? 0 : 14)
        .foregroundStyle(foreground)
    }

    /// The card's second line. A waiting question puts the question itself there: the phase line already says
    /// what is happening, and saying it again is what made the operator's card read "Waiting for your answer" three
    /// times over (2026-10-13).
    static func secondLine(_ s: RunActivityAttributes.ContentState) -> String {
        if s.phase == .needsYou, let d = s.detail, !d.isEmpty { return d }
        return s.step
    }

    /// Whether the mono tile is drawn: only when there is something to put in it, and never for a waiting question —
    /// the question is the line above it, and the tile would be the same words a third time.
    static func showsOperation(_ s: RunActivityAttributes.ContentState) -> Bool {
        guard let d = s.detail, !d.isEmpty else { return false }
        return s.phase != .needsYou
    }

    /// The title, and under it what the run is doing — two lines, nothing else.
    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                // The lock screen shares its row with the clock, so a long title takes a second line rather than
                // being cut to "Continue Claude iOS a…". The island has the full width and keeps one, and so does an
                // approval card, whose command tile and buttons already fill the lock screen's 160-point height.
                .lineLimit(surface == .lockScreen && state.phase != .needsApproval ? 2 : 1)
            Text(Self.secondLine(state))
                .font(.system(size: 13))
                .foregroundStyle(dimmed)
                .lineLimit(2)
        }
    }

    /// The command, in mono, on its own tile: the thing a reader squints at before deciding.
    private var operation: some View {
        Text(state.detail ?? "")
            .font(.system(size: 12, design: .monospaced))
            .tracking(-0.4)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// One accent action beside a plain one: the accent marks the action that lets the run continue, the other is
    /// quiet.
    private func actions(_ approval: String) -> some View {
        HStack(spacing: 8) {
            Button(intent: RunApprovalIntent(approvalId: approval, allow: false)) {
                Text("Reject")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: surface == .island ? 34 : 38)
                    .background(tile, in: Capsule())
                    .foregroundStyle(foreground)
            }
            .buttonStyle(.plain)
            Button(intent: RunApprovalIntent(approvalId: approval, allow: true)) {
                Text("Approve")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: surface == .island ? 34 : 38)
                    .background(RunPalette.accent, in: Capsule())
                    .foregroundStyle(RunPalette.navy)
            }
            .buttonStyle(.plain)
        }
    }

    /// Only a question asks the reader to open the app; a working run needs nothing from them, and a footer saying
    /// so on every card was noise.
    private var footer: some View {
        Text("Open the app to answer")
            .font(.system(size: 11))
            .foregroundStyle(dimmed)
    }
}

/// The clock: counting while it runs, and the finished duration once it is over, so a glance at a finished run
/// reads "12m" rather than a timer that is still ticking.
struct RunElapsed: View {
    let state: RunActivityAttributes.ContentState

    var body: some View {
        if state.phase.isFinished {
            Text(Self.duration(from: state.startedAt, to: state.updatedAt))
        } else {
            Text(state.startedAt, style: .timer).multilineTextAlignment(.trailing)
        }
    }

    static func duration(from: Date, to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }
}

/// What the island's compact trailing side shows: the clock, and nothing else. The glyph leads it, so the compact
/// pill is a glyph and a clock — it used to carry the phase word as well, in a region with room for four letters, and
/// the operator's phone read "Wait…" (2026-10-13).
struct RunCompactStatus: View {
    let state: RunActivityAttributes.ContentState

    var body: some View {
        RunElapsed(state: state)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .frame(width: 38, alignment: .trailing)
            .foregroundStyle(RunPalette.status(state.phase))
    }
}
