import Cocoa
import ScreenshotToolbarCore

// MARK: - Result

enum CaptureResult {
    case capture(CGRect)
    case window(CGRect, windowNumber: Int)
    case cancel
}

// MARK: - Annotation Types

enum AnnotationTool: Int, CaseIterable {
    case arrow, text, number, mosaic, rectangle, ellipse, highlight, select

    var toolbarButtonID: String? {
        switch self {
        case .arrow: return "tool_arrow"
        case .text: return "tool_text"
        case .number: return "tool_number"
        case .mosaic: return "tool_mosaic"
        case .rectangle: return "tool_rectangle"
        case .ellipse: return "tool_ellipse"
        case .highlight: return "tool_highlight"
        case .select: return nil
        }
    }

    static func toolbarTool(for buttonID: String) -> AnnotationTool? {
        allCases.first { $0.toolbarButtonID == buttonID }
    }
}

struct AnnotationItem {
    let id = UUID()
    let tool: AnnotationTool
    let color: NSColor
    let lineWidth: CGFloat

    var startPoint: CGPoint = .zero
    var endPoint: CGPoint = .zero
    var text: String = ""
    var fontSize: CGFloat = 24
    var number: Int = 0
    var mosaicRect: CGRect = .zero
    var pixelSize: Int = 8

    static func arrow(start: CGPoint, end: CGPoint, color: NSColor) -> AnnotationItem {
        AnnotationItem(tool: .arrow, color: color, lineWidth: 3, startPoint: start, endPoint: end)
    }

    static func text(point: CGPoint, text: String, color: NSColor, fontSize: CGFloat = 24) -> AnnotationItem {
        AnnotationItem(tool: .text, color: color, lineWidth: 0, startPoint: point, text: text, fontSize: fontSize)
    }

    static func number(point: CGPoint, number: Int, color: NSColor) -> AnnotationItem {
        AnnotationItem(tool: .number, color: color, lineWidth: 0, startPoint: point, number: number)
    }

    static func mosaic(rect: CGRect, pixelSize: Int = 8) -> AnnotationItem {
        AnnotationItem(tool: .mosaic, color: .clear, lineWidth: 0, startPoint: rect.origin, mosaicRect: rect, pixelSize: pixelSize)
    }
}

enum AnnotationAction {
    case save, copy, pin
}

// MARK: - Overlay Window (needs to accept key for text input)

private class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay

final class CaptureOverlay: NSObject {

    var onComplete: ((CaptureResult) -> Void)?
    var onAnnotationResult: ((NSImage, CGImage?, AnnotationAction) -> Void)?
    var onAnnotationCancel: (() -> Void)?
    var onPinAction: ((NSImage, CGRect) -> Void)?
    /// Same as onPinAction but passes the raw CGImage to avoid NSImage
    /// representation size ambiguity on Retina displays.
    var onPinCGImage: ((CGImage, NSSize, CGRect) -> Void)?
    var onLongScreenshot: ((CGRect) -> Void)?
    var onLongScreenshotFromSelection: ((CGRect) -> Void)? {
        get { overlayView?.onLongScreenshotFromSelection }
        set { overlayView?.onLongScreenshotFromSelection = newValue }
    }

    private var overlayWindow: NSWindow?
    private var overlayView: OverlayView?

    var overlayWindowNumber: Int? { overlayWindow?.windowNumber }

    func beginSelection(frozenBackground: [(CGImage, CGRect)]? = nil) {
        guard overlayWindow == nil else { return }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        let totalFrame = screens.reduce(CGRect.null) { $0.union($1.frame) }
        NSLog("[ScreenshotTool] overlay totalFrame=\(totalFrame) screens=\(screens.count)")

        overlayView = OverlayView(frame: CGRect(origin: .zero, size: totalFrame.size))
        overlayView?.screenOffset = totalFrame.origin
        if let frozen = frozenBackground {
            overlayView?.setFrozenBackground(frozen)
        }
        overlayView?.onSelectionComplete = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .capture, .window:
                // Keep overlay alive for annotation mode
                self.onComplete?(result)
            case .cancel:
                self.cleanup()
                self.onComplete?(result)
            }
        }
        overlayView?.onAnnotationAction = { [weak self] image, cgImage, action in
            guard let self = self else { return }
            self.onAnnotationResult?(image, cgImage, action)
        }
        overlayView?.onAnnotationCancel = { [weak self] in
            guard let self = self else { return }
            self.cleanup()
            self.onAnnotationCancel?()
        }
        overlayView?.onPinAction = { [weak self] image, rect in
            guard let self = self else { return }
            self.onPinAction?(image, rect)
        }
        overlayView?.onPinCGImage = { [weak self] cgImage, size, rect in
            guard let self = self else { return }
            self.onPinCGImage?(cgImage, size, rect)
        }
        overlayView?.onLongScreenshot = { [weak self] rect in
            guard let self = self else { return }
            self.onLongScreenshot?(rect)
        }

        let window = CaptureOverlayWindow(
            contentRect: totalFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.contentView = overlayView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        overlayWindow = window
    }

    func enterAnnotationMode(image: NSImage, selectionRect: CGRect, canMove: Bool = true) {
        overlayView?.enterAnnotationMode(image: image, globalRect: selectionRect, canMove: canMove)
    }

    func enterAnnotationMode(image: NSImage, cgImage: CGImage, selectionRect: CGRect, canMove: Bool = true) {
        overlayView?.enterAnnotationMode(image: image, cgImage: cgImage, globalRect: selectionRect, canMove: canMove)
    }

    func enterLongScreenshotMode(selectionRect: CGRect) {
        overlayWindow?.level = .floating
        overlayWindow?.ignoresMouseEvents = true
        overlayView?.enterLongScreenshotMode(globalRect: selectionRect)
    }

    func exitLongScreenshotMode() {
        overlayWindow?.level = .screenSaver
        overlayWindow?.ignoresMouseEvents = false
        overlayView?.exitLongScreenshotMode()
        overlayWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateLongScreenshotPreview(_ image: NSImage) {
        overlayView?.updateLongScreenshotPreview(image)
    }

    func updateLongScreenshotStatus(_ message: String) {
        overlayView?.updateLongScreenshotStatus(message)
    }

    func cleanupOverlay() {
        cleanup()
    }

    /// Restore overlay window level after a cancelled save panel
    func restoreWindowLevel() {
        overlayWindow?.level = .screenSaver
        overlayWindow?.makeKeyAndOrderFront(nil)
    }

    func clearFrozenBackground() {
        overlayView?.clearFrozenBackground()
    }

    private func cleanup() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        overlayView = nil
    }
}

// MARK: - Overlay View

private class OverlayView: NSView {

    // MARK: - Callbacks

    var onSelectionComplete: ((CaptureResult) -> Void)?
    var onAnnotationAction: ((NSImage, CGImage?, AnnotationAction) -> Void)?
    var onAnnotationCancel: (() -> Void)?
    var onPinAction: ((NSImage, CGRect) -> Void)?
    var onPinCGImage: ((CGImage, NSSize, CGRect) -> Void)?
    var onLongScreenshot: ((CGRect) -> Void)?
    var onLongScreenshotFromSelection: ((CGRect) -> Void)?
    var screenOffset = CGPoint.zero

    // Frozen background (pre-captured screenshot)
    private var frozenBackgrounds: [(CGImage, CGRect)] = []

    func setFrozenBackground(_ images: [(CGImage, CGRect)]) {
        frozenBackgrounds = images
        needsDisplay = true
    }

    func clearFrozenBackground() {
        frozenBackgrounds = []
    }

    private var trackingArea: NSTrackingArea?
    private var annotationGlobalRect: CGRect = .zero

    // MARK: - Mode

    private enum Mode { case selecting, adjusting, annotating, longScreenshotting }
    private var mode: Mode = .selecting

    // MARK: - Selection State

    private var isSelecting = false
    private var selectionStart = CGPoint.zero
    private var selectionRect = CGRect.null
    private var highlightedWindowRect: CGRect?

    // Color picker (during selecting mode)
    private var pickedColor: NSColor?
    private var colorCopyFeedback: String?
    private var colorCopyFeedbackExpiry: DispatchWorkItem?
    private let magnifierSize: CGFloat = 120
    private let magnifierZoom: CGFloat = 8

    // MARK: - Adjust State (after selection, before confirm)

    private enum AdjustDrag { case none, move, resizeLeft, resizeRight, resizeTop, resizeBottom, resizeTopLeft, resizeTopRight, resizeBottomLeft, resizeBottomRight }
    private var adjustDrag: AdjustDrag = .none
    private var adjustStartPoint = CGPoint.zero
    private var adjustStartRect = CGRect.zero

    // MARK: - Annotation State

    private var capturedImage: NSImage?
    private var capturedCGImage: CGImage? // original cropped CGImage for display
    private var captureRectLocal: CGRect = .null // in view coords
    private var annotations: [AnnotationItem] = []
    private var currentTool: AnnotationTool = .arrow
    private var currentColor: NSColor = .red
    private var inProgressItem: AnnotationItem?
    private var numberCounter = 0
    private var selectedAnnotationIndex: Int?
    private var mosaicCache: [String: NSImage] = [:]
    private let ciContext = CIContext()
    private var activeTextField: NSTextField?

    // MARK: - Long Screenshot Mode

    private var longScreenshotGlobalRect: CGRect = .null
    private var longScreenshotPreviewImage: NSImage?
    private var longScreenshotStatusText = "等待滚动…"

    func enterLongScreenshotMode(globalRect: CGRect) {
        self.longScreenshotGlobalRect = globalRect
        self.longScreenshotPreviewImage = nil
        self.longScreenshotStatusText = "等待滚动…"
        mode = .longScreenshotting
        hideTooltip()
        tooltipTargetID = nil
        needsDisplay = true
    }

    func exitLongScreenshotMode() {
        mode = .selecting
        selectionStart = .zero
        selectionRect = .null
        highlightedWindowRect = nil
        isSelecting = false
        longScreenshotPreviewImage = nil
        longScreenshotStatusText = "等待滚动…"
        needsDisplay = true
    }

    func updateLongScreenshotPreview(_ image: NSImage) {
        longScreenshotPreviewImage = image
        needsDisplay = true
    }

    func updateLongScreenshotStatus(_ message: String) {
        longScreenshotStatusText = message
        needsDisplay = true
    }

    // MARK: - Selection Move / Resize in Annotation Mode

    private var canMoveSelection = true
    private var originallyMovableSelection = true
    private var annotationToolbarExpanded = false

    private enum AnnDrag { case none, move, resizeLeft, resizeRight, resizeTop, resizeBottom, resizeTopLeft, resizeTopRight, resizeBottomLeft, resizeBottomRight }
    private var annDrag: AnnDrag = .none
    private var annDragStart = CGPoint.zero
    private var annDragStartRect = CGRect.zero

