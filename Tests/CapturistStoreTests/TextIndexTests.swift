import Foundation
import Testing
@testable import CapturistCore
@testable import CapturistStore

@Suite("Read-only library + text index")
struct TextIndexTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("read-only open never changes the library and can't write")
    func readOnlyOpen() async throws {
        let root = try makeRoot()
        let writer = try CaptureStore(root: root)
        _ = try await writer.importText("Error 502 on checkout", sourceApp: "Safari")
        let database = root.appendingPathComponent("library.sqlite")
        let before = try Data(contentsOf: database)

        let reader = try CaptureStore(readOnlyRoot: root)
        let all = try await reader.captures(search: "checkout")
        #expect(all.count == 1)
        await #expect(throws: (any Error).self) { try await reader.importText("nope", sourceApp: nil) }
        #expect(try Data(contentsOf: database) == before)
    }

    @Test("read-only open of a missing library throws instead of creating it")
    func readOnlyMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try CaptureStore(readOnlyRoot: root) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("since and limit filter captures")
    func sinceAndLimit() async throws {
        let store = try CaptureStore(root: try makeRoot())
        _ = try await store.importText("one", sourceApp: nil)
        _ = try await store.importText("two", sourceApp: nil)
        #expect(try await store.captures(limit: 1).count == 1)
        #expect(try await store.captures(since: Date().addingTimeInterval(60)).isEmpty)
    }

    @Test("indexes snippet text, searches by word prefix and ignores accents")
    func indexAndSearch() async throws {
        let root = try makeRoot()
        let store = try CaptureStore(root: root)
        let capture = try await store.importText("Conexión rechazada: error 502 en el pago", sourceApp: "Notes")
        let index = try TextIndex(path: root.appendingPathComponent("index.sqlite"))

        var progress = try index.update(captures: try await store.captures(), fileURL: store.fileURL(for:))
        #expect(progress.indexed == 1)
        progress = try index.update(captures: try await store.captures(), fileURL: store.fileURL(for:))
        #expect(progress.indexed == 0 && progress.skipped == 1)

        #expect(try index.search("conexion 50") == [capture.id])
        #expect(try index.search("pago rechaz") == [capture.id])
        #expect(try index.search("invoice").isEmpty)
        #expect(try index.search("\" OR * (").isEmpty)

        progress = try index.update(captures: [], fileURL: store.fileURL(for:))
        #expect(progress.removed == 1 && index.count == 0)
    }

    @Test("free text becomes a safe FTS query")
    func ftsQuery() {
        #expect(TextIndex.ftsQuery("error 502") == "\"error\"* \"502\"*")
        #expect(TextIndex.ftsQuery("  \"; DROP") == "\"DROP\"*")
        #expect(TextIndex.ftsQuery("***") == nil)
    }
}
