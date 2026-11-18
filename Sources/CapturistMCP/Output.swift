import CapturistCore
import Foundation

/// Stable JSON shape for agents and scripts.
public struct CaptureJSON: Encodable, Sendable {
    public let id: String
    public let shortId: String
    public let created: String
    public let kind: String
    public let name: String
    public let app: String?
    public let title: String?
    public let url: String?
    public let path: String
    public let width: Int?
    public let height: Int?
    public let size: Int64
    public let shareUrl: String?
    public var text: String?
}

public struct ClipJSON: Encodable, Sendable {
    public let id: String
    public let created: String
    public let app: String?
    public let text: String
}

public enum Output {
    nonisolated(unsafe) public static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    public static func json(_ capture: Capture, path: URL, text: String? = nil) -> CaptureJSON {
        CaptureJSON(
            id: capture.id.uuidString.lowercased(), shortId: short(capture.id),
            created: iso.string(from: capture.createdAt), kind: capture.kind.rawValue,
            name: capture.displayName, app: capture.sourceApp, title: capture.sourceTitle,
            url: capture.sourceURL, path: path.path,
            width: capture.width > 0 ? capture.width : nil, height: capture.height > 0 ? capture.height : nil,
            size: capture.byteSize, shareUrl: capture.activeShareURL?.absoluteString, text: text
        )
    }

    public static func json(_ clip: Clip) -> ClipJSON {
        ClipJSON(id: short(clip.id), created: iso.string(from: clip.created), app: clip.sourceApp, text: clip.text)
    }

    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    public static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) d ago"
        }
    }

    /// One line per capture: `abcd1234  image  3 min ago  Safari  "Name"`.
    public static func line(_ capture: Capture) -> String {
        var parts = [short(capture.id), capture.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0), ago(capture.createdAt)]
        if let app = capture.sourceApp, !app.isEmpty { parts.append(app) }
        parts.append("\"\(capture.displayName)\"")
        return parts.joined(separator: "  ")
    }

    /// Parses `30m`, `2h`, `3d`, `1w`, or an ISO date.
    public static func since(_ text: String) throws -> Date {
        let units: [Character: Double] = ["m": 60, "h": 3600, "d": 86400, "w": 604_800]
        if let unit = text.last, let size = units[unit], let amount = Double(text.dropLast()), amount >= 0 {
            return Date().addingTimeInterval(-amount * size)
        }
        if let date = iso.date(from: text) { return date }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: text) { return date }
        throw LookupError.badInput("Can't read --since '\(text)'. Use 30m, 2h, 3d, 1w or 2026-11-17.")
    }
}
