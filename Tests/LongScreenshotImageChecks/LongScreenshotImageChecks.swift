import AppKit
import CoreGraphics
import Foundation
import LongScreenshotCore

@main
struct LongScreenshotImageChecks {
    static func main() {
        let red = makeImage(rows: [[255, 0, 0, 255]])
        let blue = makeImage(rows: [[0, 0, 255, 255]])
        let combined = LongScreenshotImageComposer.compose(segments: [red, blue])
        expectTopRedBottomBlue(combined, "separate segments must remain top to bottom")

        let original = makeImage(rows: [[255, 0, 0, 255], [0, 0, 255, 255]])
        let preview = LongScreenshotImageComposer.compose(segments: [original])
        expectTopRedBottomBlue(preview, "single-frame preview must not be inverted")
        print("✅ LongScreenshotImageChecks passed")
    }

    private static func makeImage(rows: [[UInt8]]) -> CGImage {
        let pixels = rows.flatMap { $0 }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: 1, height: rows.count,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private static func expectTopRedBottomBlue(_ image: CGImage?, _ message: String) {
        guard let image, image.height == 2 else { fatalError(message) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let top = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB),
              let bottom = bitmap.colorAt(x: 0, y: 1)?.usingColorSpace(.deviceRGB),
              top.redComponent > 0.9, top.blueComponent < 0.1,
              bottom.blueComponent > 0.9, bottom.redComponent < 0.1 else {
            fatalError(message)
        }
    }
}
