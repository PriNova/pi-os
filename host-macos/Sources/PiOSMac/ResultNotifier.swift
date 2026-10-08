import AppKit
import UserNotifications

@MainActor final class ResultNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "backgroundNotifications"
    var onOpen: ((String) -> Void)?
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
    override init() { super.init(); center?.delegate = self }
    /// Only called by the explicit Settings checkbox, never on launch or task completion.
    func requestPermission() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    func notify(invocation: String, failed: Bool) async -> Bool {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), let center else { return false }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return false }
        let content = UNMutableNotificationContent()
        content.title = failed ? "pi-os — Request interrupted" : "pi-os — Answer ready"
        // No screenshot, window title, prompt or answer content in notification storage.
        content.body = "Click to view the result."
        content.userInfo = ["invocation": invocation]
        center.removeDeliveredNotifications(withIdentifiers: ["pi-os.result"])
        do {
            try await center.add(UNNotificationRequest(identifier: "pi-os.result", content: content, trigger: nil))
            return true
        } catch { return false }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["invocation"] as? String
        Task { @MainActor [weak self] in
            if let id { self?.onOpen?(id) }
            completionHandler()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
