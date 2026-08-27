import Foundation
import ServiceManagement

/// Gère le lancement de l'app à l'ouverture de session via SMAppService (API moderne, macOS 13+).
@MainActor
enum LoginItem {
    /// L'app est-elle enregistrée comme élément de démarrage ?
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// L'utilisateur a désactivé l'élément dans Réglages Système → Général → Ouverture.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Active ou désactive le lancement au démarrage.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else {
            if service.status == .enabled {
                try service.unregister()
            }
        }
    }
}
