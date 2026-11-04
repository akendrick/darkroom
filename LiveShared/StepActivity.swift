import ActivityKit
import Foundation

/// The step timer on the lock screen and in the Dynamic Island, while a
/// walk-through is open. The lock screen counts by itself from these dates;
/// the app sends a new state only when the step or the timer changes.
struct StepActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var step: String
        var detail: String          // "Step 4/9 · Tray 2 · 21.5 °C"
        /// Running towards zero: the lock screen counts down to this, then up past it.
        var endsAt: Date?
        /// Running with no set time: counts up from this.
        var countFrom: Date?
        /// Stopped: the time as it stands.
        var still: String?
    }
    var print: String
}
