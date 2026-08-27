# Google Chat Notifier

App macOS native (icône dans la barre de menus, à côté de l'heure) pour suivre ses
**messages privés Google Chat** sur un compte Google Workspace.

Une entrée par interlocuteur — nom de la personne + début de son dernier message — et un
compteur dans la barre de menus indiquant le nombre de conversations en attente de réponse.

## Fonctionnalités

- **Onglet « À traiter »** : les conversations privées dont le dernier message n'est pas de
  vous, c'est-à-dire celles auxquelles vous n'avez pas encore répondu. **Une seule entrée par
  personne**, même si elle a envoyé dix messages ; l'aperçu montre le début du dernier.
  Une pastille indique le nombre de messages non lus quand il y en a plusieurs.
- **Onglet « Récentes »** : toutes les conversations privées récentes, répondues ou non.
- **Compteur dans la barre de menus** = nombre de conversations à traiter (une par personne).
  La bulle est pleine dès qu'il y a quelque chose, creuse sinon.
- **Notification système** à chaque nouveau message privé (expéditeur + texte) ;
  clic → ouvre la conversation dans Google Chat.
- Rafraîchissement périodique configurable (1 / 2 / 5 / 15 min).
- Option « Inclure les discussions de groupe » (désactivée par défaut ; les salons nommés ne
  sont jamais suivis).
- Toggle « Lancer au démarrage » (SMAppService).

## Stack

- Swift 6 / SwiftUI `MenuBarExtra`, framework **Observation** (`@Observable`).
- Cible **macOS 15+**.
- Swift Package pur (pas de projet Xcode), bundlé en `.app` par script.
- OAuth 2.0 « application de bureau » avec **PKCE** et redirection sur la boucle locale
  (`127.0.0.1`, port éphémère) — aucune dépendance externe, `Network.framework` seulement.
- **Client secret et refresh token dans le Keychain** (jamais dans UserDefaults).
- Périmètres demandés **en lecture seule** uniquement.

## Prérequis

- macOS 15+ et les **Command Line Tools** Xcode (`xcode-select --install`).
- Un compte **Google Workspace** et le droit de créer un projet dans Google Cloud Console
  (idéalement dans l'organisation Workspace, pour pouvoir choisir un écran de consentement
  **Interne** et éviter la procédure de vérification Google).

## Configuration Google Cloud (une fois)

1. **Créez un projet** sur [console.cloud.google.com](https://console.cloud.google.com/projectcreate),
   de préférence dans votre organisation Workspace.

2. **Activez les deux API** nécessaires :
   - [Google Chat API](https://console.cloud.google.com/apis/library/chat.googleapis.com)
     — lecture des conversations, des messages et de l'état de lecture.
   - [People API](https://console.cloud.google.com/apis/library/people.googleapis.com)
     — résolution des noms des interlocuteurs (voir « Limites connues »).

3. **Configurez l'application Chat** : *API et services → Google Chat API → Configuration*.
   Renseignez au minimum le nom, la description et l'URL d'avatar. Les fonctionnalités
   interactives peuvent rester désactivées : l'app ne fait que lire, en votre nom.
   Cette page est obligatoire, l'API Chat refuse les appels sans elle.

4. **Écran de consentement OAuth** : choisissez l'audience **Interne**, puis ajoutez les
   périmètres suivants (tous en lecture seule) :

   ```
   openid
   email
   profile
   https://www.googleapis.com/auth/chat.spaces.readonly
   https://www.googleapis.com/auth/chat.messages.readonly
   https://www.googleapis.com/auth/chat.memberships.readonly
   https://www.googleapis.com/auth/chat.users.readstate.readonly
   https://www.googleapis.com/auth/directory.readonly
   ```

5. **Créez un ID client OAuth** de type **Application de bureau**
   (*API et services → Identifiants → Créer des identifiants → ID client OAuth*).
   Notez le **Client ID** et le **Client Secret**.

## Configuration de l'app

1. Lancez l'app, ouvrez les **Réglages** (⌘, ou l'engrenage du popover).
2. Collez le **Client ID** et le **Client Secret** dans la section *Client OAuth*.
3. Cliquez **Connecter un compte Google…** : le navigateur s'ouvre sur l'écran de
   consentement Google. Autorisez, puis revenez à l'app — la connexion est établie.

Le refresh token est stocké dans le trousseau macOS ; l'app se reconnecte seule ensuite.

## Build & lancement

```bash
./scripts/build-app.sh          # build release + bundle .app + signature ad-hoc
./scripts/build-app.sh --run    # idem puis lance l'app
./scripts/build-app.sh --debug  # build en configuration debug
```

L'app apparaît dans la barre de menus, sans icône dans le Dock (`LSUIElement`).

## Icône

```bash
./scripts/make-icon.sh          # régénère Resources/AppIcon.icns
```

Bulle de message blanche sur fond vert (pas de logo Google, marque déposée).

## Tests

XCTest/swift-testing ne sont pas disponibles sans Xcode complet : les tests sont compilés
dans le binaire et lancés en CLI.

```bash
swift run GoogleChatNotifier --run-checks
```

Ils couvrent le décodage des réponses Google, l'analyse des horodatages RFC 3339, la
sélection et le regroupement des conversations, la dérivation PKCE (vecteur de la RFC 7636),
le cycle complet du serveur de redirection local, et la détection des nouveaux messages.

## Comment ça marche

À chaque cycle, l'app :

1. liste les spaces de type `DIRECT_MESSAGE` (`GET /v1/spaces`), écarte les DM avec des
   applications Chat et ne garde que les 30 conversations actives les plus récentes
   (fenêtre de 45 jours) ;
2. lit l'état de lecture de chacune
   (`GET /v1/users/me/spaces/{space}/spaceReadState`) — c'est ce qui définit « non lu » ;
3. récupère les messages postérieurs à `lastReadTime` pour les conversations non lues, ou le
   seul dernier message pour les autres (`GET /v1/spaces/{space}/messages`) ;
4. résout les noms des interlocuteurs via l'API People, en un seul appel groupé et avec un
   cache persistant ;
5. construit **une entrée par conversation** et notifie les messages jamais vus.

Une conversation apparaît dans « À traiter » quand son dernier message n'est pas de vous.

## Limites connues

- **Les noms passent par l'API People.** En authentification utilisateur, l'API Chat ne
  renvoie que `users/{id}` et jamais le `displayName` : l'app résout donc les noms via
  `people:batchGet` (périmètre `directory.readonly`), qui ne fonctionne que pour les
  personnes de votre domaine Workspace. Si l'appel échoue, les conversations s'affichent
  quand même, sous le libellé « Conversation privée », et un avertissement apparaît dans
  les Réglages.
- **« Répondu » se déduit du dernier message.** L'API n'expose pas de notion de réponse :
  une conversation sort de l'onglet « À traiter » dès que le dernier message est de vous.
- Seules les 30 conversations les plus récentes (45 derniers jours) sont examinées, pour
  borner le nombre d'appels API — largement suffisant pour un usage quotidien.
- Signature ad-hoc uniquement (pas de notarisation).
- Un écran de consentement **Externe** exigerait une vérification Google : les périmètres
  `chat.messages.readonly` et `directory.readonly` sont sensibles/restreints. D'où la
  recommandation de créer le projet dans l'organisation Workspace (audience **Interne**).
