import AppKit
import ClipboardHistoryAppKit
import ClipboardHistoryCore
import Foundation

@MainActor
private final class SearchDelegateProbe: NSObject, NSSearchFieldDelegate {
    private(set) var changeCount = 0

    func controlTextDidChange(_ obj: Notification) {
        changeCount += 1
    }
}

@MainActor
enum ClipboardPanelPresentationChecks {
    static func run() async {
        checkSearchSpaceRemainsTextInput()
        checkCompactPanelLayout()
        checkPanelIsDraggableAndRounded()
        checkPanelBorderTracksAppearance()
        checkSearchUsesReferenceHeaderStyle()
        checkFilterUsesCompactPopupMenu()
        checkFavoriteVisibilityIsContextual()
        checkClearHistoryControls()
        checkReloadsCannotOverwriteClearResults()
        checkImmediateHoverPreviewPolicy()
        checkLongTextAndImageRowPresentation()
        await checkThumbnailDecodingAndCaching()
    }

    private static func checkCompactPanelLayout() {
        expect(ClipboardPanelLayout.defaultSize.width == 390, "clipboard panel must use the reduced width")
        expect(ClipboardPanelLayout.defaultSize.height == 340, "clipboard panel must use the reduced height")
        expect(ClipboardPanelLayout.minimumListHeight == 240, "compact layout must preserve room for five dense rows")
        expect(ClipboardPanelLayout.contentInset == 10, "panel content must keep balanced horizontal gutters")
        expect(ClipboardPanelLayout.verticalContentInset == 8, "panel controls must retain the reference's top inset")
        expect(ClipboardPanelLayout.headerControlHeight == 30, "header controls must use the reduced height")
        expect(ClipboardPanelLayout.headerCornerRadius == 8, "header controls must use the reduced corner radius")
        expect(ClipboardPanelLayout.headerSpacing == 10, "search and filter must have clear visual separation")
        expect(ClipboardPanelLayout.headerListSpacing == 6, "search and list must use compact vertical separation")
        expect(ClipboardPanelLayout.filterWidth == 30, "filter popup must use an icon-sized footprint")
        expect(ClipboardPanelLayout.tableStyle == .fullWidth, "the list must not add automatic top padding")
        expect(ClipboardPanelLayout.rowHeight == 48, "history rows must use the denser approved height")
        expect(ClipboardPanelLayout.rowSpacing == 1, "history rows must avoid oversized vertical gaps")
        expect(
            ClipboardPanelLayout.rowSelectionHorizontalInset == 0,
            "selected rows must align with the search field's visible left edge"
        )
        expect(ClipboardPanelLayout.rowIconSize == 28, "minimal rows must use restrained 28-point icons")
        expect(ClipboardPanelLayout.summaryFontSize == 12, "row titles must use the compact text scale")
        expect(ClipboardPanelLayout.detailFontSize == 10, "row metadata must use the compact text scale")
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
        expect((root.layer?.borderWidth ?? 0) > 0, "clipboard panel must use a faint border for definition")
        expect(root.layer?.masksToBounds == true, "panel material must be clipped to its rounded corners")
    }

