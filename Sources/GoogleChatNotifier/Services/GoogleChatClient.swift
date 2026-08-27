import Foundation

/// Erreurs de haut niveau exposées par les clients d'API Google.
enum ChatClientError: LocalizedError {
    case notSignedIn
    case unauthorized
    case forbidden(String)
    case http(status: Int, message: String)
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Aucun compte Google connecté (voir Réglages)."
        case .unauthorized:
            return "Session Google expirée : reconnectez-vous (Réglages)."
        case .forbidden(let message):
            return "Accès refusé par Google : \(message)"
        case .http(let status, let message):
            return "Erreur Google (HTTP \(status)) : \(message)"
        case .network(let error):
            return "Erreur réseau : \(error.localizedDescription)"
        case .decoding:
            return "Réponse Google illisible."
        }
    }

    /// Le jeton d'accès doit-il être rafraîchi avant de retenter ?
    var isAuthFailure: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

/// Couche HTTP commune aux API Google (Chat, People) : `GET` authentifié par jeton Bearer.
enum GoogleAPI {
    static func get<T: Decodable>(
        _ url: URL,
        accessToken: String,
        session: URLSession = .shared
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatClientError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatClientError.http(status: -1, message: "Réponse non HTTP")
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw ChatClientError.decoding(error)
            }
        case 401:
            throw ChatClientError.unauthorized
        case 403:
            throw ChatClientError.forbidden(extractErrorMessage(from: data) ?? "permission insuffisante")
        default:
            throw ChatClientError.http(
                status: http.statusCode,
                message: extractErrorMessage(from: data) ?? "erreur inconnue"
            )
        }
    }

    /// Message lisible extrait de `{ "error": { "message": … } }`.
    static func extractErrorMessage(from data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(GoogleAPIError.self, from: data),
              let message = decoded.error?.message, !message.isEmpty else {
            return nil
        }
        return message
    }

    /// Construit une URL à partir d'une base, d'un chemin et d'une query.
    /// Le chemin est inséré tel quel (il contient déjà des `/`, ex. `spaces/AAA/messages`).
    static func url(base: String, path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(string: base + "/" + path)!
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }
}

/// Client en lecture seule de l'API REST Google Chat (v1), authentification utilisateur.
struct GoogleChatClient: Sendable {
    static let base = "https://chat.googleapis.com/v1"

    private let accessToken: String
    private let session: URLSession

    init(accessToken: String, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.session = session
    }

    // MARK: - Spaces

    /// Conversations dont je suis membre, pour les types demandés (`DIRECT_MESSAGE`, `GROUP_CHAT`).
    /// Suit la pagination jusqu'à `maxSpaces`.
    func listSpaces(types: [String], maxSpaces: Int = 400) async throws -> [ChatSpace] {
        var collected: [ChatSpace] = []
        var pageToken: String?

        repeat {
            var query: [String: String] = [
                "pageSize": "100",
                "filter": Self.spaceTypeFilter(types)
            ]
            if let pageToken { query["pageToken"] = pageToken }

            let url = GoogleAPI.url(base: Self.base, path: "spaces", query: query)
            let page: ChatSpaceList = try await GoogleAPI.get(url, accessToken: accessToken, session: session)
            collected.append(contentsOf: page.spaces ?? [])
            pageToken = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
        } while pageToken != nil && collected.count < maxSpaces

        return collected
    }

    /// Filtre de `spaces.list` : `spaceType = "DIRECT_MESSAGE" OR spaceType = "GROUP_CHAT"`.
    /// Fonction pure (testable).
    static func spaceTypeFilter(_ types: [String]) -> String {
        types.map { "spaceType = \"\($0)\"" }.joined(separator: " OR ")
    }

    // MARK: - État de lecture

    /// Dernier instant de lecture du space par l'utilisateur courant.
    func readState(spaceID: String) async throws -> SpaceReadState {
        let url = GoogleAPI.url(
            base: Self.base,
            path: "users/me/spaces/\(spaceID)/spaceReadState"
        )
        return try await GoogleAPI.get(url, accessToken: accessToken, session: session)
    }

    // MARK: - Messages

    /// Messages d'une conversation, du plus récent au plus ancien.
    /// - Parameter after: si fourni (RFC 3339), ne renvoie que les messages postérieurs.
    func messages(inSpace spaceName: String, after: String?, limit: Int) async throws -> [ChatMessage] {
        var query: [String: String] = [
            "pageSize": String(limit),
            "orderBy": "createTime DESC"
        ]
        if let after, !after.isEmpty {
            query["filter"] = "createTime > \"\(after)\""
        }

        func fetch(_ query: [String: String]) async throws -> [ChatMessage] {
            let url = GoogleAPI.url(base: Self.base, path: "\(spaceName)/messages", query: query)
            let page: ChatMessageList = try await GoogleAPI.get(url, accessToken: accessToken, session: session)
            return page.messages ?? []
        }

        do {
            return try await fetch(query)
        } catch ChatClientError.http(let status, _) where status == 400 {
            // Repli si l'API refuse `orderBy` : on retente sans, puis on trie localement.
            query.removeValue(forKey: "orderBy")
            let messages = try await fetch(query)
            return messages.sorted { ($0.createDate ?? .distantPast) > ($1.createDate ?? .distantPast) }
        }
    }

    // MARK: - Membres

    /// Identifiants des membres humains d'une conversation (`users/{id}` → `{id}`).
    func humanMemberIDs(inSpace spaceName: String, limit: Int = 25) async throws -> [String] {
        let url = GoogleAPI.url(
            base: Self.base,
            path: "\(spaceName)/members",
            query: ["pageSize": String(limit)]
        )
        let page: ChatMembershipList = try await GoogleAPI.get(url, accessToken: accessToken, session: session)
        return (page.memberships ?? []).compactMap { membership in
            guard let member = membership.member, member.isHuman else { return nil }
            return member.userID
        }
    }
}
