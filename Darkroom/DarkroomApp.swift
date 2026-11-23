import SwiftUI
import UserNotifications

@main
struct DarkroomApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store: AppStore
    @State private var walks: Walks
    @Environment(\.scenePhase) private var phase

    init() {
        let s = AppStore()
        _store = State(initialValue: s)
        _walks = State(initialValue: Walks(store: s))
        PhoneWatch.shared.activate()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(walks)
                .preferredColorScheme(Look.shared.darkroom ? .dark : .light)
                .task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    await StepAlarm.shared.authorize()
                    await store.refresh()
                    store.ready = true
                }
        }
        .onChange(of: phase) { _, p in if p == .active { Task { await store.refresh() } } }
    }
}

/// While the app is open the walk-through rings itself, so the system banner
/// for the same timer stays quiet.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions { [] }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var splash = true
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if store.signedIn { HomeView() } else { SignInView() }
            if splash {
                SplashView { withAnimation(.easeOut(duration: 0.5)) { splash = false } }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .statusBarHidden(splash)
    }
}

/// On opening: the red bulb on black, its light spreading until everything is
/// red, then the app, once the lists have loaded.
private struct SplashView: View {
    @Environment(AppStore.self) private var store
    let finished: () -> Void
    @State private var lit = false
    @State private var spread = false
    @State private var inked = false
    private let red = Color(red: 1, green: 0.165, blue: 0.102)
    /// Never held longer than this, so a slow or missing connection can't trap it.
    private let longest: TimeInterval = 8

    var body: some View {
        GeometryReader { g in
            let size = hypot(g.size.width, g.size.height) * 1.5
            ZStack {
                Color.black
                Circle().fill(red).frame(width: size, height: size).blur(radius: 50)
                    .scaleEffect(spread ? 1 : 0.02)
                    .opacity(lit ? 1 : 0)
                bulb(red).opacity(lit && !inked ? 1 : 0)
                bulb(.black).opacity(inked ? 1 : 0)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
        .accessibilityLabel("Darkroom is opening")
        .task {
            let start = Date()
            withAnimation(.easeIn(duration: 0.25)) { lit = true }
            try? await Task.sleep(for: .seconds(0.25))
            withAnimation(.easeIn(duration: 1)) { spread = true }
            withAnimation(.easeIn(duration: 0.35).delay(0.6)) { inked = true }
            try? await Task.sleep(for: .seconds(1.1))
            while !store.ready && Date().timeIntervalSince(start) < longest {
                try? await Task.sleep(for: .milliseconds(100))
            }
            finished()
        }
    }

    private func bulb(_ colour: Color) -> some View {
        Image(systemName: "lightbulb.fill").font(.system(size: 110, weight: .bold)).foregroundStyle(colour)
    }
}
