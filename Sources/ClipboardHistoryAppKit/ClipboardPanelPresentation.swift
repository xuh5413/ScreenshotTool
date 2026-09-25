import AppKit
import ClipboardHistoryCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ClipboardPanelKeyCommand: Equatable, Sendable {
    case passThrough
    case moveSelection(Int)
    case restoreSelection
    case deleteSelection
    case close
}

public enum ClipboardPanelKeyRouter {
    public static func command(
        forKeyCode keyCode: UInt16,
        isEditingSearch: Bool
    ) -> ClipboardPanelKeyCommand {
        switch keyCode {
        case 126:
            return .moveSelection(-1)
        case 125:
            return .moveSelection(1)
        case 36, 76:
            return isEditingSearch ? .passThrough : .restoreSelection
        case 51, 117:
            return isEditingSearch ? .passThrough : .deleteSelection
        case 53:
            return .close
        default:
            return .passThrough
        }
    }
}

public enum ClipboardPanelLayout {
    public static let defaultSize = NSSize(width: 390, height: 340)
    public static let minimumListHeight: CGFloat = 240
    public static let contentInset: CGFloat = 10
    public static let verticalContentInset: CGFloat = 8
    public static let headerControlHeight: CGFloat = 30
    public static let headerCornerRadius: CGFloat = 8
    public static let headerSpacing: CGFloat = 10
    public static let headerListSpacing: CGFloat = 6
    public static let filterWidth: CGFloat = 30
    public static let tableStyle: NSTableView.Style = .fullWidth
    public static let rowHeight: CGFloat = 48
    public static let rowSpacing: CGFloat = 1
    public static let rowSelectionHorizontalInset: CGFloat = 0
    public static let rowIconSize: CGFloat = 28
    public static let summaryFontSize: CGFloat = 12
    public static let detailFontSize: CGFloat = 10
}

public struct ClipboardReloadGate: Sendable {
    private var generation = 0
    private var reloadRequestedWhileClearing = false
    public private(set) var isClearing = false

    public init() {}

    public mutating func beginReload() -> Int? {
        guard !isClearing else {
            reloadRequestedWhileClearing = true
            return nil
        }
        generation &+= 1
        return generation
    }

    public func accepts(_ reloadGeneration: Int) -> Bool {
        !isClearing && reloadGeneration == generation
    }

    public mutating func beginClear() {
        generation &+= 1
        isClearing = true
        reloadRequestedWhileClearing = false
    }

    @discardableResult
    public mutating func finishClear() -> Bool {
        let shouldReload = reloadRequestedWhileClearing
        reloadRequestedWhileClearing = false
        isClearing = false
        return shouldReload
    }
}

@MainActor
public final class ClipboardPanelRootView: NSVisualEffectView {
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ClipboardPanelStyling.updateBorderColor(of: self)
    }
}

@MainActor
public enum ClipboardPanelStyling {
    public static func apply(to panel: NSPanel, root: NSVisualEffectView) {
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none

        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.cornerCurve = .continuous
        root.layer?.borderWidth = 0.5
        updateBorderColor(of: root)
        root.layer?.masksToBounds = true
    }

    static func updateBorderColor(of root: NSVisualEffectView) {
        var resolvedBorderColor: CGColor?
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedBorderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        }
        root.layer?.borderColor = resolvedBorderColor
    }
}

@MainActor
private enum ClipboardHeaderControlAppearance {
    static func applyLayer(to view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = ClipboardPanelLayout.headerCornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 0
        view.layer?.masksToBounds = true
        updateLayerColors(of: view)
    }

    static func updateLayerColors(of view: NSView) {
        let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = isDark
            ? NSColor.windowBackgroundColor.withAlphaComponent(0.55)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.72)
        view.layer?.backgroundColor = background.cgColor
        view.layer?.borderColor = nil
    }

    static func updateSearchColors(of view: NSView) {
        let isDark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = isDark
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.065)
        view.layer?.backgroundColor = background.cgColor
        view.layer?.borderColor = nil
    }
}

