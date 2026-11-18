import Foundation
import UniformTypeIdentifiers

public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
    case pdf
    case file
    case text
}

public enum CaptureSource: String, Codable, CaseIterable, Sendable {
    case region
    case window
    case screen
    case camera
    case photoLibrary
    case share
    case fileImport
    /// Saved by an AI agent through the AI Agents connection.
    case agent
    /// A regular macOS screenshot (⌘⇧3/4/5) picked up from the user's watched folder.
    case nativeScreenshot
}

public enum CaptureState: String, Codable, CaseIterable, Sendable {
    case local
    case queued
    case uploading
    case uploaded
    case failed
    case deleted
}

public enum CaptureMode: String, Codable, CaseIterable, Sendable {
    case quick
    case studio
}

public enum CopyMode: String, Codable, CaseIterable, Sendable {
    case pageURL
    case directFileURL
}

public enum PostCaptureAction: String, Codable, CaseIterable, Sendable {
    case doNothing
    case openBrowser
    case notification
    case shareLink
}

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    case localOnly
    case iCloud
    case customServer
}

public struct Capture: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var kind: CaptureKind
    public var source: CaptureSource
    public var state: CaptureState
    public var originalPath: String
    public var thumbnailPath: String?
    public var previewPath: String?
    public var displayName: String
    public var width: Int
    public var height: Int
    public var durationMilliseconds: Int64
    public var byteSize: Int64
    public var checksum: String?
    public var sourceApp: String?
    public var sourceTitle: String?
    public var sourceURL: String?
    public var remotePageURL: String?
    public var remoteFileURL: String?
    public var remoteID: String?
    public var failureReason: String?
    public var updatedAt: Date
    public var syncVersion: Int64
    /// Full text of a `.text` snippet (also stored as a .txt file).
    public var textContent: String?
    /// Secret returned by the share service; needed for Stop Sharing.
    public var remoteDeleteToken: String?
    public var remoteExpiresAt: Date?

    /// A share link that hasn't expired yet.
    public var activeShareURL: URL? {
        guard let page = remotePageURL, let expires = remoteExpiresAt, expires > Date() else { return nil }
        return URL(string: page)
    }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: CaptureKind,
        source: CaptureSource,
        state: CaptureState = .local,
        originalPath: String,
        thumbnailPath: String? = nil,
        previewPath: String? = nil,
        displayName: String,
        width: Int = 0,
        height: Int = 0,
        durationMilliseconds: Int64 = 0,
        byteSize: Int64 = 0,
        checksum: String? = nil,
        sourceApp: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        remotePageURL: String? = nil,
        remoteFileURL: String? = nil,
        remoteID: String? = nil,
        failureReason: String? = nil,
        updatedAt: Date = Date(),
        syncVersion: Int64 = 0,
        textContent: String? = nil,
        remoteDeleteToken: String? = nil,
        remoteExpiresAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.source = source
        self.state = state
        self.originalPath = originalPath
        self.thumbnailPath = thumbnailPath
        self.previewPath = previewPath
        self.displayName = displayName
        self.width = width
        self.height = height
        self.durationMilliseconds = durationMilliseconds
        self.byteSize = byteSize
        self.checksum = checksum
        self.sourceApp = sourceApp
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.remotePageURL = remotePageURL
        self.remoteFileURL = remoteFileURL
        self.remoteID = remoteID
        self.failureReason = failureReason
        self.updatedAt = updatedAt
        self.syncVersion = syncVersion
        self.textContent = textContent
        self.remoteDeleteToken = remoteDeleteToken
        self.remoteExpiresAt = remoteExpiresAt
    }
}

public enum CaptureKindDetector {
    public static func kind(for url: URL) -> CaptureKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return .file
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .plainText) { return .text }
        return .file
    }

    public static func fileExtension(for kind: CaptureKind) -> String {
        switch kind {
        case .image: return "png"
        case .video: return "mp4"
        case .pdf: return "pdf"
        case .file: return "dat"
        case .text: return "txt"
        }
    }
}

public enum DisplayFormat {
    public static func byteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func duration(milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    public static func dimensions(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width) x \(height)"
    }
}
