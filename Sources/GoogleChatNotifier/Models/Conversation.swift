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

    /// En attente de ma réponse : il reste des messages non lus **et** le dernier
    /// message n'est pas de moi.
    /// C'est le critère de l'onglet « À traiter » et du compteur de la barre de menus.
    ///
    /// L'état de lecture fait partie du critère : un message déjà ouvert dans Google
    /// Chat sort de la liste, même sans réponse de ma part. Sinon toute conversation
    /// dont je n'ai pas eu le dernier mot y resterait indéfiniment.
    ///
    /// Les deux conditions sont nécessaires : `isUnread` seul laisserait passer une
    /// conversation où j'ai répondu depuis un autre appareil sans que l'état de
    /// lecture ait suivi.
    var needsReply: Bool { isUnread && !lastMessageIsMine }

    /// Tri d'affichage : non lues d'abord, puis par activité décroissante.
    static func sorted(_ conversations: [Conversation]) -> [Conversation] {
        conversations.sorted { lhs, rhs in
            if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
            return (lhs.lastActive ?? .distantPast) > (rhs.lastActive ?? .distantPast)
        }
    }

    /// URL d'ouverture, avec repli sur l'URL web de Google Chat quand l'API ne fournit
    /// pas `spaceUri`.
    ///
    /// `accountEmail` désambiguïse le compte quand plusieurs sessions Google sont
    /// ouvertes dans le navigateur : sans lui, Chat s'ouvre sur le compte par défaut et
    /// la conversation est introuvable. On passe par `authuser=<email>` plutôt que par
    /// l'index `/u/N/` : cet index est positionnel, il change dès qu'un compte est
    /// ajouté ou retiré du navigateur, alors que l'adresse, elle, est stable.
    static func openURL(uri: String?, spaceName: String, accountEmail: String? = nil) -> String {
        let base: String
        if let uri, !uri.isEmpty {
            base = uri
        } else {
            let id = spaceName.hasPrefix("spaces/") ? String(spaceName.dropFirst(7)) : spaceName
            // Sans compte connu, on retombe sur l'index 0 — le compte par défaut.
            let index = accountEmail == nil ? "u/0/" : ""
            base = "https://mail.google.com/chat/\(index)#chat/space/\(id)"
        }
        return withAuthUser(base, email: accountEmail)
    }

    /// Ajoute `authuser=<email>` à une URL Google, sans écraser un paramètre déjà présent.
    /// Le paramètre doit précéder le fragment (`#chat/space/…`) pour que Chat le voie,
    /// ce dont `URLComponents` se charge.
    static func withAuthUser(_ urlString: String, email: String?) -> String {
        guard let email, !email.isEmpty,
              var components = URLComponents(string: urlString) else { return urlString }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "authuser" }) else { return urlString }
        items.append(URLQueryItem(name: "authuser", value: email))
        components.queryItems = items
        return components.url?.absoluteString ?? urlString
    }
}
