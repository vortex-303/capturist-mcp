import CapturistCore
import CapturistStore
import Foundation

/// The captures an agent can see: a library plus its text index. Used by the CLI and by the app's local MCP server.
public final class CaptureContext: Sendable {
    public let store: CaptureStore
    public let index: TextIndex

    public init(store: CaptureStore, index: TextIndex) {
        self.store = store
        self.index = index
    }

    public func fileURL(_ capture: Capture) -> URL {
        store.fileURL(for: capture)
    }

    /// Brings the text index up to date (fast when nothing changed).
    @discardableResult
    public func refreshIndex(force: Bool = false, onEach: ((Capture) -> Void)? = nil) async throws -> TextIndex.Progress {
        let all = try await store.captures()
        return try index.update(captures: all, fileURL: fileURL, force: force, onEach: onEach)
    }

    public func recent(kind: CaptureKind? = nil, since: Date? = nil, limit: Int = 20) async throws -> [Capture] {
        try await store.captures(kind: kind, since: since, limit: limit)
    }

    /// Name, source app, window title, snippet text, and text inside images (from the index).
    public func search(_ query: String, kind: CaptureKind? = nil, limit: Int = 20) async throws -> [Capture] {
        let direct = try await store.captures(kind: kind, search: query)
        let byText = Set(try index.search(query))
        var seen = Set<UUID>()
        var results: [Capture] = []
        for capture in direct where seen.insert(capture.id).inserted { results.append(capture) }
        if !byText.isEmpty {
            for capture in try await store.captures(kind: kind) where byText.contains(capture.id) && seen.insert(capture.id).inserted {
                results.append(capture)
            }
        }
        return Array(results.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    /// `latest`, `latest~N`, or a unique prefix of the capture ID (case-insensitive).
    public func resolve(_ reference: String) async throws -> Capture {
        let ref = reference.lowercased().trimmingCharacters(in: .whitespaces)
        if ref.isEmpty || ref == "latest" || ref.hasPrefix("latest~") {
            let offset = ref.hasPrefix("latest~") ? Int(ref.dropFirst("latest~".count)) ?? -1 : 0
            guard offset >= 0 else { throw LookupError.badInput("Use latest, latest~1, latest~2 …") }
            let list = try await store.captures(limit: offset + 1)
            guard list.count > offset else { throw LookupError.notFound(reference) }
            return list[offset]
        }
        let matches = try await store.captures().filter { $0.id.uuidString.lowercased().hasPrefix(ref) }
        guard let first = matches.first else { throw LookupError.notFound(reference) }
        guard matches.count == 1 else {
            throw LookupError.badInput("'\(reference)' matches \(matches.count) captures; use more characters")
        }
        return first
    }

    /// Text for a capture: snippet text, else the index, else read it now (and remember it).
    public func text(for capture: Capture) async throws -> String {
        if capture.kind == .text, let text = capture.textContent { return text }
        if let indexed = try index.text(for: capture.id) { return indexed }
        try index.update(captures: [capture], fileURL: fileURL)
        return try index.text(for: capture.id) ?? ""
    }

    public func clips(since: Date? = nil, limit: Int = 50) async throws -> [Clip] {
        var clips = try await store.clips(limit: limit)
        if let since { clips = clips.filter { $0.created >= since } }
        return clips
    }
}
