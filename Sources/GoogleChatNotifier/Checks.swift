import Foundation

/// Tests intégrés, exécutables via `GoogleChatNotifier --run-checks`
/// (ou `swift run GoogleChatNotifier --run-checks`).
/// Alternative légère à XCTest/swift-testing, indisponibles sans Xcode installé.
@MainActor
enum Checks {
    private static var failures = 0
    private static var total = 0

    static func run() {
        dateChecks()
        decodingChecks()
        selectionChecks()
        conversationChecks()
        mentionChecks()
        oauthChecks()
        loopbackChecks()
        loopbackServerChecks()
        seenTrackerChecks()

        print("\n\(total - failures)/\(total) checks OK")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Helpers

    private static func expect(
        _ condition: Bool,
        _ label: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        total += 1
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ✗ \(label)  (\(file):\(line))")
        }
    }

    private static func space(
        id: String,
        type: String = "DIRECT_MESSAGE",
        bot: Bool? = false,
        lastActive: String?,
        displayName: String? = nil
    ) -> ChatSpace {
        ChatSpace(
            name: "spaces/\(id)",
            spaceType: type,
            displayName: displayName,
            singleUserBotDm: bot,
            lastActiveTime: lastActive,
            spaceUri: nil
        )
    }

    // MARK: - Suites

    private static func dateChecks() {
        print("Horodatages RFC 3339")

        expect(RFC3339.stripFractionalSeconds("2026-08-27T10:30:00.123456789Z")
               == "2026-08-27T10:30:00Z",
               "troncature des nanosecondes")
        expect(RFC3339.stripFractionalSeconds("2026-08-27T10:30:00Z")
               == "2026-08-27T10:30:00Z",
               "sans partie fractionnaire : inchangé")
        expect(RFC3339.stripFractionalSeconds("2026-08-27T10:30:00.5+02:00")
               == "2026-08-27T10:30:00+02:00",
               "décalage horaire préservé")

        expect(RFC3339.date(from: "2026-08-27T10:30:00.123456789Z") != nil,
               "date avec nanosecondes analysée")
        expect(RFC3339.date(from: "2026-08-27T12:30:00+02:00")
               == RFC3339.date(from: "2026-08-27T10:30:00Z"),
               "décalage horaire correctement interprété")
        expect(RFC3339.date(from: nil) == nil, "nil → nil")
        expect(RFC3339.date(from: "") == nil, "chaîne vide → nil")
        expect(RFC3339.date(from: "pas-une-date") == nil, "chaîne invalide → nil")

        let earlier = RFC3339.date(from: "2026-08-27T10:00:00Z")!
        let later = RFC3339.date(from: "2026-08-27T10:00:01.9Z")!
        expect(later > earlier, "ordre chronologique respecté")
    }

