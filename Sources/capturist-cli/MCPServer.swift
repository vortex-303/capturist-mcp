import CapturistMCP
import Foundation

/// `capturist mcp`: an MCP server over stdio (newline-delimited JSON-RPC), the way the Claude and
/// ChatGPT desktop apps (and Claude Code, Codex …) start local tools.
///
/// - Relay: when the library's app (Capturist 1.1+) is running with AI Agents on, every message
///   goes to the app's local server (all tools, including saving to the library; the app's own
///   trial/unlock rules apply).
/// - Direct: otherwise (app closed, AI Agents off, or Capturist 1.0, which has no server) the
///   library is read here, read-only.
struct MCPServer {
    let library: Library

    func run() async {
        if let endpoint = AgentEndpoint.read(from: library.root), endpoint.processIsAlive,
           await Relay.ping(endpoint) {
            await Relay(endpoint: endpoint, library: library).run()
        } else {
            let handler = MCPHandler(context: library.context)
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                if let response = await handler.handle(data) { Self.send(response) }
            }
        }
    }

    static func send(_ data: Data) {
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

/// Forwards stdio messages to the running app's `http://127.0.0.1:<port>/mcp`.
struct Relay {
    let endpoint: AgentEndpoint
    let library: Library

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120   // saving a large image can take a moment
        configuration.connectionProxyDictionary = [:]   // never through a proxy: it's localhost
        return URLSession(configuration: configuration)
    }()

    /// The app answers with our token (a short timeout: a stale file must not delay startup).
    static func ping(_ endpoint: AgentEndpoint) async -> Bool {
        guard var request = request(for: endpoint, body: Data(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#.utf8)) else { return false }
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func request(for endpoint: AgentEndpoint, body: Data, sessionID: String? = nil) -> URLRequest? {
        guard let url = URL(string: endpoint.url), url.host == "127.0.0.1" || url.host == "localhost" else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        return request
    }

    func run() async {
        var endpoint = self.endpoint
        var sessionID: String?
        var initialize: Data?          // replayed if the app restarts with a new address/token
        var direct: MCPHandler?        // used once the app is gone

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let body = line.data(using: .utf8) else { continue }
            if MCPHandler.clientName(inInitialize: body) != nil { initialize = body }

            if let direct {
                if let response = await direct.handle(body) { MCPServer.send(response) }
                continue
            }

            var outcome = await forward(body, to: endpoint, sessionID: sessionID)
            if case .unreachable = outcome, let fresh = AgentEndpoint.read(from: library.root),
               fresh != endpoint, fresh.processIsAlive {
                // The app restarted (new port or token): pick it up and carry on.
                endpoint = fresh
                sessionID = nil
                if let initialize, initialize != body,
                   case .answered(_, let id) = await forward(initialize, to: endpoint, sessionID: nil) {
                    sessionID = id
                }
                outcome = await forward(body, to: endpoint, sessionID: sessionID)
            }

            switch outcome {
            case .answered(let response, let id):
                if let id { sessionID = id }
                if let response { MCPServer.send(response) }
            case .unreachable:
                // Capturist was closed or AI Agents turned off: keep working, read-only.
                let handler = MCPHandler(context: library.context)
                direct = handler
                if let response = await handler.handle(body) { MCPServer.send(response) }
            }
        }
    }

    enum Outcome {
        case answered(Data?, sessionID: String?)
        case unreachable
    }

    private func forward(_ body: Data, to endpoint: AgentEndpoint, sessionID: String?) async -> Outcome {
        guard let request = Self.request(for: endpoint, body: body, sessionID: sessionID),
              let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        switch http.statusCode {
        case 200:
            return .answered(data.isEmpty ? nil : data, sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id"))
        case 202, 204:
            return .answered(nil, sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id"))
        default:
            return .unreachable   // 401 (new token), 403, 5xx …
        }
    }
}
