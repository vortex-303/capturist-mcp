import Foundation

public enum LinkFormatter {
    public static func pageURL(for capture: Capture) -> URL? {
        guard let raw = capture.remotePageURL else { return nil }
        return URL(string: raw)
    }

    public static func fileURL(for capture: Capture) -> URL? {
        guard let raw = capture.remoteFileURL else { return nil }
        return URL(string: raw)
    }

    public static func preferredURL(for capture: Capture, mode: CopyMode) -> URL? {
        switch mode {
        case .pageURL:
            return pageURL(for: capture) ?? fileURL(for: capture)
        case .directFileURL:
            return fileURL(for: capture) ?? pageURL(for: capture)
        }
    }

    public static func title(for capture: Capture) -> String {
        if let title = capture.sourceTitle, !title.isEmpty { return title }
        return capture.displayName
    }

    public static func markdown(for capture: Capture, mode: CopyMode) -> String? {
        guard let url = preferredURL(for: capture, mode: mode) else { return nil }
        let alt = escapeMarkdown(title(for: capture))
        return "![\(alt)](\(url.absoluteString))"
    }

    public static func html(for capture: Capture, mode: CopyMode, width: Int? = nil) -> String? {
        guard let url = preferredURL(for: capture, mode: mode) else { return nil }
        let alt = escapeHTML(title(for: capture))
        let widthAttribute = width.map { " width=\"\($0)\"" } ?? ""
        switch capture.kind {
        case .video:
            return "<video src=\"\(escapeHTML(url.absoluteString))\" controls\(widthAttribute)></video>"
        case .image, .pdf, .file, .text:
            return "<img src=\"\(escapeHTML(url.absoluteString))\" alt=\"\(alt)\"\(widthAttribute)>"
        }
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeMarkdown(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
