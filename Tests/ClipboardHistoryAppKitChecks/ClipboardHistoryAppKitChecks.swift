import AppKit
import ClipboardHistoryAppKit
import ClipboardHistoryCore
import Foundation

@main
@MainActor
struct ClipboardHistoryAppKitChecks {
    static func main() async throws {
        let source = ClipboardSource(appName: "Notes", bundleID: "com.apple.Notes")
        try checkPasteboardDecoding(source: source)
        try checkPasteboardRestore(source: source)
        try await checkMonitorSuppressionAndPriority(source: source)
        checkPanelState()
        await ClipboardPanelPresentationChecks.run()
        await checkHotkeyRoutingAndStartupIsolation()
        print("✅ ClipboardHistoryAppKitChecks passed")
    }

    private static func checkHotkeyRoutingAndStartupIsolation() async {
        var fired = false
        let router = ClipboardHotkeyActionRouter(expectedSignature: 0x434C4950, expectedID: 2) {
            fired = true
        }
        expect(
            !router.handle(signature: 0x5352544C, id: 2),
            "a screenshot signature with the clipboard ID must not be handled"
        )
        expect(!fired, "a mismatched signature must not trigger clipboard history")
        expect(
            router.handle(signature: 0x434C4950, id: 2),
            "the exact clipboard signature and ID must be handled"
        )
        expect(fired, "the exact clipboard signature and ID must trigger clipboard history")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-startup-check-\(UUID().uuidString)", isDirectory: true)
        let result = await ClipboardHistoryStartup.start(rootURL: root) { _, _ in
            throw ClipboardStoreError.openFailed("fixture")
        }
        switch result {
        case .available:
            fatalError("❌ failed database startup must not create an available runtime")
        case .unavailable(let message):
            expect(message.contains("fixture"), "startup failure must preserve the database error")
        }
    }

    private static func checkPanelState() {
        let textItem = makeItem(kind: .text, plainText: "first")
        let imageItem = makeItem(kind: .image, plainText: "图片", assetPath: "image.png")
        let fileURL = URL(fileURLWithPath: "/definitely-missing/clipboard-history-file")
        let fileItem = makeItem(kind: .files, plainText: "file", fileURLs: [fileURL])

        var state = ClipboardPanelState(items: [textItem, imageItem, fileItem])
        expect(state.selectedID == textItem.id, "first item must be selected")
        state.moveSelection(by: 1)
        expect(state.selectedID == imageItem.id, "down navigation must advance")
        state.moveSelection(by: 10)
        expect(state.selectedID == fileItem.id, "selection must clamp at the end")
        state.apply(items: [fileItem], preservingSelection: true)
        expect(state.selectedID == fileItem.id, "reload must keep an available selection")
        state.apply(items: [textItem, imageItem, fileItem], preservingSelection: false)
        expect(state.select(row: 1), "double-click activation must accept an existing row")
        expect(state.selectedID == imageItem.id, "double-click activation must select the clicked row")
        expect(!state.select(row: 10), "double-click activation must reject an invalid row")
        expect(state.selectedID == imageItem.id, "an invalid double click must preserve the selection")
        state.apply(items: [], preservingSelection: true)
        expect(state.selectedID == nil, "empty results must clear selection")
        state.apply(items: [], hasAnyHistory: true, preservingSelection: true)
        expect(
            state.hasAnyHistory,
            "an empty search or filter result must not disable clearing history that still exists"
        )

    }

    private static func checkPasteboardDecoding(source: ClipboardSource) throws {
        let board = makePasteboard()
        board.clearContents()
        board.writeObjects(["hello" as NSString])
        let candidate = ClipboardPasteboardCodec.readCandidate(
            from: board,
            source: source,
            capturedAt: .now,
            policy: .default
        )
        expect(candidate?.payload == .text("hello"), "plain text must decode")

        board.clearContents()
        board.writeObjects([NSURL(fileURLWithPath: "/tmp/a"), "fallback" as NSString])
        let files = ClipboardPasteboardCodec.readCandidate(
            from: board,
            source: source,
            capturedAt: .now,
            policy: .default
        )
        expect(
            files?.payload == .files([URL(fileURLWithPath: "/tmp/a")]),
            "file URLs must outrank text"
        )

        board.clearContents()
        let concealed = NSPasteboardItem()
        concealed.setString("secret", forType: .init("org.nspasteboard.ConcealedType"))
        concealed.setString("secret", forType: .string)
        board.writeObjects([concealed])
        expect(
            ClipboardPasteboardCodec.readCandidate(
                from: board,
                source: source,
                capturedAt: .now,
                policy: .default
            ) == nil,
            "concealed data must never decode"
        )

        board.clearContents()
        board.writeObjects(["private" as NSString])
        let excluded = ClipboardPasteboardCodec.readCandidate(
            from: board,
            source: ClipboardSource(appName: "Private", bundleID: "com.example.private"),
            capturedAt: .now,
            policy: ClipboardPrivacyPolicy(excludedBundleIDs: ["com.example.private"])
        )
        expect(excluded == nil, "excluded source applications must never decode")
    }

