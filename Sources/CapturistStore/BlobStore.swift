import CryptoKit
import Foundation
import CapturistCore

public struct ImportedBlob: Sendable {
    public let relativePath: String
    public let byteSize: Int64
    public let checksum: String
    public let fileExtension: String
}

public struct BlobStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var capturesDirectory: URL {
        root.appendingPathComponent("Captures", isDirectory: true)
    }

    public func url(forRelativePath path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// Copies `source` into the flat `Captures/` pool as `<preferredName>.<ext>`,
    /// adding " 2", " 3"… when the name is taken.
    public func importFile(at source: URL, preferredName: String? = nil) throws -> ImportedBlob {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        let kind = CaptureKindDetector.kind(for: source)
        let rawExtension = source.pathExtension.lowercased()
        let fileExtension = rawExtension.isEmpty ? CaptureKindDetector.fileExtension(for: kind) : rawExtension

        try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
        let base = Self.sanitizedBaseName(preferredName ?? source.lastPathComponent, fileExtension: fileExtension)
        let fileName = uniqueFileName(base: base, fileExtension: fileExtension)
        let destination = capturesDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: destination)

        let byteSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        let checksum = try Self.sha256(of: destination)
        return ImportedBlob(
            relativePath: "Captures/\(fileName)",
            byteSize: byteSize,
            checksum: checksum,
            fileExtension: fileExtension
        )
    }

    /// Removes a capture's file. Legacy `Captures/<uuid>/original.ext` paths remove their folder.
    public func removeFile(relativePath: String) {
        let url = url(forRelativePath: relativePath)
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL != capturesDirectory.standardizedFileURL,
           UUID(uuidString: parent.lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: parent)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Moves a legacy per-capture folder file into the flat pool. Returns the new relative path.
    public func flatten(relativePath: String, preferredName: String) throws -> String? {
        let url = url(forRelativePath: relativePath)
        let parent = url.deletingLastPathComponent()
        guard UUID(uuidString: parent.lastPathComponent) != nil,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let ext = url.pathExtension.lowercased()
        let fileName = uniqueFileName(base: Self.sanitizedBaseName(preferredName, fileExtension: ext), fileExtension: ext)
        try FileManager.default.moveItem(at: url, to: capturesDirectory.appendingPathComponent(fileName))
        try? FileManager.default.removeItem(at: parent)
        return "Captures/\(fileName)"
    }

    static func sanitizedBaseName(_ name: String, fileExtension: String) -> String {
        var base = name
        if !fileExtension.isEmpty, base.lowercased().hasSuffix("." + fileExtension) {
            base = String(base.dropLast(fileExtension.count + 1))
        }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        base = base.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if base.isEmpty { base = "Capture" }
        return String(base.prefix(180))
    }

    private func uniqueFileName(base: String, fileExtension: String) -> String {
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        var candidate = base + suffix
        var counter = 2
        while FileManager.default.fileExists(atPath: capturesDirectory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(counter)\(suffix)"
            counter += 1
        }
        return candidate
    }

    public static func sha256(of url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
