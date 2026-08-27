import Foundation

/// Un message d'un salon (ou d'une discussion de groupe) qui me cite nommément.
///
/// À la différence de `Conversation`, l'unité n'est pas le space mais **le message** :
/// deux mentions dans le même salon donnent deux entrées, parce qu'elles appellent
/// chacune une réponse distincte.
struct Mention: Identifiable, Sendable {
    /// Nom de ressource du message (`spaces/{space}/messages/{id}`) — identifiant stable.
    let messageName: String
    /// Nom du salon où la mention a eu lieu.
    let spaceTitle: String
    /// Nom de l'auteur du message, résolu via l'API People.
    let authorName: String
    /// Début du message citant.
    let preview: String
    let date: Date?
    /// URL d'ouverture du salon dans Google Chat.
    let uri: String?
    /// Discussion de groupe plutôt que salon nommé.
    let isGroup: Bool

    var id: String { messageName }

    /// Tri d'affichage : de la mention la plus récente à la plus ancienne.
    static func sorted(_ mentions: [Mention]) -> [Mention] {
        mentions.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Extrait les mentions de `userID` parmi les messages d'un space.
    ///
    /// Mes propres messages sont écartés : se citer soi-même en répondant à un fil est
    /// courant et n'appelle aucune action.
    static func extract(
        from messages: [ChatMessage],
        in space: ChatSpace,
        myUserID: String,
        names: [String: String],
        accountEmail: String?
    ) -> [Mention] {
        messages.compactMap { message in
            guard message.sender?.userID != myUserID else { return nil }
            guard message.mentions(userID: myUserID) else { return nil }
            return Mention(
                messageName: message.name,
                spaceTitle: space.roomTitle,
                authorName: message.sender?.userID.flatMap { names[$0] } ?? "Quelqu'un",
                preview: message.displayText,
                date: message.createDate,
                uri: Conversation.openURL(uri: space.spaceUri,
                                          spaceName: space.name,
                                          accountEmail: accountEmail),
                isGroup: space.isGroupChat
            )
        }
    }
}
