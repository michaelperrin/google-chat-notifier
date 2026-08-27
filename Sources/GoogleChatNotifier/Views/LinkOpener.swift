import AppKit

/// Ouvre une URL dans le navigateur puis referme le popover de la barre de menus.
@MainActor
enum LinkOpener {
    static func open(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else { return }

        // Au moment du clic, la fenêtre du popover a le focus clavier : on la capture
        // avant que l'ouverture de l'URL ne fasse passer le navigateur au premier plan.
        let popover = NSApp.keyWindow ?? NSApp.windows.first { window in
            window.isVisible
                && (window.className.contains("StatusBar") || window.className.contains("MenuBarExtra"))
        }

        NSWorkspace.shared.open(url)
        popover?.close()
    }
}
