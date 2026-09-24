import AppKit
import ClipboardHistoryAppKit
import ClipboardHistoryCore
import Foundation

@MainActor
enum ClipboardPanelPresentationChecks {
    static func run() async {
        checkSearchSpaceRemainsTextInput()
        checkCompactPanelLayout()
        checkPanelIsDraggableAndRounded()
        checkFilterControlUsesEqualCapsuleSegments()
        checkClearHistoryControls()
        checkReloadsCannotOverwriteClearResults()
        checkImmediateHoverPreviewPolicy()
        checkLongTextAndImageRowPresentation()
        await checkThumbnailDecodingAndCaching()
    }

    private static func checkCompactPanelLayout() {
        expect(ClipboardPanelLayout.defaultSize.width == 470, "clipboard panel must use the approved compact width")
        expect(ClipboardPanelLayout.defaultSize.height == 410, "clipboard panel must use the approved compact height")
        expect(ClipboardPanelLayout.minimumListHeight == 300, "compact layout must preserve enough room for history rows")
    }

    private static func checkSearchSpaceRemainsTextInput() {
        expect(
            ClipboardPanelKeyRouter.command(forKeyCode: 49, isEditingSearch: true) == .passThrough,
            "space in the search field must be passed to the text editor"
        )
        expect(
            ClipboardPanelKeyRouter.command(forKeyCode: 49, isEditingSearch: false) == .passThrough,
            "space outside search must not resize the single-column panel"
        )
        expect(
            ClipboardPanelKeyRouter.command(forKeyCode: 51, isEditingSearch: true) == .passThrough,
            "delete in the search field must edit the query"
        )
        expect(
            ClipboardPanelKeyRouter.command(forKeyCode: 36, isEditingSearch: true) == .passThrough,
            "return in the search field must keep the panel open without copying"
        )
        expect(
            ClipboardPanelKeyRouter.command(forKeyCode: 36, isEditingSearch: false) == .restoreSelection,
            "return outside the search field must still restore the selected item"
        )
        expect(
            ClipboardPanelKeyRouter.command(forKeyCode: 125, isEditingSearch: true) == .moveSelection(1),
            "down arrow must keep keyboard navigation available while searching"
        )
    }

