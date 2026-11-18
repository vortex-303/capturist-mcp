import CapturistCore
import Foundation

/// `library.json` in the library root: where the user-visible files live (e.g. ~/Capturist).
/// Read by the app, the CLI and the MCP server, so every reader resolves the same paths.
public enum LibraryConfig {
    public static let fileName = "library.json"
    /// Marks a folder as a Capturist files folder: `{"bundleID": "…"}`.
    public static let markerName = ".capturist-library"

    struct Contents: Codable { var files: String? }

    public static func filesFolder(in root: URL) -> URL? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              let path = contents.files, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func write(filesFolder: URL?, in root: URL) throws {
        let url = root.appendingPathComponent(fileName)
        guard let filesFolder else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(Contents(files: filesFolder.path)).write(to: url, options: .atomic)
    }

    /// The bundle id that owns a files folder, if it's marked as one.
    public static func owner(of folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(markerName)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["bundleID"] as? String
    }

    public static func mark(_ folder: URL, owner bundleID: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["bundleID": bundleID])
        try data.write(to: folder.appendingPathComponent(markerName), options: .atomic)
    }

    /// Files the library ignores in its folder: hidden files, our marker, unfinished downloads.
    static func isIgnored(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["download", "crdownload", "part", "partial", "tmp"].contains(ext)
    }
}

public struct ReconcileResult: Sendable, Equatable {
    public var added = 0
    public var renamed = 0
    public var removed = 0
    /// True when the check was skipped because the folder looked unavailable (nothing changed).
    public var skipped = false
    public var changed: Bool { added + renamed + removed > 0 }
}

extension CaptureStore {
    /// The folder the user sees (nil while files still live inside the library root).
    public nonisolated var filesFolder: URL? { blobs.filesFolder }
    public nonisolated var filesDirectory: URL { blobs.capturesDirectory }

    /// Moves every capture file into `folder` (created if needed), then records it in `library.json`.
    /// Files keep their names unless one is taken in the new folder (then " 2"…, and the row follows).
    /// Returns how many files moved. Rows whose file is already missing are left alone.
    @discardableResult
    public func relocateFiles(to folder: URL, owner bundleID: String) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let current = blobs.capturesDirectory.standardizedFileURL
        if folder.standardizedFileURL == current { return 0 }

        var moved = 0
        let rows = try database.query("SELECT * FROM captures WHERE deleted_at IS NULL AND original_path LIKE 'Captures/%'")
        for row in rows {
            let capture = try Self.capture(from: row)
            let source = blobs.url(forRelativePath: capture.originalPath)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let name = source.lastPathComponent
            let ext = source.pathExtension
            let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            let fileName = BlobStore.uniqueFileName(base: base, fileExtension: ext, in: folder)
            let destination = folder.appendingPathComponent(fileName)
            let size = (try? fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value
            try fileManager.moveItem(at: source, to: destination)
            let movedSize = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            guard movedSize == size else {
                throw CaptureStoreError.missingOriginal("\(destination.path) (size changed while moving)")
            }
            let newPath = BlobStore.prefix + fileName
            if newPath != capture.originalPath {
                try database.execute("UPDATE captures SET original_path = ?, updated_at = ? WHERE id = ?",
                                     [.text(newPath), .real(Date().timeIntervalSince1970), .text(capture.id.uuidString)])
            }
            moved += 1
        }
        try LibraryConfig.mark(folder, owner: bundleID)
        try LibraryConfig.write(filesFolder: folder, in: root)
        blobs.location.set(folder)

        // The old folder goes once it holds nothing but our marker / Finder litter.
        let leftovers = ((try? fileManager.contentsOfDirectory(atPath: current.path)) ?? [])
            .filter { $0 != LibraryConfig.markerName && $0 != ".DS_Store" }
        if leftovers.isEmpty { try? fileManager.removeItem(at: current) }
        return moved
    }

