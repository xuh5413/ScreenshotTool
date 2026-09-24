import AppKit
import ClipboardHistoryCore
import Foundation
import ImageIO

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
    public static let defaultSize = NSSize(width: 470, height: 410)
    public static let minimumListHeight: CGFloat = 300
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
        root.layer?.masksToBounds = true
    }
}

@MainActor
public enum ClipboardFilterControlStyling {
    public static func apply(to control: NSSegmentedControl) {
        control.segmentStyle = .capsule
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 13, weight: .medium)
        control.selectedSegment = 0
        for segment in 0..<control.segmentCount {
            control.setWidth(44, forSegment: segment)
        }
    }
}

@MainActor
public enum ClipboardClearHistoryPresentation {
    public static func apply(to button: NSButton) {
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.title = ""
        button.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: "清空全部剪贴板历史"
        )?.withSymbolConfiguration(symbolConfiguration)
        button.imagePosition = .imageOnly
        button.toolTip = "清空全部剪贴板历史"
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .secondaryLabelColor
        button.isEnabled = false
    }

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

    public init(item: ClipboardItem) {
        let singleLine = item.plainText.replacingOccurrences(of: "\n", with: " ")
        let title = Self.title(for: item.kind)
        summary = singleLine.isEmpty ? title : singleLine
        toolTip = item.plainText.isEmpty ? title : item.plainText
        symbolName = Self.symbolName(for: item.kind)
        kindTitle = title
        usesImageThumbnail = item.kind == .image
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
}