@MainActor
public final class ClipboardSearchField: NSSearchField {
    private let searchIconView = NSImageView()
    private let clearButton = NSButton()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSearchIcon()
        configureClearButton()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSearchIcon()
        configureClearButton()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ClipboardHeaderControlAppearance.updateSearchColors(of: self)
    }

    public override func layout() {
        super.layout()
        layoutAccessoryViews()
        updateClearButtonVisibility()
        updateFieldEditorLayout()
    }

    public override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        updateFieldEditorLayout()
        // NSSearchField performs one more field-editor setup pass after this
        // callback the first time it becomes active. Reapply our geometry on
        // the next main-loop turn so the initial caret uses the same centered
        // layout as subsequently entered text.
        DispatchQueue.main.async { [weak self] in
            self?.updateFieldEditorLayout()
        }
    }

    public override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        updateClearButtonVisibility()
        updateFieldEditorLayout()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === searchIconView ? self : hitView
    }

    @objc private func clearSearch(_ sender: Any?) {
        stringValue = ""
        currentEditor()?.string = ""
        updateClearButtonVisibility()
        delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: self)
        )
    }

    private func configureSearchIcon() {
        searchIconView.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        searchIconView.imageAlignment = .alignCenter
        searchIconView.imageScaling = .scaleProportionallyDown
        searchIconView.contentTintColor = .secondaryLabelColor
        searchIconView.setAccessibilityElement(false)
        addSubview(searchIconView)
    }

    private func configureClearButton() {
        clearButton.title = ""
        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "清除搜索"
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        clearButton.imagePosition = .imageOnly
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.isBordered = false
        clearButton.focusRingType = .none
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearSearch(_:))
        clearButton.toolTip = "清除搜索"
        addSubview(clearButton)
        updateClearButtonVisibility()
    }

    private func layoutAccessoryViews() {
        searchIconView.frame = NSRect(
            x: bounds.minX + 10,
            y: floor(bounds.midY - 7),
            width: 14,
            height: 14
        )
        clearButton.frame = NSRect(
            x: bounds.maxX - 28,
            y: bounds.minY,
            width: 24,
            height: bounds.height
        )
    }

    private func updateClearButtonVisibility() {
        let editorText = currentEditor()?.string
        clearButton.isHidden = (editorText ?? stringValue).isEmpty
    }

    private func updateFieldEditorLayout() {
        guard let editor = currentEditor() as? NSTextView,
              let searchCell = cell as? ClipboardSearchFieldCell else { return }
        let textRect = searchCell.searchTextRect(forBounds: bounds)
        if let editorClipView = editor.superview,
           editorClipView.superview === self {
            // AppKit positions the shared field editor through its private clip
            // view. Moving only the NSTextView leaves that clip view at x = 0,
            // so typed text can appear underneath the search icon.
            editorClipView.frame = textRect
            editorClipView.bounds = textRect
            editor.frame = textRect
            editor.bounds = NSRect(origin: .zero, size: textRect.size)
        } else {
            editor.frame = textRect
        }
        searchCell.configureFieldEditor(editor, forHeight: textRect.height)
    }
}

@MainActor
public final class ClipboardSearchFieldCell: NSSearchFieldCell {
    public override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let configuredEditor = super.setUpFieldEditorAttributes(textObj)
        if let textView = configuredEditor as? NSTextView {
            configureFieldEditor(
                textView,
                forHeight: ClipboardPanelLayout.headerControlHeight
            )
        }
        return configuredEditor
    }

    public func configureFieldEditor(_ editor: NSTextView, forHeight height: CGFloat) {
        let activeFont = font ?? .systemFont(ofSize: 13)
        editor.font = activeFont
        var typingAttributes = editor.typingAttributes
        typingAttributes[.font] = activeFont
        typingAttributes[.foregroundColor] = textColor ?? NSColor.labelColor
        editor.typingAttributes = typingAttributes
        editor.textContainer?.lineFragmentPadding = 0
        let lineHeight = ceil(
            editor.layoutManager?.defaultLineHeight(for: activeFont)
                ?? activeFont.boundingRectForFont.height
        )
        editor.textContainerInset = NSSize(
            width: 0,
            height: max(0, floor((height - lineHeight) / 2))
        )
    }

    public override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let trailingInset: CGFloat = stringValue.isEmpty ? 10 : 28
        return NSRect(
            x: rect.minX + 32,
            y: rect.minY,
            width: max(0, rect.width - 32 - trailingInset),
            height: rect.height
        )
    }
}