    private static func checkPasteboardRestore(source: ClipboardSource) throws {
        let board = makePasteboard()

        let text = makeItem(kind: .text, plainText: "restored text")
        expect(ClipboardPasteboardCodec.restore(item: text, assetData: nil, to: board), "text restore must succeed")
        expect(board.string(forType: .string) == "restored text", "text restore must write string data")

        let link = makeItem(kind: .link, plainText: "https://example.com/path")
        expect(ClipboardPasteboardCodec.restore(item: link, assetData: nil, to: board), "link restore must succeed")
        expect(board.string(forType: .URL) == link.plainText, "link restore must write URL data")
        expect(board.string(forType: .string) == link.plainText, "link restore must write string data")

        let imageData = validPNGData()
        let image = makeItem(kind: .image, plainText: "图片", assetPath: "image.png", byteSize: Int64(imageData.count))
        expect(ClipboardPasteboardCodec.restore(item: image, assetData: imageData, to: board), "image restore must succeed")
        expect(board.data(forType: .png) != nil, "image restore must write PNG data")
        expect(board.data(forType: .tiff) != nil, "image restore must write TIFF compatibility data")
        board.clearContents()
        board.setString("keep existing clipboard", forType: .string)
        expect(!ClipboardPasteboardCodec.restore(item: image, assetData: nil, to: board), "missing image data must fail")
        expect(
            board.string(forType: .string) == "keep existing clipboard",
            "failed restore must preserve the existing clipboard"
        )

        let fileURLs = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]
        let files = makeItem(kind: .files, plainText: "a b", fileURLs: fileURLs)
        expect(ClipboardPasteboardCodec.restore(item: files, assetData: nil, to: board), "file restore must succeed")
        let restoredFiles = readFileURLs(from: board)
        expect(restoredFiles == fileURLs, "file restore must preserve every file URL")

        _ = source
    }

    private static func checkMonitorSuppressionAndPriority(source: ClipboardSource) async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("clipboard-monitor-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let store = ClipboardStore(
            databaseURL: root.appendingPathComponent("history.sqlite"),
            assetsDirectoryURL: root.appendingPathComponent("assets")
        )
        try await store.open()
        let board = makePasteboard()
        board.clearContents()

        let monitor = ClipboardMonitor(pasteboard: board, store: store, privacyPolicy: .default)
        var changeNotifications = 0
        monitor.onHistoryChanged = { changeNotifications += 1 }

        board.clearContents()
        board.writeObjects(["monitored text" as NSString])
        await monitor.pollNow()
        var items = try await store.query()
        expect(items.count == 1 && items[0].kind == .text, "monitor must persist a user clipboard write")
        expect(changeNotifications == 1, "monitor must notify after a stored change")

        expect(
            ClipboardPasteboardCodec.restore(item: items[0], assetData: nil, to: board),
            "monitor fixture restore must succeed"
        )
        monitor.suppress(changeCount: board.changeCount)
        await monitor.pollNow()
        items = try await store.query()
        expect(items.count == 1, "restoring history must not create another row")
        expect(changeNotifications == 1, "suppressed writes must not emit a history change")

        let mixed = NSPasteboardItem()
        mixed.setString(URL(fileURLWithPath: "/tmp/priority").absoluteString, forType: .fileURL)
        mixed.setData(validPNGData(), forType: .png)
        mixed.setString("fallback", forType: .string)
        board.clearContents()
        board.writeObjects([mixed])
        await monitor.pollNow()
        items = try await store.query()
        expect(items.count == 2, "one mixed pasteboard item must add exactly one history row")
        expect(items.first?.kind == .files, "file URLs must win mixed-representation priority")
    }

    private static func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("clipboard-check-\(UUID().uuidString)"))
    }

    private static func readFileURLs(from board: NSPasteboard) -> [URL] {
        let objects = board.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        return objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
    }

    private static func makeItem(
        kind: ClipboardItemKind,
        plainText: String,
        assetPath: String? = nil,
        fileURLs: [URL] = [],
        byteSize: Int64 = 0
    ) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            kind: kind,
            contentHash: UUID().uuidString,
            plainText: plainText,
            assetPath: assetPath,
            fileURLs: fileURLs,
            source: ClipboardSource(appName: nil, bundleID: nil),
            createdAt: .now,
            updatedAt: .now,
            lastRestoredAt: nil,
            isFavorite: false,
            byteSize: byteSize
        )
    }

    private static func validPNGData() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("❌ \(message)") }
    }
}
