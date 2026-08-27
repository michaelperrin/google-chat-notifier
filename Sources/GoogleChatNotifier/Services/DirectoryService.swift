import Foundation

/// Résout les noms affichables des interlocuteurs.
///
/// En authentification utilisateur, l'API Chat ne renvoie que `users/{id}` (jamais le
/// `displayName`). On passe donc par l'API People (`people:batchGet`, périmètre
/// `directory.readonly`), avec un cache persistant pour limiter les appels.
///
/// Le service est « au mieux » : un échec n'interrompt pas le rafraîchissement, il est
/// simplement remonté dans `lastError` pour affichage dans les Réglages.
actor DirectoryService {
    static let shared = DirectoryService()

    private static let peopleBase = "https://people.googleapis.com/v1"
    /// Durée de validité d'un nom en cache (les noms changent rarement).
    private static let cacheLifetime: TimeInterval = 30 * 24 * 3600

    private enum Key {
        static let names = "directory.names"
        static let namesRefreshedAt = "directory.namesRefreshedAt"
        static let members = "directory.spaceMembers"
    }

    private let defaults: UserDefaults
    private let session: URLSession

    /// `userID → nom affichable`.
    private var names: [String: String]
    /// `spaces/{id} → identifiants des autres participants`.
    private var members: [String: [String]]

    /// Dernière erreur de résolution des noms (nil si tout va bien).
    private(set) var lastError: String?

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        self.names = defaults.dictionary(forKey: Key.names) as? [String: String] ?? [:]
        self.members = defaults.dictionary(forKey: Key.members) as? [String: [String]] ?? [:]

        // Purge périodique : on repart d'un cache vide pour capter les renommages.
        let refreshedAt = defaults.double(forKey: Key.namesRefreshedAt)
        if refreshedAt > 0, Date().timeIntervalSince1970 - refreshedAt > Self.cacheLifetime {
            self.names = [:]
            defaults.removeObject(forKey: Key.names)
        }
    }

    // MARK: - Participants d'une conversation

    /// Identifiants des autres participants d'une conversation.
    /// Résultat mis en cache : la composition d'un DM ne change jamais.
    func participants(
        ofSpace spaceName: String,
        excluding myUserID: String,
        client: GoogleChatClient
    ) async -> [String] {
        if let cached = members[spaceName] { return cached }

        guard let fetched = try? await client.humanMemberIDs(inSpace: spaceName) else {
            return []
        }
        let others = fetched.filter { $0 != myUserID }
        members[spaceName] = others
        defaults.set(members, forKey: Key.members)
        return others
    }

    // MARK: - Noms

    /// Nom affichable connu pour un identifiant, sans appel réseau.
    func cachedName(for userID: String) -> String? { names[userID] }

    /// Complète le cache pour les identifiants inconnus, puis renvoie la table complète
    /// des noms résolus parmi `userIDs`.
    @discardableResult
    func resolveNames(for userIDs: [String], accessToken: String) async -> [String: String] {
        let unknown = Array(Set(userIDs.filter { !$0.isEmpty && names[$0] == nil }))

        if !unknown.isEmpty {
            // `people:batchGet` accepte 200 ressources par appel ; on reste prudent.
            for chunk in stride(from: 0, to: unknown.count, by: 50).map({ start in
                Array(unknown[start..<min(start + 50, unknown.count)])
            }) {
                do {
                    let fetched = try await fetchNames(for: chunk, accessToken: accessToken)
                    names.merge(fetched) { _, new in new }
                    lastError = nil
                } catch {
                    lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    break
                }
            }
            defaults.set(names, forKey: Key.names)
            if defaults.double(forKey: Key.namesRefreshedAt) == 0 {
                defaults.set(Date().timeIntervalSince1970, forKey: Key.namesRefreshedAt)
            }
        }

        return names.filter { userIDs.contains($0.key) }
    }

    private func fetchNames(for userIDs: [String], accessToken: String) async throws -> [String: String] {
        var components = URLComponents(string: Self.peopleBase + "/people:batchGet")!
        components.queryItems =
            [URLQueryItem(name: "personFields", value: "names,emailAddresses")]
            + userIDs.map { URLQueryItem(name: "resourceNames", value: "people/\($0)") }

        let response: PeopleBatchResponse = try await GoogleAPI.get(
            components.url!,
            accessToken: accessToken,
            session: session
        )
        return response.displayNames
    }

    /// Efface les caches (déconnexion, changement de compte).
    func reset() {
        names = [:]
        members = [:]
        lastError = nil
        defaults.removeObject(forKey: Key.names)
        defaults.removeObject(forKey: Key.namesRefreshedAt)
        defaults.removeObject(forKey: Key.members)
    }
}