@MainActor
public enum ClipboardSearchFieldPresentation {
    public static func apply(to control: NSSearchField) {
        let sendsSearchStringImmediately = control.sendsSearchStringImmediately
        let sendsWholeSearchString = control.sendsWholeSearchString
        control.placeholderString = ""
        control.setAccessibilityLabel("搜索剪贴板历史")
        let centeredCell = ClipboardSearchFieldCell(textCell: control.stringValue)
        centeredCell.placeholderString = control.placeholderString
        centeredCell.font = .systemFont(ofSize: 13, weight: .regular)
        centeredCell.searchButtonCell = nil
        centeredCell.cancelButtonCell = nil
        centeredCell.isEditable = true
        centeredCell.isSelectable = true
        centeredCell.usesSingleLineMode = true
        centeredCell.wraps = false
        centeredCell.isScrollable = true
        control.cell = centeredCell
        control.isEditable = true
        control.isSelectable = true
        control.isEnabled = true
        control.cell?.isEditable = true
        control.cell?.isSelectable = true
        control.sendsSearchStringImmediately = sendsSearchStringImmediately
        control.sendsWholeSearchString = sendsWholeSearchString
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 13, weight: .regular)
        control.isBordered = false
        control.drawsBackground = false
        control.focusRingType = .none
        control.textColor = .labelColor
        ClipboardHeaderControlAppearance.applyLayer(to: control)
        ClipboardHeaderControlAppearance.updateSearchColors(of: control)
    }
}

@MainActor
public final class ClipboardFilterPopUpButton: NSPopUpButton {
    private let iconView = NSImageView()
    private let activeIndicatorView = NSView()

    public var displayedTitle: String {
        selectedItem?.title ?? ClipboardFilterMenuPresentation.titles[0]
    }

    public var showsActiveFilterIndicator: Bool {
        !activeIndicatorView.isHidden
    }

    public convenience init() {
        self.init(frame: .zero, pullsDown: false)
    }

    public override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        configureIcon()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureIcon()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.clear.cgColor
        activeIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    public override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: 1, dy: 1)
    }

    public override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: focusRingMaskBounds,
            xRadius: ClipboardPanelLayout.headerCornerRadius,
            yRadius: ClipboardPanelLayout.headerCornerRadius
        ).fill()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === iconView ? self : hitView
    }

    public func synchronizeDisplayedTitle() {
        let title = selectedItem?.title ?? ClipboardFilterMenuPresentation.titles[0]
        let isActive = indexOfSelectedItem > 0
            && ClipboardFilterMenuPresentation.titles.indices.contains(indexOfSelectedItem)
        activeIndicatorView.isHidden = !isActive
        setAccessibilityValue(isActive ? "\(title)，已启用" : title)
        toolTip = isActive ? "筛选：\(title)（已启用）" : "筛选：\(title)"
        iconView.contentTintColor = .secondaryLabelColor
        for (index, item) in itemArray.prefix(ClipboardFilterMenuPresentation.titles.count).enumerated() {
            item.state = index == indexOfSelectedItem ? .on : .off
        }
    }

    private func configureIcon() {
        iconView.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        activeIndicatorView.wantsLayer = true
        activeIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        activeIndicatorView.layer?.cornerRadius = 2.5
        activeIndicatorView.isHidden = true
        activeIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(activeIndicatorView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            activeIndicatorView.widthAnchor.constraint(equalToConstant: 5),
            activeIndicatorView.heightAnchor.constraint(equalToConstant: 5),
            activeIndicatorView.centerXAnchor.constraint(equalTo: iconView.trailingAnchor, constant: -1),
            activeIndicatorView.centerYAnchor.constraint(equalTo: iconView.topAnchor, constant: 1)
        ])
        setAccessibilityLabel("筛选剪贴板类型")
    }
}