    private static func decodingChecks() {
        print("Décodage des modèles Google Chat")

        let spacesJSON = """
        { "spaces": [
            { "name": "spaces/AAAA", "spaceType": "DIRECT_MESSAGE",
              "lastActiveTime": "2026-08-27T09:00:00.123456Z",
              "spaceUri": "https://chat.google.com/dm/AAAA" },
            { "name": "spaces/BBBB", "spaceType": "DIRECT_MESSAGE",
              "singleUserBotDm": true, "lastActiveTime": "2026-08-27T08:00:00Z" },
            { "name": "spaces/CCCC", "spaceType": "SPACE", "displayName": "Équipe Café",
              "lastActiveTime": "2026-08-27T07:00:00Z" }
          ], "nextPageToken": "" }
        """.data(using: .utf8)!

        guard let list = try? JSONDecoder().decode(ChatSpaceList.self, from: spacesJSON) else {
            expect(false, "décodage de la liste de spaces")
            return
        }
        let spaces = list.spaces ?? []
        expect(spaces.count == 3, "3 spaces décodés")
        expect(spaces[0].spaceID == "AAAA", "spaceID sans le préfixe « spaces/ »")
        expect(spaces[0].isHumanConversation, "DM humain retenu")
        expect(!spaces[1].isHumanConversation, "DM avec une application Chat écarté")
        expect(!spaces[2].isHumanConversation, "salon nommé écarté")
        expect(spaces[2].displayName == "Équipe Café", "displayName (accents préservés)")
        expect(spaces[0].lastActiveDate != nil, "lastActiveTime analysé")

        let messagesJSON = """
        { "messages": [
            { "name": "spaces/AAAA/messages/1", "createTime": "2026-08-27T09:00:00Z",
              "text": "Salut, tu as vu la démo ?", "sender": { "name": "users/123", "type": "HUMAN" } },
            { "name": "spaces/AAAA/messages/2", "createTime": "2026-08-27T08:00:00Z",
              "sender": { "name": "users/456", "type": "HUMAN" },
              "attachment": [ { "contentName": "compte-rendu.pdf" } ] }
          ] }
        """.data(using: .utf8)!

        guard let messages = try? JSONDecoder().decode(ChatMessageList.self, from: messagesJSON).messages else {
            expect(false, "décodage de la liste de messages")
            return
        }
        expect(messages.count == 2, "2 messages décodés")
        expect(messages[0].sender?.userID == "123", "userID sans le préfixe « users/ »")
        expect(messages[0].displayText == "Salut, tu as vu la démo ?",
               "texte du message (accents préservés)")
        expect(messages[1].displayText == "📎 compte-rendu.pdf",
               "repli sur le nom de la pièce jointe")

        let readStateJSON = """
        { "name": "users/me/spaces/AAAA/spaceReadState",
          "lastReadTime": "2026-08-27T08:30:00.500Z" }
        """.data(using: .utf8)!
        let readState = try? JSONDecoder().decode(SpaceReadState.self, from: readStateJSON)
        expect(readState?.lastReadTime == "2026-08-27T08:30:00.500Z", "lastReadTime décodé")

        let peopleJSON = """
        { "responses": [
            { "httpStatusCode": 200, "person": { "resourceName": "people/123",
              "names": [ { "displayName": "Amélie Durand" } ] } },
            { "httpStatusCode": 200, "person": { "resourceName": "people/456",
              "emailAddresses": [ { "value": "bob@example.com" } ] } },
            { "httpStatusCode": 404, "requestedResourceName": "people/789" }
          ] }
        """.data(using: .utf8)!
        let names = (try? JSONDecoder().decode(PeopleBatchResponse.self, from: peopleJSON))?.displayNames
        expect(names?["123"] == "Amélie Durand", "nom résolu (accents préservés)")
        expect(names?["456"] == "bob@example.com", "repli sur l'adresse e-mail")
        expect(names?["789"] == nil, "personne introuvable : aucune entrée")

        let errorJSON = """
        { "error": { "code": 403, "status": "PERMISSION_DENIED",
          "message": "Google Chat API has not been used in project 42 before." } }
        """.data(using: .utf8)!
        expect(GoogleAPI.extractErrorMessage(from: errorJSON)?.hasPrefix("Google Chat API") == true,
               "extraction du message d'erreur Google")
        expect(GoogleAPI.extractErrorMessage(from: Data("{}".utf8)) == nil,
               "corps sans erreur → nil")

        expect(GoogleChatClient.spaceTypeFilter(["DIRECT_MESSAGE", "GROUP_CHAT"])
               == "spaceType = \"DIRECT_MESSAGE\" OR spaceType = \"GROUP_CHAT\"",
               "filtre spaces.list")
    }

