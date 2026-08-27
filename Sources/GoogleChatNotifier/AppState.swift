import Foundation
import Observation

/// État central de l'app : conversations chargées, compte connecté, erreurs, et
/// orchestration des appels à l'API Google Chat.
@MainActor
@Observable
final class AppState {
    /// Conversations récentes, non lues d'abord puis par activité décroissante.
    /// Une entrée par interlocuteur.
    var conversations: [Conversation] = []
    var account: GoogleAccount?

    var isRefreshing = false
    var errorMessage: String?
    /// Avertissement non bloquant (ex. noms d'interlocuteurs non résolus).
    var directoryWarning: String?
    var lastUpdated: Date?

    /// Ancienneté maximale d'une conversation prise en compte.
    private static let recencyWindow: TimeInterval = 45 * 24 * 3600
    /// Nombre de conversations examinées à chaque cycle (les plus récentes).
    private static let maxSpaces = 30
    /// Messages non lus rapatriés par conversation.
    private static let maxUnreadPerSpace = 25
    /// Appels simultanés à l'API.
    private static let concurrency = 6

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var seen = SeenTracker(key: "seen.messages")

    init(preferences: Preferences = .shared) {
        self.preferences = preferences
        self.account = preferences.storedAccount
    }

    // MARK: - Données dérivées

    /// Conversations en attente de ma réponse : le contenu de l'onglet « À traiter ».
    var pendingConversations: [Conversation] { conversations.filter(\.needsReply) }

    /// Compteur affiché dans la barre de menus = nombre de conversations à traiter
    /// (une par personne, quel que soit le nombre de messages reçus).
    var badgeCount: Int { pendingConversations.count }

    var isSignedIn: Bool { OAuthService.shared.isSignedIn }

    var isConfigured: Bool {
        Preferences.isConfigured(
            clientID: preferences.clientID,
            clientSecret: KeychainStore.get(.clientSecret)
        )
    }

    // MARK: - Connexion

    /// Lance le flux OAuth (navigateur + boucle locale) et mémorise le compte.
    @discardableResult
    func signIn() async throws -> GoogleAccount {
        let account = try await OAuthService.shared.signIn()
        self.account = account
        preferences.storedAccount = account
        // Nouveau compte : les caches de l'ancien n'ont plus de sens.
        await DirectoryService.shared.reset()
        seen.reset()
        errorMessage = nil
        return account
    }

    func signOut() async {
        await OAuthService.shared.signOut()
        await DirectoryService.shared.reset()
        seen.reset()
        account = nil
        preferences.clearAccount()
        conversations = []
        errorMessage = nil
        directoryWarning = nil
        lastUpdated = nil
    }

    // MARK: - Rafraîchissement

    /// Recharge les conversations. Notifie les nouveaux messages, sauf au premier chargement.
    func refresh(notifyNew: Bool = true) async {
        guard isConfigured else {
            errorMessage = OAuthError.notConfigured.localizedDescription
            return
        }
        guard isSignedIn else {
            errorMessage = OAuthError.notSignedIn.localizedDescription
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            try await load(notifyNew: notifyNew)
            errorMessage = nil
            lastUpdated = Date()
        } catch let error as ChatClientError where error.isAuthFailure {
            // Jeton d'accès périmé : on force un rafraîchissement et on retente une fois.
            await OAuthService.shared.invalidateAccessToken()
            do {
                try await load(notifyNew: notifyNew)
                errorMessage = nil
                lastUpdated = Date()
            } catch {
                errorMessage = Self.describe(error)
            }
        } catch {
            errorMessage = Self.describe(error)
        }

        directoryWarning = await DirectoryService.shared.lastError
    }

    private func load(notifyNew: Bool) async throws {
        let token = try await OAuthService.shared.token()
        let client = GoogleChatClient(accessToken: token)
        let myUserID = account?.sub ?? ""

        // 1. Conversations privées (et discussions de groupe si l'option est activée),
        //    limitées aux plus récentes.
        let candidates = Self.candidates(
            from: try await client.listSpaces(types: preferences.spaceTypes),
            now: Date(),
            limit: Self.maxSpaces
        )

        // 2. État de lecture de chacune : c'est ce qui définit « non lu ».
        let readStates = await mapConcurrently(candidates, limit: Self.concurrency) { space in
            let state = try? await client.readState(spaceID: space.spaceID)
            return SpaceState(space: space, lastReadTime: state?.lastReadTime)
        }

        // 3. Messages : tous les non lus si la conversation en a, sinon le dernier message
        //    seul (suffisant pour savoir si j'ai répondu et pour afficher l'aperçu).
        let loaded = await mapConcurrently(readStates, limit: Self.concurrency) { state -> LoadedSpace in
            let messages = (try? await client.messages(
                inSpace: state.space.name,
                after: state.isUnread ? state.lastReadTime : nil,
                limit: state.isUnread ? Self.maxUnreadPerSpace : 1
            )) ?? []
            let participants = await DirectoryService.shared.participants(
                ofSpace: state.space.name,
                excluding: myUserID,
                client: client
            )
            return LoadedSpace(state: state, messages: messages, participants: participants)
        }

        // 4. Résolution des noms (API People) en un seul lot.
        let userIDs = loaded.flatMap { $0.participants + $0.messages.compactMap { $0.sender?.userID } }
        let names = await DirectoryService.shared.resolveNames(for: userIDs, accessToken: token)

        // 5. Construction du modèle d'affichage : une entrée par conversation.
        let built = loaded.map { Self.makeConversation($0, names: names, myUserID: myUserID) }
        conversations = Conversation.sorted(built)

        // 6. Notifications sur les nouveaux messages non lus.
        notify(built, names: names, notifyNew: notifyNew)
    }

