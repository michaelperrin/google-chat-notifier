import SwiftUI
import AppKit

/// Contenu du popover de la barre de menus : onglets natifs + pied de page.
struct MenuContentView: View {
    @Environment(AppState.self) private var appState
    let poller: Poller

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isConfigured || !appState.isSignedIn {
                onboarding
            } else {
                ForEach(appState.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TabView {
                    ConversationListSection(
                        conversations: appState.pendingConversations,
                        error: appState.errorMessage,
                        emptyMessage: "Aucun message en attente 🎉"
                    )
                    .tabItem { Label("À traiter", systemImage: "tray.and.arrow.down") }

                    ConversationListSection(
                        conversations: appState.conversations,
                        error: appState.errorMessage,
                        emptyMessage: "Aucune conversation récente."
                    )
                    .tabItem { Label("Récentes", systemImage: "clock") }

                    MentionListSection(
                        mentions: appState.mentions,
                        error: appState.errorMessage,
                        emptyMessage: appState.watchesMentions
                            ? "Aucune mention non lue 🎉"
                            : "Surveillance des mentions désactivée (voir Réglages)."
                    )
                    .tabItem { Label("Mentions", systemImage: "at") }
                }
                .padding(.top, 6)
            }

            Divider()
            footer
        }
        .frame(width: 380, height: 460)
    }

    /// Écran affiché tant que le client OAuth n'est pas configuré ou le compte pas connecté.
    private var onboarding: some View {
        VStack(spacing: 12) {
            Image(systemName: "message.badge")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Google Chat Notifier")
                .font(.headline)
            Text(appState.isConfigured
                 ? "Connectez votre compte Google Workspace pour suivre vos messages privés."
                 : "Renseignez le client OAuth (Client ID et Client Secret) dans les Réglages.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Ouvrir les Réglages…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let updated = appState.lastUpdated {
                Text("Maj \(updated, format: .dateTime.hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Pas encore synchronisé")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                poller.refreshNow()
            } label: {
                if appState.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Rafraîchir")
            .disabled(appState.isRefreshing)

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Réglages")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quitter")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Section de l'onglet « Mentions ». Même structure que `ConversationListSection`,
/// mais l'unité affichée est le message et non la conversation.
private struct MentionListSection: View {
    let mentions: [Mention]
    let error: String?
    let emptyMessage: String

    var body: some View {
        Group {
            if let error {
                PlaceholderView(text: error, icon: "exclamationmark.triangle")
            } else if mentions.isEmpty {
                PlaceholderView(text: emptyMessage, icon: nil)
            } else {
                List(mentions) { mention in
                    MentionRowView(mention: mention)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
        }
    }
}

/// État vide ou erreur, centré dans l'onglet.
private struct PlaceholderView: View {
    let text: String
    let icon: String?

    var body: some View {
        VStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Section réutilisable : liste de conversations, message d'erreur, ou état vide.
private struct ConversationListSection: View {
    let conversations: [Conversation]
    let error: String?
    let emptyMessage: String

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if conversations.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(conversations) { conversation in
                    ConversationRowView(conversation: conversation)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
        }
    }
}
