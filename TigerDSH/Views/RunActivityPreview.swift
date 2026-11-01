/// Simulator and DEBUG builds only, like the hook in `TigerDSHApp` that reaches it: the Release build the test
/// suite runs is a Simulator build, so `DEBUG` alone would leave that hook naming a type this file does not define.
#if DEBUG || targetEnvironment(simulator)
import SwiftUI

/// The run card and the island's pieces, rendered for one phase at a time, so the design can be looked at without a
/// Simulator island screenshot — those come back black while the activity itself is fine. Reached only by launching
/// with `-liveActivityPreview running|awaiting|approval|completed`; nothing in the shipped UI leads here.
struct RunActivityPreview: View {
    let phase: RunPhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Lock screen") {
                    RunCard(state: state)
                        .background(RunPalette.navy, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                section("Island, expanded") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            RunBadge(phase: state.phase, size: 30)
                            Spacer()
                            RunClock(state: state, size: 20, showsLabel: false).padding(.top, 2)
                        }
                        RunCard(state: state, surface: .island, showsFooter: false)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
                }
                section("Island, compact") {
                    HStack(spacing: 10) {
                        RunBadge(phase: state.phase, size: 22)
                        Spacer().frame(width: 120)
                        RunCompactStatus(state: state)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.black, in: Capsule())
                }
                section("Island, minimal") {
                    RunBadge(phase: state.phase, size: 22)
                        .padding(6)
                        .background(Color.black, in: Capsule())
                }
            }
            .padding(20)
        }
        .background(RunPalette.navy)
        .accessibilityIdentifier("activity.preview")
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(RunPalette.quiet)
            content()
        }
    }

    private var state: RunActivityAttributes.ContentState {
        switch phase {
        case .needsYou:
            return .init(phase: .needsYou, title: "Count from 1 to 400",
                         step: "Waiting for your answer",
                         detail: "Should I keep counting past 400, or stop at 400?",
                         approvalId: nil, startedAt: Date().addingTimeInterval(-193), updatedAt: Date())
        case .needsApproval:
            return .init(phase: .needsApproval, title: "Continue Claude iOS app build",
                         step: "Waiting for you to allow a command", detail: "git push origin main",
                         approvalId: "preview", startedAt: Date().addingTimeInterval(-193), updatedAt: Date())
        case .done:
            return .init(phase: .done, title: "Continue Claude iOS app build", step: "Finished", detail: nil,
                         approvalId: nil, startedAt: Date().addingTimeInterval(-742), updatedAt: Date())
        default:
            return .init(phase: .running, title: "Continue Claude iOS app build", step: "Running bash", detail: nil,
                         approvalId: nil, startedAt: Date().addingTimeInterval(-193), updatedAt: Date())
        }
    }
}
#endif
