import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads the text (and QR / barcodes) in a capture with Apple Vision, on device.
/// Shared by the `capturist` CLI and, later, the app's background indexer.
public enum TextRecognizer {
    public struct Result: Sendable, Equatable {
        public var text: String
        public var barcodes: [String]

        public var combined: String {
            barcodes.isEmpty ? text : text + (text.isEmpty ? "" : "\n") + barcodes.joined(separator: "\n")
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)

        public var description: String {
            switch self {
            case .unreadable(let path): return "Can't read image at \(path)"
            }
        }
    }

    /// Maximum PDF pages read per document.
    public static let maxPDFPages = 5

    public static func recognize(fileURL: URL) throws -> Result {
        let images: [CGImage]
        if fileURL.pathExtension.lowercased() == "pdf" {
            images = pdfPages(fileURL)
        } else if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            images = [image]
        } else {
            images = []
        }
        guard !images.isEmpty else { throw Failure.unreadable(fileURL.path) }

        var texts: [String] = []
        var codes: [String] = []
        for image in images {
            let page = try recognize(image: image)
            if !page.text.isEmpty { texts.append(page.text) }
            codes.append(contentsOf: page.barcodes)
        }
        return Result(text: texts.joined(separator: "\n\n"), barcodes: Array(NSOrderedSet(array: codes)) as? [String] ?? codes)
    }

    public static func recognize(image: CGImage) throws -> Result {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true

        let barcodeRequest = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([textRequest, barcodeRequest])

        let lines = (textRequest.results ?? [])
            .compactMap { observation -> (CGRect, String)? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return (observation.boundingBox, candidate.string)
            }
            .sorted { lhs, rhs in
                // Vision's origin is bottom-left: higher maxY comes first; same row → left to right.
                abs(lhs.0.midY - rhs.0.midY) > min(lhs.0.height, rhs.0.height) / 2
                    ? lhs.0.midY > rhs.0.midY
                    : lhs.0.minX < rhs.0.minX
            }
            .map(\.1)

        let barcodes = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
        return Result(text: lines.joined(separator: "\n"), barcodes: barcodes)
    }

    private static func pdfPages(_ url: URL) -> [CGImage] {
        guard let document = CGPDFDocument(url as CFURL) else { return [] }
        let count = min(document.numberOfPages, maxPDFPages)
        guard count > 0 else { return [] }
        return (1...count).compactMap { number in
            guard let page = document.page(at: number) else { return nil }
            let box = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 2
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard width > 0, height > 0,
                  let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return nil }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            return context.makeImage()
        }
    }
}