    // MARK: - Assemblage (fonctions pures, testables)

    /// Une conversation candidate et son état de lecture.
    struct SpaceState: Sendable {
        let space: ChatSpace
        let lastReadTime: String?

        /// Non lue : le dernier message est postérieur à ma dernière lecture.
        var isUnread: Bool {
            guard let lastActive = space.lastActiveDate else { return false }
            guard let lastRead = RFC3339.date(from: lastReadTime) else { return true }
            return lastActive > lastRead
        }
    }

    struct LoadedSpace: Sendable {
        let state: SpaceState
        let messages: [ChatMessage]
        let participants: [String]
    }

    /// Conversations retenues : humaines, actives récemment, les plus récentes d'abord.
    /// Fonction pure (testable).
    static func candidates(from spaces: [ChatSpace], now: Date, limit: Int) -> [ChatSpace] {
        let cutoff = now.addingTimeInterval(-recencyWindow)
        return spaces
            .filter(\.isHumanConversation)
            .filter { ($0.lastActiveDate ?? .distantPast) > cutoff }
            .sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Nom affiché pour une conversation : nom du space s'il en a un, sinon les participants.
    static func title(
        space: ChatSpace,
        participants: [String],
        names: [String: String]
    ) -> String {
        if let displayName = space.displayName, !displayName.isEmpty { return displayName }

        let resolved = participants.compactMap { names[$0] }
        if resolved.isEmpty {
            return space.isGroupChat ? "Discussion de groupe" : "Conversation privée"
        }
        if resolved.count <= 3 { return resolved.joined(separator: ", ") }
        return resolved.prefix(2).joined(separator: ", ") + " +\(resolved.count - 2)"
    }

    private static func makeConversation(
        _ loaded: LoadedSpace,
        names: [String: String],
        myUserID: String
    ) -> Conversation {
        let space = loaded.state.space
        // `messages` est trié du plus récent au plus ancien dans les deux branches
        // de chargement : le premier élément est donc toujours le dernier message.
        let latest = loaded.messages.first
        // Mes propres messages ne sont jamais « non lus ».
        let unread = loaded.state.isUnread
            ? loaded.messages.filter { $0.sender?.userID != myUserID }
            : []

        return Conversation(
            spaceName: space.name,
            title: title(space: space, participants: loaded.participants, names: names),
            uri: Conversation.openURL(uri: space.spaceUri, spaceName: space.name),
            lastActive: latest?.createDate ?? space.lastActiveDate,
            preview: latest?.displayText,
            lastMessageIsMine: latest?.sender?.userID == myUserID,
            unread: unread,
            isGroup: space.isGroupChat
        )
    }

    // MARK: - Notifications

    private func notify(_ conversations: [Conversation], names: [String: String], notifyNew: Bool) {
        // Table message → conversation, pour retrouver l'expéditeur et l'URL au moment de notifier.
        var byMessageID: [String: (Conversation, ChatMessage)] = [:]
        for conversation in conversations {
            for message in conversation.unread {
                byMessageID[message.name] = (conversation, message)
            }
        }
        let currentIDs = Array(byMessageID.keys)

        guard notifyNew else {
            seen.markSeen(currentIDs)
            return
        }

        for id in seen.consumeNew(current: currentIDs) {
            guard let (conversation, message) = byMessageID[id] else { continue }
            let sender = message.sender?.userID.flatMap { names[$0] } ?? conversation.title
            NotificationService.shared.notifyMessage(
                title: sender,
                subtitle: conversation.isGroup ? conversation.title : nil,
                body: message.displayText,
                // Les identifiants de message contiennent des « / » : on les remplace.
                identifier: id.replacingOccurrences(of: "/", with: "-"),
                url: conversation.uri
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
