import SwiftUI
import UserNotifications

@main
struct DarkroomApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var phase

    init() {
        PhoneWatch.shared.activate()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(Look.shared.darkroom ? .dark : .light)
                .task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    await store.refresh()
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
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if store.signedIn { HomeView() } else { SignInView() }
        }
    }
}
