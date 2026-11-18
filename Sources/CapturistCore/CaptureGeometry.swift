import CoreGraphics

public enum CaptureGeometry {
    /// Converts an AppKit screen-local selection (origin bottom-left)
    /// to a pixel crop rectangle for a top-left-origin CGImage.
    public static func pixelCropRect(
        selection: CGRect,
        screenSize: CGSize,
        imageSize: CGSize
    ) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0,
              imageSize.width > 0, imageSize.height > 0,
              selection.width > 0, selection.height > 0 else {
            return .zero
        }

        let scaleX = imageSize.width / screenSize.width
        let scaleY = imageSize.height / screenSize.height

        let rect = CGRect(
            x: selection.minX * scaleX,
            y: (screenSize.height - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        ).integral

        return rect.intersection(CGRect(origin: .zero, size: imageSize))
    }
}
