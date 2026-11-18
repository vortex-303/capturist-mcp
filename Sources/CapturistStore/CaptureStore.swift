import Foundation
import CapturistCore

public struct LibraryStats: Sendable, Equatable {
    public let captureCount: Int
    public let totalBytes: Int64

    public init(captureCount: Int, totalBytes: Int64) {
        self.captureCount = captureCount
        self.totalBytes = totalBytes
    }
}

public enum CaptureStoreError: Error, CustomStringConvertible, Sendable {
    case corruptRow(String)
    case missingOriginal(String)

    public var description: String {
        switch self {
        case .corruptRow(let detail): return "Corrupt capture row: \(detail)"
        case .missingOriginal(let path): return "Missing original file: \(path)"
        }
    }
}

public actor CaptureStore {
    public nonisolated let root: URL
    public nonisolated let blobs: BlobStore
    private let database: SQLiteDatabase

    public init(root: URL) throws {
        self.root = root
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.blobs = BlobStore(root: root)

        let databaseURL = root.appendingPathComponent("library.sqlite")
        let database = try SQLiteDatabase(path: databaseURL.path)
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA foreign_keys = ON")
        try Migrations.migrate(database)
        self.database = database
    }

    /// Opens an existing library without creating folders, migrating or changing the database.
    /// For readers outside the app (the `capturist` CLI); write methods will fail.
    public init(readOnlyRoot root: URL) throws {
        self.root = root
        self.blobs = BlobStore(root: root)
        let databaseURL = root.appendingPathComponent("library.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw SQLiteError(code: 14, message: "no library at \(databaseURL.path)")
        }
        self.database = try SQLiteDatabase(path: databaseURL.path, readOnly: true)
    }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Capturist", isDirectory: true)
    }

    public static func defaultSettingsURL() -> URL {
        defaultRoot().appendingPathComponent("settings.json")
    }

    @discardableResult
    public func importFile(
        at url: URL,
        source: CaptureSource = .fileImport,
        displayName: String? = nil,
        sourceApp: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        textContent: String? = nil
    ) throws -> Capture {
        let id = UUID()
        let resolvedName = displayName ?? (url.lastPathComponent.isEmpty ? "Capture" : url.lastPathComponent)
        let blob = try blobs.importFile(at: url, preferredName: resolvedName)
        let kind = CaptureKindDetector.kind(for: url)
        let dimensions = MediaProbe.dimensions(of: blobs.url(forRelativePath: blob.relativePath))

        let capture = Capture(
            id: id,
            kind: kind,
            source: source,
            state: .local,
            originalPath: blob.relativePath,
            displayName: resolvedName,
            width: dimensions?.width ?? 0,
            height: dimensions?.height ?? 0,
            byteSize: blob.byteSize,
            checksum: blob.checksum,
            sourceApp: sourceApp,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            textContent: textContent
        )

        do {
            try insert(capture)
        } catch {
            blobs.removeFile(relativePath: blob.relativePath)
            throw error
        }
        return capture
    }

    /// Saves a text snippet as `<first line>.txt` and keeps the text searchable.
    @discardableResult
    public func importText(
        _ text: String,
        source: CaptureSource = .share,
        sourceApp: String? = nil,
        title: String? = nil
    ) throws -> Capture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snippet.txt")
        try Data(text.utf8).write(to: url)
        return try importFile(
            at: url,
            source: source,
            displayName: Self.snippetTitle(for: title?.isEmpty == false ? title! : text) + ".txt",
            sourceApp: sourceApp,
            textContent: text
        )
    }

    static func snippetTitle(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Snippet"
        return firstLine.count > 60 ? String(firstLine.prefix(57)) + "…" : firstLine
    }

    public func captures(
        kind: CaptureKind? = nil, search: String? = nil, since: Date? = nil, limit: Int? = nil
    ) throws -> [Capture] {
        var clauses = ["deleted_at IS NULL"]
        var parameters: [SQLValue] = []

        if let since {
            clauses.append("created_at >= ?")
            parameters.append(.real(since.timeIntervalSince1970))
        }

        if let kind {
            clauses.append("kind = ?")
            parameters.append(.text(kind.rawValue))
        }

        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clauses.append("(display_name LIKE ? OR source_title LIKE ? OR source_app LIKE ? OR text_content LIKE ?)")
            let pattern = "%\(search)%"
            parameters.append(.text(pattern))
            parameters.append(.text(pattern))
            parameters.append(.text(pattern))
            parameters.append(.text(pattern))
        }

        let sql = """
            SELECT * FROM captures
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY created_at DESC\(limit.map { " LIMIT \($0)" } ?? "")
            """
        return try database.query(sql, parameters).map(Self.capture(from:))
    }

    public func capture(id: UUID) throws -> Capture? {
        let rows = try database.query("SELECT * FROM captures WHERE id = ? LIMIT 1", [.text(id.uuidString)])
        return try rows.first.map(Self.capture(from:))
    }

    public func setShared(
        id: UUID,
        pageURL: String,
        fileURL: String,
        remoteID: String,
        deleteToken: String,
        expiresAt: Date
    ) throws {
        try database.execute(
            """
            UPDATE captures SET state = ?, remote_page_url = ?, remote_file_url = ?, remote_id = ?,
                remote_delete_token = ?, remote_expires_at = ?, updated_at = ? WHERE id = ?
            """,
            [.text(CaptureState.uploaded.rawValue), .text(pageURL), .text(fileURL), .text(remoteID),
             .text(deleteToken), .real(expiresAt.timeIntervalSince1970), .real(Date().timeIntervalSince1970),
             .text(id.uuidString)]
        )
    }

    public func clearShared(id: UUID) throws {
        try database.execute(
            """
            UPDATE captures SET state = ?, remote_page_url = NULL, remote_file_url = NULL, remote_id = NULL,
                remote_delete_token = NULL, remote_expires_at = NULL, updated_at = ? WHERE id = ?
            """,
            [.text(CaptureState.local.rawValue), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    public func setThumbnail(_ relativePath: String, for id: UUID) throws {
        try database.execute(
            "UPDATE captures SET thumbnail_path = ?, updated_at = ? WHERE id = ?",
            [.text(relativePath), .real(Date().timeIntervalSince1970), .text(id.uuidString)]
        )
    }

    /// Removes the file and tombstones the row.
    public func delete(id: UUID) throws {
        if let existing = try capture(id: id) {
            blobs.removeFile(relativePath: existing.originalPath)
        }
        let now = Date().timeIntervalSince1970
        try database.execute(
            "UPDATE captures SET state = ?, deleted_at = ?, updated_at = ? WHERE id = ?",
            [.text(CaptureState.deleted.rawValue), .real(now), .real(now), .text(id.uuidString)]
        )
    }

    /// One-time move from `Captures/<uuid>/original.ext` to the flat pool. Returns how many moved.
    @discardableResult
    public func flattenLegacyLayout() throws -> Int {
        // Files of already-deleted captures (old soft delete kept them) are removed.
        for row in try database.query(
            "SELECT * FROM captures WHERE deleted_at IS NOT NULL AND original_path LIKE 'Captures/%/%'"
        ) {
            blobs.removeFile(relativePath: try Self.capture(from: row).originalPath)
        }
        let rows = try database.query(
            "SELECT * FROM captures WHERE deleted_at IS NULL AND original_path LIKE 'Captures/%/%'"
        )
        var moved = 0
        for row in rows {
            let capture = try Self.capture(from: row)
            guard let newPath = try blobs.flatten(relativePath: capture.originalPath, preferredName: capture.displayName) else {
                continue
            }
            try database.execute(
                "UPDATE captures SET original_path = ?, thumbnail_path = NULL, updated_at = ? WHERE id = ?",
                [.text(newPath), .real(Date().timeIntervalSince1970), .text(capture.id.uuidString)]
            )
            moved += 1
        }
        return moved
    }

    // MARK: Clipboard history (24 h)

    /// Records copied text. Empty text is ignored; text identical to the newest clip just refreshes its time.
    @discardableResult
    public func addClip(text: String, sourceApp: String?, at date: Date = Date()) throws -> Clip? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let stored = text.count > Clip.maxCharacters ? String(text.prefix(Clip.maxCharacters)) : text
        if let newest = try clips(limit: 1).first, newest.text == stored {
            try database.execute("UPDATE clips SET created = ?, source_app = ? WHERE id = ?",
                                 [.real(date.timeIntervalSince1970), sourceApp.map(SQLValue.text) ?? .null,
                                  .text(newest.id.uuidString)])
            return Clip(id: newest.id, created: date, text: stored, sourceApp: sourceApp)
        }
        let clip = Clip(created: date, text: stored, sourceApp: sourceApp)
        try database.execute("INSERT INTO clips (id, created, text, source_app) VALUES (?, ?, ?, ?)",
                             [.text(clip.id.uuidString), .real(date.timeIntervalSince1970), .text(stored),
                              sourceApp.map(SQLValue.text) ?? .null])
        try purgeClips()
        return clip
    }

    public func clips(limit: Int = Clip.maxCount) throws -> [Clip] {
        try database.query("SELECT * FROM clips ORDER BY created DESC LIMIT ?", [.integer(Int64(limit))]).compactMap { row in
            guard let idValue = row.string("id"), let id = UUID(uuidString: idValue),
                  let created = row.double("created"), let text = row.string("text") else { return nil }
            return Clip(id: id, created: Date(timeIntervalSince1970: created), text: text, sourceApp: row.string("source_app"))
        }
    }

    public func deleteClip(id: UUID) throws {
        try database.execute("DELETE FROM clips WHERE id = ?", [.text(id.uuidString)])
    }

    public func clearClips() throws {
        try database.execute("DELETE FROM clips")
    }

    /// Drops clips older than 24 h and keeps at most `Clip.maxCount`.
    public func purgeClips(now: Date = Date()) throws {
        try database.execute("DELETE FROM clips WHERE created < ?", [.real(now.timeIntervalSince1970 - Clip.lifetime)])
        try database.execute(
            "DELETE FROM clips WHERE id NOT IN (SELECT id FROM clips ORDER BY created DESC LIMIT ?)",
            [.integer(Int64(Clip.maxCount))]
        )
    }

    /// Moves a clip into the permanent Saved snippets.
    @discardableResult
    public func pinClip(id: UUID) throws -> Capture? {
        guard let clip = try clips().first(where: { $0.id == id }) else { return nil }
        let capture = try importText(clip.text, sourceApp: clip.sourceApp)
        try deleteClip(id: id)
        return capture
    }

    public func stats() throws -> LibraryStats {
        let row = try database.query(
            "SELECT COUNT(*) AS count, COALESCE(SUM(byte_size), 0) AS bytes FROM captures WHERE deleted_at IS NULL"
        ).first
        return LibraryStats(
            captureCount: row?.int("count") ?? 0,
            totalBytes: row?.int64("bytes") ?? 0
        )
    }

    public nonisolated func fileURL(for capture: Capture) -> URL {
        blobs.url(forRelativePath: capture.originalPath)
    }

    private func insert(_ capture: Capture) throws {
        let parameters: [SQLValue] = [
            .text(capture.id.uuidString),
            .real(capture.createdAt.timeIntervalSince1970),
            .text(capture.kind.rawValue),
            .text(capture.source.rawValue),
            .text(capture.state.rawValue),
            .text(capture.originalPath),
            capture.thumbnailPath.map(SQLValue.text) ?? .null,
            capture.previewPath.map(SQLValue.text) ?? .null,
            .text(capture.displayName),
            .integer(Int64(capture.width)),
            .integer(Int64(capture.height)),
            .integer(capture.durationMilliseconds),
            .integer(capture.byteSize),
            capture.checksum.map(SQLValue.text) ?? .null,
            capture.sourceApp.map(SQLValue.text) ?? .null,
            capture.sourceTitle.map(SQLValue.text) ?? .null,
            capture.sourceURL.map(SQLValue.text) ?? .null,
            capture.remotePageURL.map(SQLValue.text) ?? .null,
            capture.remoteFileURL.map(SQLValue.text) ?? .null,
            capture.remoteID.map(SQLValue.text) ?? .null,
            capture.failureReason.map(SQLValue.text) ?? .null,
            .null,
            .real(capture.updatedAt.timeIntervalSince1970),
            .integer(capture.syncVersion),
            capture.textContent.map(SQLValue.text) ?? .null,
        ]

        try database.execute(
            """
            INSERT INTO captures (
                id, created_at, kind, source, state, original_path, thumbnail_path, preview_path,
                display_name, width, height, duration_ms, byte_size, checksum, source_app, source_title,
                source_url, remote_page_url, remote_file_url, remote_id, failure_reason, deleted_at,
                updated_at, sync_version, text_content
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            parameters
        )
    }

    private static func capture(from row: DatabaseRow) throws -> Capture {
        guard let idValue = row.string("id"), let id = UUID(uuidString: idValue) else {
            throw CaptureStoreError.corruptRow("invalid id")
        }
        guard let createdAt = row.double("created_at") else {
            throw CaptureStoreError.corruptRow("missing created_at")
        }
        guard let kindValue = row.string("kind"), let kind = CaptureKind(rawValue: kindValue) else {
            throw CaptureStoreError.corruptRow("invalid kind")
        }
        // Values added by newer versions (e.g. source "agent") must not break older readers:
        // fall back instead of failing the whole library.
        let source = row.string("source").flatMap(CaptureSource.init(rawValue:)) ?? .fileImport
        let state = row.string("state").flatMap(CaptureState.init(rawValue:)) ?? .local
        guard let originalPath = row.string("original_path") else {
            throw CaptureStoreError.corruptRow("missing original_path")
        }
        guard let displayName = row.string("display_name") else {
            throw CaptureStoreError.corruptRow("missing display_name")
        }

        return Capture(
            id: id,
            createdAt: Date(timeIntervalSince1970: createdAt),
            kind: kind,
            source: source,
            state: state,
            originalPath: originalPath,
            thumbnailPath: row.string("thumbnail_path"),
            previewPath: row.string("preview_path"),
            displayName: displayName,
            width: row.int("width") ?? 0,
            height: row.int("height") ?? 0,
            durationMilliseconds: row.int64("duration_ms") ?? 0,
            byteSize: row.int64("byte_size") ?? 0,
            checksum: row.string("checksum"),
            sourceApp: row.string("source_app"),
            sourceTitle: row.string("source_title"),
            sourceURL: row.string("source_url"),
            remotePageURL: row.string("remote_page_url"),
            remoteFileURL: row.string("remote_file_url"),
            remoteID: row.string("remote_id"),
            failureReason: row.string("failure_reason"),
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? createdAt),
            syncVersion: row.int64("sync_version") ?? 0,
            textContent: row.string("text_content"),
            remoteDeleteToken: row.string("remote_delete_token"),
            remoteExpiresAt: row.double("remote_expires_at").map { Date(timeIntervalSince1970: $0) }
        )
    }
}
