import CoreGraphics

public enum LongScreenshotImageComposer {
    public static func compose(
        segments: [CGImage],
        maximumPixelWidth: Int? = nil,
        maximumPixelHeight: Int? = nil
    ) -> CGImage? {
        guard let first = segments.first else { return nil }
        let sourceWidth = first.width
        let sourceHeight = segments.reduce(0) { $0 + $1.height }
        guard sourceWidth > 0, sourceHeight > 0,
              segments.allSatisfy({ $0.width == sourceWidth && $0.height > 0 }) else { return nil }

        var outputScale = 1.0
        if let maximumPixelWidth {
            outputScale = min(outputScale, Double(maximumPixelWidth) / Double(sourceWidth))
        }
        if let maximumPixelHeight {
            outputScale = min(outputScale, Double(maximumPixelHeight) / Double(sourceHeight))
        }
        let minimumScale = 1 / Double(max(sourceWidth, sourceHeight))
        outputScale = min(1, max(outputScale, minimumScale))

        let outputWidth = max(1, Int((Double(sourceWidth) * outputScale).rounded()))
        let outputHeight = max(1, Int((Double(sourceHeight) * outputScale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputWidth * 4,
            space: first.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        context.interpolationQuality = outputScale < 1 ? .medium : .none
        var sourceY = 0
        for segment in segments {
            let startY = Int((Double(sourceY) * outputScale).rounded())
            sourceY += segment.height
            let endY = Int((Double(sourceY) * outputScale).rounded())
            let destinationHeight = endY - startY
            guard destinationHeight > 0 else { continue }
            context.draw(segment, in: CGRect(
                x: 0,
                y: outputHeight - endY,
                width: outputWidth,
                height: destinationHeight
            ))
        }
        return context.makeImage()
    }
}
