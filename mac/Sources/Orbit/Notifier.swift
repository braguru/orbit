import UserNotifications

/// Mac notifications for allowance alerts. They come from this app, so they only appear while it runs
/// (its menu bar icon keeps it running after the window closes).
enum Notifier {
    static func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = Delegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ e: Event) {
        let content = UNMutableNotificationContent()
        content.title = e.title
        if let detail = e.detail { content.body = detail }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "orbit-event-\(e.id)", content: content, trigger: nil))
    }

    /// Shows notifications even while Orbit is the app in front.
    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Delegate()

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions { [.banner, .sound] }
    }
}
