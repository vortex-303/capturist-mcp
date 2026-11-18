import Foundation
import Testing
@testable import CapturistCore
@testable import CapturistStore

@Suite("Capture store")
struct CaptureStoreTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!

    private func makeSource(in root: URL, name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Self.onePixelPNG.write(to: url)
        return url
    }

    @Test("imports, lists, searches, and tombstones a capture")
    func importListDelete() async throws {
        let root = try makeRoot()
        let store = try CaptureStore(root: root)
        let source = try makeSource(in: root, name: "Screen Shot.png")
        let capture = try await store.importFile(at: source)

        #expect(capture.kind == .image)
        #expect(capture.byteSize > 0)
        #expect(capture.width == 1)
        #expect(capture.height == 1)
        #expect(capture.checksum?.count == 64)

        var all = try await store.captures()
        #expect(all.count == 1)

        all = try await store.captures(search: "Screen")
        #expect(all.count == 1)

        all = try await store.captures(search: "missing")
        #expect(all.isEmpty)

        let stats = try await store.stats()
        #expect(stats.captureCount == 1)
        #expect(stats.totalBytes == capture.byteSize)

        try await store.delete(id: capture.id)
        all = try await store.captures()
        #expect(all.isEmpty)

        let hidden = try await store.capture(id: capture.id)
        #expect(hidden?.state == .deleted)
    }

    @Test("filters by kind and stores thumbnails")
    func filterAndThumbnail() async throws {
        let root = try makeRoot()
        let store = try CaptureStore(root: root)
        let image = try await store.importFile(at: makeSource(in: root, name: "a.png"))
        _ = try await store.importFile(at: makeSource(in: root, name: "b.zip"))

        let images = try await store.captures(kind: .image)
        #expect(images.map(\.id) == [image.id])

        try await store.setThumbnail("Captures/\(image.id.uuidString)/thumb.jpg", for: image.id)
        let updated = try await store.capture(id: image.id)
        #expect(updated?.thumbnailPath?.hasSuffix("thumb.jpg") == true)
    }

    @Test("stores captures flat with readable, unique names and deletes the file")
    func flatLayout() async throws {
        let root = try makeRoot()
        let store = try CaptureStore(root: root)
        let source = try makeSource(in: root, name: "src.png")
        let first = try await store.importFile(at: source, displayName: "Screenshot 2026-11-12 at 07.01.23.png")
        let second = try await store.importFile(at: source, displayName: "Screenshot 2026-11-12 at 07.01.23.png")
        let odd = try await store.importFile(at: source, displayName: "a/b: c")

        #expect(first.originalPath == "Captures/Screenshot 2026-11-12 at 07.01.23.png")
        #expect(second.originalPath == "Captures/Screenshot 2026-11-12 at 07.01.23 2.png")
        #expect(odd.originalPath == "Captures/a-b. c.png")

        let file = store.fileURL(for: first)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await store.delete(id: first.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: second).path))
    }

    @Test("moves legacy per-capture folders into the flat pool")
    func legacyMigration() async throws {
        let root = try makeRoot()
        let store = try CaptureStore(root: root)
        let capture = try await store.importFile(at: makeSource(in: root, name: "x.png"), displayName: "Old Shot.png")

        // Recreate the old layout for this row.
        let legacyDir = root.appendingPathComponent("Captures/\(capture.id.uuidString)")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: store.fileURL(for: capture), to: legacyDir.appendingPathComponent("original.png"))
        let db = try SQLiteDatabase(path: root.appendingPathComponent("library.sqlite").path)
        try db.execute("UPDATE captures SET original_path = ? WHERE id = ?",
                       [.text("Captures/\(capture.id.uuidString)/original.png"), .text(capture.id.uuidString)])

        let moved = try await store.flattenLegacyLayout()
        #expect(moved == 1)
        let updated = try #require(try await store.capture(id: capture.id))
        #expect(updated.originalPath == "Captures/Old Shot.png")
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: updated).path))
        #expect(!FileManager.default.fileExists(atPath: legacyDir.path))
        #expect(try await store.flattenLegacyLayout() == 0)
    }

    @Test("saves text snippets as .txt and searches their content")
    func textSnippets() async throws {
        let root = try makeRoot()
        let store = try CaptureStore(root: root)
        let snippet = try await store.importText("\n  Deploy checklist\nnpm run build && wrangler pages deploy", sourceApp: "Notes")

        #expect(snippet.kind == .text)
        #expect(snippet.displayName == "Deploy checklist.txt")
        #expect(snippet.originalPath == "Captures/Deploy checklist.txt")
        #expect(snippet.textContent?.contains("wrangler") == true)
        #expect(try String(contentsOf: store.fileURL(for: snippet), encoding: .utf8).contains("npm run build"))

        #expect(try await store.captures(search: "wrangler").map(\.id) == [snippet.id])
        #expect(try await store.captures(kind: .text).count == 1)
        #expect(try await store.capture(id: snippet.id)?.textContent?.hasPrefix("\n  Deploy") == true)

        let long = String(repeating: "a", count: 100)
        #expect(CaptureStore.snippetTitle(for: long).count == 58)
        #expect(CaptureStore.snippetTitle(for: "   \n ") == "Snippet")
    }

    @Test("records and clears share links")
    func shareLinks() async throws {
        let root = try makeRoot()
        let store = try CaptureStore(root: root)
        let capture = try await store.importFile(at: makeSource(in: root, name: "a.png"))
        #expect(capture.activeShareURL == nil)

        try await store.setShared(id: capture.id, pageURL: "https://capturist.nodetools.org/s/abcdEFGH",
                                  fileURL: "https://capturist.nodetools.org/s/abcdEFGH/raw", remoteID: "abcdEFGH",
                                  deleteToken: "tok", expiresAt: Date().addingTimeInterval(3600))
        var shared = try #require(try await store.capture(id: capture.id))
        #expect(shared.state == .uploaded)
        #expect(shared.activeShareURL?.absoluteString == "https://capturist.nodetools.org/s/abcdEFGH")
        #expect(shared.remoteDeleteToken == "tok")

        try await store.setShared(id: capture.id, pageURL: "https://x/s/old", fileURL: "https://x/s/old/raw",
                                  remoteID: "old", deleteToken: "t", expiresAt: Date().addingTimeInterval(-1))
        shared = try #require(try await store.capture(id: capture.id))
        #expect(shared.activeShareURL == nil)

        try await store.clearShared(id: capture.id)
        shared = try #require(try await store.capture(id: capture.id))
        #expect(shared.remotePageURL == nil && shared.remoteDeleteToken == nil && shared.state == .local)
    }

    @Test("clipboard history: add, dedupe, purge after 24 h, cap, pin")
    func clipboardHistory() async throws {
        let root = try makeRoot()
        let store = try CaptureStore(root: root)

        #expect(try await store.addClip(text: "   \n", sourceApp: nil) == nil)
        let first = try #require(try await store.addClip(text: "hello world", sourceApp: "Safari"))
        let again = try #require(try await store.addClip(text: "hello world", sourceApp: "Notes"))
        #expect(again.id == first.id)
        #expect(try await store.clips().count == 1)
        #expect(try await store.clips().first?.sourceApp == "Notes")

        try await store.addClip(text: "old", sourceApp: nil, at: Date().addingTimeInterval(-25 * 3600))
        try await store.addClip(text: "second", sourceApp: nil)
        try await store.purgeClips()
        #expect(try await store.clips().map(\.text) == ["second", "hello world"])

        for i in 0..<(Clip.maxCount + 5) {
            try await store.addClip(text: "item \(i)", sourceApp: nil, at: Date().addingTimeInterval(Double(i)))
        }
        #expect(try await store.clips().count == Clip.maxCount)

        let newest = try #require(try await store.clips(limit: 1).first)
        let pinned = try #require(try await store.pinClip(id: newest.id))
        #expect(pinned.kind == .text)
        #expect(try await store.clips().contains { $0.id == newest.id } == false)

        try await store.clearClips()
        #expect(try await store.clips().isEmpty)
        #expect(Clip(text: "\n  Title line \nbody").title == "Title line")
    }

    @Test("missing source reports an error")
    func missingSource() async throws {
        let root = try makeRoot()
        let store = try CaptureStore(root: root)
        let missing = root.appendingPathComponent("nope.png")

        await #expect(throws: (any Error).self) {
            try await store.importFile(at: missing)
        }
    }
}
