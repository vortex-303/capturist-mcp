import CoreGraphics
import Foundation
import ImageIO

public struct MediaDimensions: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum MediaProbe {
    public static func dimensions(of url: URL) -> MediaDimensions? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            if width > 0, height > 0 {
                return MediaDimensions(width: width, height: height)
            }
        }

        guard url.pathExtension.lowercased() == "pdf",
              let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else {
            return nil
        }
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width.rounded())
        let height = Int(box.height.rounded())
        guard width > 0, height > 0 else { return nil }
        return MediaDimensions(width: width, height: height)
    }
}
