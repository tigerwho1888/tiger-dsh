import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TigerDSHWidgetBundle: WidgetBundle {
    var body: some Widget { RunActivityWidget() }
}

/// The run, in the Dynamic Island and on the lock screen, laid out the way the reference the operator admires does
/// it: the compact island is almost empty — a glyph leading, the live clock trailing in tabular figures — and
/// everything with words lives in the card. One status colour per phase, one accent for the action, nothing else
/// coloured.
struct RunActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunActivityAttributes.self) { context in
            RunCard(state: context.state)
                .activityBackgroundTint(RunPalette.navy)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // The expanded island: the badge leading, the clock trailing, the words and any action under them.
                // The configuration turns the system's content margins off (the lock-screen card pads itself), so
                // every region carries its own inset here: without it the badge sat in the island's rounded corner
                // and was cut by it, and the words floated in the middle (operator's phone, 2026-10-14).
                DynamicIslandExpandedRegion(.leading) {
                    RunBadge(phase: context.state.phase, size: 30)
                        .padding(.leading, 20).padding(.top, 14)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RunClock(state: context.state, size: 20, showsLabel: false)
                        .padding(.trailing, 20).padding(.top, 16)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RunCard(state: context.state, surface: .island, showsFooter: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
                }
            } compactLeading: {
                RunBadge(phase: context.state.phase, size: 22)
            } compactTrailing: {
                RunCompactStatus(state: context.state)
            } minimal: {
                RunBadge(phase: context.state.phase, size: 22)
            }
            .keylineTint(RunPalette.status(context.state.phase))
        }
        .contentMarginsDisabled()
    }
}
