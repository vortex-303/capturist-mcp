import Foundation

/// Where a running Capturist app (1.1+) answers AI agents. The app writes `agents.json` into its
/// library folder while its local MCP server is listening (mode 0600) and removes it when the
/// server stops; `capturist mcp` reads it to relay desktop AI apps (Claude, ChatGPT) to the app.
public struct AgentEndpoint: Codable, Equatable, Sendable {
    public static let fileName = "agents.json"

    public var url: String
    public var token: String
    public var app: String
    public var version: String
    public var pid: Int32

    public init(url: String, token: String, app: String, version: String, pid: Int32) {
        self.url = url
        self.token = token
        self.app = app
        self.version = version
        self.pid = pid
    }

    public static func fileURL(in libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(fileName)
    }

    public static func read(from libraryRoot: URL) -> AgentEndpoint? {
        guard let data = try? Data(contentsOf: fileURL(in: libraryRoot)) else { return nil }
        return try? JSONDecoder().decode(AgentEndpoint.self, from: data)
    }

    public func write(to libraryRoot: URL) throws {
        let url = Self.fileURL(in: libraryRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func remove(from libraryRoot: URL) {
        try? FileManager.default.removeItem(at: fileURL(in: libraryRoot))
    }

    /// True while the process that wrote the file is still alive.
    public var processIsAlive: Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
