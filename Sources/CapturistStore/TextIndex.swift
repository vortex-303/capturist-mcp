import CapturistCore
import Foundation

/// Full-text index of the text inside captures (Vision for images/PDFs, the snippet text for text).
/// One row per capture, refreshed when the capture's checksum changes. Lives in its own SQLite file,
/// so a reader (the CLI) can keep an index without touching the app's library.
public final class TextIndex: @unchecked Sendable {
    public struct Progress: Sendable {
        public var indexed: Int
        public var skipped: Int
        public var failed: Int
        public var removed: Int
    }

    private let database: SQLiteDatabase

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        database = try SQLiteDatabase(path: path.path)
        try database.execute("PRAGMA journal_mode = WAL")
        try database.executeScript("""
            CREATE TABLE IF NOT EXISTS entries (
                id TEXT PRIMARY KEY NOT NULL,
                checksum TEXT NOT NULL,
                text TEXT NOT NULL,
                indexed_at REAL NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
                id UNINDEXED, text, tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
    }

    /// Indexes captures that are new or changed and drops entries for captures that are gone.
    @discardableResult
    public func update(
        captures: [Capture],
        fileURL: (Capture) -> URL,
        force: Bool = false,
        onEach: ((Capture) -> Void)? = nil
    ) throws -> Progress {
        var progress = Progress(indexed: 0, skipped: 0, failed: 0, removed: 0)
        let known = Dictionary(
            uniqueKeysWithValues: try database.query("SELECT id, checksum FROM entries").compactMap { row in
                row.string("id").map { ($0, row.string("checksum") ?? "") }
            }
        )
        for capture in captures {
            let key = capture.id.uuidString
            let version = capture.checksum ?? "\(capture.byteSize)-\(capture.updatedAt.timeIntervalSince1970)"
            if !force, known[key] == version {
                progress.skipped += 1
                continue
            }
            onEach?(capture)
            let text: String
            switch capture.kind {
            case .text:
                text = capture.textContent ?? (try? String(contentsOf: fileURL(capture), encoding: .utf8)) ?? ""
            case .image, .pdf:
                guard let result = try? TextRecognizer.recognize(fileURL: fileURL(capture)) else {
                    progress.failed += 1
                    continue
                }
                text = result.combined
            default:
                progress.skipped += 1
                continue
            }
            try store(id: key, checksum: version, text: text)
            progress.indexed += 1
        }
        let live = Set(captures.map(\.id.uuidString))
        for id in known.keys where !live.contains(id) {
            try remove(id: id)
            progress.removed += 1
        }
        return progress
    }

    public func text(for id: UUID) throws -> String? {
        try database.query("SELECT text FROM entries WHERE id = ?", [.text(id.uuidString)]).first?.string("text")
    }

    public func store(id: String, checksum: String, text: String) throws {
        try database.execute(
            "INSERT OR REPLACE INTO entries (id, checksum, text, indexed_at) VALUES (?, ?, ?, ?)",
            [.text(id), .text(checksum), .text(text), .real(Date().timeIntervalSince1970)]
        )
        try database.execute("DELETE FROM entries_fts WHERE id = ?", [.text(id)])
        try database.execute("INSERT INTO entries_fts (id, text) VALUES (?, ?)", [.text(id), .text(text)])
    }

    public func remove(id: String) throws {
        try database.execute("DELETE FROM entries WHERE id = ?", [.text(id)])
        try database.execute("DELETE FROM entries_fts WHERE id = ?", [.text(id)])
    }

    public var count: Int {
        (try? database.query("SELECT COUNT(*) AS n FROM entries").first?.int("n")) ?? 0
    }

    /// Capture IDs whose text matches every word of `query` (prefix match, accents ignored), best first.
    public func search(_ query: String, limit: Int = 200) throws -> [UUID] {
        guard let match = Self.ftsQuery(query) else { return [] }
        return try database.query(
            "SELECT id FROM entries_fts WHERE entries_fts MATCH ? ORDER BY rank LIMIT ?",
            [.text(match), .integer(Int64(limit))]
        ).compactMap { $0.string("id").flatMap(UUID.init(uuidString:)) }
    }

    /// Turns free text into a safe FTS5 query: every word quoted, prefix-matched, all required.
    static func ftsQuery(_ query: String) -> String? {
        let words = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
