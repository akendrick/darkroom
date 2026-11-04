import Foundation

/// What the phone shows on the Watch: the current page and its timer.
/// Sent as the WatchConnectivity application context (latest one wins).
struct WatchScreen: Codable, Equatable {
    var active: Bool            // a walk-through is open
    var title: String           // page title, e.g. "Hot develop"
    var step = ""               // "6/9", empty off the step pages
    var detail: String          // "40 °C"
    var hasTimer: Bool          // false on choose / start / finish pages
    var timer: StepTimer
    var canNext: Bool           // false while a choice is still needed on the phone
    var nextLabel: String       // "Next" or "Finish"
    var pageKey: String         // which print and page this is; commands carry it back
    var sentAt: Date

    static let idle = WatchScreen(active: false, title: "Darkroom", step: "", detail: "Start a walk-through on the iPhone",
                                  hasTimer: false, timer: StepTimer(), canNext: false, nextLabel: "Next", pageKey: "", sentAt: .distantPast)
}

/// Buttons pressed on the Watch, carried out on the phone.
enum WatchCommand: String, Codable {
    case next, pause, restart
}

enum WatchKeys {
    static let screen = "screen"
    static let command = "command"
    static let sentAt = "sentAt"
    static let id = "id"            // each press once only
    static let pageKey = "pageKey"  // the page the press was meant for
}

extension JSONEncoder { static let watch = JSONEncoder() }
extension JSONDecoder { static let watch = JSONDecoder() }
