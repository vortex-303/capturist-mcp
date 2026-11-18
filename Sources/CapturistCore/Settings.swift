import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var defaultStillMode: CaptureMode
    public var defaultVideoMode: CaptureMode
    public var countdownSeconds: Int
    public var captureSRGB: Bool
    public var shutterSound: Bool
    public var highQualityUploads: Bool
    public var highQualityThresholdMB: Int
    public var standardThresholdMB: Int
    public var copyMode: CopyMode
    public var postCaptureAction: PostCaptureAction
    public var maxFramerate: Int
    public var maxRecordingMinutes: Int
    public var launchAtLogin: Bool
    public var syncMode: SyncMode

    public init(
        defaultStillMode: CaptureMode = .quick,
        defaultVideoMode: CaptureMode = .quick,
        countdownSeconds: Int = 0,
        captureSRGB: Bool = false,
        shutterSound: Bool = true,
        highQualityUploads: Bool = false,
        highQualityThresholdMB: Int = 10,
        standardThresholdMB: Int = 1,
        copyMode: CopyMode = .pageURL,
        postCaptureAction: PostCaptureAction = .notification,
        maxFramerate: Int = 30,
        maxRecordingMinutes: Int = 5,
        launchAtLogin: Bool = false,
        syncMode: SyncMode = .localOnly
    ) {
        self.defaultStillMode = defaultStillMode
        self.defaultVideoMode = defaultVideoMode
        self.countdownSeconds = countdownSeconds
        self.captureSRGB = captureSRGB
        self.shutterSound = shutterSound
        self.highQualityUploads = highQualityUploads
        self.highQualityThresholdMB = highQualityThresholdMB
        self.standardThresholdMB = standardThresholdMB
        self.copyMode = copyMode
        self.postCaptureAction = postCaptureAction
        self.maxFramerate = maxFramerate
        self.maxRecordingMinutes = maxRecordingMinutes
        self.launchAtLogin = launchAtLogin
        self.syncMode = syncMode
    }

    public static let defaults = AppSettings()

    public var compressionThresholdMB: Int {
        highQualityUploads ? highQualityThresholdMB : standardThresholdMB
    }
}

public actor SettingsStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? decoder.decode(AppSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
