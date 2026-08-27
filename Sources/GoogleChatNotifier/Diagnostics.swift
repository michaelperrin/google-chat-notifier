import Foundation

/// Sonde de diagnostic, lancée depuis le bundle pour partager ses préférences et son
/// accès au trousseau :
///
/// ```
/// ./GoogleChatNotifier.app/Contents/MacOS/GoogleChatNotifier --diagnose
/// ```
///
/// Elle rejoue ce que fait un cycle de rafraîchissement et affiche, conversation par
/// conversation, les valeurs sur lesquelles l'app fonde ses décisions. Les textes des
/// messages ne sont jamais affichés.
enum Diagnostics {
    static func run() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await probe()
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func probe() async {
        print("=== Google Chat Notifier — diagnostic ===\n")

        let clientID = UserDefaults.standard.string(forKey: "oauth.clientID") ?? ""
        print("Client ID        : \(clientID.isEmpty ? "MANQUANT" : mask(clientID))")
        print("Client secret    : \(KeychainStore.get(.clientSecret) != nil ? "présent" : "MANQUANT")")
        print("Refresh token    : \(KeychainStore.get(.refreshToken) != nil ? "présent" : "MANQUANT")")

        let token: String
        do {
            token = try await OAuthService.shared.token()
            print("Jeton d'accès    : obtenu")
        } catch {
            print("Jeton d'accès    : ÉCHEC — \(describe(error))")
            return
        }

        // Périmètres réellement accordés : c'est la première chose à vérifier quand
        // l'état de lecture ou les noms manquent.
        await printGrantedScopes(token: token)

        let account = try? await OAuthService.shared.fetchUserInfo()
        let myUserID = account?.sub ?? ""
        print("\nCompte           : \(account?.email ?? "inconnu")")
        print("Mon user id      : \(mask(myUserID))")

        let client = GoogleChatClient(accessToken: token)
        let spaces: [ChatSpace]
        do {
            spaces = try await client.listSpaces(types: ["DIRECT_MESSAGE"])
        } catch {
            print("\nspaces.list      : ÉCHEC — \(describe(error))")
            return
        }
        let candidates = Array(
            spaces
                .filter(\.isHumanConversation)
                .sorted { ($0.lastActiveDate ?? .distantPast) > ($1.lastActiveDate ?? .distantPast) }
                .prefix(10)
        )
        print("spaces.list      : \(spaces.count) DM, dont \(spaces.filter(\.isHumanConversation).count) humains")
        print("\n10 conversations les plus récentes :\n")

        for space in candidates {
            print("• \(mask(space.spaceID))")
            print("    lastActiveTime : \(space.lastActiveTime ?? "ABSENT")")

            var readStateError: String?
            var lastReadTime: String?
            do {
                lastReadTime = try await client.readState(spaceID: space.spaceID).lastReadTime
                print("    lastReadTime   : \(lastReadTime ?? "absent (jamais ouverte ?)")")
            } catch {
                readStateError = describe(error)
                print("    lastReadTime   : ÉCHEC — \(readStateError!)")
            }

            let state = AppState.SpaceState(
                space: space,
                lastReadTime: lastReadTime,
                readStateError: readStateError
            )
            print("    → non lue      : \(state.isUnread)")

            let latest = try? await client.messages(inSpace: space.name, after: nil, limit: 1).first
            let senderID = latest?.sender?.userID
            let isMine = senderID == myUserID && !myUserID.isEmpty
            print("    dernier msg de : \(senderID.map(mask) ?? "inconnu")\(isMine ? "  (= moi)" : "")")
            print("    → à traiter    : \(!isMine && latest != nil)")

            // Compte visé par le lien d'ouverture : avec plusieurs sessions Google
            // ouvertes, un lien sans `authuser` tombe sur le mauvais compte.
            let openURL = Conversation.openURL(uri: space.spaceUri,
                                               spaceName: space.name,
                                               accountEmail: account?.email)
            let target = URLComponents(string: openURL)?
                .queryItems?.first { $0.name == "authuser" }?.value
            print("    ouverture      : \(target.map { "compte \($0)" } ?? "COMPTE PAR DÉFAUT (authuser absent)")")

            let participants = try? await client.humanMemberIDs(inSpace: space.name)
            let others = (participants ?? []).filter { $0 != myUserID }
            let names = await DirectoryService.shared.resolveNames(for: others, accessToken: token)
            print("    interlocuteur  : \(others.compactMap { names[$0] }.joined(separator: ", "))"
                  + (others.isEmpty ? "  (aucun autre membre !)" : ""))
            print("")
        }

        if let error = await DirectoryService.shared.lastError {
            print("API People       : ÉCHEC — \(error)")
        }
        print("=== fin ===")
    }

    /// Périmètres accordés au jeton courant (`tokeninfo`), comparés à ceux demandés.
    private static func printGrantedScopes(token: String) async {
        var components = URLComponents(string: "https://oauth2.googleapis.com/tokeninfo")!
        components.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let granted = json["scope"] as? String else {
            print("Périmètres       : non vérifiables")
            return
        }
        let grantedSet = Set(granted.split(separator: " ").map(String.init))
        print("\nPérimètres accordés :")
        for scope in OAuthService.scopes {
            let short = scope.replacingOccurrences(of: "https://www.googleapis.com/auth/", with: "")
            print("  \(grantedSet.contains(scope) ? "✓" : "✗ MANQUANT") \(short)")
        }
    }

    /// N'expose que les extrémités d'un identifiant (les journaux peuvent être partagés).
    private static func mask(_ value: String) -> String {
        guard value.count > 10 else { return value }
        return value.prefix(4) + "…" + value.suffix(4)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