    private static func checkPanelIsDraggableAndRounded() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 440),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let root = NSVisualEffectView()

        ClipboardPanelStyling.apply(to: panel, root: root)

        expect(panel.isMovable, "clipboard panel must remain movable")
        expect(panel.isMovableByWindowBackground, "clipboard panel background must initiate dragging")
        expect(panel.animationBehavior == .none, "clipboard panel must close without a flashing window animation")
        expect(!panel.hasShadow, "borderless rounded panel must not draw a rectangular native shadow")
        expect(root.wantsLayer, "rounded clipping requires a layer-backed root view")
        expect((root.layer?.cornerRadius ?? 0) > 0, "clipboard panel must have rounded corners")
        expect(root.layer?.cornerCurve == .continuous, "clipboard panel corners must use the continuous curve")
        expect(root.layer?.masksToBounds == true, "panel material must be clipped to its rounded corners")
    }

    private static func checkFilterControlUsesEqualCapsuleSegments() {
        let control = NSSegmentedControl(
            labels: ["全部", "文字", "图片", "文件", "收藏"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )

        ClipboardFilterControlStyling.apply(to: control)

        expect(control.segmentStyle == .capsule, "filter buttons must use the capsule style")
        expect(control.controlSize == .regular, "filter buttons must match the search field height")
        let widths = (0..<control.segmentCount).map { control.width(forSegment: $0) }
        let firstWidth = widths.first ?? -1
        expect(widths.allSatisfy { $0 == firstWidth }, "all five filter buttons must have equal widths")
        expect(firstWidth == 44, "compact panel must use the approved filter button width")
        expect(control.selectedSegment == 0, "the all-items filter must be selected initially")
    }

    private static func checkClearHistoryControls() {
        let button = NSButton()
        ClipboardClearHistoryPresentation.apply(to: button)

        expect(button.title.isEmpty, "clear-all history must use an icon without a text label")
        expect(button.image != nil, "clear-all history must expose a trash icon")
        expect(button.imagePosition == .imageOnly, "clear-all history must display only the trash icon")
        expect(button.contentTintColor == .secondaryLabelColor, "clear-all history must use a neutral tint")
        expect(button.toolTip == "清空全部剪贴板历史", "the icon-only action must keep an explanatory tooltip")
        expect(!button.isEnabled, "clear-all history must stay disabled until history is available")
        expect(
            !ClipboardClearHistoryPresentation.shouldClear(after: .alertFirstButtonReturn),
            "the default alert response must cancel the destructive action"
        )
        expect(
            ClipboardClearHistoryPresentation.shouldClear(after: .alertSecondButtonReturn),
            "explicitly choosing the destructive button must clear history"
        )
    }

    private static func checkReloadsCannotOverwriteClearResults() {
        var gate = ClipboardReloadGate()
        let staleReload = gate.beginReload()
        expect(staleReload != nil, "normal history reloads must be allowed")
        expect(gate.accepts(staleReload!), "the latest reload result must be accepted")

        gate.beginClear()
        expect(!gate.accepts(staleReload!), "starting a clear must invalidate an in-flight reload")
        expect(gate.beginReload() == nil, "reloads triggered during clear must be deferred")
        expect(gate.finishClear(), "a reload requested during clear must run after clearing finishes")

        let freshReload = gate.beginReload()
        expect(freshReload != nil, "reloads must resume after clearing finishes")
        expect(gate.accepts(freshReload!), "the post-clear reload must be authoritative")

        gate.beginClear()
        expect(!gate.finishClear(), "clearing without a concurrent reload must not schedule redundant work")
    }

    private static func checkImmediateHoverPreviewPolicy() {
        expect(ClipboardHoverPreviewPolicy.delay == 0, "truncated text hover must not use the system tooltip delay")
        expect(
            ClipboardHoverPreviewPolicy.dismissalGraceInterval > 0 &&
                ClipboardHoverPreviewPolicy.dismissalGraceInterval <= 0.2,
            "hover preview must allow the pointer to cross into scrollable content without feeling sticky"
        )
        expect(
            ClipboardHoverPreviewPolicy.shouldPresent(
                fullText: "a complete long clipboard entry",
                renderedWidth: 260,
                availableWidth: 120
            ),
            "truncated clipboard text must show the immediate hover preview"
        )
        expect(
            !ClipboardHoverPreviewPolicy.shouldPresent(
                fullText: "short",
                renderedWidth: 40,
                availableWidth: 120
            ),
            "fully visible clipboard text must not show a redundant hover preview"
        )
    }

    private static func checkLongTextAndImageRowPresentation() {
        let fullText = "第一行很长的文字\n第二行完整内容"
        let text = makeItem(kind: .text, plainText: fullText)
        let textRow = ClipboardHistoryRowPresentation(item: text)

        expect(textRow.summary == "第一行很长的文字 第二行完整内容", "row summary must stay on one line")
        expect(textRow.toolTip == fullText, "hover text must preserve the complete original content")
        expect(!textRow.usesImageThumbnail, "text rows must keep their type symbol")

        let image = makeItem(kind: .image, plainText: "图片", assetPath: "fixture.png")
        let imageRow = ClipboardHistoryRowPresentation(item: image)
        expect(imageRow.usesImageThumbnail, "image rows must request an inline thumbnail")
    }

    private static func checkThumbnailDecodingAndCaching() async {
        let loader = ClipboardThumbnailLoader(cacheLimit: 2)
        let itemID = UUID()
        let thumbnail = await loader.thumbnail(
            for: itemID,
            data: makePNG(width: 80, height: 40),
            maximumPixelSize: 20
        )
        expect(thumbnail?.width == 20, "thumbnail decoding must respect the maximum pixel width")
        expect(thumbnail?.height == 10, "thumbnail decoding must preserve the source aspect ratio")

        let cached = await loader.thumbnail(
            for: itemID,
            data: Data([0x00, 0x01]),
            maximumPixelSize: 20
        )
        expect(cached?.width == 20, "a decoded thumbnail must be reused for the same history item")
        let invalid = await loader.thumbnail(
            for: UUID(),
            data: Data([0x00, 0x01]),
            maximumPixelSize: 20
        )
        expect(invalid == nil, "invalid image data must leave the placeholder intact")
    }

    private static func makePNG(width: Int, height: Int) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    private static func makeItem(
        kind: ClipboardItemKind,
        plainText: String,
        assetPath: String? = nil
    ) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            kind: kind,
            contentHash: UUID().uuidString,
            plainText: plainText,
            assetPath: assetPath,
            fileURLs: [],
            source: ClipboardSource(appName: "Notes", bundleID: "com.apple.Notes"),
            createdAt: .now,
            updatedAt: .now,
            lastRestoredAt: nil,
            isFavorite: false,
            byteSize: 0
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("❌ \(message)") }
    }
}
