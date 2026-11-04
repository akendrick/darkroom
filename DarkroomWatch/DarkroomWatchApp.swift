import SwiftUI
import UserNotifications
import WatchConnectivity
import WatchKit

@main
struct DarkroomWatchApp: App {
    @State private var link = WatchLink()
    var body: some Scene {
        WindowGroup { TimerScreen().environment(link) }
    }
}

/// The phone's current page and timer, and the three buttons that act on it.
@MainActor @Observable
final class WatchLink: NSObject, WCSessionDelegate {
    var screen = WatchScreen.idle
    var reachable = false
    private var buzzedFor: Date?

    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Carried out on the phone. Until the phone answers, the Watch shows the
    /// result straight away so the buttons feel instant.
    func press(_ cmd: WatchCommand) {
        var s = screen
        switch cmd {
        case .pause: if s.timer.isRunning { s.timer.pause() } else { s.timer.start() }
        case .restart: s.timer.reset(); s.timer.start()
        case .next: break
        }
        if cmd != .next { apply(s) }
        let msg: [String: Any] = [WatchKeys.command: cmd.rawValue, WatchKeys.sentAt: Date(),
                                  WatchKeys.id: UUID().uuidString, WatchKeys.pageKey: screen.pageKey]
        let wc = WCSession.default
        if wc.isReachable { wc.sendMessage(msg, replyHandler: nil) { _ in wc.transferUserInfo(msg) } }
        else { wc.transferUserInfo(msg) }
        WKInterfaceDevice.current().play(.click)
    }

    private func apply(_ s: WatchScreen) {
        screen = s
        scheduleBuzz()
    }

    /// A tap on the wrist when the countdown ends, even with the screen off.
    private func scheduleBuzz() {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: ["step-timer"])
        guard screen.active, screen.hasTimer, let end = screen.timer.endsAt, end > .now else { return }
        let n = UNMutableNotificationContent()
        n.title = "\(screen.title) — time"
        n.sound = .default
        c.add(UNNotificationRequest(identifier: "step-timer", content: n,
                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: end.timeIntervalSinceNow, repeats: false)))
    }

    /// While the Watch app is open it buzzes itself at zero.
    func tick(_ now: Date) {
        guard screen.hasTimer, let end = screen.timer.endsAt, now >= end, buzzedFor != end else { return }
        buzzedFor = end
        WKInterfaceDevice.current().play(.notification)
    }

    private nonisolated func receive(_ dict: [String: Any]) {
        guard let data = dict[WatchKeys.screen] as? Data,
              let s = try? JSONDecoder.watch.decode(WatchScreen.self, from: data) else { return }
        Task { @MainActor in if s.sentAt >= self.screen.sentAt { self.apply(s) } }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        receive(session.receivedApplicationContext)
        let r = session.isReachable
        Task { @MainActor in self.reachable = r }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let r = session.isReachable
        Task { @MainActor in self.reachable = r }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) { receive(ctx) }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { receive(message) }
}

let red = Color(red: 1, green: 0.165, blue: 0.102)

struct TimerScreen: View {
    @Environment(WatchLink.self) private var link

    var body: some View {
        let s = link.screen
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(s.title.uppercased()).font(.system(size: 15, weight: .bold).width(.condensed)).lineLimit(1).minimumScaleFactor(0.6)
                if !s.step.isEmpty {
                    Text(s.step.uppercased()).font(.system(size: 17, weight: .heavy).width(.compressed)).monospacedDigit()
                }
            }
            if !s.detail.isEmpty { Text(s.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(red.opacity(0.6))
                .lineLimit(s.active ? 1 : 3).multilineTextAlignment(.center).minimumScaleFactor(0.8) }
            if s.hasTimer {
                // The time fills the screen. Tap it to start or pause.
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let d = s.timer.display(at: ctx.date)
                    Text(d.text)
                        .font(.system(size: 200, weight: .heavy).width(.compressed)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(d.over && Int(ctx.date.timeIntervalSince1970 * 2) % 2 == 0 ? 0.4 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture { link.press(.pause) }
                        .onChange(of: ctx.date) { _, now in link.tick(now) }
                }
            } else if s.active {
                Text(s.canNext ? "" : "Choose on the iPhone").font(.footnote).foregroundStyle(red.opacity(0.6))
                    .frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
            if s.active {
                HStack(spacing: 6) {
                    if s.hasTimer {
                        Button { link.press(.restart) } label: {
                            Image(systemName: "arrow.counterclockwise.circle").font(.system(size: 26, weight: .semibold))
                        }
                        .buttonStyle(.plain).frame(width: 44, height: 44)
                        .accessibilityLabel("Restart timer")
                    }
                    Button { link.press(.next) } label: {
                        Text(s.nextLabel.uppercased())
                            .font(.system(size: 22, weight: .heavy).width(.condensed))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(red.opacity(s.canNext ? 1 : 0.35), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(!s.canNext)
                }
            }
            if !link.reachable && s.active {
                Text("iPhone out of reach").font(.system(size: 10)).foregroundStyle(red.opacity(0.5))
            }
        }
        .foregroundStyle(red)
        .containerBackground(.black, for: .navigation)
    }
}
