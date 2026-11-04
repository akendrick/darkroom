import ActivityKit
import Foundation

/// Keeps the lock-screen timer (a Live Activity) in step with the walk-through:
/// one activity while a print is open, ended when the walk-through closes.
@MainActor
final class LiveTimer {
    static let shared = LiveTimer()
    private var activity: Activity<StepActivity>?
    private var last: StepActivity.ContentState?

    func show(print: String, _ state: StepActivity.ContentState) {
        guard state != last else { return }
        last = state
        let content = ActivityContent(state: state, staleDate: nil)
        // One left on the lock screen from before the app was last closed: carry it on.
        if activity == nil { activity = Activity<StepActivity>.activities.first { $0.activityState == .active } }
        if let a = activity, a.activityState == .active {
            Task { await a.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: StepActivity(print: print), content: content)
    }

    func end() {
        last = nil
        let a = activity; activity = nil
        Task {
            await a?.end(nil, dismissalPolicy: .immediate)
            // Any left from before the app was last closed.
            for old in Activity<StepActivity>.activities { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
