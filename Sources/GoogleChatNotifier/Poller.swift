import Foundation

/// Déclenche un rafraîchissement au lancement puis à intervalle régulier.
@MainActor
final class Poller {
    private let appState: AppState
    private let preferences: Preferences
    private var timer: Timer?
    private var started = false

    init(appState: AppState, preferences: Preferences = .shared) {
        self.appState = appState
        self.preferences = preferences
    }

    /// Premier chargement (sans notification, pour ne pas alerter tout l'historique)
    /// + démarrage du timer.
    func start() {
        guard !started else { return }
        started = true

        Task { await appState.refresh(notifyNew: false) }
        scheduleTimer()
    }

    /// Rafraîchissement manuel immédiat (bouton refresh, connexion d'un compte…).
    func refreshNow() {
        Task { await appState.refresh(notifyNew: true) }
    }

    /// Reprogramme le timer selon l'intervalle courant (à appeler quand il change).
    func reschedule() {
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, preferences.refreshMinutes) * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.appState.refresh(notifyNew: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