    private static func selectionChecks() {
        print("Sélection des conversations")

        let now = RFC3339.date(from: "2026-08-27T12:00:00Z")!
        let all = [
            space(id: "OLD", lastActive: "2026-01-01T12:00:00Z"),
            space(id: "RECENT", lastActive: "2026-08-27T11:00:00Z"),
            space(id: "BOT", bot: true, lastActive: "2026-08-27T11:30:00Z"),
            space(id: "ROOM", type: "SPACE", lastActive: "2026-08-27T11:45:00Z"),
            space(id: "HIER", lastActive: "2026-08-26T12:00:00Z")
        ]
        let candidates = AppState.candidates(from: all, now: now, limit: 10)
        expect(candidates.map(\.spaceID) == ["RECENT", "HIER"],
               "garde les DM humains récents, triés par activité décroissante")
        expect(AppState.candidates(from: all, now: now, limit: 1).map(\.spaceID) == ["RECENT"],
               "limite respectée")

        // État de lecture → non lu.
        let unreadState = AppState.SpaceState(
            space: space(id: "A", lastActive: "2026-08-27T11:00:00Z"),
            lastReadTime: "2026-08-27T10:00:00Z"
        )
        let readState = AppState.SpaceState(
            space: space(id: "B", lastActive: "2026-08-27T09:00:00Z"),
            lastReadTime: "2026-08-27T10:00:00Z"
        )
        let neverOpened = AppState.SpaceState(
            space: space(id: "C", lastActive: "2026-08-27T09:00:00Z"),
            lastReadTime: nil
        )
        expect(unreadState.isUnread, "dernier message postérieur à la lecture → non lu")
        expect(!readState.isUnread, "dernier message antérieur à la lecture → lu")
        expect(neverOpened.isUnread, "conversation jamais ouverte → non lue")

        // État de lecture indisponible : on ne prétend pas que tout est non lu.
        let broken = AppState.SpaceState(
            space: space(id: "D", lastActive: "2026-08-27T11:00:00Z"),
            lastReadTime: nil,
            readStateError: "403 PERMISSION_DENIED"
        )
        expect(!broken.isUnread, "état de lecture en échec → conversation considérée lue")
        expect(AppState.readStateWarning(for: [unreadState, readState, broken]) == nil,
               "un échec isolé n'alerte pas")
        expect(AppState.readStateWarning(for: [broken, broken, unreadState])?
                .contains("chat.users.readstate.readonly") == true,
               "échec généralisé → avertissement nommant le périmètre manquant")
        expect(AppState.readStateWarning(for: [unreadState, readState]) == nil,
               "aucun échec → aucun avertissement")

        expect(AppState.title(space: space(id: "A", lastActive: nil),
                              participants: ["123"], names: ["123": "Amélie Durand"])
               == "Amélie Durand",
               "titre = nom de l'interlocuteur")
        expect(AppState.title(space: space(id: "A", type: "GROUP_CHAT", lastActive: nil),
                              participants: ["1", "2", "3", "4"],
                              names: ["1": "A", "2": "B", "3": "C", "4": "D"])
               == "A, B +2",
               "groupe : deux noms puis un compteur")
        expect(AppState.title(space: space(id: "A", lastActive: nil), participants: [], names: [:])
               == "Conversation privée",
               "repli quand aucun nom n'est résolu")
        expect(AppState.title(space: space(id: "A", type: "GROUP_CHAT", lastActive: nil,
                                           displayName: "Projet Été"),
                              participants: ["1"], names: ["1": "A"])
               == "Projet Été",
               "displayName du space prioritaire")
    }

