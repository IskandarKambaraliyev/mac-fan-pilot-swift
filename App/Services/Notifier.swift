import Foundation
import UserNotifications

/// Banners for things that happen while nobody is looking at the popover. Permission is asked
/// for the first time one is needed.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // One identifier per kind of event, so a repeat replaces the banner instead of stacking.
            center.add(UNNotificationRequest(identifier: title, content: content, trigger: nil))
        }
    }

    /// Show the banner even while the settings window makes this the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
