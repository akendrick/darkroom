import Foundation

/// One step's timer. Counts down from `target` (the typed or preset time), or
/// up when there is none. Kept as a start date plus time already run, so it is
/// right after the app sleeps or the Watch screen goes off.
struct StepTimer: Codable, Equatable {
    var target: Int?            // seconds
    var carried: Double = 0     // seconds run before the current start
    var startedAt: Date?        // set while running

    var isRunning: Bool { startedAt != nil }
    var hasRun: Bool { isRunning || carried > 0 }

    func elapsed(at now: Date = .now) -> Double {
        carried + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    /// Seconds left (negative once over), or nil when counting up.
    func remaining(at now: Date = .now) -> Double? {
        target.map { Double($0) - elapsed(at: now) }
    }

    /// When the countdown reaches zero, if it is running.
    var endsAt: Date? {
        guard let start = startedAt, let t = target else { return nil }
        return start.addingTimeInterval(Double(t) - carried)
    }

    mutating func start(at now: Date = .now) { if startedAt == nil { startedAt = now } }
    mutating func pause(at now: Date = .now) {
        guard startedAt != nil else { return }
        carried = elapsed(at: now); startedAt = nil
    }
    mutating func reset() { carried = 0; startedAt = nil }

    /// "4:59", "+0:05" when over, or the count up.
    func display(at now: Date = .now) -> (text: String, over: Bool) {
        if let left = remaining(at: now), hasRun {
            let over = left < 0
            return ((over ? "+" : "") + Duration.format(Int(abs(left.rounded(.up)))), over)
        }
        if let t = target { return (Duration.format(t), false) }
        return (Duration.format(Int(elapsed(at: now))), false)
    }
}
