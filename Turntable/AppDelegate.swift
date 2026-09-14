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
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                DebugLog.shared.add("apns", granted ? "notification permission granted" : "notification permission denied")
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } catch {
                DebugLog.shared.add("apns", "authorization request failed: \(error.localizedDescription)")
            }
        }
        return true
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
