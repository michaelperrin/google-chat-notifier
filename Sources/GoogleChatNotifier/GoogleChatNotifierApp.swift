import SwiftUI
import AppKit

/// Point d'entrée. `--run-checks` exécute les tests intégrés (utile sans Xcode/XCTest),
/// sinon on lance l'app SwiftUI normalement.
@main
enum Main {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--run-checks") {
            Checks.run()
        } else {
            GoogleChatNotifierApp.main()
        }
    }
}

struct GoogleChatNotifierApp: App {
    @State private var appState: AppState
    @State private var poller: Poller

    init() {
        let state = AppState()
        _appState = State(initialValue: state)
        _poller = State(initialValue: Poller(appState: state))

        NotificationService.shared.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(poller: poller)
                .environment(appState)
                .task { poller.start() }
        } label: {
            MenuBarLabel(count: appState.badgeCount)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(poller: poller)
                .environment(appState)
        }
    }
}

/// Libellé de la barre de menus : bulle de message + nombre de conversations à traiter.
/// La bulle est pleine dès qu'il y a quelque chose à traiter, creuse sinon.
private struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 3) {
                Image(systemName: "message.fill")
                Text("\(count)")
            }
        } else {
            Image(systemName: "message")
        }
    }
}
