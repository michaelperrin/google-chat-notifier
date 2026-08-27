import Foundation
import Observation

/// Préférences non sensibles (le client secret et le refresh token sont dans le Keychain).
/// Persiste dans UserDefaults ; observable par SwiftUI via le framework Observation.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let clientID = "oauth.clientID"
        static let refreshMinutes = "refreshMinutes"
        static let includeGroupChats = "includeGroupChats"
        static let accountEmail = "account.email"
        static let accountName = "account.name"
        static let accountSub = "account.sub"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Lecture initiale. didSet ne se déclenche pas pendant init : pas de ré-écriture parasite.
        self.clientID = defaults.string(forKey: Key.clientID) ?? ""
        let minutes = defaults.integer(forKey: Key.refreshMinutes)
        self.refreshMinutes = minutes > 0 ? minutes : 2
        self.includeGroupChats = defaults.bool(forKey: Key.includeGroupChats)
    }

    /// Client ID OAuth du client « Application de bureau ». Requis, sans défaut.
    var clientID: String {
        didSet { defaults.set(clientID, forKey: Key.clientID) }
    }

    /// Intervalle de rafraîchissement, en minutes (défaut : 2).
    var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Key.refreshMinutes) }
    }

    /// Inclure aussi les discussions de groupe (hors salons nommés). Défaut : non.
    var includeGroupChats: Bool {
        didSet { defaults.set(includeGroupChats, forKey: Key.includeGroupChats) }
    }

    /// Types de spaces interrogés, au format attendu par le filtre de `spaces.list`.
    var spaceTypes: [String] {
        includeGroupChats ? ["DIRECT_MESSAGE", "GROUP_CHAT"] : ["DIRECT_MESSAGE"]
    }

    // MARK: - Compte connecté (cache d'affichage, rechargé à chaque connexion)

    /// Compte mémorisé, pour afficher « connecté en tant que… » dès le lancement.
    var storedAccount: GoogleAccount? {
        get {
            guard let sub = defaults.string(forKey: Key.accountSub), !sub.isEmpty else { return nil }
            return GoogleAccount(
                sub: sub,
                email: defaults.string(forKey: Key.accountEmail),
                name: defaults.string(forKey: Key.accountName)
            )
        }
        set {
            defaults.set(newValue?.sub, forKey: Key.accountSub)
            defaults.set(newValue?.email, forKey: Key.accountEmail)
            defaults.set(newValue?.name, forKey: Key.accountName)
        }
    }

    /// Nettoie tout ce qui dépend du compte (déconnexion).
    func clearAccount() {
        storedAccount = nil
    }

    /// Le client OAuth est-il complètement renseigné ?
    static func isConfigured(clientID: String, clientSecret: String?) -> Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(clientSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
