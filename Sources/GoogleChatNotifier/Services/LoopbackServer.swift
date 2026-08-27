import Foundation
import Network

/// Serveur HTTP minimal et à usage unique, écoutant sur `127.0.0.1`, le temps de recevoir
/// la redirection OAuth de Google (flux « installed app » / boucle locale).
///
/// `@unchecked Sendable` : l'état mutable est intégralement protégé par `lock`, les
/// rappels de `NWListener` étant délivrés sur `queue`, hors de tout acteur.
final class LoopbackServer: @unchecked Sendable {
    enum Failure: LocalizedError {
        case cannotStart(String)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotStart(let detail):
                return "Impossible d'ouvrir le port local d'authentification : \(detail)"
            case .timedOut:
                return "Délai d'authentification dépassé."
            case .cancelled:
                return "Authentification annulée."
            }
        }
    }

    private let queue = DispatchQueue(label: "fr.michaelperrin.google-chat-notifier.oauth")
    private let lock = NSLock()

    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var redirectContinuation: CheckedContinuation<[String: String], Error>?
    /// Résultat arrivé avant l'appel à `waitForRedirect` : conservé pour ne pas le perdre.
    private var pendingResult: Result<[String: String], Error>?
    private var timeoutWork: DispatchWorkItem?
    private var connections: [NWConnection] = []

    /// Page renvoyée au navigateur une fois le code reçu.
    private static let successPage = """
    <!doctype html><html lang="fr"><head><meta charset="utf-8">
    <title>Google Chat Notifier</title></head>
    <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:4rem">
    <h1>C'est bon 👍</h1>
    <p>Vous pouvez fermer cet onglet et revenir à Google&nbsp;Chat Notifier.</p>
    </body></html>
    """

    // MARK: - Cycle de vie

    /// Démarre l'écoute et renvoie le port attribué par le système.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Failure.cannotStart(error.localizedDescription)
        }

        lock.withLock { self.listener = listener }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else {
                    self.resumeStart(.failure(Failure.cannotStart("port non attribué")))
                    return
                }
                self.resumeStart(.success(port))
            case .failed(let error):
                self.resumeStart(.failure(Failure.cannotStart(error.localizedDescription)))
                self.finish(.failure(Failure.cannotStart(error.localizedDescription)))
            case .cancelled:
                self.resumeStart(.failure(Failure.cancelled))
            default:
                break
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { startContinuation = continuation }
            listener.start(queue: queue)
        }
    }

    /// Attend la redirection du navigateur et renvoie les paramètres de la query string.
    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            // Le navigateur peut avoir répondu avant qu'on ne se mette en attente.
            if let ready = lock.withLock({
                let captured = pendingResult
                pendingResult = nil
                return captured
            }) {
                continuation.resume(with: ready)
                return
            }

            let work = DispatchWorkItem { [weak self] in
                self?.finish(.failure(Failure.timedOut))
            }
            lock.withLock {
                redirectContinuation = continuation
                timeoutWork = work
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// Ferme l'écoute et les connexions en cours. Idempotent.
    func stop() {
        let (listener, openConnections, work) = lock.withLock {
            let captured = (self.listener, connections, timeoutWork)
            self.listener = nil
            connections = []
            timeoutWork = nil
            return captured
        }

        work?.cancel()
        openConnections.forEach { $0.cancel() }
        listener?.cancel()
    }

    // MARK: - Connexions

    private func handle(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }

        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, error == nil, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let parameters = Self.queryParameters(fromRequest: request)
            self.respond(on: connection)
            if let parameters {
                self.finish(.success(parameters))
            }
        }
    }

    private func respond(on connection: NWConnection) {
        let body = Data(Self.successPage.utf8)
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        connection.send(
            content: Data(response.utf8) + body,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Continuations

    private func resumeStart(_ result: Result<UInt16, Error>) {
        let continuation = lock.withLock {
            let captured = startContinuation
            startContinuation = nil
            return captured
        }
        continuation?.resume(with: result)
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let (continuation, work) = lock.withLock { () -> (CheckedContinuation<[String: String], Error>?, DispatchWorkItem?) in
            let captured = (redirectContinuation, timeoutWork)
            redirectContinuation = nil
            timeoutWork = nil
            // Personne n'attend encore : on met le résultat de côté.
            if captured.0 == nil, pendingResult == nil {
                pendingResult = result
            }
            return captured
        }

        work?.cancel()
        continuation?.resume(with: result)
    }

    // MARK: - Analyse HTTP

    /// Extrait les paramètres de query de la ligne de requête HTTP.
    /// `GET /?code=4/abc&state=xyz HTTP/1.1` → `["code": "4/abc", "state": "xyz"]`.
    /// Renvoie `nil` si la requête n'est pas exploitable (ex. `/favicon.ico`). Fonction pure (testable).
    static func queryParameters(fromRequest request: String) -> [String: String]? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first
                ?? request.split(separator: "\n", maxSplits: 1).first else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" else { return nil }

        guard let components = URLComponents(string: "http://127.0.0.1" + fields[1]),
              let items = components.queryItems, !items.isEmpty else { return nil }

        return Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
}
