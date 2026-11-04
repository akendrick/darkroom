import Foundation
import WatchConnectivity

/// Sends the current page and timer to the Watch, and carries out the Watch's
/// Next / Pause / Restart on the phone.
final class PhoneWatch: NSObject, WCSessionDelegate {
    static let shared = PhoneWatch()

    /// Set by the app to the walk-through that is open.
    @MainActor var onCommand: ((WatchCommand) -> Void)?

    private var last: WatchScreen?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ screen: WatchScreen) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { last = screen; return }
        // Same page and timer as last time: nothing to send.
        if var a = last, a.sentAt != screen.sentAt { a.sentAt = screen.sentAt; if a == screen { return } }
        last = screen
        guard let data = try? JSONEncoder.watch.encode(screen) else { return }
        let s = WCSession.default
        guard s.isPaired, s.isWatchAppInstalled else { return }
        // The context reaches the Watch whenever it next wakes; a message is
        // faster when the Watch app is open.
        try? s.updateApplicationContext([WatchKeys.screen: data])
        if s.isReachable { s.sendMessage([WatchKeys.screen: data], replyHandler: nil, errorHandler: nil) }
    }

    private func handle(_ msg: [String: Any]) {
        guard let raw = msg[WatchKeys.command] as? String, let cmd = WatchCommand(rawValue: raw) else { return }
        // A command queued while the phone was out of reach is stale after a minute.
        if let t = msg[WatchKeys.sentAt] as? Date, Date.now.timeIntervalSince(t) > 60 { return }
        Task { @MainActor in self.onCommand?(cmd) }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        if state == .activated, let l = last { last = nil; send(l) }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { handle(message) }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) { handle(userInfo) }
}