@MainActor
public enum ClipboardFilterMenuPresentation {
    public static let titles = ["全部", "文字", "图片", "文件", "收藏"]

    public static func apply(to control: NSPopUpButton) {
        control.removeAllItems()
        control.addItems(withTitles: titles)
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 13, weight: .regular)
        control.isBordered = false
        control.focusRingType = .exterior
        (control.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        ClipboardHeaderControlAppearance.applyLayer(to: control)
        control.layer?.backgroundColor = NSColor.clear.cgColor
        control.menu?.autoenablesItems = false
        control.selectItem(at: 0)
        control.imagePosition = .imageOnly
        control.imageScaling = .scaleProportionallyDown
        for (index, item) in (control.itemArray).enumerated() {
            item.tag = index
        }
        (control as? ClipboardFilterPopUpButton)?.synchronizeDisplayedTitle()
    }

}

public enum ClipboardFavoriteVisibility {
    public static func shouldShow(isHovered: Bool) -> Bool {
        false
    }
}

@MainActor
public enum ClipboardClearHistoryPresentation {
    public static func shouldClear(after response: NSApplication.ModalResponse) -> Bool {
        response == .alertSecondButtonReturn
    }
}

public enum ClipboardHoverPreviewPolicy {
    public static let delay: TimeInterval = 0
    public static let dismissalGraceInterval: TimeInterval = 0.12

    public static func shouldPresent(
        fullText: String,
        renderedWidth: CGFloat,
        availableWidth: CGFloat
    ) -> Bool {
        !fullText.isEmpty && availableWidth > 0 && renderedWidth > availableWidth
    }
}

@MainActor
final class ClipboardHoverTextField: NSTextField {
    var fullText = "" {
        didSet {
            toolTip = nil
            if oldValue != fullText {
                closePreview()
            }
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverPopover: NSPopover?
    private var closeWorkItem: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        cancelScheduledClose()
        guard shouldShowPreview else { return }
        guard hoverPopover?.isShown != true else { return }
        showPreview()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        scheduleClosePreview()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            closePreview()
        }
    }

    private var shouldShowPreview: Bool {
        let displayFont = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let renderedWidth = (stringValue as NSString).size(
            withAttributes: [.font: displayFont]
        ).width
        return ClipboardHoverPreviewPolicy.shouldPresent(
            fullText: fullText,
            renderedWidth: renderedWidth,
            availableWidth: bounds.width
        )
    }

    private func showPreview() {
        closePreview()

        let displayFont = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let horizontalInset: CGFloat = 16
        let naturalTextWidth = (fullText as NSString).size(
            withAttributes: [.font: displayFont]
        ).width
        let textWidth = min(360, max(180, ceil(naturalTextWidth) + horizontalInset))
        let textBounds = (fullText as NSString).boundingRect(
            with: NSSize(
                width: textWidth - horizontalInset,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: displayFont]
        )
        let fullTextHeight = max(24, ceil(textBounds.height) + 16)
        let visibleTextHeight = min(240, fullTextHeight)

        let textView = NSTextView(frame: NSRect(
            x: 0,
            y: 0,
            width: textWidth,
            height: fullTextHeight
        ))
        textView.string = fullText
        textView.font = displayFont
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: textWidth,
            height: .greatestFiniteMagnitude
        )

