import Foundation
import Testing
@testable import CapturistCore

@Suite("Core models and formatting")
struct CapturistCoreTests {
    @Test("kind detection follows file extension")
    func kindDetection() {
        #expect(CaptureKindDetector.kind(for: URL(fileURLWithPath: "/tmp/a.png")) == .image)
        #expect(CaptureKindDetector.kind(for: URL(fileURLWithPath: "/tmp/a.mov")) == .video)
        #expect(CaptureKindDetector.kind(for: URL(fileURLWithPath: "/tmp/a.pdf")) == .pdf)
        #expect(CaptureKindDetector.kind(for: URL(fileURLWithPath: "/tmp/a.zip")) == .file)
    }

    @Test("markdown and html embeds use the preferred URL")
    func embeds() throws {
        let capture = Capture(
            kind: .image,
            source: .fileImport,
            originalPath: "Captures/x/original.png",
            displayName: "shot.png",
            remotePageURL: "https://example.com/c/1",
            remoteFileURL: "https://cdn.example.com/1.png"
        )

        let markdown = try #require(LinkFormatter.markdown(for: capture, mode: .directFileURL))
        #expect(markdown == "![shot.png](https://cdn.example.com/1.png)")

        let html = try #require(LinkFormatter.html(for: capture, mode: .pageURL, width: 640))
        #expect(html.contains("src=\"https://example.com/c/1\""))
        #expect(html.contains("width=\"640\""))
    }

    @Test("settings store round-trips")
    func settingsRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: url)
        var settings = AppSettings.defaults
        settings.highQualityUploads = true
        settings.countdownSeconds = 3
        settings.copyMode = .directFileURL

        try await store.save(settings)
        let loaded = await store.load()
        #expect(loaded == settings)
    }

    @Test("selection converts to a top-left pixel crop")
    func cropGeometry() {
        let rect = CaptureGeometry.pixelCropRect(
            selection: CGRect(x: 100, y: 100, width: 200, height: 100),
            screenSize: CGSize(width: 1_000, height: 800),
            imageSize: CGSize(width: 2_000, height: 1_600)
        )
        #expect(rect == CGRect(x: 200, y: 1_200, width: 400, height: 200))
    }

    @Test("crop clamps to image bounds")
    func cropClamp() {
        let rect = CaptureGeometry.pixelCropRect(
            selection: CGRect(x: 900, y: 700, width: 300, height: 300),
            screenSize: CGSize(width: 1_000, height: 800),
            imageSize: CGSize(width: 1_000, height: 800)
        )
        #expect(rect == CGRect(x: 900, y: 0, width: 100, height: 100))
    }

    @Test("compression threshold follows quality mode")
    func threshold() {
        var settings = AppSettings.defaults
        settings.highQualityUploads = false
        settings.standardThresholdMB = 1
        #expect(settings.compressionThresholdMB == 1)

        settings.highQualityUploads = true
        settings.highQualityThresholdMB = 10
        #expect(settings.compressionThresholdMB == 10)
    }
}

@Suite("Service key equivalents")
struct ServiceKeyTests {
    @Test func toPBS() {
        #expect(ServiceKey.pbs(from: "⌥⌘7") == "@~7")
        #expect(ServiceKey.pbs(from: "⌘⌥7") == "@~7")
        #expect(ServiceKey.pbs(from: "⌃⇧⌘S") == "@^$s")
        #expect(ServiceKey.pbs(from: "⌥7") == nil)      // Services need ⌘
        #expect(ServiceKey.pbs(from: "⌥⌘") == nil)
    }

    @Test func toDisplay() {
        #expect(ServiceKey.display(fromPBS: "@~7") == "⌥⌘7")
        #expect(ServiceKey.display(fromPBS: "@^$s") == "⌃⇧⌘S")
    }
}
