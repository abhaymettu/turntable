import UIKit
import UserNotifications

/// Client side of the APNs steering path only: ask, register, hand the token to the
/// server. The APNs Auth Key that actually sends a push is a developer-portal artifact,
/// see the "Needs him" list in README.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Notifications are asked for after pairing, not on the welcome screen: before the
        // phone follows a server there is nothing to notify about, and a permission alert
        // over a first-run screen is a prompt with no context.
        Task { @MainActor in
            guard Pairing.shared.isPaired else { return }
            await Self.requestNotifications()
        }
        return true
    }

    @MainActor
    static func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else {
            if await center.notificationSettings().authorizationStatus == .authorized {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            DebugLog.shared.add("apns", granted ? "notification permission granted" : "notification permission denied")
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            DebugLog.shared.add("apns", "authorization request failed: \(error.localizedDescription)")
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            DebugLog.shared.add("apns", "device token: \(token)")
            await APNsLink.shared.submit(token: token)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            DebugLog.shared.add("apns", "registration failed: \(error.localizedDescription)")
        }
    }
}