        let scrollView = NSScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: textWidth,
            height: visibleTextHeight
        ))
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = fullTextHeight > visibleTextHeight
        scrollView.autohidesScrollers = true

        let container = ClipboardHoverContainerView(frame: scrollView.frame)
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        container.onMouseEntered = { [weak self] in
            self?.cancelScheduledClose()
        }
        container.onMouseExited = { [weak self] in
            self?.scheduleClosePreview()
        }

        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = container.frame.size

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = container.frame.size
        hoverPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func scheduleClosePreview() {
        cancelScheduledClose()
        let workItem = DispatchWorkItem { [weak self] in
            self?.closePreview()
        }
        closeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ClipboardHoverPreviewPolicy.dismissalGraceInterval,
            execute: workItem
        )
    }

    private func cancelScheduledClose() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
    }

    private func closePreview() {
        cancelScheduledClose()
        hoverPopover?.close()
        hoverPopover = nil
    }
}

@MainActor
private final class ClipboardHoverContainerView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }
}

public struct ClipboardHistoryRowPresentation: Equatable, Sendable {
    public let summary: String
    public let toolTip: String
    public let symbolName: String
    public let kindTitle: String
    public let usesImageThumbnail: Bool
    public let thumbnailFileURL: URL?

    public init(item: ClipboardItem) {
        let singleLine = item.plainText.replacingOccurrences(of: "\n", with: " ")
        let title = Self.title(for: item.kind)
        summary = singleLine.isEmpty ? title : singleLine
        toolTip = item.plainText.isEmpty ? title : item.plainText
        symbolName = Self.symbolName(for: item.kind)
        kindTitle = title
        thumbnailFileURL = item.kind == .files
            ? item.fileURLs.first(where: Self.isImageFile)
            : nil
        usesImageThumbnail = item.kind == .image || thumbnailFileURL != nil
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static func title(for kind: ClipboardItemKind) -> String {
        switch kind {
        case .text: return "文字"
        case .link: return "链接"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    private static func symbolName(for kind: ClipboardItemKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        }
    }
}

public enum ClipboardThumbnailDecoder {
    public static func thumbnail(from data: Data, maximumPixelSize: Int) -> CGImage? {
        guard maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return thumbnail(from: source, maximumPixelSize: maximumPixelSize)
    }

    public static func thumbnail(fromFileURL url: URL, maximumPixelSize: Int) -> CGImage? {
        guard maximumPixelSize > 0, url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return thumbnail(from: source, maximumPixelSize: maximumPixelSize)
    }

    private static func thumbnail(
        from source: CGImageSource,
        maximumPixelSize: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return image
    }
}

public actor ClipboardThumbnailLoader {
    private final class ImageBox: NSObject {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSUUID, ImageBox>()

    public init(cacheLimit: Int = 100) {
        cache.countLimit = max(1, cacheLimit)
    }

    public func cachedThumbnail(for itemID: UUID) -> CGImage? {
        cache.object(forKey: itemID as NSUUID)?.image
    }

    public func thumbnail(
        for itemID: UUID,
        data: Data,
        maximumPixelSize: Int
    ) -> CGImage? {
        if let cached = cachedThumbnail(for: itemID) {
            return cached
        }
        guard !Task.isCancelled,
              let image = ClipboardThumbnailDecoder.thumbnail(
                from: data,
                maximumPixelSize: maximumPixelSize
              ) else {
            return nil
        }
        cache.setObject(ImageBox(image), forKey: itemID as NSUUID)
        return image
    }

    public func thumbnail(
        for itemID: UUID,
        fileURL: URL,
        maximumPixelSize: Int
    ) -> CGImage? {
        if let cached = cachedThumbnail(for: itemID) {
            return cached
        }
        guard !Task.isCancelled,
              let image = ClipboardThumbnailDecoder.thumbnail(
                fromFileURL: fileURL,
                maximumPixelSize: maximumPixelSize
              ) else {
            return nil
        }
        cache.setObject(ImageBox(image), forKey: itemID as NSUUID)
        return image
    }
}
