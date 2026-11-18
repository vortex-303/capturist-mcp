/// Errors shared by the CLI and the in-app MCP server.
public enum LookupError: Error, Sendable {
    case notFound(String)
    case badInput(String)

    public var message: String {
        switch self {
        case .notFound(let ref): return "No capture matches '\(ref)'. Try recent_captures / `capturist recent`."
        case .badInput(let text): return text
        }
    }
}
