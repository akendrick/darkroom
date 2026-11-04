import AlarmKit
import SwiftUI

/// The running step's alarm, through AlarmKit: it rings like the Clock app's
/// timer — on the lock screen, through silent mode and Focus — until stopped.
/// When AlarmKit isn't allowed the walk-through falls back to a notification.
@MainActor
final class StepAlarm {
    static let shared = StepAlarm()
    private var id: UUID?
    private var end: Date?

    struct Meta: AlarmMetadata {}

    var usable: Bool { AlarmManager.shared.authorizationState == .authorized }

    func authorize() async {
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
    }

    /// The one alarm, at `end`; nil takes it away (and stops it if it's ringing).
    func set(_ end: Date?, title: String) {
        guard end != self.end else { return }
        self.end = end
        if let old = id { try? AlarmManager.shared.cancel(id: old); id = nil }
        guard let end, usable else { return }
        let new = UUID(); id = new
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
