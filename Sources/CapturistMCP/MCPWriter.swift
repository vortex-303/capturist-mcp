import CapturistCore
import Foundation

/// Optional write access for agents ("save to Capturist"). The app supplies it; the CLI stays read-only.
public struct MCPWriter: Sendable {
    /// The user's "Allow agents to add to my library" switch.
    public let isEnabled: @Sendable () async -> Bool
    public let saveText: @Sendable (_ text: String, _ title: String?, _ client: String?) async throws -> Capture
    public let saveFile: @Sendable (_ data: Data, _ fileExtension: String, _ title: String?, _ client: String?) async throws -> Capture

    public init(
        isEnabled: @escaping @Sendable () async -> Bool,
        saveText: @escaping @Sendable (String, String?, String?) async throws -> Capture,
        saveFile: @escaping @Sendable (Data, String, String?, String?) async throws -> Capture
    ) {
        self.isEnabled = isEnabled
        self.saveText = saveText
        self.saveFile = saveFile
    }

    public static let maxFileBytes = 10 * 1024 * 1024
    public static let maxTextCharacters = 200_000
    public static let allowedTypes: [String: String] = ["image/png": "png", "image/jpeg": "jpg", "application/pdf": "pdf"]
}

public enum SaveError: Error, Sendable {
    case rateLimited
    case tooLarge
    case unsupported(String)

    public var message: String {
        switch self {
        case .rateLimited: return "Too many saves in the last hour. Try again later."
        case .tooLarge: return "That's too big to save (max 10 MB, or 200,000 characters of text)."
        case .unsupported(let type): return "Can't save \(type). Use image/png, image/jpeg or application/pdf."
        }
    }
}