    private static func conversationChecks() {
        print("Modèle d'affichage (une entrée par interlocuteur)")

        func message(_ id: String, from sender: String, at time: String) -> ChatMessage {
            ChatMessage(
                name: "spaces/A/messages/\(id)",
                sender: ChatUser(name: "users/\(sender)", displayName: nil, type: "HUMAN"),
                createTime: time,
                text: "message \(id)",
                argumentText: nil,
                attachment: nil,
                annotations: nil
            )
        }

        // Trois messages non lus de la même personne → une seule entrée.
        let pending = Conversation(
            spaceName: "spaces/A",
            title: "Amélie Durand",
            uri: "https://chat.google.com/dm/A",
            lastActive: RFC3339.date(from: "2026-08-27T11:00:00Z"),
            preview: "message 3",
            lastMessageIsMine: false,
            unread: [message("3", from: "123", at: "2026-08-27T11:00:00Z"),
                     message("2", from: "123", at: "2026-08-27T10:30:00Z"),
                     message("1", from: "123", at: "2026-08-27T10:00:00Z")],
            isGroup: false
        )
        expect(pending.unreadCount == 3, "trois messages non lus recouverts par une entrée")
        expect(pending.preview == "message 3", "aperçu = début du dernier message")
        expect(pending.needsReply, "dernier message reçu → en attente de réponse")

        let answered = Conversation(
            spaceName: "spaces/B", title: "Bob", uri: nil,
            lastActive: RFC3339.date(from: "2026-08-27T09:00:00Z"),
            preview: "ok, merci !", lastMessageIsMine: true, unread: [], isGroup: false
        )
        expect(!answered.needsReply, "dernier message envoyé par moi → rien à traiter")

        let empty = Conversation(
            spaceName: "spaces/C", title: "Carole", uri: nil, lastActive: nil,
            preview: nil, lastMessageIsMine: false, unread: [], isGroup: false
        )
        expect(!empty.needsReply, "conversation sans message → rien à traiter")

        // Déjà lu dans Google Chat : le dernier message vient bien de l'autre, mais
        // il n'y a plus rien à traiter tant qu'aucun nouveau message n'arrive.
        let readByMe = Conversation(
            spaceName: "spaces/D",
            title: "Denis",
            uri: nil,
            lastActive: RFC3339.date(from: "2026-08-27T08:00:00Z"),
            preview: "tu as vu le compte rendu ?",
            lastMessageIsMine: false,
            unread: [],
            isGroup: false
        )
        expect(!readByMe.needsReply, "message reçu mais déjà lu → rien à traiter")

        // Répondu depuis un autre appareil sans que l'état de lecture ait suivi.
        let answeredElsewhere = Conversation(
            spaceName: "spaces/E",
            title: "Émile",
            uri: nil,
            lastActive: RFC3339.date(from: "2026-08-27T08:00:00Z"),
            preview: "de rien !",
            lastMessageIsMine: true,
            unread: [message("9", from: "123", at: "2026-08-27T07:00:00Z")],
            isGroup: false
        )
        expect(!answeredElsewhere.needsReply,
               "non lu mais dernier message de moi → rien à traiter")

        let sorted = Conversation.sorted([answered, empty, pending])
        expect(sorted.map(\.spaceName) == ["spaces/A", "spaces/B", "spaces/C"],
               "non lues d'abord, puis par activité décroissante")

        expect(Conversation.openURL(uri: "https://chat.google.com/dm/A", spaceName: "spaces/A")
               == "https://chat.google.com/dm/A",
               "spaceUri utilisé quand il est fourni")
        expect(Conversation.openURL(uri: nil, spaceName: "spaces/AAAA")
               == "https://mail.google.com/chat/u/0/#chat/space/AAAA",
               "repli sur l'URL web de Google Chat")

        // Plusieurs comptes Google ouverts : l'URL doit désigner le bon compte.
        expect(Conversation.openURL(uri: "https://chat.google.com/dm/A",
                                    spaceName: "spaces/A",
                                    accountEmail: "moi@exemple.com")
               == "https://chat.google.com/dm/A?authuser=moi@exemple.com",
               "spaceUri complété par authuser")
        expect(Conversation.openURL(uri: nil,
                                    spaceName: "spaces/AAAA",
                                    accountEmail: "moi@exemple.com")
               == "https://mail.google.com/chat/?authuser=moi@exemple.com#chat/space/AAAA",
               "repli : authuser avant le fragment, plus d'index /u/N/ en dur")
        expect(Conversation.withAuthUser("https://chat.google.com/dm/A?hl=fr",
                                         email: "moi@exemple.com")
               == "https://chat.google.com/dm/A?hl=fr&authuser=moi@exemple.com",
               "authuser ajouté aux paramètres existants")
        expect(Conversation.withAuthUser("https://chat.google.com/dm/A?authuser=autre@exemple.com",
                                         email: "moi@exemple.com")
               == "https://chat.google.com/dm/A?authuser=autre@exemple.com",
               "authuser déjà présent : jamais écrasé")
        expect(Conversation.withAuthUser("https://chat.google.com/dm/A", email: nil)
               == "https://chat.google.com/dm/A",
               "compte inconnu : URL inchangée")
        expect(Conversation.withAuthUser("https://chat.google.com/dm/A", email: "")
               == "https://chat.google.com/dm/A",
               "adresse vide : URL inchangée")
        expect(Conversation.openURL(uri: "", spaceName: "spaces/AAAA").hasPrefix("https://mail.google.com"),
               "spaceUri vide → repli")

        // Horodatage relatif affiché dans la ligne.
        let now = RFC3339.date(from: "2026-08-27T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        expect(ConversationRowView.relativeTime(
                RFC3339.date(from: "2026-08-26T12:00:00Z")!, now: now, calendar: calendar) == "hier",
               "veille → « hier »")
        expect(ConversationRowView.relativeTime(
                RFC3339.date(from: "2026-06-01T12:00:00Z")!, now: now, calendar: calendar) != "hier",
               "date ancienne → date courte")
    }

    private static func mentionChecks() {
        print("Mentions @moi dans les salons")

        let me = "42"

        func annotation(user: String, kind: String? = "MENTION", type: String = "USER_MENTION")
            -> ChatAnnotation {
            ChatAnnotation(
                type: type,
                userMention: ChatAnnotation.UserMention(
                    user: ChatUser(name: "users/\(user)", displayName: nil, type: "HUMAN"),
                    type: kind
                )
            )
        }

        func message(
            _ id: String,
            from sender: String,
            at time: String = "2026-08-27T10:00:00Z",
            text: String = "on en parle ?",
            annotations: [ChatAnnotation]?
        ) -> ChatMessage {
            ChatMessage(
                name: "spaces/R/messages/\(id)",
                sender: ChatUser(name: "users/\(sender)", displayName: nil, type: "HUMAN"),
                createTime: time,
                text: text,
                argumentText: nil,
                attachment: nil,
                annotations: annotations
            )
        }

        // Détection : c'est l'annotation qui fait foi, pas le texte.
        expect(message("1", from: "7", annotations: [annotation(user: me)]).mentions(userID: me),
               "annotation USER_MENTION sur moi → mention")
        expect(!message("2", from: "7", annotations: [annotation(user: "99")]).mentions(userID: me),
               "mention de quelqu'un d'autre → ignorée")
        expect(!message("3", from: "7", annotations: nil).mentions(userID: me),
               "aucune annotation → pas de mention")
        expect(!message("4", from: "7", text: "@Moi tu peux voir ?", annotations: nil)
                .mentions(userID: me),
               "« @Moi » dans le texte sans annotation → pas de mention (homonymie)")
        expect(!message("5", from: "7", annotations: [annotation(user: me, kind: "ADD")])
                .mentions(userID: me),
               "ajout au salon (ADD) → pas une mention")
        expect(!message("6", from: "7", annotations: [annotation(user: me, type: "SLASH_COMMAND")])
                .mentions(userID: me),
               "annotation d'un autre type → ignorée")
        expect(!message("7", from: "7", annotations: [annotation(user: me)]).mentions(userID: ""),
               "identifiant vide → jamais de mention")
        expect(message("8", from: "7",
                       annotations: [annotation(user: "99"), annotation(user: me)])
                .mentions(userID: me),
               "mention parmi plusieurs annotations")

        // Extraction : une entrée par message, mes propres messages écartés.
        let room = ChatSpace(
            name: "spaces/R", spaceType: "SPACE", displayName: "Équipe produit",
            singleUserBotDm: nil, lastActiveTime: "2026-08-27T10:00:00Z",
            spaceUri: "https://chat.google.com/room/R"
        )
        let extracted = Mention.extract(
            from: [
                message("a", from: "7", at: "2026-08-27T10:00:00Z", annotations: [annotation(user: me)]),
                message("b", from: me, at: "2026-08-27T09:00:00Z", annotations: [annotation(user: me)]),
                message("c", from: "8", at: "2026-08-27T11:00:00Z", annotations: [annotation(user: me)]),
                message("d", from: "7", at: "2026-08-27T08:00:00Z", annotations: nil),
            ],
            in: room,
            myUserID: me,
            names: ["7": "Amélie Durand"],
            accountEmail: "moi@exemple.com"
        )
        expect(extracted.count == 2, "deux mentions retenues sur quatre messages")
        expect(!extracted.contains { $0.messageName.hasSuffix("/b") },
               "mes propres messages ne me mentionnent jamais")
        expect(extracted.first?.spaceTitle == "Équipe produit", "nom du salon repris")
        expect(extracted.first?.authorName == "Amélie Durand", "auteur résolu via l'annuaire")
        expect(extracted.last?.authorName == "Quelqu'un", "auteur non résolu → libellé de repli")
        expect(extracted.first?.uri == "https://chat.google.com/room/R?authuser=moi@exemple.com",
               "lien du salon complété par authuser")

        expect(Mention.sorted(extracted).map(\.messageName)
               == ["spaces/R/messages/c", "spaces/R/messages/a"],
               "mentions triées de la plus récente à la plus ancienne")

        // Libellés de salon.
        expect(room.roomTitle == "Équipe produit", "salon nommé")
        expect(ChatSpace(name: "spaces/G", spaceType: "GROUP_CHAT", displayName: nil,
                         singleUserBotDm: nil, lastActiveTime: nil, spaceUri: nil).roomTitle
               == "Discussion de groupe",
               "groupe sans nom → libellé dédié")
        expect(ChatSpace(name: "spaces/S", spaceType: "SPACE", displayName: "   ",
                         singleUserBotDm: nil, lastActiveTime: nil, spaceUri: nil).roomTitle
               == "Salon sans nom",
               "salon au nom vide → libellé de repli")

        // Sélection des salons : les messages privés n'entrent jamais dans cet onglet.
        let now = RFC3339.date(from: "2026-08-27T12:00:00Z")!
        let dm = ChatSpace(name: "spaces/D", spaceType: "DIRECT_MESSAGE", displayName: nil,
                           singleUserBotDm: nil, lastActiveTime: "2026-08-27T11:00:00Z",
                           spaceUri: nil)
        let rooms = AppState.candidates(from: [room, dm], now: now, limit: 10,
                                        accept: { !$0.isDirectMessage })
        expect(rooms.map(\.name) == ["spaces/R"], "messages privés exclus des salons à scruter")
    }

    private static func oauthChecks() {
        print("Flux OAuth (PKCE)")

        // Vecteur de test de la RFC 7636, annexe B.
        expect(OAuthService.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
               == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
               "code_challenge S256 (vecteur RFC 7636)")

        let verifier = OAuthService.randomURLSafeString(length: 64)
        expect(verifier.count == 64, "code_verifier de 64 caractères")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        expect(verifier.unicodeScalars.allSatisfy { allowed.contains($0) },
               "code_verifier dans l'alphabet non réservé")
        expect(OAuthService.randomURLSafeString(length: 32)
               != OAuthService.randomURLSafeString(length: 32),
               "deux tirages successifs diffèrent")

        expect(OAuthService.formEncode("a+b/c=d&e") == "a%2Bb%2Fc%3Dd%26e",
               "encodage des caractères réservés")
        expect(OAuthService.formBody(["b": "2", "a": "1"]) == "a=1&b=2",
               "corps de formulaire trié (déterministe)")

        let url = OAuthService.authorizationURL(
            clientID: "client-42",
            redirectURI: "http://127.0.0.1:52341",
            state: "st",
            codeChallenge: "ch"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        expect(url.host == "accounts.google.com", "point de terminaison Google")
        expect(value("redirect_uri") == "http://127.0.0.1:52341", "redirect_uri sur la boucle locale")
        expect(value("code_challenge_method") == "S256", "PKCE S256")
        expect(value("access_type") == "offline" && value("prompt") == "consent",
               "refresh token demandé explicitement")
        expect(value("scope")?.contains("chat.messages.readonly") == true,
               "périmètre de lecture des messages demandé")
        expect(value("scope")?.contains("chat.users.readstate.readonly") == true,
               "périmètre d'état de lecture demandé")
        expect(OAuthService.scopes.allSatisfy { !$0.hasSuffix("/chat.messages") },
               "aucun périmètre en écriture")
    }

    private static func loopbackChecks() {
        print("Redirection OAuth (serveur local)")

        let request = "GET /?state=xyz&code=4%2Fabc HTTP/1.1\r\nHost: 127.0.0.1:52341\r\n\r\n"
        let parameters = LoopbackServer.queryParameters(fromRequest: request)
        expect(parameters?["code"] == "4/abc", "code décodé (pourcentage)")
        expect(parameters?["state"] == "xyz", "state extrait")

        let denied = "GET /?error=access_denied HTTP/1.1\r\n\r\n"
        expect(LoopbackServer.queryParameters(fromRequest: denied)?["error"] == "access_denied",
               "refus de l'utilisateur remonté")

        expect(LoopbackServer.queryParameters(fromRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil,
               "requête sans query ignorée")
        expect(LoopbackServer.queryParameters(fromRequest: "POST /?code=1 HTTP/1.1\r\n\r\n") == nil,
               "méthode autre que GET ignorée")
        expect(LoopbackServer.queryParameters(fromRequest: "") == nil, "requête vide ignorée")
    }

    /// Cycle complet du serveur de redirection : écoute, réception, réponse HTTP.
    /// Le test se fait en boucle locale, sans réseau externe.
    private static func loopbackServerChecks() {
        print("Serveur local : cycle complet")

        let server = LoopbackServer()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var received: [String: String]?
        nonisolated(unsafe) var failure: String?
        nonisolated(unsafe) var pageServed = false

        Task.detached {
            do {
                let port = try await server.start()
                let url = URL(string: "http://127.0.0.1:\(port)/?code=4%2Fabc&state=xyz")!
                // On lance la requête d'abord : le serveur doit savoir mémoriser un résultat
                // arrivé avant qu'on ne se mette en attente.
                if let (data, _) = try? await URLSession.shared.data(from: url) {
                    pageServed = String(data: data, encoding: .utf8)?.contains("Google Chat Notifier") == true
                }
                received = try await server.waitForRedirect(timeout: 10)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            done.signal()
        }

        let timedOut = done.wait(timeout: .now() + 20) == .timedOut
        server.stop()

        expect(!timedOut, "le cycle se termine sans blocage")
        expect(failure == nil, "aucune erreur : \(failure ?? "—")")
        expect(received?["code"] == "4/abc", "code d'autorisation reçu par le serveur")
        expect(received?["state"] == "xyz", "state reçu par le serveur")
        expect(pageServed, "page de confirmation renvoyée au navigateur")
    }

    private static func seenTrackerChecks() {
        print("Détection des nouveaux messages (SeenTracker)")

        expect(
            SeenTracker.newIDs(current: ["a", "b", "c"], seen: ["a"]) == ["b", "c"],
            "newIDs (fonction pure)"
        )

        let suite = "checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var tracker = SeenTracker(key: "seen", defaults: defaults)

        expect(tracker.consumeNew(current: ["a", "b"]).isEmpty, "premier lancement : aucune notif")
        expect(tracker.consumeNew(current: ["a", "b", "c"]) == ["c"], "nouveau message détecté")
        expect(tracker.consumeNew(current: ["a", "b", "c"]).isEmpty, "rien de neuf : aucune notif")

        // Tout est lu (liste vide), puis un message arrive : il doit encore être notifié.
        expect(tracker.consumeNew(current: []).isEmpty, "plus rien à traiter")
        expect(tracker.consumeNew(current: ["d"]) == ["d"],
               "après une liste vide, le message suivant est bien notifié")

        tracker.reset()
        expect(tracker.consumeNew(current: ["e"]).isEmpty, "après reset : ré-amorçage silencieux")
    }
}
