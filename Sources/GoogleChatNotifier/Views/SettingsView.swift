import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Bindable private var preferences = Preferences.shared
    let poller: Poller

    @State private var clientSecret: String = KeychainStore.get(.clientSecret) ?? ""
    @State private var isConnecting = false
    @State private var statusMessage: String?
    @State private var statusOK = false
    @State private var launchAtLogin = false
    @State private var loginError: String?

    private let refreshOptions = [1, 2, 5, 15]

    private var canConnect: Bool {
        Preferences.isConfigured(clientID: preferences.clientID, clientSecret: clientSecret)
            && !isConnecting
    }

    var body: some View {
        Form {
            Section("Compte Google") {
                if let account = appState.account, appState.isSignedIn {
                    Label(account.email ?? account.name ?? "Compte connecté",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Button("Se déconnecter") {
                        Task {
                            await appState.signOut()
                            statusMessage = nil
                        }
                    }
                } else {
                    Text("Aucun compte connecté.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(isConnecting ? "Connexion…" : "Connecter un compte Google…") {
                        Task { await connect() }
                    }
                    .disabled(!canConnect)

                    if isConnecting {
                        ProgressView().controlSize(.small)
                    }
                }

                if let statusMessage {
                    Label(statusMessage, systemImage: statusOK ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(statusOK ? .green : .red)
                        .font(.callout)
                }

                if isConnecting {
                    Text("Autorisez l'accès dans le navigateur qui vient de s'ouvrir, "
                         + "puis revenez ici.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let warning = appState.directoryWarning {
                    Label("Noms des interlocuteurs non résolus : \(warning)",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section("Client OAuth (Google Cloud)") {
                TextField("Client ID", text: $preferences.clientID,
                          prompt: Text("123456789-abc.apps.googleusercontent.com"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                SecureField("Client Secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: clientSecret) { _, newValue in
                        KeychainStore.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                          for: .clientSecret)
                    }

                Text("Créez un client OAuth de type « Application de bureau » dans Google Cloud "
                     + "Console, activez les API Google Chat et People, puis collez ici les "
                     + "identifiants. La procédure complète est dans le README.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Ouvrir Google Cloud Console…") {
                    if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }

            Section("Rafraîchissement") {
                Picker("Intervalle", selection: $preferences.refreshMinutes) {
                    ForEach(refreshOptions, id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .onChange(of: preferences.refreshMinutes) {
                    poller.reschedule()
                }
            }

            Section("Conversations suivies") {
                Toggle("Inclure les discussions de groupe", isOn: $preferences.includeGroupChats)
                    .onChange(of: preferences.includeGroupChats) {
                        poller.refreshNow()
                    }
                Text("Par défaut, seuls les messages privés en tête-à-tête sont suivis. "
                     + "Les salons nommés ne le sont jamais.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Text("Une notification système est envoyée à chaque nouveau message privé. "
                     + "Cliquer la notification ouvre la conversation dans Google Chat. "
                     + "Le compteur de la barre de menus indique le nombre de conversations "
                     + "en attente de votre réponse (une par personne).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Démarrage") {
                Toggle("Lancer au démarrage de la session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Text("Pour un lancement fiable, installez l'app dans /Applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginError = nil
        } catch {
            // Rétablit l'état réel et signale l'échec.
            launchAtLogin = LoginItem.isEnabled
            loginError = "Impossible de modifier le lancement au démarrage : \(error.localizedDescription)"
        }
    }

    private func connect() async {
        isConnecting = true
        statusMessage = nil
        defer { isConnecting = false }

        do {
            let account = try await appState.signIn()
            statusOK = true
            statusMessage = "Connecté en tant que \(account.email ?? account.name ?? account.sub)."
            poller.refreshNow()
        } catch {
            statusOK = false
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