    /// Brings the library in line with its files folder after changes made in Finder:
    /// new files are added (not copied), renamed files follow (matched by checksum), deleted files leave the library.
    /// Does nothing without a files folder, or when the folder looks unavailable.
    @discardableResult
    public func reconcileFilesFolder() throws -> ReconcileResult {
        var result = ReconcileResult()
        guard let folder = blobs.filesFolder else { return result }
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else {
            result.skipped = true
            return result
        }
        let files = Set(names.filter { name in
            guard !LibraryConfig.isIgnored(name) else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        })

        let rows = try database.query("SELECT * FROM captures WHERE deleted_at IS NULL AND original_path LIKE 'Captures/%'")
        let captures = try rows.map(Self.capture(from:))
        var known = Set<String>()
        var missing: [Capture] = []
        for capture in captures {
            let name = String(capture.originalPath.dropFirst(BlobStore.prefix.count))
            if files.contains(name) { known.insert(name) } else if !name.contains("/") { missing.append(capture) }
        }
        var unknown = files.subtracting(known)

        // Safety: if most files vanished at once, the folder is probably unmounted or not readable.
        if captures.count >= 5, missing.count * 2 > captures.count {
            result.skipped = true
            return result
        }

        let now = Date().timeIntervalSince1970
        // Renames: a missing row whose checksum matches a new file.
        if !missing.isEmpty, !unknown.isEmpty {
            var byChecksum: [String: String] = [:]
            for name in unknown {
                if let sum = try? BlobStore.sha256(of: folder.appendingPathComponent(name)) { byChecksum[sum] = name }
            }
            missing.removeAll { capture in
                guard let sum = capture.checksum, let name = byChecksum.removeValue(forKey: sum) else { return false }
                unknown.remove(name)
                let display = Self.displayName(forFile: name, previous: capture.displayName)
                try? database.execute("UPDATE captures SET original_path = ?, display_name = ?, updated_at = ? WHERE id = ?",
                                      [.text(BlobStore.prefix + name), .text(display), .real(now), .text(capture.id.uuidString)])
                result.renamed += 1
                return true
            }
        }
        // Deleted in Finder: the row goes (the file is already gone).
        for capture in missing {
            try database.execute("UPDATE captures SET state = ?, deleted_at = ?, updated_at = ? WHERE id = ?",
                                 [.text(CaptureState.deleted.rawValue), .real(now), .real(now), .text(capture.id.uuidString)])
            result.removed += 1
        }
        // Added in Finder: a row pointing at the file where it is.
        for name in unknown.sorted() {
            try adoptFile(named: name, in: folder)
            result.added += 1
        }
        return result
    }

    private func adoptFile(named name: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(name)
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let kind = CaptureKindDetector.kind(for: url)
        let dimensions = MediaProbe.dimensions(of: url)
        var text: String?
        if kind == .text, ((attributes?[.size] as? NSNumber)?.intValue ?? 0) < 1_000_000 {
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        let created = (attributes?[.creationDate] as? Date) ?? Date()
        let capture = Capture(
            id: UUID(),
            createdAt: created,
            kind: kind,
            source: .fileImport,
            state: .local,
            originalPath: BlobStore.prefix + name,
            displayName: Self.displayName(forFile: name, previous: nil, kind: kind),
            width: dimensions?.width ?? 0,
            height: dimensions?.height ?? 0,
            byteSize: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            checksum: try? BlobStore.sha256(of: url),
            sourceApp: "Finder",
            textContent: text
        )
        try insert(capture)
    }

    /// Snippets keep ".txt" in their display name; other captures show the name without the extension.
    static func displayName(forFile name: String, previous: String?, kind: CaptureKind? = nil) -> String {
        let ext = (name as NSString).pathExtension
        let stripped = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        if let previous { return previous.lowercased().hasSuffix("." + ext.lowercased()) && !ext.isEmpty ? name : stripped }
        return kind == .text ? name : stripped
    }
}
