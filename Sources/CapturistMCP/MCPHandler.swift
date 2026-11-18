import CapturistCore
import CapturistStore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// MCP (JSON-RPC 2.0) request handling shared by the CLI (stdio) and the app (local HTTP).
/// Read-only: tools + resources over a `CaptureContext`.
public struct MCPHandler: Sendable {
    public let context: CaptureContext
    /// Returns nil when access is allowed, or the message agents should see (e.g. trial ended).
    public let accessCheck: @Sendable () async -> String?
    public let serverName: String
    /// Save tools (app only); nil keeps the server read-only.
    public let writer: MCPWriter?

    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public init(context: CaptureContext, serverName: String = "capturist", writer: MCPWriter? = nil,
                accessCheck: @escaping @Sendable () async -> String? = { nil }) {
        self.context = context
        self.serverName = serverName
        self.writer = writer
        self.accessCheck = accessCheck
    }

    /// The `clientInfo.name` of an `initialize` request (used to label saved items), else nil.
    public static func clientName(inInitialize data: Data) -> String? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "initialize",
              let info = (message["params"] as? [String: Any])?["clientInfo"] as? [String: Any],
              let name = info["name"] as? String, !name.isEmpty else { return nil }
        return Self.friendlyClientName(name)
    }

    static func friendlyClientName(_ raw: String) -> String {
        let known = ["claude-code": "Claude Code", "claude-ai": "Claude", "cursor-vscode": "Cursor", "cursor": "Cursor",
                     "opencode": "OpenCode", "codex-mcp-client": "Codex", "codex": "Codex"]
        return known[raw.lowercased()] ?? raw
    }

    struct RPCError: Error { let code: Int; let message: String }

    /// One JSON-RPC message in → the response, or nil for notifications / unparseable input.
    public func handle(_ data: Data, client: String? = nil) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil } // notification
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result = try await handle(method: method, params: params, client: client)
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as RPCError {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        } catch let error as LookupError {
            return encode(["jsonrpc": "2.0", "id": id, "result": toolError(error.message)])
        } catch let error as SaveError {
            return encode(["jsonrpc": "2.0", "id": id, "result": toolError(error.message)])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id, "result": toolError(String(describing: error))])
        }
    }

    private func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    private func toolError(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    private func handle(method: String, params: [String: Any], client: String?) async throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0],
                "capabilities": ["tools": [String: Any](), "resources": [String: Any]()],
                "serverInfo": ["name": serverName, "version": Guide.version],
                "instructions": Guide.agentGuide,
            ]
        case "ping":
            return [:]
        case "tools/list":
            var tools = Self.tools
            if let writer, await writer.isEnabled() { tools += Self.saveTools }
            return ["tools": tools]
        case "tools/call":
            if let denied = await accessCheck() { return toolError(denied) }
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return try await call(name, arguments, client: client)
        case "resources/list":
            if await accessCheck() != nil { return ["resources": [Any]()] }
            let recent = try await context.recent(limit: 20)
            return ["resources": recent.map { capture in
                [
                    "uri": "capturist://capture/\(Output.short(capture.id))",
                    "name": capture.displayName,
                    "description": "\(capture.kind.rawValue), \(capture.sourceApp ?? "unknown app"), \(Output.ago(capture.createdAt))",
                    "mimeType": mimeType(capture),
                ] as [String: Any]
            }]
        case "resources/read":
            if let denied = await accessCheck() { throw RPCError(code: -32001, message: denied) }
            let uri = params["uri"] as? String ?? ""
            guard uri.hasPrefix("capturist://capture/"), let ref = uri.split(separator: "/").last.map(String.init) else {
                throw RPCError(code: -32602, message: "Unknown resource \(uri)")
            }
            let capture = try await context.resolve(ref)
            if capture.kind == .image, let image = imageData(capture) {
                return ["contents": [["uri": uri, "mimeType": image.mime, "blob": image.data.base64EncodedString()]]]
            }
            return ["contents": [["uri": uri, "mimeType": "text/plain", "text": try await context.text(for: capture)]]]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func call(_ name: String, _ arguments: [String: Any], client: String?) async throws -> [String: Any] {
        func string(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ key: String, _ fallback: Int) -> Int {
            let value = (arguments[key] as? Int) ?? (arguments[key] as? Double).map(Int.init) ?? fallback
            return min(max(value, 1), 200)
        }
        let kind = try string("kind").map { value -> CaptureKind in
            guard let kind = CaptureKind(rawValue: value) else { throw LookupError.badInput("kind must be image, text or pdf") }
            return kind
        }

        switch name {
        case "recent_captures":
            try await context.refreshIndex()
            let since = try string("since").map(Output.since)
            return listResult(try await context.recent(kind: kind, since: since, limit: int("limit", 20)))
        case "search_captures":
            guard let query = string("query") else { throw LookupError.badInput("query is required") }
            try await context.refreshIndex()
            return listResult(try await context.search(query, kind: kind, limit: int("limit", 20)))
        case "get_capture":
            let capture = try await context.resolve(string("ref") ?? "latest")
            let text = try await context.text(for: capture)
            let details = Output.json(capture, path: context.fileURL(capture), text: text.isEmpty ? nil : text)
            var content: [[String: Any]] = [["type": "text", "text": Output.encode(details)]]
            if capture.kind == .image, let image = imageData(capture) {
                content.append(["type": "image", "data": image.data.base64EncodedString(), "mimeType": image.mime])
            }
            return ["content": content]
        case "capture_text":
            let capture = try await context.resolve(string("ref") ?? "latest")
            let text = try await context.text(for: capture)
            return ["content": [["type": "text", "text": text.isEmpty ? "(no text found in this capture)" : text]]]
        case "recent_clips":
            let clips = try await context.clips(since: try string("since").map(Output.since), limit: int("limit", 50))
            let text = clips.isEmpty
                ? "No clipboard history (it may be turned off in Capturist)."
                : Output.encode(clips.map(Output.json))
            return ["content": [["type": "text", "text": text]]]
        case "save_snippet", "save_image":
            guard let writer, await writer.isEnabled() else {
                return toolError("Saving to Capturist is turned off. The user can allow it in Capturist → Settings → AI Agents.")
            }
            let title = string("title")
            let saved: Capture
            if name == "save_snippet" {
                guard let text = arguments["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LookupError.badInput("text is required") }
                guard text.count <= MCPWriter.maxTextCharacters else { throw SaveError.tooLarge }
                saved = try await writer.saveText(text, title, client)
            } else {
                let mime = string("mimeType") ?? "image/png"
                guard let ext = MCPWriter.allowedTypes[mime] else { throw SaveError.unsupported(mime) }
                guard let encoded = string("data") else { throw LookupError.badInput("data (base64) is required") }
                let cleaned = encoded.contains(",") && encoded.hasPrefix("data:") ? String(encoded.split(separator: ",", maxSplits: 1)[1]) : encoded
                guard cleaned.count <= MCPWriter.maxFileBytes / 3 * 4 + 8 else { throw SaveError.tooLarge }
                guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters), !data.isEmpty else {
                    throw LookupError.badInput("data must be base64-encoded file bytes")
                }
                guard data.count <= MCPWriter.maxFileBytes else { throw SaveError.tooLarge }
                saved = try await writer.saveFile(data, ext, title, client)
            }
            return ["content": [["type": "text", "text": "Saved to Capturist as \"\(saved.displayName)\" (ref \(Output.short(saved.id))). The user can find it in their library."]]]
        default:
            throw RPCError(code: -32602, message: "Unknown tool \(name)")
        }
    }

    private func listResult(_ list: [Capture]) -> [String: Any] {
        let text = list.isEmpty ? "No captures found." : Output.encode(list.map { Output.json($0, path: context.fileURL($0)) })
        return ["content": [["type": "text", "text": text]]]
    }

    private func mimeType(_ capture: Capture) -> String {
        switch capture.kind {
        case .image: return "image/png"
        case .pdf: return "application/pdf"
        default: return "text/plain"
        }
    }

    /// The capture image, downscaled to at most 1568 px (what vision models use anyway).
    private func imageData(_ capture: Capture) -> (data: Data, mime: String)? {
        let url = context.fileURL(capture)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1568,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, "image/png")
    }

    nonisolated(unsafe) static let refSchema: [String: Any] = ["type": "string", "description": "latest, latest~1, latest~2 …, or the first characters of a capture id"]
    nonisolated(unsafe) static let kindSchema: [String: Any] = ["type": "string", "enum": ["image", "text", "pdf"]]
    nonisolated(unsafe) static let sinceSchema: [String: Any] = ["type": "string", "description": "e.g. 30m, 2h, 3d, 1w or 2026-11-17"]
    nonisolated(unsafe) static let limitSchema: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 200]

    nonisolated(unsafe) public static let saveTools: [[String: Any]] = [
        ["name": "save_snippet", "description": Guide.toolSaveSnippet,
         "inputSchema": ["type": "object", "properties": [
            "text": ["type": "string", "description": "The text to keep (markdown is fine)."],
            "title": ["type": "string", "description": "Short name shown in the library (optional)."],
         ], "required": ["text"]]],
        ["name": "save_image", "description": Guide.toolSaveImage,
         "inputSchema": ["type": "object", "properties": [
            "data": ["type": "string", "description": "Base64-encoded file bytes (max 10 MB)."],
            "mimeType": ["type": "string", "enum": ["image/png", "image/jpeg", "application/pdf"]],
            "title": ["type": "string", "description": "Short name shown in the library (optional)."],
         ], "required": ["data"]]],
    ]

    nonisolated(unsafe) public static let tools: [[String: Any]] = [
        ["name": "recent_captures", "description": Guide.toolRecent,
         "inputSchema": ["type": "object", "properties": ["since": sinceSchema, "kind": kindSchema, "limit": limitSchema]],
         "annotations": ["readOnlyHint": true]],
        ["name": "search_captures", "description": Guide.toolSearch,
         "inputSchema": ["type": "object", "properties": ["query": ["type": "string"], "kind": kindSchema, "limit": limitSchema], "required": ["query"]],
         "annotations": ["readOnlyHint": true]],
        ["name": "get_capture", "description": Guide.toolGet,
         "inputSchema": ["type": "object", "properties": ["ref": refSchema]],
         "annotations": ["readOnlyHint": true]],
        ["name": "capture_text", "description": Guide.toolText,
         "inputSchema": ["type": "object", "properties": ["ref": refSchema]],
         "annotations": ["readOnlyHint": true]],
        ["name": "recent_clips", "description": Guide.toolClips,
         "inputSchema": ["type": "object", "properties": ["since": sinceSchema, "limit": limitSchema]],
         "annotations": ["readOnlyHint": true]],
    ]
}