    private static func checkPanelBorderTracksAppearance() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 410),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let root = ClipboardPanelRootView()
        root.appearance = NSAppearance(named: .aqua)
        ClipboardPanelStyling.apply(to: panel, root: root)
        let lightBorder = root.layer?.borderColor

        root.appearance = NSAppearance(named: .darkAqua)
        root.viewDidChangeEffectiveAppearance()
        let darkBorder = root.layer?.borderColor

        expect(lightBorder != darkBorder, "panel border must refresh when macOS appearance changes")
    }

    private static func checkFilterUsesCompactPopupMenu() {
        let control = ClipboardFilterPopUpButton()

        ClipboardFilterMenuPresentation.apply(to: control)

        expect(control.controlSize == .regular, "filter popup must use the scaled reference control metrics")
        expect(!control.isBordered, "filter popup must avoid the heavy default AppKit bezel")
        expect(control.focusRingType == .exterior, "keyboard focus must remain visible around the custom popup")
        expect(control.wantsLayer, "filter popup must draw its own subtle rounded background")
        expect(
            control.layer?.cornerRadius == ClipboardPanelLayout.headerCornerRadius,
            "filter popup must match the reference's soft corners"
        )
        expect(
            control.layer?.backgroundColor == NSColor.clear.cgColor,
            "filter popup background must remain fully transparent"
        )
        expect(control.layer?.borderWidth == 0, "filter popup must not look like a bordered button")
        let filterIcons = control.subviews.compactMap { $0 as? NSImageView }
        expect(
            filterIcons.contains { $0.image != nil },
            "filter popup must use a compact filter symbol"
        )
        expect(control.imagePosition == .imageOnly, "filter popup must hide the selected title in the header")
        expect(
            (control.cell as? NSPopUpButtonCell)?.arrowPosition == .noArrow,
            "filter popup must replace the bulky native arrow with the reference chevron"
        )
        expect(
            control.itemTitles == ["全部", "文字", "图片", "文件", "收藏"],
            "filter categories must live in one compact popup instead of five persistent segments"
        )
        expect(control.indexOfSelectedItem == 0, "the all-items filter must be selected initially")
        expect(control.menu?.autoenablesItems == false, "clear-history availability must follow panel state")
        expect(control.displayedTitle == "全部", "custom filter label must mirror the initial selection")
        expect(!control.showsActiveFilterIndicator, "the all-items filter must not show an active badge")
        expect(control.itemArray[0].state == .on, "the current filter must be checked in the menu")
        expect(
            control.accessibilityValue() as? String == "全部",
            "the default filter accessibility value must name the current selection"
        )
        control.selectItem(at: 2)
        control.synchronizeDisplayedTitle()
        expect(control.displayedTitle == "图片", "custom filter label must mirror later selections")
        expect(control.showsActiveFilterIndicator, "a non-default filter must remain visibly active")
        expect(control.itemArray[2].state == .on, "the selected filter must be checked in the menu")
        expect(
            control.itemArray.enumerated().allSatisfy { index, item in
                index == 2 || item.state == .off
            },
            "only the selected filter may be checked"
        )
        expect(
            control.toolTip == "筛选：图片（已启用）",
            "the active filter tooltip must name the current selection"
        )
        expect(
            control.accessibilityValue() as? String == "图片，已启用",
            "the active filter accessibility value must announce that filtering is enabled"
        )
        expect(
            filterIcons.allSatisfy { $0.contentTintColor == .secondaryLabelColor },
            "filter selection must not add an accent color"
        )
        control.selectItem(at: 0)
        control.synchronizeDisplayedTitle()
        expect(!control.showsActiveFilterIndicator, "returning to all items must hide the active badge")
        expect(control.itemArray[0].state == .on, "returning to all items must restore its menu checkmark")
        expect(ClipboardPanelLayout.filterWidth == 30, "filter popup must use an icon-sized footprint")
    }

    private static func checkSearchUsesReferenceHeaderStyle() {
        let search = ClipboardSearchField()
        search.frame = NSRect(x: 0, y: 0, width: 300, height: ClipboardPanelLayout.headerControlHeight)
        search.appearance = NSAppearance(named: .aqua)
        search.sendsSearchStringImmediately = true

        ClipboardSearchFieldPresentation.apply(to: search)
        search.layoutSubtreeIfNeeded()

        expect(search.placeholderString?.isEmpty == true, "search must not show placeholder text")
        expect(search.isEditable, "search must accept typed queries")
        expect(search.isSelectable, "search must allow selecting and replacing query text")
        expect(search.cell?.isEditable == true, "search cell must preserve native editing behavior")
        expect(search.controlSize == .regular, "search must use the same scaled metrics as the filter")
        expect(search.font?.pointSize == 13, "search text must match the scaled reference")
        expect(!search.isBordered, "search must avoid the default inset AppKit bezel")
        expect(!search.drawsBackground, "search must use the shared translucent layer background")
        expect(search.focusRingType == .none, "search must avoid a mismatched rectangular focus ring")
        expect(search.wantsLayer, "search must draw the reference rounded container")
        expect(
            search.layer?.cornerRadius == ClipboardPanelLayout.headerCornerRadius,
            "search and filter must share the same corner radius"
        )
        expect(search.layer?.backgroundColor != nil, "search must have the same quiet translucent fill")
        expect(
            abs((search.layer?.backgroundColor?.alpha ?? 0) - 0.065) < 0.001,
            "light-mode search background must use the approved subtle neutral opacity"
        )
        expect(search.layer?.borderWidth == 0, "search must not look like a bordered button")
        expect(search.sendsSearchStringImmediately, "custom search styling must preserve immediate filtering")
        guard let cell = search.cell as? NSSearchFieldCell else {
            fatalError("❌ search must retain an NSSearchFieldCell")
        }
        let bounds = NSRect(x: 0, y: 0, width: 300, height: ClipboardPanelLayout.headerControlHeight)
        let textRect = cell.searchTextRect(forBounds: bounds)
        let searchIcons = search.subviews.compactMap { $0 as? NSImageView }
        expect(
            searchIcons.count == 1
                && searchIcons[0].frame == NSRect(x: 10, y: 8, width: 14, height: 14),
            "search icon must be an independently centered view: \(searchIcons.map(\.frame))"
        )
        expect(
            textRect.minX == 32 && textRect.width == 258,
            "search text must keep an eight-point gap after the search icon"
        )
        expect(
            textRect.minY == bounds.minY && textRect.height == bounds.height,
            "the field editor must receive the full control height for baseline centering"
        )
        let initialEditor = NSTextView(frame: bounds)
        guard let configuredEditor = cell.setUpFieldEditorAttributes(initialEditor) as? NSTextView else {
            fatalError("❌ search cell must configure an NSTextView field editor")
        }
        expect(
            configuredEditor.font?.pointSize == 13
                && configuredEditor.textContainer?.lineFragmentPadding == 0
                && configuredEditor.textContainerInset.height == 7,
            "the initial empty field editor must be vertically centered before any text is entered"
        )
        search.stringValue = "query"
        search.layout()
        expect(
            cell.searchTextRect(forBounds: bounds).width == 240,
            "entered text must leave room for the cancel button"
        )
        let clearButtons = search.subviews.compactMap { $0 as? NSButton }
        expect(
            clearButtons.count == 1 && !clearButtons[0].isHidden,
            "a non-empty search must show one directly clickable clear button"
        )
        let delegateProbe = SearchDelegateProbe()
        search.delegate = delegateProbe
        clearButtons[0].performClick(nil)
        expect(
            search.stringValue.isEmpty && clearButtons[0].isHidden && delegateProbe.changeCount == 1,
            "clicking clear must empty the search and immediately refresh the filtered results"
        )
    }

    private static func checkFavoriteVisibilityIsContextual() {
        expect(
            !ClipboardFavoriteVisibility.shouldShow(isHovered: false),
            "favorite actions must stay hidden when the pointer is elsewhere"
        )
        expect(
            !ClipboardFavoriteVisibility.shouldShow(isHovered: true),
            "hovering a row must not expose an inline favorite action"
        )
    }

    private static func checkClearHistoryControls() {
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

        let imageFileURL = URL(fileURLWithPath: "/tmp/clipboard-photo.PNG")
        let imageFile = makeItem(
            kind: .files,
            plainText: imageFileURL.lastPathComponent,
            fileURLs: [imageFileURL]
        )
        let imageFileRow = ClipboardHistoryRowPresentation(item: imageFile)
        expect(imageFileRow.kindTitle == "文件", "image files must keep file semantics")
        expect(imageFileRow.usesImageThumbnail, "image files must request an inline thumbnail")
        expect(
            imageFileRow.thumbnailFileURL == imageFileURL,
            "image file thumbnails must read from the original file URL"
        )

        let documentURL = URL(fileURLWithPath: "/tmp/document.xlsx")
        let document = makeItem(
            kind: .files,
            plainText: documentURL.lastPathComponent,
            fileURLs: [documentURL]
        )
        let documentRow = ClipboardHistoryRowPresentation(item: document)
        expect(!documentRow.usesImageThumbnail, "non-image files must keep their file symbol")
        expect(documentRow.thumbnailFileURL == nil, "non-image files must not start image decoding")
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

        let imageFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-thumbnail-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageFileURL) }
        do {
            try makePNG(width: 80, height: 40).write(to: imageFileURL, options: .atomic)
        } catch {
            fatalError("❌ image-file thumbnail fixture must be writable: \(error)")
        }
        let fileThumbnail = await loader.thumbnail(
            for: UUID(),
            fileURL: imageFileURL,
            maximumPixelSize: 20
        )
        expect(fileThumbnail?.width == 20, "image-file thumbnails must respect the maximum width")
        expect(fileThumbnail?.height == 10, "image-file thumbnails must preserve aspect ratio")
        let missingFileThumbnail = await loader.thumbnail(
            for: UUID(),
            fileURL: imageFileURL.deletingLastPathComponent().appendingPathComponent("missing.png"),
            maximumPixelSize: 20
        )
        expect(missingFileThumbnail == nil, "missing image files must leave the file placeholder intact")
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
        assetPath: String? = nil,
        fileURLs: [URL] = []
    ) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            kind: kind,
            contentHash: UUID().uuidString,
            plainText: plainText,
            assetPath: assetPath,
            fileURLs: fileURLs,
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
