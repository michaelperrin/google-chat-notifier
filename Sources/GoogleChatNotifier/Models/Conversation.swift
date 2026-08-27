import Foundation

/// Une conversation privée telle qu'affichée dans le popover : **une entrée par
/// interlocuteur**, avec le début du dernier message reçu.
struct Conversation: Identifiable, Sendable {
    /// Nom de ressource du space (`spaces/{id}`) — identifiant stable.
    let spaceName: String
    /// Nom de l'interlocuteur (ou des participants pour une discussion de groupe).
    let title: String
    /// URL d'ouverture dans Google Chat.
    let uri: String?
    /// Date du dernier message de la conversation.
    let lastActive: Date?
    /// Dernier message de la conversation (celui dont on affiche le début).
    let preview: String?
    /// Le dernier message vient de moi → il n'y a rien à répondre.
    let lastMessageIsMine: Bool
    /// Messages reçus après ma dernière lecture, du plus récent au plus ancien.
    let unread: [ChatMessage]
    /// Discussion de groupe (par opposition à un tête-à-tête).
    let isGroup: Bool

    var id: String { spaceName }

    /// Nombre de messages non lus (affiché en pastille quand il dépasse 1).
    var unreadCount: Int { unread.count }
    var isUnread: Bool { !unread.isEmpty }

    /// En attente de ma réponse : le dernier message n'est pas de moi.
    /// C'est le critère de l'onglet « À traiter » et du compteur de la barre de menus.
    var needsReply: Bool { preview != nil && !lastMessageIsMine }

    /// Tri d'affichage : non lues d'abord, puis par activité décroissante.
    static func sorted(_ conversations: [Conversation]) -> [Conversation] {
        conversations.sorted { lhs, rhs in
            if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
            return (lhs.lastActive ?? .distantPast) > (rhs.lastActive ?? .distantPast)
        }
    }

    /// URL d'ouverture, avec repli sur l'URL web de Google Chat quand l'API ne fournit
    /// pas `spaceUri`.
    static func openURL(uri: String?, spaceName: String) -> String {
        if let uri, !uri.isEmpty { return uri }
        let id = spaceName.hasPrefix("spaces/") ? String(spaceName.dropFirst(7)) : spaceName
        return "https://mail.google.com/chat/u/0/#chat/space/\(id)"
    }
}
