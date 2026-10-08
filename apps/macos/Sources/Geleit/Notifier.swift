import Foundation
import UserNotifications

/// Notificações do sistema. Falhas trazem o botão "Conectar" para tentar de novo com um clique.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let retryCategory = "GELEIT_RETRY"
    private static let retryAction = "GELEIT_CONNECT"

    var onAction: (@MainActor (UUID) -> Void)?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter exige rodar de dentro de um .app (bundle).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        guard let center else { return }
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.retryAction, title: "Conectar", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.retryCategory, actions: [action], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, actionProfileID: UUID? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let id = actionProfileID {
            content.categoryIdentifier = Self.retryCategory
            content.userInfo = ["profile": id.uuidString]
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == Self.retryAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo["profile"] as? String,
              let id = UUID(uuidString: raw) else { return }
        Task { @MainActor in self.onAction?(id) }
    }
}
