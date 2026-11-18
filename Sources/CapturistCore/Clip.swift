import Foundation

/// A piece of copied text kept in the 24-hour clipboard history.
public struct Clip: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var created: Date
    public var text: String
    public var sourceApp: String?

    public init(id: UUID = UUID(), created: Date = Date(), text: String, sourceApp: String? = nil) {
        self.id = id
        self.created = created
        self.text = text
        self.sourceApp = sourceApp
    }

    /// First non-empty line, trimmed and shortened for list rows.
    public var title: String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    public static let lifetime: TimeInterval = 24 * 3600
    public static let maxCharacters = 100_000
    public static let maxCount = 500
}
