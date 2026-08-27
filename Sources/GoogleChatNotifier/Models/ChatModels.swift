import Foundation

// MARK: - Google Chat

/// Un « space » Google Chat. Une conversation privée est un space de type `DIRECT_MESSAGE`.
struct ChatSpace: Decodable, Identifiable, Sendable {
    /// Format `spaces/{id}`.
    let name: String
    let spaceType: String?
    let displayName: String?
    /// `true` quand le DM est avec une application Chat (bot) et non un humain.
    let singleUserBotDm: Bool?
    /// Horodatage du dernier message du space (RFC 3339).
    let lastActiveTime: String?
    /// URL d'ouverture de la conversation dans Google Chat.
    let spaceUri: String?

    var id: String { name }

    /// Identifiant nu, sans le préfixe `spaces/` (requis par l'URL du read state).
    var spaceID: String {
        name.hasPrefix("spaces/") ? String(name.dropFirst(7)) : name
    }

    var isDirectMessage: Bool { spaceType == "DIRECT_MESSAGE" }
    var isGroupChat: Bool { spaceType == "GROUP_CHAT" }

    /// Conversation entre humains (on écarte les DM avec les applications Chat).
    var isHumanConversation: Bool {
        (isDirectMessage || isGroupChat) && singleUserBotDm != true
    }

    var lastActiveDate: Date? { RFC3339.date(from: lastActiveTime) }
}

/// Réponse de `GET /v1/spaces`.
struct ChatSpaceList: Decodable, Sendable {
    let spaces: [ChatSpace]?
    let nextPageToken: String?
}

/// Un message Google Chat (`GET /v1/spaces/{space}/messages`).
struct ChatMessage: Decodable, Identifiable, Sendable {
    /// Format `spaces/{space}/messages/{message}`.
    let name: String
    let sender: ChatUser?
    let createTime: String?
    let text: String?
    /// Corps du message débarrassé des mentions d'applications Chat.
    let argumentText: String?
    let attachment: [ChatAttachment]?

    var id: String { name }
    var createDate: Date? { RFC3339.date(from: createTime) }

    /// Texte affichable, avec repli sur le nom de la pièce jointe puis un libellé générique.
    var displayText: String {
        let body = (text ?? argumentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        if let attachment, let first = attachment.first {
            return "📎 " + (first.contentName ?? "Pièce jointe")
        }
        return "(message sans texte)"
    }
}

struct ChatAttachment: Decodable, Sendable {
    let contentName: String?
}

/// Utilisateur Chat. En authentification utilisateur, Google ne renseigne que `name` et `type` :
/// le nom affichable est résolu séparément via l'API People (voir `DirectoryService`).
struct ChatUser: Decodable, Sendable {
    /// Format `users/{id}`.
    let name: String?
    let displayName: String?
    let type: String?

    /// Identifiant nu, sans le préfixe `users/`.
    var userID: String? {
        guard let name else { return nil }
        return name.hasPrefix("users/") ? String(name.dropFirst(6)) : name
    }

    var isHuman: Bool { type == nil || type == "HUMAN" }
}

/// Réponse de `GET /v1/spaces/{space}/messages`.
struct ChatMessageList: Decodable, Sendable {
    let messages: [ChatMessage]?
    let nextPageToken: String?
}

/// État de lecture d'un space pour l'utilisateur courant.
/// `GET /v1/users/me/spaces/{space}/spaceReadState`
struct SpaceReadState: Decodable, Sendable {
    let name: String?
    /// Horodatage du dernier message lu (RFC 3339). `nil` = jamais ouvert.
    let lastReadTime: String?
}

/// Une adhésion à un space (`GET /v1/spaces/{space}/members`).
struct ChatMembership: Decodable, Sendable {
    let name: String?
    let state: String?
    let member: ChatUser?
}

struct ChatMembershipList: Decodable, Sendable {
    let memberships: [ChatMembership]?
    let nextPageToken: String?
}

// MARK: - Erreur d'API Google

/// Corps d'erreur commun aux API Google : `{ "error": { "code": …, "message": …, "status": … } }`.
struct GoogleAPIError: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        let code: Int?
        let message: String?
        let status: String?
    }
    let error: Detail?
}

// MARK: - Compte connecté

/// Profil OpenID de l'utilisateur connecté (`GET /v1/userinfo`).
/// `sub` est l'identifiant numérique Google : c'est aussi le `{id}` de `users/{id}` côté Chat.
struct GoogleAccount: Decodable, Sendable {
    let sub: String
    let email: String?
    let name: String?
}

// MARK: - API People

/// Réponse de `GET https://people.googleapis.com/v1/people:batchGet`.
struct PeopleBatchResponse: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let httpStatusCode: Int?
        let person: Person?
        let requestedResourceName: String?
    }
    struct Person: Decodable, Sendable {
        let resourceName: String?
        let names: [Name]?
        let emailAddresses: [Email]?
    }
    struct Name: Decodable, Sendable {
        let displayName: String?
    }
    struct Email: Decodable, Sendable {
        let value: String?
    }

    let responses: [Entry]?

    /// Extrait la table `userID → nom affichable` (repli sur l'adresse e-mail).
    var displayNames: [String: String] {
        var result: [String: String] = [:]
        for entry in responses ?? [] {
            let resource = entry.person?.resourceName ?? entry.requestedResourceName
            guard let resource else { continue }
            let id = resource.hasPrefix("people/") ? String(resource.dropFirst(7)) : resource
            let label = entry.person?.names?.first?.displayName
                ?? entry.person?.emailAddresses?.first?.value
            if let label, !label.isEmpty {
                result[id] = label
            }
        }
        return result
    }
}

// MARK: - Dates

/// Analyse des horodatages RFC 3339 renvoyés par Google.
/// La précision va jusqu'aux nanosecondes (`2024-01-15T10:30:00.123456789Z`), que
/// `ISO8601DateFormatter` ne sait pas lire : on tronque la partie fractionnaire.
enum RFC3339 {
    /// `Date.ISO8601FormatStyle` est un type valeur `Sendable`, contrairement à
    /// `ISO8601DateFormatter` : il peut donc être partagé entre acteurs sans risque.
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return try? style.parse(stripFractionalSeconds(string))
    }

    /// `2024-01-15T10:30:00.123456789Z` → `2024-01-15T10:30:00Z`. Fonction pure (testable).
    static func stripFractionalSeconds(_ string: String) -> String {
        guard let dot = string.firstIndex(of: ".") else { return string }
        // Fin de la partie fractionnaire : premier caractère non numérique après le point.
        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isNumber {
            end = string.index(after: end)
        }
        return String(string[string.startIndex..<dot]) + String(string[end...])
    }
}
