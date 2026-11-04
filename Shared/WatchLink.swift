import Foundation

/// What the phone shows on the Watch: the current page and its timer.
/// Sent as the WatchConnectivity application context (latest one wins).
struct WatchScreen: Codable, Equatable {
    var active: Bool            // a walk-through is open
    var title: String           // page title, e.g. "Hot develop"
    var detail: String          // "Step 6 of 9 · Tray 3 · 40 °C"
    var hasTimer: Bool          // false on choose / start / finish pages
    var timer: StepTimer
    var canNext: Bool           // false while a choice is still needed on the phone
    var nextLabel: String       // "Next" or "Finish"
    var sentAt: Date

    static let idle = WatchScreen(active: false, title: "Darkroom", detail: "Start a walk-through on the iPhone",
                                  hasTimer: false, timer: StepTimer(), canNext: false, nextLabel: "Next", sentAt: .distantPast)
}

/// Buttons pressed on the Watch, carried out on the phone.
enum WatchCommand: String, Codable {
    case next, pause, restart
}

enum WatchKeys {
    static let screen = "screen"
    static let command = "command"
    static let sentAt = "sentAt"
}

extension JSONEncoder { static let watch = JSONEncoder() }
extension JSONDecoder { static let watch = JSONDecoder() }
