import Foundation
import AppKit
import UserNotifications

/// Envoi des notifications système (UNUserNotificationCenter) et gestion des clics.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    /// Demande l'autorisation d'envoyer des notifications (idempotent).
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                NSLog("Autorisation notifications refusée : \(error.localizedDescription)")
            } else {
                NSLog("Notifications autorisées : \(granted)")
            }
        }
    }

    /// Notifie un nouveau message privé.
    /// - Parameters:
    ///   - title: expéditeur.
    ///   - subtitle: contexte (nom de la discussion de groupe, sinon vide).
    ///   - body: texte du message.
    ///   - identifier: clé unique (nom de ressource du message).
    ///   - url: URL de la conversation, ouverte au clic.
    func notifyMessage(
        title: String,
        subtitle: String? = nil,
        body: String,
        identifier: String,
        url: String?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        if let url {
            content.userInfo = ["url": url]
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                NSLog("Envoi notification échoué : \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Affiche la notification même si l'app est active (utile pour une app de barre de menus).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Clic sur une notification → ouvre la conversation dans Google Chat.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let urlString = response.notification.request.content.userInfo["url"] as? String
        completionHandler()
        if let urlString, let url = URL(string: urlString) {
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
    }
}
