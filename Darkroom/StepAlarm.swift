import AlarmKit
import SwiftUI

/// Each open print's step alarm, through AlarmKit: it rings like the Clock
/// app's timer — on the lock screen, through silent mode and Focus — until
/// stopped. When AlarmKit isn't allowed the walk-through falls back to a
/// notification.
@MainActor
final class StepAlarm {
    static let shared = StepAlarm()
    private var alarms: [String: (id: UUID, end: Date, title: String)] = [:]

    struct Meta: AlarmMetadata {}

    var usable: Bool { AlarmManager.shared.authorizationState == .authorized }

    func authorize() async {
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
    }

    /// The print's one alarm (`key` is its client id), at `end`; nil takes it
    /// away (and stops it if it's ringing).
    func set(_ key: String, _ end: Date?, title: String) {
        guard end != alarms[key]?.end || title != alarms[key]?.title else { return }
        if let old = alarms.removeValue(forKey: key) { try? AlarmManager.shared.cancel(id: old.id) }
        guard let end, usable else { return }
        let new = UUID(); alarms[key] = (new, end, title)
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
        let attributes = AlarmAttributes<Meta>(presentation: AlarmPresentation(alert: alert), tintColor: Theme.red)
        Task {
            _ = try? await AlarmManager.shared.schedule(
                id: new, configuration: .alarm(schedule: .fixed(end), attributes: attributes, sound: .default))
        }
    }
}