    /// Snap a point to the pixel grid of the current display to avoid sub-pixel
    /// interpolation (drawn image jitter / blur).
    private func alignToPixelGrid(_ point: CGPoint) -> CGPoint {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let unit = 1.0 / scale
        return CGPoint(
            x: round(point.x / unit) * unit,
            y: round(point.y / unit) * unit
        )
    }

    // MARK: - Toolbar Layout

    private struct ToolbarLayout {
        static let height = ScreenshotToolbarMetrics.height
        static let pad = ScreenshotToolbarMetrics.horizontalPadding
        static let gap = ScreenshotToolbarMetrics.buttonGap
        static let separatorWidth: CGFloat = 13

        static let swatchColors: [NSColor] = [
            .red, .systemOrange, .systemYellow, .systemGreen,
            .systemCyan, .systemBlue, .systemPurple, .white, .black,
        ]

        static func buttonWidth(_ button: ScreenshotToolbarButton) -> CGFloat {
            ScreenshotToolbarMetrics.buttonSize
        }

        static func hasSeparator(
            before button: ScreenshotToolbarButton,
            in buttons: [ScreenshotToolbarButton]
        ) -> Bool {
            button.id == "tool_rectangle" || button.id == "undo"
                || (button.id == "pin" && !buttons.contains(where: { $0.id == "undo" }))
        }

        static func totalWidth(_ buttons: [ScreenshotToolbarButton]) -> CGFloat {
            let separators = buttons.filter { hasSeparator(before: $0, in: buttons) }.count
            return CGFloat(buttons.count - 1) * gap
                + buttons.reduce(0) { $0 + buttonWidth($1) }
                + CGFloat(separators) * separatorWidth
                + pad * 2
        }
    }

    private var toolbarGlobalRect: CGRect = .null
    private var toolbarHitRects: [String: CGRect] = [:]

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let maxScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0
        layer?.contentsScale = maxScale
        layer?.backgroundColor = NSColor.clear.cgColor
        updateTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateTrackingArea() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    // MARK: - Enter Annotation Mode

