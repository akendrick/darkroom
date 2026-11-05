import ActivityKit
import Foundation

/// Keeps the lock-screen timers (Live Activities) in step with the
/// walk-throughs: one activity per open print, keyed by its client id, ended
/// when that walk-through closes.
@MainActor
final class LiveTimer {
    static let shared = LiveTimer()
    private var activities: [String: Activity<StepActivity>] = [:]
    private var last: [String: StepActivity.ContentState] = [:]
    private var inverted: [String: Bool] = [:]
    private var ending: Set<String> = []     // activity ids on their way out

    func show(key: String, print: String, inverted inv: Bool, _ state: StepActivity.ContentState) {
        // Moved between halves: the look is fixed per activity, so start a new one.
        if let was = inverted[key], was != inv { end(key: key) }
        inverted[key] = inv
        guard state != last[key] else { return }
        last[key] = state
        let content = ActivityContent(state: state, staleDate: nil)
        // One left on the lock screen from before the app was last closed: carry it on.
        if activities[key] == nil {
            activities[key] = Activity<StepActivity>.activities.first {
                $0.attributes.key == key && $0.activityState == .active && !ending.contains($0.id) && ($0.attributes.inverted == true) == inv
            }
        }
        if let a = activities[key], a.activityState == .active {
            Task { await a.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activities[key] = try? Activity.request(attributes: StepActivity(print: print, key: key, inverted: inv), content: content)
    }

    func end(key: String) {
        last[key] = nil; inverted[key] = nil
        let a = activities.removeValue(forKey: key)
        // This print's, and any from an older version of the app (no key).
        let old = Activity<StepActivity>.activities.filter { $0.attributes.key == key || $0.attributes.key == nil }
        ending.formUnion(([a].compactMap { $0 } + old).map(\.id))
        Task {
            await a?.end(nil, dismissalPolicy: .immediate)
            for o in old { await o.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
