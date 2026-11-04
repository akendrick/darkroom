import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DarkroomLive: WidgetBundle {
    var body: some Widget { StepTimerLive() }
}

/// Red on black whatever the phone's look, so it's safe under the safelight.
private let red = Color(red: 1, green: 0.165, blue: 0.102)

struct StepTimerLive: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StepActivity.self) { ctx in
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctx.state.step.uppercased()).font(.system(size: 22, weight: .heavy).width(.condensed)).lineLimit(1)
                    Text(ctx.state.detail).font(.system(.footnote, design: .monospaced)).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 8)
                TimeText(state: ctx.state)
                    .font(.system(size: 52, weight: .heavy).width(.compressed)).monospacedDigit()
            }
            .foregroundStyle(red)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(red)
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(ctx.state.step.uppercased()).font(.system(size: 18, weight: .heavy).width(.condensed)).lineLimit(1)
                        .foregroundStyle(red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimeText(state: ctx.state).font(.system(size: 34, weight: .heavy).width(.compressed)).monospacedDigit()
                        .foregroundStyle(red)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(ctx.state.detail).font(.system(.footnote, design: .monospaced)).foregroundStyle(red.opacity(0.7))
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(red)
            } compactTrailing: {
                TimeText(state: ctx.state).monospacedDigit().foregroundStyle(red).frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(red)
            }
        }
    }
}

/// Counts on its own: down to zero (the alarm rings there; the app shows the
/// time over), up from the start with no set time, or still while stopped.
private struct TimeText: View {
    let state: StepActivity.ContentState
    var body: some View {
        if let end = state.endsAt {
            Text(timerInterval: Date.now...max(end, .now), countsDown: true).multilineTextAlignment(.trailing)
        } else if let from = state.countFrom {
            Text(timerInterval: from...from.addingTimeInterval(12 * 3600), countsDown: false).multilineTextAlignment(.trailing)
        } else {
            Text(state.still ?? "").opacity(0.6)
        }
    }
}
