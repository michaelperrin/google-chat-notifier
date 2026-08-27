import Foundation
import CryptoKit
import AppKit

/// Erreurs du flux d'autorisation Google.
enum OAuthError: LocalizedError {
    case notConfigured
    case notSignedIn
    case stateMismatch
    case denied(String)
    case server(String)
    case network(Error)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Client OAuth incomplet : renseignez le Client ID et le Client Secret (Réglages)."
        case .notSignedIn:
            return "Aucun compte Google connecté (voir Réglages)."
        case .stateMismatch:
            return "Réponse d'authentification incohérente (paramètre « state »)."
        case .denied(let reason):
            return "Autorisation refusée : \(reason)"
        case .server(let message):
            return "Google a refusé la demande : \(message)"
        case .network(let error):
            return "Erreur réseau : \(error.localizedDescription)"
        case .malformedResponse:
            return "Réponse d'authentification illisible."
        }
    }
}

/// Réponse du point de terminaison `/token`.
private struct TokenResponse: Decodable {
    let accessToken: String?
    let expiresIn: Int?
    let refreshToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case error
        case errorDescription = "error_description"
    }
}

/// Gère le flux OAuth 2.0 « application de bureau » (boucle locale + PKCE) et fournit
/// un jeton d'accès valide au reste de l'app.
///
/// Le refresh token vit dans le Keychain ; le jeton d'accès reste en mémoire.
actor OAuthService {
    static let shared = OAuthService()

    /// Périmètres demandés. Tous en lecture seule.
    static let scopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/chat.spaces.readonly",
        "https://www.googleapis.com/auth/chat.messages.readonly",
        "https://www.googleapis.com/auth/chat.memberships.readonly",
        "https://www.googleapis.com/auth/chat.users.readstate.readonly",
        "https://www.googleapis.com/auth/directory.readonly"
    ]

    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoEndpoint = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!
    private static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    private let session: URLSession
    private var accessToken: String?
    private var expiresAt: Date?
    /// Rafraîchissement en cours : mutualisé pour éviter les appels concurrents.
    private var refreshTask: Task<String, Error>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - État

    nonisolated var isSignedIn: Bool { KeychainStore.get(.refreshToken) != nil }

    /// Identifiants du client OAuth, lus au dernier moment (modifiables dans les Réglages).
    private func credentials() throws -> (clientID: String, clientSecret: String) {
        let clientID = (UserDefaults.standard.string(forKey: "oauth.clientID") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = (KeychainStore.get(.clientSecret) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw OAuthError.notConfigured }
        return (clientID, clientSecret)
    }

    // MARK: - Connexion

    /// Ouvre le navigateur sur l'écran de consentement Google, attend la redirection sur la
    /// boucle locale, échange le code contre des jetons, et renvoie le profil du compte.
    func signIn() async throws -> GoogleAccount {
        let (clientID, clientSecret) = try credentials()

        let server = LoopbackServer()
        defer { server.stop() }

        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        let verifier = Self.randomURLSafeString(length: 64)
        let state = Self.randomURLSafeString(length: 32)
        let authURL = Self.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: Self.codeChallenge(for: verifier)
        )

        _ = await MainActor.run { NSWorkspace.shared.open(authURL) }

        // 5 minutes : le temps de choisir un compte et d'accepter l'écran de consentement.
        let parameters = try await server.waitForRedirect(timeout: 300)

        if let error = parameters["error"] {
            throw OAuthError.denied(error)
        }
        guard parameters["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = parameters["code"] else { throw OAuthError.malformedResponse }

        let response = try await postToken([
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ])

        guard let refreshToken = response.refreshToken else {
            // Sans `refresh_token`, l'app ne pourrait pas se reconnecter après expiration.
            throw OAuthError.server(
                "aucun refresh token renvoyé (révoquez l'accès de l'app dans votre compte Google, puis réessayez)"
            )
        }
        KeychainStore.set(refreshToken, for: .refreshToken)
        store(accessToken: response.accessToken, expiresIn: response.expiresIn)

        return try await fetchUserInfo()
    }

    /// Révoque le refresh token côté Google (au mieux) et efface l'état local.
    func signOut() async {
        if let refreshToken = KeychainStore.get(.refreshToken) {
            var request = URLRequest(url: Self.revokeEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("token=\(Self.formEncode(refreshToken))".utf8)
            _ = try? await session.data(for: request)
        }
        KeychainStore.delete(.refreshToken)
        accessToken = nil
        expiresAt = nil
        refreshTask = nil
    }

    // MARK: - Jeton d'accès

    /// Jeton d'accès valide, rafraîchi si nécessaire.
    func token() async throws -> String {
        if let accessToken, let expiresAt, expiresAt > Date().addingTimeInterval(60) {
            return accessToken
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { try await refreshAccessToken() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// Force un rafraîchissement au prochain appel (à utiliser après un HTTP 401).
    func invalidateAccessToken() {
        accessToken = nil
        expiresAt = nil
    }

    private func refreshAccessToken() async throws -> String {
        let (clientID, clientSecret) = try credentials()
        guard let refreshToken = KeychainStore.get(.refreshToken) else {
            throw OAuthError.notSignedIn
        }
        let response = try await postToken([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
        guard let newToken = response.accessToken else { throw OAuthError.malformedResponse }
        store(accessToken: newToken, expiresIn: response.expiresIn)
        return newToken
    }

    private func store(accessToken newToken: String?, expiresIn: Int?) {
        accessToken = newToken
        expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn ?? 3600))
    }

    // MARK: - Profil

    /// Profil OpenID du compte connecté. `sub` sert d'identifiant utilisateur côté Chat.
    func fetchUserInfo() async throws -> GoogleAccount {
        let accessToken = try await token()
        var request = URLRequest(url: Self.userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthError.network(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.server(String(data: data, encoding: .utf8) ?? "réponse inattendue")
        }
        guard let account = try? JSONDecoder().decode(GoogleAccount.self, from: data) else {
            throw OAuthError.malformedResponse
        }
        return account
    }

    // MARK: - HTTP

    private func postToken(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formBody(fields).utf8)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw OAuthError.network(error)
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw OAuthError.malformedResponse
        }
        if let error = decoded.error {
            throw OAuthError.server(decoded.errorDescription.map { "\(error) — \($0)" } ?? error)
        }
        return decoded
    }

    // MARK: - Helpers purs (testables)

    /// URL de l'écran de consentement Google.
    /// `access_type=offline` + `prompt=consent` garantissent l'émission d'un refresh token.
    static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }

    /// Challenge PKCE : `base64url(SHA256(verifier))`, sans remplissage (RFC 7636 §4.2).
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Chaîne aléatoire dans l'alphabet non réservé de la RFC 7636 (§4.1).
    static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    /// Encode un corps `application/x-www-form-urlencoded`, clés triées (déterministe).
    static func formBody(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&")
    }

    static func formEncode(_ value: String) -> String {
        // Alphabet volontairement restrictif : `+`, `/`, `=`, `&` doivent être encodés.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