    func enterAnnotationMode(image: NSImage, globalRect: CGRect, canMove: Bool = true) {
        enterAnnotationMode(image: image, cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil), globalRect: globalRect, canMove: canMove)
    }

    func enterAnnotationMode(image: NSImage, cgImage: CGImage?, globalRect: CGRect, canMove: Bool = true) {
        hideTooltip()
        tooltipTargetID = nil
        capturedImage = image
        capturedCGImage = cgImage
        annotationGlobalRect = globalRect
        captureRectLocal = CGRect(
            x: globalRect.origin.x - screenOffset.x,
            y: globalRect.origin.y - screenOffset.y,
            width: globalRect.width,
            height: globalRect.height
        )
        // Snap to pixel grid to avoid sub-pixel rendering jitter
        captureRectLocal.origin = alignToPixelGrid(captureRectLocal.origin)
        annotations = []
        currentTool = .arrow
        currentColor = .red
        numberCounter = 0
        selectedAnnotationIndex = nil
        inProgressItem = nil
        canMoveSelection = canMove
        originallyMovableSelection = canMove
        annotationToolbarExpanded = false
        annDrag = .none
        annDragStart = .zero
        annDragStartRect = .zero
        highlightedWindowRect = nil
        isSelecting = false
        selectionRect = .null
        mode = .annotating
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch mode {
        case .selecting:
            drawSelecting(ctx)
        case .adjusting:
            drawAdjusting(ctx)
        case .annotating:
            drawAnnotating(ctx)
        case .longScreenshotting:
            drawLongScreenshot(ctx)
        }
    }

    // MARK: - Selection Drawing

    private func drawSelecting(_ ctx: CGContext) {
        // Draw frozen background (full brightness) — pre-captured screenshot
        for (cgImage, screenFrame) in frozenBackgrounds {
            let localFrame = CGRect(
                x: screenFrame.origin.x - screenOffset.x,
                y: screenFrame.origin.y - screenOffset.y,
                width: screenFrame.width,
                height: screenFrame.height
            )
            ctx.draw(cgImage, in: localFrame)
        }

        if !selectionRect.isNull && isSelecting {
            let r = selectionRect
            let outsideRects = [
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: r.minY - bounds.minY),
                CGRect(x: bounds.minX, y: r.minY, width: r.minX - bounds.minX, height: r.height),
                CGRect(x: r.maxX, y: r.minY, width: bounds.maxX - r.maxX, height: r.height),
                CGRect(x: bounds.minX, y: r.maxY, width: bounds.width, height: bounds.maxY - r.maxY),
            ]
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            for rect in outsideRects where rect.width > 0 && rect.height > 0 {
                ctx.fill(rect)
            }

            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(r)

            let w = Int(r.width)
            let h = Int(r.height)
            let dimText = "\(w) × \(h)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            let textSize = (dimText as NSString).size(withAttributes: [.font: font])

            let labelPadding: CGFloat = 8
            var labelRect = CGRect(
                x: r.midX - (textSize.width + labelPadding * 2) / 2,
                y: r.maxY + 8,
                width: textSize.width + labelPadding * 2,
                height: textSize.height + 6
            )
            if labelRect.maxY > bounds.maxY - 4 {
                labelRect.origin.y = r.minY - labelRect.height - 4
            }

            let bg = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
            NSColor.black.withAlphaComponent(0.65).setFill()
            bg.fill()

            let textPt = CGPoint(
                x: labelRect.midX - textSize.width / 2,
                y: labelRect.midY - textSize.height / 2
            )
            (dimText as NSString).draw(at: textPt, withAttributes: [
                .font: font,
                .foregroundColor: NSColor.white
            ])
        } else {
            // No selection yet — dim the entire screen
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fill(bounds)
        }

        // Highlighted window border
        if let hwRect = highlightedWindowRect {
            // CGWindow bounds Y is from top of primary display (top-left origin).
            // Convert to bottom-left: primaryHeight - cgY - cgH
            let primaryH = NSScreen.main?.frame.height ?? bounds.height
            let blY = primaryH - hwRect.origin.y - hwRect.height
            let localRect = CGRect(
                x: hwRect.origin.x - screenOffset.x,
                y: blY - screenOffset.y,
                width: hwRect.width,
                height: hwRect.height
            )
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(2)
            ctx.setShadow(offset: .zero, blur: 8, color: NSColor.systemYellow.withAlphaComponent(0.5).cgColor)
            ctx.stroke(localRect)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }

        // Crosshair + Color picker
        if !isSelecting {
            let mouseGlobal = NSEvent.mouseLocation
            let localPt = CGPoint(
                x: mouseGlobal.x - screenOffset.x,
                y: mouseGlobal.y - screenOffset.y
            )
            if bounds.contains(localPt) {
                // Subtle outer ring
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: CGRect(x: localPt.x - 16, y: localPt.y - 16, width: 32, height: 32))

                // Crosshair lines
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: localPt.x - 14, y: localPt.y))
                ctx.addLine(to: CGPoint(x: localPt.x + 14, y: localPt.y))
                ctx.move(to: CGPoint(x: localPt.x, y: localPt.y - 14))
                ctx.addLine(to: CGPoint(x: localPt.x, y: localPt.y + 14))
                ctx.strokePath()
            }

            // Color picker magnifier + info
            drawColorPicker(ctx, at: localPt)
        }
    }

    // MARK: - Color Picker Drawing

    private func drawColorPicker(_ ctx: CGContext, at localPt: CGPoint) {
        guard let color = pickedColor else { return }
        guard bounds.contains(localPt) else { return }

        let gap: CGFloat = 14
        let screenW = bounds.width
        let screenH = bounds.height

        // Position: prefer top-right of cursor
        let panelW = magnifierSize
        let panelH: CGFloat = 62
        let totalH = magnifierSize + panelH
        let magOnRight = localPt.x + gap + magnifierSize + 20 <= screenW
        let magAbove = localPt.y - gap - totalH >= bounds.minY

        let magX = magOnRight ? localPt.x + gap : localPt.x - gap - magnifierSize
        let magY = magAbove ? localPt.y - gap - magnifierSize : localPt.y + gap + panelH
        let magRect = CGRect(x: magX, y: magY, width: magnifierSize, height: magnifierSize)

        // Panel flush with magnifier
        let panelX = magX
        let panelY = magAbove ? magY - panelH : magY + magnifierSize
        let panelRect = CGRect(x: max(4, min(panelX, screenW - panelW - 4)),
                               y: max(4, min(panelY, screenH - panelH - 4)),
                               width: panelW, height: panelH)

        // Draw zoomed pixels
        let globalPt = globalPoint(localPt)
        let halfSample = (magnifierSize / magnifierZoom) / 2

        for (cgImage, screenFrame) in frozenBackgrounds {
            guard screenFrame.contains(globalPt) else { continue }
            let scale = CGFloat(cgImage.width) / screenFrame.width
            let srcCx = (globalPt.x - screenFrame.origin.x) * scale
            let srcCy = CGFloat(cgImage.height) - (globalPt.y - screenFrame.origin.y) * scale
            let srcW = halfSample * 2 * scale
            let srcH = halfSample * 2 * scale
            let srcRect = CGRect(x: srcCx - srcW / 2, y: srcCy - srcH / 2, width: srcW, height: srcH)

            guard let cropped = cgImage.cropping(to: srcRect) else { continue }

            // Magnifier shadow
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 16, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(magRect)
            ctx.restoreGState()

            // Clip and draw zoomed image
            ctx.saveGState()
            ctx.clip(to: magRect)
            ctx.interpolationQuality = .none
            ctx.draw(cropped, in: magRect)

            // Pixel grid
            let gridColor = NSColor.black.withAlphaComponent(0.12).cgColor
            ctx.setStrokeColor(gridColor)
            ctx.setLineWidth(0.5)
            let pixelPt = magnifierSize / (halfSample * 2)
            for i in 1..<Int(halfSample * 2) {
                let offset = CGFloat(i) * pixelPt
                ctx.move(to: CGPoint(x: magRect.minX + offset, y: magRect.minY))
                ctx.addLine(to: CGPoint(x: magRect.minX + offset, y: magRect.maxY))
                ctx.move(to: CGPoint(x: magRect.minX, y: magRect.minY + offset))
                ctx.addLine(to: CGPoint(x: magRect.maxX, y: magRect.minY + offset))
            }
            ctx.strokePath()

            // Border
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(2.5)
            ctx.stroke(magRect)
            ctx.restoreGState()

            // Center ring
            let cx = magRect.midX
            let cy = magRect.midY
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            let ringRadius: CGFloat = 5
            ctx.strokeEllipse(in: CGRect(x: cx - ringRadius, y: cy - ringRadius,
                                          width: ringRadius * 2, height: ringRadius * 2))

            // Center crosshair
            let chGap: CGFloat = ringRadius + 2
            let chOuter: CGFloat = pixelPt * 1.2
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(0.5)
            let segments: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (cx + chGap, cy, cx + chOuter, cy),
                (cx - chGap, cy, cx - chOuter, cy),
                (cx, cy + chGap, cx, cy + chOuter),
                (cx, cy - chGap, cx, cy - chOuter),
            ]
            for (x1, y1, x2, y2) in segments {
                ctx.move(to: CGPoint(x: x1, y: y1))
                ctx.addLine(to: CGPoint(x: x2, y: y2))
            }
            ctx.strokePath()

            // Center dot
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: cx - 0.5, y: cy - 0.5, width: 1, height: 1))
            break
        }

        // Panel background (white)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: NSColor.black.withAlphaComponent(0.2).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(panelRect)
        ctx.restoreGState()

        // Panel border
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(panelRect)

        // Color swatch
        let swatchSize: CGFloat = 22
        let swatchX = panelRect.minX + 8
        let swatchY = panelRect.midY - swatchSize / 2
        let swatchRect = CGRect(x: swatchX, y: swatchY, width: swatchSize, height: swatchSize)
        let swatchPath = CGPath(roundedRect: swatchRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(swatchPath)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(swatchPath)
        ctx.strokePath()

        let textX = swatchRect.maxX + 8

        // Row 1: HEX
        let hexStr = colorHexString(color)
        let hexFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        let hexY = panelRect.midY + 8
        (hexStr as NSString).draw(at: CGPoint(x: textX, y: hexY), withAttributes: [
            .font: hexFont,
            .foregroundColor: NSColor.black
        ])

        // Row 2: RGB
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        let rgbStr = String(format: "%.0f  %.0f  %.0f", r * 255, g * 255, b * 255)
        let rgbFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let rgbY = panelRect.midY - 4
        (rgbStr as NSString).draw(at: CGPoint(x: textX, y: rgbY), withAttributes: [
            .font: rgbFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.45)
        ])

        // Row 3: Coordinates (top-left origin)
        let mousePos = NSEvent.mouseLocation
        let primaryH = NSScreen.main?.frame.height ?? 0
        let tlY = Int(primaryH - mousePos.y)
        let coordStr = "(\(Int(mousePos.x)), \(tlY))"
        let coordFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let coordY = panelRect.midY - 16
        (coordStr as NSString).draw(at: CGPoint(x: textX, y: coordY), withAttributes: [
            .font: coordFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.45)
        ])

        // Hint
        let hintText = "按 C 复制色号"
        let hintFont = NSFont.systemFont(ofSize: 9, weight: .regular)
        let hintSize = (hintText as NSString).size(withAttributes: [.font: hintFont])
        let hintX = panelRect.midX - hintSize.width / 2
        let hintY = panelRect.minY + 4
        (hintText as NSString).draw(at: CGPoint(x: hintX, y: hintY), withAttributes: [
            .font: hintFont,
            .foregroundColor: NSColor.black.withAlphaComponent(0.25)
        ])

        // Copy feedback toast
        if let feedback = colorCopyFeedback {
            let fbFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            let fbSize = (feedback as NSString).size(withAttributes: [.font: fbFont])
            let fbPad: CGFloat = 10
            let fbX = panelRect.midX - (fbSize.width + fbPad * 2) / 2
            let fbY = magAbove ? panelRect.minY - fbSize.height - 10 : panelRect.maxY + 10
            let fbRect = CGRect(x: fbX, y: fbY, width: fbSize.width + fbPad * 2, height: fbSize.height + 6)
            let fbPath = CGPath(roundedRect: fbRect, cornerWidth: 4, cornerHeight: 4, transform: nil)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(fbPath)
            ctx.fillPath()
            ctx.restoreGState()

            (feedback as NSString).draw(at: CGPoint(x: fbX + fbPad, y: fbY + 3), withAttributes: [
                .font: fbFont,
                .foregroundColor: NSColor.black
            ])
        }
    }

    private func colorHexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "#??????" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Adjusting Drawing

    private func drawAdjusting(_ ctx: CGContext) {
        // Draw frozen background (full brightness)
        for (cgImage, screenFrame) in frozenBackgrounds {
            let localFrame = CGRect(
                x: screenFrame.origin.x - screenOffset.x,
                y: screenFrame.origin.y - screenOffset.y,
                width: screenFrame.width,
                height: screenFrame.height
            )
            ctx.draw(cgImage, in: localFrame)
        }

        let r = selectionRect

        // Dim outside the selected region
        let outsideRects = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: r.minY - bounds.minY),
            CGRect(x: bounds.minX, y: r.minY, width: r.minX - bounds.minX, height: r.height),
            CGRect(x: r.maxX, y: r.minY, width: bounds.maxX - r.maxX, height: r.height),
            CGRect(x: bounds.minX, y: r.maxY, width: bounds.width, height: bounds.maxY - r.maxY),
        ]
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        for rect in outsideRects where rect.width > 0 && rect.height > 0 {
            ctx.fill(rect)
        }

        // Selection border
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(r)

        // Dimension label
        drawSelectionLabel(ctx, rect: r)

        // Resize handles
        let hs: CGFloat = 8
        let half = hs / 2
        let handlePts = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ]
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1)
        for pt in handlePts {
            let hr = CGRect(x: pt.x - half, y: pt.y - half, width: hs, height: hs)
            ctx.fill(hr)
            ctx.stroke(hr)
        }
    }

    private func drawSelectionLabel(_ ctx: CGContext, rect r: CGRect) {
        let w = Int(r.width)
        let h = Int(r.height)
        let dimText = "\(w) × \(h)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let textSize = (dimText as NSString).size(withAttributes: [.font: font])
        let labelPadding: CGFloat = 8
        var labelRect = CGRect(
            x: r.midX - (textSize.width + labelPadding * 2) / 2,
            y: r.maxY + 8,
            width: textSize.width + labelPadding * 2,
            height: textSize.height + 6
        )
        if labelRect.maxY > bounds.maxY - 4 {
            labelRect.origin.y = r.minY - labelRect.height - 4
        }
        let bg = NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        bg.fill()
        let textPt = CGPoint(
            x: labelRect.midX - textSize.width / 2,
            y: labelRect.midY - textSize.height / 2
        )
        (dimText as NSString).draw(at: textPt, withAttributes: [
            .font: font,
            .foregroundColor: NSColor.white
        ])
    }

    private func drawAnnotationHandles(_ ctx: CGContext, rect r: CGRect) {
        let hs: CGFloat = 8
        let half = hs / 2
        let handlePts = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ]
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1)
        for pt in handlePts {
            let hr = CGRect(x: pt.x - half, y: pt.y - half, width: hs, height: hs)
            ctx.fill(hr)
            ctx.stroke(hr)
        }
    }

    // MARK: - Long Screenshot Drawing

    private func drawLongScreenshot(_ ctx: CGContext) {
        let r = longScreenshotGlobalRect

        let localRect = CGRect(
            x: r.origin.x - screenOffset.x,
            y: r.origin.y - screenOffset.y,
            width: r.width, height: r.height
        )
        let outsideRects = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: localRect.minY - bounds.minY),
            CGRect(x: bounds.minX, y: localRect.minY, width: localRect.minX - bounds.minX, height: localRect.height),
            CGRect(x: localRect.maxX, y: localRect.minY, width: bounds.maxX - localRect.maxX, height: localRect.height),
            CGRect(x: bounds.minX, y: localRect.maxY, width: bounds.width, height: bounds.maxY - localRect.maxY),
        ]
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.58).cgColor)
        for rect in outsideRects where rect.width > 0 && rect.height > 0 {
            ctx.fill(rect)
        }

        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(localRect)

        drawSelectionLabel(ctx, rect: localRect)
        drawLongScreenshotPreview(ctx, selectionRect: localRect)
    }

    private func drawLongScreenshotPreview(_ ctx: CGContext, selectionRect: CGRect) {
        let previewW: CGFloat = 150
        let previewH = min(bounds.height - 80, max(260, selectionRect.height))
        let gap: CGFloat = 24
        var x = selectionRect.maxX + gap
        if x + previewW > bounds.maxX - 20 {
            x = selectionRect.minX - gap - previewW
        }
        if x < bounds.minX + 20 {
            x = max(bounds.minX + 20, selectionRect.maxX - previewW - 12)
        }

        let y = min(max(selectionRect.maxY - previewH, bounds.minY + 40), bounds.maxY - previewH - 40)
        let previewRect = CGRect(x: x, y: y, width: previewW, height: previewH)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        let bgPath = NSBezierPath(roundedRect: previewRect, xRadius: 2, yRadius: 2)
        NSColor.white.setFill()
        bgPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(previewRect)

        let contentRect = previewRect.insetBy(dx: 8, dy: 8)
        ctx.saveGState()
        ctx.clip(to: contentRect)
        if let image = longScreenshotPreviewImage, image.size.width > 0, image.size.height > 0 {
            var scale = contentRect.width / image.size.width
            let drawH = image.size.height * scale
            if drawH > contentRect.height {
                scale = contentRect.height / image.size.height
            }
            let drawW = image.size.width * scale
            let drawRect = CGRect(
                x: contentRect.midX - drawW / 2,
                y: contentRect.maxY - min(drawH, contentRect.height),
                width: drawW,
                height: min(drawH, contentRect.height)
            )
            image.draw(in: drawRect)
        } else {
            for i in 0..<18 {
                let rowY = previewRect.maxY - 18 - CGFloat(i) * 16
                let lineW = previewW - CGFloat((i % 4) * 14) - 28
                ctx.setFillColor(NSColor.black.withAlphaComponent(i % 5 == 0 ? 0.18 : 0.1).cgColor)
                ctx.fill(CGRect(x: previewRect.minX + 14, y: rowY, width: lineW, height: 4))
            }
        }
        ctx.restoreGState()

        let statusFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let statusAttributes: [NSAttributedString.Key: Any] = [
            .font: statusFont,
            .foregroundColor: NSColor.white,
        ]
        let statusSize = (longScreenshotStatusText as NSString).size(withAttributes: statusAttributes)
        let statusWidth = min(bounds.width - 16, statusSize.width + 18)
        let statusX = max(
            bounds.minX + 8,
            min(previewRect.midX - statusWidth / 2, bounds.maxX - statusWidth - 8)
        )
        let statusRect = CGRect(
            x: statusX,
            y: previewRect.minY - 28,
            width: statusWidth,
            height: 22
        )
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: statusRect, xRadius: 7, yRadius: 7).fill()
        (longScreenshotStatusText as NSString).draw(
            in: statusRect.insetBy(dx: 9, dy: 4),
            withAttributes: statusAttributes
        )
    }

    // MARK: - Annotation Drawing

    private func drawAnnotating(_ ctx: CGContext) {
        let cr = captureRectLocal

        // Draw frozen background with the selection rect clipped out,
        // so the captured image draws on a clean area with no sub-pixel ghosting
        for (cgImage, screenFrame) in frozenBackgrounds {
            let localFrame = CGRect(
                x: screenFrame.origin.x - screenOffset.x,
                y: screenFrame.origin.y - screenOffset.y,
                width: screenFrame.width,
                height: screenFrame.height
            )
            ctx.saveGState()
            ctx.addRect(localFrame)
            ctx.addRect(cr)
            ctx.clip(using: .evenOdd)
            ctx.draw(cgImage, in: localFrame)
            ctx.restoreGState()
        }

        // Dim everything outside the capture rect
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)

        // Draw dim around the capture rect (not over it)
        let outsideRects = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: cr.minY - bounds.minY), // bottom
            CGRect(x: bounds.minX, y: cr.minY, width: cr.minX - bounds.minX, height: cr.height), // left
            CGRect(x: cr.maxX, y: cr.minY, width: bounds.maxX - cr.maxX, height: cr.height), // right
            CGRect(x: bounds.minX, y: cr.maxY, width: bounds.width, height: bounds.maxY - cr.maxY), // top
        ]
        for r in outsideRects where r.width > 0 && r.height > 0 {
            ctx.fill(r)
        }

        // Draw captured image on the clean (clipped-out) area
        if let cgImg = capturedCGImage {
            ctx.draw(cgImg, in: cr)
        }

        // Show selection border, dimensions and resize handles when movable
        if canMoveSelection {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(cr)
            drawSelectionLabel(ctx, rect: cr)
            drawAnnotationHandles(ctx, rect: cr)
        }

        // Draw annotations
        for annotation in annotations {
            drawAnnotation(annotation, in: ctx)
        }
        if let inProgress = inProgressItem {
            drawAnnotation(inProgress, in: ctx)
        }

        // Draw selected annotation highlight
        if let selIdx = selectedAnnotationIndex, selIdx < annotations.count {
            let sel = annotations[selIdx]
            var highlightRect: CGRect?
            switch sel.tool {
            case .arrow:
                let start = imageToView(sel.startPoint)
                let end = imageToView(sel.endPoint)
                highlightRect = rectFromPoints(start, end).insetBy(dx: -6, dy: -6)
            case .mosaic:
                let origin = imageToView(sel.mosaicRect.origin)
                let size = CGSize(width: sel.mosaicRect.width, height: sel.mosaicRect.height)
                highlightRect = CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -4)
            case .rectangle, .ellipse, .highlight:
                let start = imageToView(sel.startPoint)
                let end = imageToView(sel.endPoint)
                highlightRect = rectFromPoints(start, end).insetBy(dx: -6, dy: -6)
            case .text, .number, .select:
                break
            }
            if let hr = highlightRect {
                ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.6).cgColor)
                ctx.setLineWidth(2)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.stroke(hr)
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }

        // Draw highlight dimming last so it correctly dims everything (including
        // annotations like mosaic, arrows, etc.) outside the highlight rects.
        drawHighlightDimming(ctx)

        // Draw toolbar
        drawToolbar(ctx)
    }

    private func drawAnnotation(_ annotation: AnnotationItem, in ctx: CGContext) {
        switch annotation.tool {
        case .arrow: drawArrow(annotation, in: ctx)
        case .text: drawText(annotation, in: ctx)
        case .number: drawNumber(annotation, in: ctx)
        case .mosaic: drawMosaic(annotation, in: ctx)
        case .rectangle: drawRectShape(annotation, in: ctx)
        case .ellipse: drawEllipseShape(annotation, in: ctx)
        case .highlight: drawHighlightShape(annotation, in: ctx)
        case .select: break
        }
    }

    // MARK: - Coordinate Helpers

    private func globalPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + screenOffset.x, y: local.y + screenOffset.y)
    }

    private func globalRect(_ local: CGRect) -> CGRect {
        CGRect(
            x: local.origin.x + screenOffset.x,
            y: local.origin.y + screenOffset.y,
            width: local.width,
            height: local.height
        )
    }

    /// Convert from view coordinates to image-relative coordinates (bottom-left).
    private func viewToImage(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: viewPoint.x - captureRectLocal.origin.x,
            y: viewPoint.y - captureRectLocal.origin.y
        )
    }

    /// Convert from image-relative coordinates to view coordinates.
    private func imageToView(_ imagePoint: CGPoint) -> CGPoint {
        CGPoint(
            x: imagePoint.x + captureRectLocal.origin.x,
            y: imagePoint.y + captureRectLocal.origin.y
        )
    }

    // MARK: - Pixel Color Sampling

    private func sampleColor(at localPt: CGPoint) -> NSColor? {
        let globalPt = globalPoint(localPt)
        for (cgImage, screenFrame) in frozenBackgrounds {
            guard screenFrame.contains(globalPt) else { continue }
            let scale = CGFloat(cgImage.width) / screenFrame.width
            let px = Int(round((globalPt.x - screenFrame.origin.x) * scale))
            let py = Int(round((screenFrame.origin.y + screenFrame.height - globalPt.y) * scale))
            guard px >= 0, py >= 0, px < cgImage.width, py < cgImage.height else { return nil }

            guard let data = cgImage.dataProvider?.data else { return nil }
            let bytes = CFDataGetBytePtr(data)
            let bpr = cgImage.bytesPerRow
            let bpp = cgImage.bitsPerPixel / 8
            let offset = py * bpr + px * bpp

            let ri: Int, gi: Int, bi: Int, ai: Int
            let byteOrder = cgImage.bitmapInfo.intersection(.byteOrderMask)
            if byteOrder == .byteOrder32Little {
                // BGRA
                ri = 2; gi = 1; bi = 0; ai = 3
            } else {
                // RGBA (byteOrder32Big or default)
                ri = 0; gi = 1; bi = 2; ai = 3
            }

            let r = CGFloat(bytes?[offset + ri] ?? 0) / 255.0
            let g = CGFloat(bytes?[offset + gi] ?? 0) / 255.0
            let b = CGFloat(bytes?[offset + bi] ?? 0) / 255.0
            let a = bpp >= 4 ? CGFloat(bytes?[offset + ai] ?? 255) / 255.0 : 1.0

            let cgCS = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let nsCS = NSColorSpace(cgColorSpace: cgCS)!
            return NSColor(colorSpace: nsCS, components: [r, g, b, a], count: 4)
        }
        return nil
    }

    // MARK: - Arrow Drawing

    private func drawArrow(_ annotation: AnnotationItem, in ctx: CGContext) {
        let start = imageToView(annotation.startPoint)
        let end = imageToView(annotation.endPoint)
        drawTaperedArrow(start: start, end: end, color: annotation.color, in: ctx)
    }

    private func drawTaperedArrow(
        start: CGPoint,
        end: CGPoint,
        color: NSColor,
        in ctx: CGContext
    ) {
        let points = ScreenshotAnnotationGeometry.taperedArrowPolygon(start: start, end: end)
        guard let first = points.first else { return }

        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - Text Drawing

    private func drawText(_ annotation: AnnotationItem, in ctx: CGContext) {
        let point = imageToView(annotation.startPoint)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: annotation.fontSize),
            .foregroundColor: annotation.color,
        ]
        (annotation.text as NSString).draw(at: point, withAttributes: attrs)
    }

    // MARK: - Number Drawing

    private func textColorForFillColor(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.5 ? .black : .white
    }

    private func drawNumber(_ annotation: AnnotationItem, in ctx: CGContext) {
        let point = imageToView(annotation.startPoint)
        let radius: CGFloat = 14
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)

        ctx.saveGState()
        ctx.setFillColor(annotation.color.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: rect)

        let text = "\(annotation.number)"
        let font = NSFont.boldSystemFont(ofSize: 14)
        let textColor = textColorForFillColor(annotation.color)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let attrStr = NSAttributedString(string: text, attributes: textAttrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, .excludeTypographicLeading)
        let textPoint = CGPoint(
            x: point.x - bounds.width / 2 - bounds.origin.x,
            y: point.y - bounds.midY
        )
        ctx.textPosition = textPoint
        CTLineDraw(line, ctx)
    }

    // MARK: - Mosaic Drawing

    private func drawRectShape(_ annotation: AnnotationItem, in ctx: CGContext) {
        let start = imageToView(annotation.startPoint)
        let end = imageToView(annotation.endPoint)
        let rect = rectFromPoints(start, end)
        ctx.setStrokeColor(annotation.color.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(rect)
    }

    private func drawEllipseShape(_ annotation: AnnotationItem, in ctx: CGContext) {
        let start = imageToView(annotation.startPoint)
        let end = imageToView(annotation.endPoint)
        let rect = rectFromPoints(start, end)
        ctx.setStrokeColor(annotation.color.cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: rect)
    }

    private func drawHighlightDimming(_ ctx: CGContext) {
        let cr = captureRectLocal
        var rects: [CGRect] = annotations.filter { $0.tool == .highlight }.map {
            rectFromPoints(imageToView($0.startPoint), imageToView($0.endPoint)).intersection(cr)
        }.filter { !$0.isNull && $0.width > 1 && $0.height > 1 }

        if let inProgress = inProgressItem, inProgress.tool == .highlight {
            let rect = rectFromPoints(imageToView(inProgress.startPoint), imageToView(inProgress.endPoint)).intersection(cr)
            if !rect.isNull && rect.width > 1 && rect.height > 1 {
                rects.append(rect)
            }
        }

        guard !rects.isEmpty else { return }

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.40).cgColor)
        let path = CGMutablePath()
        path.addRect(cr)
        for rect in rects {
            path.addRect(rect)
        }
        ctx.addPath(path)
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()
    }

    private func drawHighlightShape(_ annotation: AnnotationItem, in ctx: CGContext) {
        // Highlight dimming is handled globally in drawHighlightDimming
    }

    private func drawMosaic(_ annotation: AnnotationItem, in ctx: CGContext) {
        let rect = annotation.mosaicRect // bottom-left image coords
        let viewOrigin = imageToView(rect.origin)
        let viewRect = CGRect(origin: viewOrigin, size: rect.size)

        if viewRect.width < 2 || viewRect.height < 2 { return }

        // Flip Y to top-left for CGImage cropping
        let imageH = capturedImage?.size.height ?? rect.height
        let flippedRect = CGRect(
            x: rect.origin.x,
            y: imageH - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        guard let pixelated = pixelateRegion(flippedRect, pixelSize: annotation.pixelSize) else {
            ctx.setFillColor(NSColor.gray.cgColor)
            ctx.fill(viewRect)
            return
        }

        pixelated.draw(in: viewRect)
    }

    private func pixelateRegion(_ region: CGRect, pixelSize: Int) -> NSImage? {
        guard let image = capturedImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let scale = image.recommendedLayerContentsScale(0)
        let scaledRect = CGRect(
            x: region.origin.x * scale,
            y: region.origin.y * scale,
            width: region.width * scale,
            height: region.height * scale
        )

        guard let cropped = cgImage.cropping(to: scaledRect) else { return nil }

        let ciImage = CIImage(cgImage: cropped)
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(max(Float(pixelSize), 1), forKey: kCIInputScaleKey)

        guard let output = filter.outputImage else { return nil }

        let rep = NSCIImageRep(ciImage: output)
        let result = NSImage(size: region.size)
        result.addRepresentation(rep)
        return result
    }

    /// Render pixelated region directly to CGImage (avoids NSImage/NSGraphicsContext in export).
    private func pixelatedCGImage(region: CGRect, pixelSize: Int) -> CGImage? {
        guard let baseCG = capturedCGImage else { return nil }
        let imgW = capturedImage?.size.width ?? CGFloat(baseCG.width)
        let imgH = capturedImage?.size.height ?? CGFloat(baseCG.height)
        let scaleX = CGFloat(baseCG.width) / max(imgW, 1)
        let scaleY = CGFloat(baseCG.height) / max(imgH, 1)
        let scaledRect = CGRect(
            x: region.origin.x * scaleX,
            y: region.origin.y * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY
        )
        guard let cropped = baseCG.cropping(to: scaledRect) else { return nil }
        let ciImage = CIImage(cgImage: cropped)
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(max(Float(pixelSize), 1), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: output.extent)
    }

    // MARK: - Toolbar Drawing

    private func drawFlatToolbarBackground(_ rect: CGRect, context ctx: CGContext) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: ScreenshotToolbarMetrics.cornerRadius,
            cornerHeight: ScreenshotToolbarMetrics.cornerRadius,
            transform: nil
        )
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 8,
            color: NSColor.black.withAlphaComponent(0.24).cgColor
        )
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.98).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(ScreenshotToolbarMetrics.borderWidth)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawLongScreenshotGlyph(in rect: CGRect, context ctx: CGContext) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let scale: CGFloat = 0.84

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Open capture frame at the top, matching the reference toolbar icon.
        ctx.move(to: CGPoint(x: center.x - 9 * scale, y: center.y + 2 * scale))
        ctx.addLine(to: CGPoint(x: center.x - 9 * scale, y: center.y + 10 * scale))
        ctx.addLine(to: CGPoint(x: center.x + 9 * scale, y: center.y + 10 * scale))
        ctx.addLine(to: CGPoint(x: center.x + 9 * scale, y: center.y + 2 * scale))
        ctx.strokePath()

        // Symmetric scissors below the frame.
        let ringRadius: CGFloat = 3.1 * scale
        let leftRing = CGPoint(x: center.x - 5.5 * scale, y: center.y - 6 * scale)
        let rightRing = CGPoint(x: center.x + 5.5 * scale, y: center.y - 6 * scale)
        ctx.strokeEllipse(in: CGRect(
            x: leftRing.x - ringRadius, y: leftRing.y - ringRadius,
            width: ringRadius * 2, height: ringRadius * 2
        ))
        ctx.strokeEllipse(in: CGRect(
            x: rightRing.x - ringRadius, y: rightRing.y - ringRadius,
            width: ringRadius * 2, height: ringRadius * 2
        ))

        let crossing = CGPoint(x: center.x, y: center.y - 1.5 * scale)
        ctx.move(to: CGPoint(x: leftRing.x + 2.2 * scale, y: leftRing.y + 2.2 * scale))
        ctx.addLine(to: crossing)
        ctx.addLine(to: CGPoint(x: center.x + 6 * scale, y: center.y + 5.5 * scale))
        ctx.move(to: CGPoint(x: rightRing.x - 2.2 * scale, y: rightRing.y + 2.2 * scale))
        ctx.addLine(to: crossing)
        ctx.addLine(to: CGPoint(x: center.x - 6 * scale, y: center.y + 5.5 * scale))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawAnnotateGlyph(in rect: CGRect, context ctx: CGContext) {
        let center = CGPoint(x: rect.midX, y: rect.midY)

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let pen = CGMutablePath()
        pen.move(to: CGPoint(x: center.x - 9, y: center.y - 7))
        pen.addLine(to: CGPoint(x: center.x - 7, y: center.y - 1))
        pen.addLine(to: CGPoint(x: center.x + 4, y: center.y + 9))
        pen.addLine(to: CGPoint(x: center.x + 8, y: center.y + 5))
        pen.addLine(to: CGPoint(x: center.x - 2, y: center.y - 5))
        pen.closeSubpath()
        ctx.addPath(pen)
        ctx.strokePath()

        ctx.move(to: CGPoint(x: center.x + 2, y: center.y + 7))
        ctx.addLine(to: CGPoint(x: center.x + 6, y: center.y + 3))
        ctx.move(to: CGPoint(x: center.x - 7, y: center.y - 1))
        ctx.addLine(to: CGPoint(x: center.x - 2, y: center.y - 5))
        ctx.move(to: CGPoint(x: center.x - 9, y: center.y - 9))
        ctx.addLine(to: CGPoint(x: center.x + 7, y: center.y - 9))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawToolbar(_ ctx: CGContext) {
        let cr = captureRectLocal
        let buttons = ScreenshotToolbarConfiguration.buttons(
            for: annotationToolbarExpanded ? .annotating : .quick
        )
        let tH = ToolbarLayout.height
        let tW = ToolbarLayout.totalWidth(buttons)

        // Position below capture rect, centered
        var tX = cr.midX - tW / 2
        var tY = cr.minY - tH - 8
        if tY < bounds.minY + 4 { tY = cr.maxY + 8 }
        if tY + tH > bounds.maxY - 4 { tY = bounds.maxY - tH - 8 }
        tX = max(bounds.minX + 4, min(tX, bounds.maxX - tW - 4))

        toolbarGlobalRect = CGRect(x: tX, y: tY, width: tW, height: tH)
        toolbarHitRects = [:]

        drawFlatToolbarBackground(toolbarGlobalRect, context: ctx)

        var curX = tX + ToolbarLayout.pad
        for button in buttons {
            if ToolbarLayout.hasSeparator(before: button, in: buttons) {
                let separatorX = curX + ToolbarLayout.separatorWidth / 2
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: separatorX, y: tY + 10))
                ctx.addLine(to: CGPoint(x: separatorX, y: tY + tH - 10))
                ctx.strokePath()
                curX += ToolbarLayout.separatorWidth
            }

            let buttonHeight = ScreenshotToolbarMetrics.buttonSize
            let rect = CGRect(
                x: curX, y: tY + (tH - buttonHeight) / 2,
                width: ToolbarLayout.buttonWidth(button), height: buttonHeight
            )
            toolbarHitRects[button.id] = rect

            let isSelectedTool = AnnotationTool.toolbarTool(for: button.id) == currentTool
                && !canMoveSelection
            if isSelectedTool {
                let selectedPath = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                NSColor.black.withAlphaComponent(0.09).setFill()
                selectedPath.fill()
            }

            if button.id == "annotate" {
                drawAnnotateGlyph(in: rect, context: ctx)
            } else if button.id == "longscreenshot" {
                drawLongScreenshotGlyph(in: rect, context: ctx)
            } else if button.id == "color_picker" {
                ctx.setFillColor(currentColor.cgColor)
                ctx.fillEllipse(in: rect.insetBy(dx: 8, dy: 8))
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.78).cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: rect.insetBy(dx: 8, dy: 8))
            } else if button.id == "tool_text" {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 24, weight: .light),
                    .foregroundColor: NSColor.black,
                ]
                let glyph = "A" as NSString
                let size = glyph.size(withAttributes: attributes)
                glyph.draw(
                    at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                    withAttributes: attributes
                )
            } else {
                if !button.symbol.isEmpty {
                    let iconSize = ScreenshotToolbarMetrics.iconPointSize + 1
                    let iconX = rect.midX - iconSize / 2
                    let iconRect = CGRect(x: iconX, y: rect.midY - iconSize / 2,
                                          width: iconSize, height: iconSize)
                    let iconColor: NSColor = button.id == "undo" && annotations.isEmpty
                        ? NSColor.black.withAlphaComponent(0.24)
                        : .black
                    let symbolConfig = NSImage.SymbolConfiguration(
                        pointSize: ScreenshotToolbarMetrics.iconPointSize,
                        weight: .light
                    )
                        .applying(NSImage.SymbolConfiguration(paletteColors: [iconColor]))
                    NSImage(systemSymbolName: button.symbol, accessibilityDescription: button.title)?
                        .withSymbolConfiguration(symbolConfig)?.draw(in: iconRect)
                }
                if let title = button.title {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: NSColor.black,
                    ]
                    let text = title as NSString
                    let textSize = text.size(withAttributes: attributes)
                    let textX = button.symbol.isEmpty ? rect.midX - textSize.width / 2 : rect.minX + 29
                    text.draw(at: CGPoint(x: textX, y: rect.midY - textSize.height / 2),
                              withAttributes: attributes)
                }
            }

            curX = rect.maxX + ToolbarLayout.gap
        }
    }

    private var tooltipLabel: NSTextField?
    private var tooltipTargetID: String?

    private func showTooltip(for id: String, buttonRect: CGRect) {
        let tips: [String: String] = [
            "annotate": "标注", "back": "返回截图", "more": "更多操作",
            "color_picker": "选择颜色",
            "tool_arrow": "箭头", "tool_text": "文字", "tool_number": "编号",
            "tool_mosaic": "马赛克", "tool_rectangle": "矩形", "tool_ellipse": "椭圆",
            "tool_highlight": "区域高亮",
            "undo": "撤销", "longscreenshot": "长截图", "save": "保存", "copy": "复制",
            "pin": "固定", "cancel": "取消",
        ]
        guard let text = tips[id] else { hideTooltip(); return }

        let label: NSTextField
        if let existing = tooltipLabel {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 14)
            label.textColor = NSColor.white
            label.isBordered = false
            label.isEditable = false
            label.isSelectable = false
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
            label.layer?.cornerRadius = 4
            label.alignment = .center
            addSubview(label)
            tooltipLabel = label
        }

        label.stringValue = text
        label.sizeToFit()

        let padding: CGFloat = 8
        let labelW = label.frame.width + padding * 2
        let labelH = label.frame.height + padding
        let x = buttonRect.midX - labelW / 2
        let y = buttonRect.minY - labelH - 6
        label.frame = CGRect(x: x, y: y, width: labelW, height: labelH)

        label.isHidden = false
    }

    private func hideTooltip() {
        tooltipLabel?.isHidden = true
    }

    // MARK: - Mouse Events

    override func hitTest(_ point: NSPoint) -> NSView? {
        if mode == .longScreenshotting { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        switch mode {
        case .selecting:
            mouseDownSelecting(event)
        case .adjusting:
            mouseDownAdjusting(event)
        case .annotating:
            mouseDownAnnotating(event)
        case .longScreenshotting:
            break // ignored — overlay window has ignoresMouseEvents = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch mode {
        case .selecting:
            mouseDraggedSelecting(event)
        case .adjusting:
            mouseDraggedAdjusting(event)
        case .annotating:
            mouseDraggedAnnotating(event)
        case .longScreenshotting:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .selecting:
            mouseUpSelecting(event)
        case .adjusting:
            mouseUpAdjusting(event)
        case .annotating:
            mouseUpAnnotating(event)
        case .longScreenshotting:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        switch mode {
        case .selecting:
            mouseMovedSelecting(event)
        case .adjusting:
            mouseMovedAdjusting(event)
        case .annotating:
            mouseMovedAnnotating(event)
        case .longScreenshotting:
            break
        }
    }

    // MARK: - Frozen Background Cropping

    private func croppedImage(from globalRect: CGRect) -> (NSImage, CGSize, CGImage)? {
        for (cgImage, screenFrame) in frozenBackgrounds {
            let inter = screenFrame.intersection(globalRect)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }

            let scale = CGFloat(cgImage.width) / screenFrame.width
            let originX = round((inter.origin.x - screenFrame.origin.x) * scale)
            let originY = round(CGFloat(cgImage.height) - (inter.origin.y - screenFrame.origin.y + inter.height) * scale)
            let cropW = round(inter.width * scale)
            let cropH = round(inter.height * scale)
            let cropRect = CGRect(x: originX, y: originY, width: cropW, height: cropH)

            guard let cropped = cgImage.cropping(to: cropRect) else { continue }
            capturedCGImage = cropped
            let adjustedSize = NSSize(width: cropW / scale, height: cropH / scale)
            return (NSImage(cgImage: cropped, size: adjustedSize), adjustedSize, cropped)
        }
        capturedCGImage = nil
        return nil
    }

    // MARK: - Selection Mouse Events

    private func mouseDownSelecting(_ event: NSEvent) {
        let pt = event.locationInWindow
        NSLog("[ScreenshotTool] mouseDown pt=\(pt) isSelecting=\(isSelecting)")

        if isSelecting { return }
        isSelecting = true
        selectionStart = pt
        selectionRect = CGRect(origin: pt, size: .zero)
        highlightedWindowRect = nil
    }

    private func mouseDraggedSelecting(_ event: NSEvent) {
        guard isSelecting else { return }
        let pt = event.locationInWindow
        selectionRect = CGRect(
            x: min(selectionStart.x, pt.x),
            y: min(selectionStart.y, pt.y),
            width: abs(pt.x - selectionStart.x),
            height: abs(pt.y - selectionStart.y)
        )
        highlightedWindowRect = nil
        needsDisplay = true
    }

    private func mouseUpSelecting(_ event: NSEvent) {
        guard isSelecting else { return }
        isSelecting = false

        if selectionRect.width >= 10 && selectionRect.height >= 10 {
            confirmSelection()
        } else {
            let globalPt = globalPoint(event.locationInWindow)
            if let winInfo = WindowDetector.windowInfoAtPoint(globalPt, excluding: window?.windowNumber) {
                onSelectionComplete?(.window(winInfo.rect, windowNumber: winInfo.windowNumber))
            } else {
                onSelectionComplete?(.cancel)
            }
            selectionRect = .null
            needsDisplay = true
        }
    }

    private func mouseMovedSelecting(_ event: NSEvent) {
        guard !isSelecting else { return }
        NSCursor.crosshair.set()

        let localPt = event.locationInWindow
        let picked = sampleColor(at: localPt)
        pickedColor = picked

        let globalPt = globalPoint(localPt)
        if let winRect = WindowDetector.windowAtPoint(globalPt, excluding: window?.windowNumber) {
            if highlightedWindowRect != winRect {
                highlightedWindowRect = winRect
            }
        } else {
            if highlightedWindowRect != nil {
                highlightedWindowRect = nil
            }
        }
        needsDisplay = true
    }

    // MARK: - Adjusting Mouse Events

    private func mouseDownAdjusting(_ event: NSEvent) {
        let pt = event.locationInWindow
        if event.clickCount >= 2 { confirmSelection(); return }

        // Check handle hit
        let action = hitTestAdjustHandle(at: pt)
        if action != .none {
            adjustDrag = action
            adjustStartPoint = pt
            adjustStartRect = selectionRect
            return
        }

        // Inside selection → move
        if selectionRect.contains(pt) {
            adjustDrag = .move
            adjustStartPoint = pt
            adjustStartRect = selectionRect
            return
        }

        // Clicked outside → start new selection
        cancelAdjusting()
        mode = .selecting
        isSelecting = true
        selectionStart = pt
        selectionRect = CGRect(origin: pt, size: .zero)
        highlightedWindowRect = nil
        needsDisplay = true
    }

    private func mouseDraggedAdjusting(_ event: NSEvent) {
        switch adjustDrag {
        case .none:
            return
        case .move:
            let pt = event.locationInWindow
            let delta = CGPoint(x: pt.x - adjustStartPoint.x, y: pt.y - adjustStartPoint.y)
            var r = adjustStartRect
            r.origin.x = max(bounds.minX, min(adjustStartRect.origin.x + delta.x, bounds.maxX - adjustStartRect.width))
            r.origin.y = max(bounds.minY, min(adjustStartRect.origin.y + delta.y, bounds.maxY - adjustStartRect.height))
            selectionRect = r
        default:
            resizeSelection(with: event.locationInWindow)
        }
        needsDisplay = true
    }

    private func mouseUpAdjusting(_ event: NSEvent) {
        adjustDrag = .none
        adjustStartPoint = .zero
        adjustStartRect = .zero
    }

    private func mouseMovedAdjusting(_ event: NSEvent) {
        let pt = event.locationInWindow

        // Over a handle
        let action = hitTestAdjustHandle(at: pt)
        if action != .none {
            switch action {
            case .resizeLeft, .resizeRight: NSCursor.resizeLeftRight.set()
            case .resizeTop, .resizeBottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
            return
        }

        // Over the selection
        if selectionRect.contains(pt) {
            NSCursor.openHand.set()
            return
        }

        NSCursor.crosshair.set()
    }

    private func hitTestAdjustHandle(at point: CGPoint) -> AdjustDrag {
        let hs: CGFloat = 12 // wider hit area
        let half = hs / 2
        let r = selectionRect
        let handles: [(CGRect, AdjustDrag)] = [
            (CGRect(x: r.minX - half, y: r.minY - half, width: hs, height: hs), .resizeBottomLeft),
            (CGRect(x: r.midX - half, y: r.minY - half, width: hs, height: hs), .resizeBottom),
            (CGRect(x: r.maxX - half, y: r.minY - half, width: hs, height: hs), .resizeBottomRight),
            (CGRect(x: r.maxX - half, y: r.midY - half, width: hs, height: hs), .resizeRight),
            (CGRect(x: r.maxX - half, y: r.maxY - half, width: hs, height: hs), .resizeTopRight),
            (CGRect(x: r.midX - half, y: r.maxY - half, width: hs, height: hs), .resizeTop),
            (CGRect(x: r.minX - half, y: r.maxY - half, width: hs, height: hs), .resizeTopLeft),
            (CGRect(x: r.minX - half, y: r.midY - half, width: hs, height: hs), .resizeLeft),
        ]
        for (rect, action) in handles where rect.contains(point) {
            return action
        }
        return .none
    }

    private func resizeSelection(with point: CGPoint) {
        let minSize: CGFloat = 10
        let start = adjustStartRect
        let clamped = CGPoint(x: max(bounds.minX, min(point.x, bounds.maxX)),
                              y: max(bounds.minY, min(point.y, bounds.maxY)))

        var newMinX = start.minX, newMinY = start.minY
        var newMaxX = start.maxX, newMaxY = start.maxY

        switch adjustDrag {
        case .resizeLeft, .resizeTopLeft, .resizeBottomLeft:
            newMinX = min(start.maxX - minSize, clamped.x)
        case .resizeRight, .resizeTopRight, .resizeBottomRight:
            newMaxX = max(start.minX + minSize, clamped.x)
        default:
            break
        }
        switch adjustDrag {
        case .resizeBottom, .resizeBottomLeft, .resizeBottomRight:
            newMinY = min(start.maxY - minSize, clamped.y)
        case .resizeTop, .resizeTopLeft, .resizeTopRight:
            newMaxY = max(start.minY + minSize, clamped.y)
        default:
            break
        }

        selectionRect = CGRect(x: newMinX, y: newMinY,
                               width: newMaxX - newMinX,
                               height: newMaxY - newMinY)
    }

    private func confirmSelection() {
        guard selectionRect.width >= 10 && selectionRect.height >= 10 else { return }
        let globalSel = globalRect(selectionRect)

        adjustDrag = .none
        selectionRect = .null
        needsDisplay = true

        if !frozenBackgrounds.isEmpty, let (image, adjustedSize, originalCG) = croppedImage(from: globalSel) {
            let adjustedGlobalRect = CGRect(
                x: globalSel.midX - adjustedSize.width / 2,
                y: globalSel.midY - adjustedSize.height / 2,
                width: adjustedSize.width,
                height: adjustedSize.height
            )
            // Pass the original cropped CGImage directly to avoid NSImage → CGImage round-trip
            // which can lose Retina scale info and cause blurry text.
            enterAnnotationMode(image: image, cgImage: originalCG, globalRect: adjustedGlobalRect)
        } else {
            onSelectionComplete?(.capture(globalSel))
        }
    }

    private func cancelAdjusting() {
        adjustDrag = .none
        adjustStartPoint = .zero
        adjustStartRect = .zero
        mode = .selecting
        isSelecting = false
        selectionRect = .null
        highlightedWindowRect = nil
        needsDisplay = true
    }

    private func mouseMovedAnnotating(_ event: NSEvent) {
        let pt = event.locationInWindow

        if let hitID = hitTestToolbar(pt) {
            NSCursor.pointingHand.set()
            let toolbarMode: ScreenshotToolbarMode = annotationToolbarExpanded ? .annotating : .quick
            if !ScreenshotToolbarConfiguration.showsHoverTooltips(for: toolbarMode) {
                tooltipTargetID = nil
                hideTooltip()
            } else if hitID != tooltipTargetID {
                tooltipTargetID = hitID
                if let rect = toolbarHitRects[hitID] {
                    showTooltip(for: hitID, buttonRect: rect)
                }
            }
        } else {
            if tooltipTargetID != nil {
                tooltipTargetID = nil
                hideTooltip()
            }
            if canMoveSelection {
                // Check handle cursor first
                let handleHit = hitTestAnnHandle(at: pt, rect: captureRectLocal)
                switch handleHit {
                case .resizeLeft, .resizeRight: NSCursor.resizeLeftRight.set()
                case .resizeTop, .resizeBottom: NSCursor.resizeUpDown.set()
                case .resizeTopLeft, .resizeBottomRight, .resizeTopRight, .resizeBottomLeft: NSCursor.crosshair.set()
                default:
                    if captureRectLocal.contains(pt) {
                        NSCursor.openHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            } else if annotationToolbarExpanded && captureRectLocal.contains(pt) {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    // MARK: - Annotation Mouse Events

    private var imageBounds: CGRect {
        CGRect(origin: .zero, size: captureRectLocal.size)
    }

    private func clampToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, min(point.x, imageBounds.width)),
            y: max(0, min(point.y, imageBounds.height))
        )
    }

    private func mouseDownAnnotating(_ event: NSEvent) {
        let viewPt = event.locationInWindow

        // Check toolbar hit first
        if let hitID = hitTestToolbar(viewPt) {
            handleToolbarAction(hitID)
            return
        }

        if canMoveSelection {
            // Check resize handle hit first (handles may be outside captureRectLocal)
            let handleHit = hitTestAnnHandle(at: viewPt, rect: captureRectLocal)
            if handleHit != .none {
                annDrag = handleHit
                annDragStart = viewPt
                annDragStartRect = captureRectLocal
                return
            }
            // Inside selection → move
            if captureRectLocal.contains(viewPt) {
                annDrag = .move
                annDragStart = viewPt
                annDragStartRect = captureRectLocal
                return
            }
            // Clicked outside → ignore
            return
        }

        guard annotationToolbarExpanded, captureRectLocal.contains(viewPt) else { return }

        let imagePt = viewToImage(viewPt)

        switch currentTool {
        case .arrow:
            let pt = clampToImage(imagePt)
            inProgressItem = AnnotationItem.arrow(start: pt, end: pt, color: currentColor)

        case .mosaic:
            inProgressItem = AnnotationItem.mosaic(rect: CGRect(origin: clampToImage(imagePt), size: .zero))

        case .text:
            showTextField(at: imagePt)

        case .number:
            numberCounter += 1
            let item = AnnotationItem.number(point: imagePt, number: numberCounter, color: currentColor)
            addAnnotation(item)

        case .rectangle, .ellipse, .highlight:
            let pt = clampToImage(imagePt)
            inProgressItem = AnnotationItem(tool: currentTool, color: currentColor, lineWidth: 3, startPoint: pt, endPoint: pt)

        case .select:
            selectedAnnotationIndex = nil
            for (i, ann) in annotations.enumerated().reversed() {
                if hitTestAnnotation(ann, at: imagePt) {
                    selectedAnnotationIndex = i
                    break
                }
            }
            needsDisplay = true
        }
    }

    private func mouseDraggedAnnotating(_ event: NSEvent) {
        // Handle selection resize / move when canMoveSelection
        if annDrag != .none {
            let pt = event.locationInWindow
            switch annDrag {
            case .move:
                let delta = CGPoint(x: pt.x - annDragStart.x, y: pt.y - annDragStart.y)
                var newOrigin = CGPoint(
                    x: annDragStartRect.origin.x + delta.x,
                    y: annDragStartRect.origin.y + delta.y
                )
                newOrigin = alignToPixelGrid(newOrigin)
                newOrigin.x = max(bounds.minX, min(newOrigin.x, bounds.maxX - captureRectLocal.width))
                newOrigin.y = max(bounds.minY, min(newOrigin.y, bounds.maxY - captureRectLocal.height))
                captureRectLocal.origin = newOrigin
                annotationGlobalRect = CGRect(
                    origin: CGPoint(x: newOrigin.x + screenOffset.x, y: newOrigin.y + screenOffset.y),
                    size: annotationGlobalRect.size
                )
                recaptureAnnotationImage()
            default:
                resizeAnnotationRect(to: pt)
            }
            needsDisplay = true
            return
        }
        guard var inProgress = inProgressItem else { return }
        let viewPt = event.locationInWindow
        let imagePt = viewToImage(viewPt)

        switch currentTool {
        case .arrow:
            inProgress.endPoint = clampToImage(imagePt)
            inProgressItem = inProgress
            needsDisplay = true

        case .mosaic:
            let clamped = clampToImage(imagePt)
            let origin = CGPoint(x: min(inProgress.startPoint.x, clamped.x),
                                 y: min(inProgress.startPoint.y, clamped.y))
            let size = CGSize(width: abs(clamped.x - inProgress.startPoint.x),
                              height: abs(clamped.y - inProgress.startPoint.y))
            inProgress.mosaicRect = CGRect(origin: origin, size: size)
            inProgressItem = inProgress
            needsDisplay = true

        case .rectangle, .ellipse, .highlight:
            inProgress.endPoint = clampToImage(imagePt)
            inProgressItem = inProgress
            needsDisplay = true

        default:
            break
        }
    }

    private func mouseUpAnnotating(_ event: NSEvent) {
        if annDrag != .none {
            annDrag = .none
            annDragStart = .zero
            annDragStartRect = .zero
            return
        }
        guard let inProgress = inProgressItem else { return }

        switch currentTool {
        case .arrow:
            let dist = hypot(inProgress.endPoint.x - inProgress.startPoint.x,
                             inProgress.endPoint.y - inProgress.startPoint.y)
            if dist > 5 { addAnnotation(inProgress) }

        case .mosaic:
            if inProgress.mosaicRect.width >= 5 && inProgress.mosaicRect.height >= 5 {
                addAnnotation(inProgress)
            }

        case .rectangle, .ellipse, .highlight:
            let dist = hypot(inProgress.endPoint.x - inProgress.startPoint.x,
                             inProgress.endPoint.y - inProgress.startPoint.y)
            if dist > 5 { addAnnotation(inProgress) }

        default:
            break
        }

        inProgressItem = nil
        needsDisplay = true
    }

    // MARK: - Annotation Resize Helpers

    private func hitTestAnnHandle(at point: CGPoint, rect r: CGRect) -> AnnDrag {
        let hs: CGFloat = 12
        let half = hs / 2
        let handles: [(CGRect, AnnDrag)] = [
            (CGRect(x: r.minX - half, y: r.minY - half, width: hs, height: hs), .resizeBottomLeft),
            (CGRect(x: r.midX - half, y: r.minY - half, width: hs, height: hs), .resizeBottom),
            (CGRect(x: r.maxX - half, y: r.minY - half, width: hs, height: hs), .resizeBottomRight),
            (CGRect(x: r.maxX - half, y: r.midY - half, width: hs, height: hs), .resizeRight),
            (CGRect(x: r.maxX - half, y: r.maxY - half, width: hs, height: hs), .resizeTopRight),
            (CGRect(x: r.midX - half, y: r.maxY - half, width: hs, height: hs), .resizeTop),
            (CGRect(x: r.minX - half, y: r.maxY - half, width: hs, height: hs), .resizeTopLeft),
            (CGRect(x: r.minX - half, y: r.midY - half, width: hs, height: hs), .resizeLeft),
        ]
        for (rect, action) in handles where rect.contains(point) {
            return action
        }
        return .none
    }

    private func resizeAnnotationRect(to point: CGPoint) {
        let minSize: CGFloat = 20
        let start = annDragStartRect
        let clamped = CGPoint(x: max(bounds.minX, min(point.x, bounds.maxX)),
                              y: max(bounds.minY, min(point.y, bounds.maxY)))

        var newMinX = start.minX, newMinY = start.minY
        var newMaxX = start.maxX, newMaxY = start.maxY

        switch annDrag {
        case .resizeLeft, .resizeTopLeft, .resizeBottomLeft:
            newMinX = min(start.maxX - minSize, clamped.x)
        case .resizeRight, .resizeTopRight, .resizeBottomRight:
            newMaxX = max(start.minX + minSize, clamped.x)
        default:
            break
        }
        switch annDrag {
        case .resizeBottom, .resizeBottomLeft, .resizeBottomRight:
            newMinY = min(start.maxY - minSize, clamped.y)
        case .resizeTop, .resizeTopLeft, .resizeTopRight:
            newMaxY = max(start.minY + minSize, clamped.y)
        default:
            break
        }

        let newRect = CGRect(x: newMinX, y: newMinY,
                            width: newMaxX - newMinX,
                            height: newMaxY - newMinY)
        let alignedOrigin = alignToPixelGrid(newRect.origin)
        let alignedRect = CGRect(origin: alignedOrigin, size: newRect.size)
        captureRectLocal = alignedRect
        annotationGlobalRect = CGRect(
            origin: CGPoint(x: alignedRect.origin.x + screenOffset.x, y: alignedRect.origin.y + screenOffset.y),
            size: CGSize(width: alignedRect.width, height: alignedRect.height)
        )

        // Recapture image from frozen background at the new rect
        recaptureAnnotationImage()
    }

    private func recaptureAnnotationImage() {
        guard !frozenBackgrounds.isEmpty else { return }
        let globalSel = annotationGlobalRect
        guard globalSel.width >= 10 && globalSel.height >= 10 else { return }
        if let (image, adjustedSize, originalCG) = croppedImage(from: globalSel) {
            capturedImage = image
            capturedCGImage = originalCG
            let adjustedOrigin = alignToPixelGrid(CGPoint(
                x: globalSel.midX - adjustedSize.width / 2,
                y: globalSel.midY - adjustedSize.height / 2
            ))
            captureRectLocal = CGRect(
                x: adjustedOrigin.x - screenOffset.x,
                y: adjustedOrigin.y - screenOffset.y,
                width: adjustedSize.width,
                height: adjustedSize.height
            )
            annotationGlobalRect = CGRect(
                origin: adjustedOrigin,
                size: adjustedSize
            )
        }
    }

    // MARK: - Toolbar Hit Testing

    private func hitTestToolbar(_ point: CGPoint) -> String? {
        for (id, rect) in toolbarHitRects where rect.contains(point) {
            return id
        }
        return nil
    }

    private func handleToolbarAction(_ id: String) {
        if id == "annotate" {
            annotationToolbarExpanded = true
            canMoveSelection = false
            hideTooltip()
            tooltipTargetID = nil
            needsDisplay = true
            return
        }

        if id == "back" {
            annotationToolbarExpanded = false
            canMoveSelection = originallyMovableSelection && annotations.isEmpty
            hideTooltip()
            tooltipTargetID = nil
            needsDisplay = true
            return
        }

        if id == "more" {
            showMoreMenu()
            return
        }

        if id == "color_picker" {
            showColorMenu()
            return
        }

        if id == "cancel" {
            onAnnotationCancel?()
            return
        }

        if id == "undo" {
            undoLast()
            return
        }

        if id == "longscreenshot" {
            onLongScreenshot?(annotationGlobalRect)
            return
        }

        if id == "save" {
            guard let (cgImage, _, _) = renderCGImage() else { return }
            let image = NSImage(cgImage: cgImage, size: capturedImage?.size ?? .zero)
            // Lower level so save panel isn't blocked by overlay
            self.window?.level = .floating
            onAnnotationAction?(image, cgImage, .save)
            // Don't close — App.swift will close on successful save
            return
        }

        if id == "copy" {
            guard let (cgImage, _, imageSize) = renderCGImage() else { return }
            let image = NSImage(cgImage: cgImage, size: imageSize)
            onAnnotationAction?(image, cgImage, .copy)
            onAnnotationCancel?()
            return
        }

        if id == "pin" {
            guard let (cgImage, _, imageSize) = renderCGImage() else { return }
            onPinCGImage?(cgImage, imageSize, annotationGlobalRect)
            onAnnotationCancel?()
            return
        }

        // Tool selection
        if let tool = AnnotationTool.toolbarTool(for: id) {
            currentTool = tool
            canMoveSelection = false
            needsDisplay = true
            return
        }

        // Color selection
        if id.hasPrefix("color_"), let idx = Int(id.replacingOccurrences(of: "color_", with: "")) {
            if ToolbarLayout.swatchColors.indices.contains(idx) {
                currentColor = ToolbarLayout.swatchColors[idx]
                needsDisplay = true
            }
        }
    }

    private func showMoreMenu() {
        guard let rect = toolbarHitRects["more"] else { return }
        let menu = NSMenu()
        for action in ScreenshotToolbarConfiguration.moreActions {
            let title = action == "save" ? "保存到文件…" : "取消截图"
            let item = NSMenuItem(title: title, action: #selector(toolbarMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: self)
    }

    private func showColorMenu() {
        guard let rect = toolbarHitRects["color_picker"] else { return }
        let names = ["红色", "橙色", "黄色", "绿色", "青色", "蓝色", "紫色", "白色", "黑色"]
        let menu = NSMenu()
        for (index, name) in names.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(toolbarMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "color_\(index)"
            item.state = currentColor == ToolbarLayout.swatchColors[index] ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: self)
    }

    @objc private func toolbarMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        handleToolbarAction(action)
    }

    // MARK: - Hit Testing (for select tool)

    private func hitTestAnnotation(_ annotation: AnnotationItem, at point: CGPoint) -> Bool {
        let tolerance: CGFloat = 15
        switch annotation.tool {
        case .arrow:
            return distanceToLine(point, annotation.startPoint, annotation.endPoint) < tolerance
        case .text:
            let size = (annotation.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: annotation.fontSize)])
            let rect = CGRect(origin: annotation.startPoint, size: size).insetBy(dx: -4, dy: -4)
            return rect.contains(point)
        case .number:
            return hypot(point.x - annotation.startPoint.x, point.y - annotation.startPoint.y) < 16
        case .mosaic:
            return annotation.mosaicRect.insetBy(dx: -4, dy: -4).contains(point)
        case .rectangle, .ellipse, .highlight:
            let rect = rectFromPoints(annotation.startPoint, annotation.endPoint).insetBy(dx: -6, dy: -6)
            return rect.contains(point)
        case .select:
            return false
        }
    }

    private func distanceToLine(_ point: CGPoint, _ lineStart: CGPoint, _ lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(point.x - lineStart.x, point.y - lineStart.y) }
        let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / (length * length)))
        let projX = lineStart.x + t * dx
        let projY = lineStart.y + t * dy
        return hypot(point.x - projX, point.y - projY)
    }

    // MARK: - Annotation Management

    private func addAnnotation(_ annotation: AnnotationItem) {
        annotations.append(annotation)
        canMoveSelection = false
        needsDisplay = true
    }

    private func undoLast() {
        guard !annotations.isEmpty else { return }
        let removed = annotations.removeLast()
        if removed.tool == .number {
            numberCounter = max(0, numberCounter - 1)
        }
        needsDisplay = true
    }

    // MARK: - Text Field

    private func showTextField(at imagePoint: CGPoint) {
        activeTextField?.removeFromSuperview()
        let viewPoint = imageToView(imagePoint)
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: 200, height: 32))
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.systemFont(ofSize: 24)
        field.textColor = currentColor
        field.placeholderString = "输入文字..."
        field.target = self
        field.action = #selector(textFieldDoneEditing(_:))
        addSubview(field)
        field.becomeFirstResponder()
        activeTextField = field
    }

    @objc private func textFieldDoneEditing(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let imagePt = viewToImage(sender.frame.origin)
            let item = AnnotationItem.text(point: imagePt, text: text, color: currentColor)
            addAnnotation(item)
        }
        sender.removeFromSuperview()
        activeTextField = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if mode == .longScreenshotting { return }

        if mode == .annotating && activeTextField == nil &&
            (event.keyCode == 0x24 || event.keyCode == 0x4C) { // Return / Enter
            handleToolbarAction("copy")
            return
        }

        if mode == .adjusting {
            if event.keyCode == 53 { // Escape
                cancelAdjusting()
                return
            }
            if event.keyCode == 0x24 || event.keyCode == 0x4C { // Return / Enter
                confirmSelection()
                return
            }
        }

        // C key — copy color in selecting mode
        if mode == .selecting || mode == .adjusting {
            if let chars = event.charactersIgnoringModifiers, chars.lowercased() == "c" {
                if let color = pickedColor {
                    let hex = colorHexString(color)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(hex, forType: .string)
                    colorCopyFeedback = "已复制 \(hex)"
                    colorCopyFeedbackExpiry?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        self?.colorCopyFeedback = nil
                        self?.needsDisplay = true
                    }
                    colorCopyFeedbackExpiry = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
                    needsDisplay = true
                }
                return
            }
        }

        if event.keyCode == 53 { // Escape
            if mode == .annotating {
                if activeTextField != nil {
                    activeTextField?.removeFromSuperview()
                    activeTextField = nil
                    window?.makeFirstResponder(self)
                    return
                }
                if inProgressItem != nil || selectedAnnotationIndex != nil {
                    inProgressItem = nil
                    selectedAnnotationIndex = nil
                    needsDisplay = true
                    return
                }
                // Nothing active — dismiss overlay
                onAnnotationCancel?()
                return
            } else {
                // Selection mode
                onSelectionComplete?(.cancel)
                return
            }
        }
        if mode == .annotating && (event.keyCode == 51 || event.keyCode == 117) {
            if let selIdx = selectedAnnotationIndex, selIdx < annotations.count {
                annotations.remove(at: selIdx)
                selectedAnnotationIndex = nil
                needsDisplay = true
                return
            }
        }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Render Final Image

    /// Render the base image + annotations into a new CGImage at pixel resolution.
    /// Returns `(cgImage, pixelSize, pointSize)`.
    private func renderCGImage() -> (CGImage, NSSize, NSSize)? {
        guard let image = capturedImage else { return nil }
        let imageSize = image.size

        let baseCGImage: CGImage
        if let cap = capturedCGImage {
            baseCGImage = cap
        } else {
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            baseCGImage = cg
        }

        let pixelW = baseCGImage.width
        let pixelH = baseCGImage.height

        // Render in DeviceRGB to avoid color-matching that shifts pixel values.
        let displayColorSpace = baseCGImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: displayColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.draw(baseCGImage, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        let sx = CGFloat(pixelW) / imageSize.width
        let sy = CGFloat(pixelH) / imageSize.height
        ctx.saveGState()
        ctx.scaleBy(x: sx, y: sy)

        // Draw annotations first (mosaic, arrows, text, etc.)
        for annotation in annotations {
            switch annotation.tool {
            case .arrow, .text, .number, .mosaic, .rectangle, .ellipse:
                drawAnnotationFixed(annotation, in: ctx, imageSize: imageSize)
            case .highlight:
                break
            case .select:
                break
            }
        }

        // Draw highlight dimming last so it correctly dims everything (including
        // annotations) outside the highlight rects.
        let highlightRects = annotations.filter { $0.tool == .highlight }.map {
            rectFromPoints($0.startPoint, $0.endPoint)
        }.filter { !$0.isNull && $0.width > 1 && $0.height > 1 }
        if !highlightRects.isEmpty {
            let imageBounds = CGRect(origin: .zero, size: imageSize)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.40).cgColor)
            let path = CGMutablePath()
            path.addRect(imageBounds)
            for rect in highlightRects {
                path.addRect(rect.intersection(imageBounds))
            }
            ctx.addPath(path)
            ctx.drawPath(using: .eoFill)
        }

        ctx.restoreGState()

        guard let resultCGImage = ctx.makeImage() else { return nil }

        // Re-tag with the screen's ICC profile without converting pixel values.
        // CGImage.copy(colorSpace:) only changes the profile tag, preserving
        // the DeviceRGB pixel values which already match the display's primaries.
        let screenCS = { () -> CGColorSpace? in
            let pt = CGPoint(x: annotationGlobalRect.midX, y: annotationGlobalRect.midY)
            return NSScreen.screens.first { $0.frame.contains(pt) }?.colorSpace?.cgColorSpace
                ?? NSScreen.main?.colorSpace?.cgColorSpace
        }()
        let taggedCGImage = screenCS.flatMap { resultCGImage.copy(colorSpace: $0) } ?? resultCGImage
        return (taggedCGImage, NSSize(width: pixelW, height: pixelH), imageSize)
    }

    func renderedImage() -> NSImage? {
        guard let (resultCGImage, _, imageSize) = renderCGImage() else { return nil }

        // Use NSBitmapImageRep with explicit point-size so the
        // pixel-to-point ratio is correct for Retina displays.
        // NSImage(cgImage:size:) can create a mismatch between
        // the rep's size (pixelsWide ÷ 72dpi) and the image size,
        // causing NSView to apply extra interpolation on draw.
        let rep = NSBitmapImageRep(cgImage: resultCGImage)
        rep.size = imageSize
        let outputImage = NSImage(size: imageSize)
        outputImage.addRepresentation(rep)
        return outputImage
    }

    /// Draw an annotation in the export context (no transform, already flipped).
    private func drawAnnotationFixed(_ annotation: AnnotationItem, in ctx: CGContext, imageSize: CGSize) {
        switch annotation.tool {
        case .arrow:
            drawTaperedArrow(
                start: annotation.startPoint,
                end: annotation.endPoint,
                color: annotation.color,
                in: ctx
            )

        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: annotation.fontSize),
                .foregroundColor: annotation.color,
            ]
            let attrStr = NSAttributedString(string: annotation.text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            ctx.textPosition = annotation.startPoint
            CTLineDraw(line, ctx)

        case .number:
            let point = annotation.startPoint
            let radius: CGFloat = 14
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(annotation.color.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect)

            let text = "\(annotation.number)"
            let font = NSFont.boldSystemFont(ofSize: 14)
            let textColor = textColorForFillColor(annotation.color)
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            let attrStr = NSAttributedString(string: text, attributes: textAttrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(line, .excludeTypographicLeading)
            let textPoint = CGPoint(
                x: point.x - bounds.width / 2 - bounds.origin.x,
                y: point.y - bounds.midY
            )
            ctx.textPosition = textPoint
            CTLineDraw(line, ctx)

        case .mosaic:
            let viewRect = annotation.mosaicRect // bottom-left
            if viewRect.width < 2 || viewRect.height < 2 { return }
            // Flip Y for CGImage cropping (top-left origin)
            let cropRect = CGRect(x: viewRect.origin.x,
                                  y: imageSize.height - viewRect.origin.y - viewRect.height,
                                  width: viewRect.width, height: viewRect.height)
            guard let pixelatedCG = pixelatedCGImage(region: cropRect, pixelSize: annotation.pixelSize) else {
                ctx.setFillColor(NSColor.gray.cgColor)
                ctx.fill(viewRect)
                return
            }
            ctx.draw(pixelatedCG, in: viewRect)

        case .rectangle:
            let rect = rectFromPoints(annotation.startPoint, annotation.endPoint)
            ctx.setStrokeColor(annotation.color.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(rect)

        case .ellipse:
            let rect = rectFromPoints(annotation.startPoint, annotation.endPoint)
            ctx.setStrokeColor(annotation.color.cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: rect)

        case .highlight:
            break

        case .select:
            break
        }
    }
}

// MARK: - Helper

private func rectFromPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
           width: abs(a.x - b.x), height: abs(a.y - b.y))
}
