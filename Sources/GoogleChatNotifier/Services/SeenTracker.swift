import Foundation

/// Suit les identifiants déjà vus afin de ne notifier que les nouveaux éléments.
/// Persiste dans UserDefaults pour survivre aux relances de l'app.
struct SeenTracker {
    private let defaults: UserDefaults
    private let key: String
    /// Clé du drapeau « premier passage effectué ».
    private var bootstrapKey: String { key + ".bootstrapped" }

    init(key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
    }

    /// Détermine, parmi `currentIDs`, ceux jamais vus jusqu'ici — sans effet de bord.
    /// Fonction pure pour faciliter les tests.
    static func newIDs(current currentIDs: [String], seen: Set<String>) -> [String] {
        currentIDs.filter { !seen.contains($0) }
    }

    /// Ensemble des identifiants déjà vus (persisté).
    func seen() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    /// Enregistre l'ensemble courant comme « vu » et marque l'amorçage comme fait.
    func markSeen(_ ids: [String]) {
        defaults.set(Array(Set(ids)), forKey: key)
        defaults.set(true, forKey: bootstrapKey)
    }

    /// Renvoie les nouveaux identifiants et met à jour le stockage en une passe.
    ///
    /// Le tout premier appel ne renvoie rien : on ne veut pas notifier tout l'historique au
    /// premier lancement. Le drapeau d'amorçage est distinct de l'ensemble mémorisé, sans quoi
    /// une liste momentanément vide (tout est lu) ferait passer le message suivant à la trappe.
    mutating func consumeNew(current currentIDs: [String]) -> [String] {
        let previouslySeen = seen()
        let bootstrapped = defaults.bool(forKey: bootstrapKey)
        markSeen(currentIDs)

        guard bootstrapped else { return [] }
        return Self.newIDs(current: currentIDs, seen: previouslySeen)
    }

    /// Remet le suivi à zéro (déconnexion, changement de compte).
    func reset() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: bootstrapKey)
    }
}
