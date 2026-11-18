import Foundation
import Testing
@testable import CapturistMCP

@Suite("Agent endpoint file")
struct AgentEndpointTests {
    @Test("writes 0600, reads back, removes")
    func roundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AgentEndpoint.read(from: root) == nil)
        let endpoint = AgentEndpoint(url: "http://127.0.0.1:47833/mcp", token: "cap_test", app: "Capturist Complete",
                                     version: "1.1.0", pid: ProcessInfo.processInfo.processIdentifier)
        try endpoint.write(to: root)
        #expect(AgentEndpoint.read(from: root) == endpoint)
        #expect(endpoint.processIsAlive)

        let mode = try FileManager.default.attributesOfItem(atPath: AgentEndpoint.fileURL(in: root).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        AgentEndpoint.remove(from: root)
        #expect(AgentEndpoint.read(from: root) == nil)
    }

    @Test("a dead process isn't relayed to")
    func deadProcess() {
        let endpoint = AgentEndpoint(url: "http://127.0.0.1:1/mcp", token: "x", app: "Capturist", version: "1.1.0", pid: 999_999)
        #expect(!endpoint.processIsAlive)
    }
}
