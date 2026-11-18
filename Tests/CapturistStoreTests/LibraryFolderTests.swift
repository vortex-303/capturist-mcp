import Foundation
import Testing
@testable import CapturistCore
@testable import CapturistStore

@Suite("Library files folder")
struct LibraryFolderTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!
    private static let png2 = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func importPNG(_ store: CaptureStore, named name: String, data: Data = png, scratch: URL) async throws -> Capture {
        let source = scratch.appendingPathComponent(name)
        try data.write(to: source)
        return try await store.importFile(at: source)
    }

    @Test("without library.json files stay in <root>/Captures")
    func defaultLayout() async throws {
        let root = try temp(), scratch = try temp()
        let store = try CaptureStore(root: root)
        let capture = try await importPNG(store, named: "a.png", scratch: scratch)
        #expect(store.fileURL(for: capture).path == root.appendingPathComponent("Captures/a.png").path)
        #expect(store.filesFolder == nil)
    }

    @Test("relocate moves files, keeps rows, writes library.json; readers follow")
    func relocate() async throws {
        let root = try temp(), scratch = try temp(), folder = try temp().appendingPathComponent("Capturist")
        let store = try CaptureStore(root: root)
        let a = try await importPNG(store, named: "a.png", scratch: scratch)
        let b = try await store.importText("hello world", sourceApp: "Notes")

        let moved = try await store.relocateFiles(to: folder, owner: "test.bundle")
        #expect(moved == 2)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.png").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Captures").path))
        #expect(store.fileURL(for: a).path == folder.appendingPathComponent("a.png").path)
        #expect(LibraryConfig.owner(of: folder) == "test.bundle")
        #expect(LibraryConfig.filesFolder(in: root)?.path == folder.path)

        let reopened = try CaptureStore(readOnlyRoot: root)
        let rows = try await reopened.captures()
        #expect(rows.count == 2)
        for row in rows { #expect(FileManager.default.fileExists(atPath: reopened.fileURL(for: row).path)) }
        _ = b
    }

    @Test("relocate renames on collision and updates the row")
    func relocateCollision() async throws {
        let root = try temp(), scratch = try temp(), folder = try temp()
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.png"))
        let store = try CaptureStore(root: root)
        let a = try await importPNG(store, named: "a.png", scratch: scratch)
        try await store.relocateFiles(to: folder, owner: "t")
        let row = try await store.capture(id: a.id)
        #expect(row?.originalPath == "Captures/a 2.png")
        #expect(FileManager.default.contentsEqual(atPath: store.fileURL(for: row!).path, andPath: scratch.appendingPathComponent("a.png").path))
    }

    @Test("Finder changes: add, rename, delete")
    func reconcile() async throws {
        let root = try temp(), scratch = try temp(), folder = try temp()
        let store = try CaptureStore(root: root)
        let keep = try await importPNG(store, named: "keep.png", scratch: scratch)
        let renamed = try await importPNG(store, named: "old.png", data: Self.png2, scratch: scratch)
        let gone = try await store.importText("bye", sourceApp: nil)
        let other = try await importPNG(store, named: "other.png", scratch: scratch)
        let fifth = try await store.importText("five", sourceApp: nil)
        try await store.relocateFiles(to: folder, owner: "t")
        _ = (keep, other, fifth)

        let fm = FileManager.default
        try fm.moveItem(at: folder.appendingPathComponent("old.png"), to: folder.appendingPathComponent("New name.png"))
        try fm.removeItem(at: store.fileURL(for: gone))
        try "notes".write(to: folder.appendingPathComponent("dropped.txt"), atomically: true, encoding: .utf8)
        try "partial".write(to: folder.appendingPathComponent("big.zip.crdownload"), atomically: true, encoding: .utf8)

        let result = try await store.reconcileFilesFolder()
        #expect(result == ReconcileResult(added: 1, renamed: 1, removed: 1, skipped: false))
        let all = try await store.captures()
        #expect(all.count == 5)
        let follow = try await store.capture(id: renamed.id)
        #expect(follow?.displayName == "New name.png")  // imported as "old.png", so the extension stays
        #expect(follow?.originalPath == "Captures/New name.png")
        let dropped = all.first { $0.originalPath == "Captures/dropped.txt" }
        #expect(dropped?.textContent == "notes")
        #expect(dropped?.sourceApp == "Finder")
        #expect(try await store.reconcileFilesFolder() == ReconcileResult())
    }

    @Test("folder gone or mostly empty: nothing is deleted")
    func reconcileSafety() async throws {
        let root = try temp(), scratch = try temp(), folder = try temp()
        let store = try CaptureStore(root: root)
        for i in 0..<6 { _ = try await importPNG(store, named: "f\(i).png", data: Data(Self.png + Data([UInt8(i)])), scratch: scratch) }
        try await store.relocateFiles(to: folder, owner: "t")
        for i in 0..<4 { try FileManager.default.removeItem(at: folder.appendingPathComponent("f\(i).png")) }
        #expect(try await store.reconcileFilesFolder().skipped)
        try FileManager.default.removeItem(at: folder)
        #expect(try await store.reconcileFilesFolder().skipped)
        #expect(try await store.captures().count == 6)
    }
}
