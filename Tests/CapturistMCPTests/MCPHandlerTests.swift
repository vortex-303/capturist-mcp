import Foundation
import Testing
@testable import CapturistMCP
@testable import CapturistStore

@Suite("MCP handler")
struct MCPHandlerTests {
    private static let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!

    private func makeContext() async throws -> CaptureContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CaptureStore(root: root)
        _ = try await store.importText("Checkout failed: error 502 from payments", sourceApp: "Safari")
        let png = root.appendingPathComponent("Dashboard.png")
        try Self.onePixelPNG.write(to: png)
        _ = try await store.importFile(at: png, sourceApp: "Figma")
        return CaptureContext(store: store, index: try TextIndex(path: root.appendingPathComponent("index.sqlite")))
    }

    private func call(_ handler: MCPHandler, _ method: String, _ params: [String: Any] = [:], id: Int = 1) async throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try #require(await handler.handle(try JSONSerialization.data(withJSONObject: request)))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("initialize, tools/list and notifications")
    func basics() async throws {
        let handler = MCPHandler(context: try await makeContext())
        let initialize = try await call(handler, "initialize", ["protocolVersion": "2025-03-26"])
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        let tools = try #require((try await call(handler, "tools/list"))["result"] as? [String: Any])
        #expect((tools["tools"] as? [[String: Any]])?.count == 5)
        let note = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(await handler.handle(note) == nil)
        let unknown = try await call(handler, "nope/nope")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test("search finds snippet text; get_capture returns an image for screenshots")
    func searchAndGet() async throws {
        let handler = MCPHandler(context: try await makeContext())
        let search = try await call(handler, "tools/call", ["name": "search_captures", "arguments": ["query": "502 payments"]])
        let text = (((search["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("Checkout failed"))

        let get = try await call(handler, "tools/call", ["name": "get_capture", "arguments": ["ref": "latest"]])
        let content = try #require((get["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.contains { $0["type"] as? String == "image" })
    }

    @Test("denied access returns a tool error, tools/list still works")
    func gated() async throws {
        let handler = MCPHandler(context: try await makeContext()) { "Capturist's free trial has ended." }
        let result = try #require((try await call(handler, "tools/call", ["name": "recent_captures"]))["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let tools = try #require((try await call(handler, "tools/list"))["result"] as? [String: Any])
        #expect((tools["tools"] as? [[String: Any]])?.isEmpty == false)
    }

    @Test("unknown refs are a tool error, not a crash")
    func unknownRef() async throws {
        let handler = MCPHandler(context: try await makeContext())
        let result = try #require((try await call(handler, "tools/call", ["name": "get_capture", "arguments": ["ref": "zzzz9999"]]))["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    private func writer(for context: CaptureContext, enabled: Bool) -> MCPWriter {
        let store = context.store
        return MCPWriter(
            isEnabled: { enabled },
            saveText: { text, title, client in try await store.importText(text, source: .agent, sourceApp: client, title: title) },
            saveFile: { data, ext, title, client in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
                try data.write(to: url)
                return try await store.importFile(at: url, source: .agent, displayName: title.map { $0 + "." + ext }, sourceApp: client)
            }
        )
    }

    @Test("save tools are hidden and refused while saving is off")
    func saveOff() async throws {
        let context = try await makeContext()
        let handler = MCPHandler(context: context, writer: writer(for: context, enabled: false))
        let tools = try #require((try await call(handler, "tools/list"))["result"] as? [String: Any])
        #expect((tools["tools"] as? [[String: Any]])?.count == 5)
        let result = try #require((try await call(handler, "tools/call", ["name": "save_snippet", "arguments": ["text": "hi"]]))["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test("agents can save snippets and images, labelled with the client")
    func saveOn() async throws {
        let context = try await makeContext()
        let handler = MCPHandler(context: context, writer: writer(for: context, enabled: true))
        let tools = try #require((try await call(handler, "tools/list"))["result"] as? [String: Any])
        #expect((tools["tools"] as? [[String: Any]])?.count == 7)

        let request: [String: Any] = ["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                      "params": ["name": "save_snippet", "arguments": ["text": "Release checklist\n1. tag", "title": "Release notes"]]]
        _ = await handler.handle(try JSONSerialization.data(withJSONObject: request), client: "Claude Code")
        let snippet = try #require(try await context.store.captures(search: "Release notes").first)
        #expect(snippet.source == .agent && snippet.sourceApp == "Claude Code")

        let image = try await call(handler, "tools/call", ["name": "save_image", "arguments": [
            "data": Self.onePixelPNG.base64EncodedString(), "mimeType": "image/png", "title": "Diagram"]])
        #expect(((image["result"] as? [String: Any])?["isError"] as? Bool) != true)
        #expect(try await context.store.captures(kind: .image).contains { $0.displayName == "Diagram.png" })

        let bad = try #require((try await call(handler, "tools/call", ["name": "save_image", "arguments": ["data": "AAAA", "mimeType": "image/gif"]]))["result"] as? [String: Any])
        #expect(bad["isError"] as? Bool == true)
    }

    @Test("client names from initialize are made friendly")
    func clientName() throws {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                               "params": ["clientInfo": ["name": "claude-code", "version": "2"]]])
        #expect(MCPHandler.clientName(inInitialize: data) == "Claude Code")
    }
}
