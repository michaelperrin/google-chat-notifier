import Foundation
import Security

/// Stockage des secrets OAuth dans le trousseau (Keychain) macOS.
/// Rien de sensible n'est écrit dans UserDefaults.
enum KeychainStore {
    private static let service = "fr.michaelperrin.google-chat-notifier"

    /// Comptes utilisés dans le trousseau.
    enum Item: String {
        /// « Client secret » du client OAuth « Application de bureau ».
        case clientSecret = "google-oauth-client-secret"
        /// Jeton de rafraîchissement obtenu à la connexion (longue durée de vie).
        case refreshToken = "google-oauth-refresh-token"
    }

    /// Enregistre (ou remplace) une valeur. `nil` ou chaîne vide supprime l'entrée.
    static func set(_ value: String?, for item: Item) {
        guard let value, !value.isEmpty else {
            delete(item)
            return
        }
        // Supprime l'éventuelle entrée existante puis ré-insère (évite errSecDuplicateItem).
        delete(item)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Lit une valeur, ou `nil` si l'entrée n'existe pas.
    static func get(_ item: Item) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func delete(_ item: Item) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
