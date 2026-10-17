import UserNotifications

/// Mac notifications for allowance alerts. They come from this app, so they only appear while it runs
/// (its menu bar icon keeps it running after the window closes).
enum Notifier {
    static func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = Delegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Allowance alerts, security alerts about someone probing this Mac or a network losing its protection,
    /// and router changes worth knowing about (DNS, bypass mode, power faults, a lost link to the dish).
    /// (A new device joining is already shown in the app, so it stays quiet.)
    static func worthAlerting(_ e: Event) -> Bool {
        if e.cat == "usage" { return true }
        guard e.cat == "security" || e.cat == "network", e.tone == "crit" || e.tone == "warn" else { return false }
        let title = e.title.lowercased()
        if title.contains("secure dns was turned on") || title.contains("public internet address") { return false }
        return ["scanning", "tried to connect", "probing", "isolation", "password",
                "dns servers changed", "secure dns was turned off", "bypass mode", "power feed", "lost its link to the dish"].contains { title.contains($0) }
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
