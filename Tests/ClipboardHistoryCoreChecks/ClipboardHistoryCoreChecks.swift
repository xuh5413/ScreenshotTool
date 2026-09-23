import Foundation
import ClipboardHistoryCore

@main
struct ClipboardHistoryCoreChecks {
    static func main() throws {
        let source = ClipboardSource(appName: "Notes", bundleID: "com.apple.Notes")
        let first = ClipboardCandidate(
            payload: .text("hello\r\nworld"),
            source: source,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let second = ClipboardCandidate(
            payload: .text("hello\nworld"),
            source: source,
            capturedAt: Date(timeIntervalSince1970: 2)
        )
        let a = try ClipboardContentNormalizer.normalized(candidate: first)
        let b = try ClipboardContentNormalizer.normalized(candidate: second)
        expect(a.contentHash == b.contentHash, "line endings must normalize before hashing")
        expect(a.plainText == "hello\nworld", "normalized text must be stored")

        let link = try ClipboardContentNormalizer.normalized(candidate: ClipboardCandidate(
            payload: .link(URL(string: "HTTPS://Example.COM/path")!),
            source: source,
            capturedAt: .now
        ))
        expect(
            link.kind == .link && link.plainText == "https://example.com/path",
            "links must have a canonical representation"
        )

        let files = try ClipboardContentNormalizer.normalized(candidate: ClipboardCandidate(
            payload: .files([
                URL(fileURLWithPath: "/tmp/a"),
                URL(fileURLWithPath: "/tmp/b")
            ]),
            source: source,
            capturedAt: .now
        ))
        expect(
            files.fileURLs.count == 2 && files.kind == .files,
            "file order and type must survive normalization"
        )

        expectThrowsEmptyContent()
        print("✅ ClipboardHistoryCoreChecks passed")
    }

    private static func expectThrowsEmptyContent() {
        let source = ClipboardSource(appName: nil, bundleID: nil)
        do {
            _ = try ClipboardContentNormalizer.normalized(candidate: ClipboardCandidate(
                payload: .text(""),
                source: source,
                capturedAt: .now
            ))
            fatalError("❌ empty text must be rejected")
        } catch ClipboardNormalizationError.emptyContent {
            // Expected.
        } catch {
            fatalError("❌ wrong empty-content error: \(error)")
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("❌ \(message)") }
    }
}
