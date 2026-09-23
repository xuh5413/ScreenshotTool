import Cocoa
import LongScreenshotCore
import ScreenCaptureKit
import ScreenshotToolbarCore

/// Borderless panel that can become key (needed for the control panel to work correctly)
private class ControlPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Keeps the long-screenshot controls consistent with the clickable toolbar affordance.
private final class ToolbarIconButton: NSButton {
    private var handTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let handTrackingArea {
            removeTrackingArea(handTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        handTrackingArea = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

/// Creates a plain NSButton with a symbol image, no border, no bezel
private func makeSymbolButton(symbol: String, color: NSColor, action: Selector, target: AnyObject) -> NSButton {
    let btn = ToolbarIconButton(frame: .zero)
    btn.isBordered = false
    btn.bezelStyle = .regularSquare
    btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(
            pointSize: ScreenshotToolbarMetrics.iconPointSize,
            weight: .light
        ))
    btn.contentTintColor = color
    btn.action = action
    btn.target = target
    btn.imageScaling = .scaleProportionallyDown
    btn.focusRingType = .none
    return btn
}

enum LongScreenshotCompletionAction {
    case annotate   // enter annotation mode (natural end of scroll)
    case copy       // copy result to clipboard
    case save       // save result to file
}

private struct LongScreenshotCapturedFrame {
    let image: CGImage
    let droppedBeforeCapture: Int
}

final class LongScreenshotManager {

    var onProgress: ((String) -> Void)?
    var onPreviewUpdate: ((NSImage) -> Void)?
    var onComplete: ((NSImage, CGRect) -> Void)?
    var onError: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onCompleteWithAction: ((NSImage, CGRect, LongScreenshotCompletionAction) -> Void)?

    /// Thread-safe cancellation flag
    private let cancellationLock = NSLock()
    private var _isCancelled = false
    private var _userCancelled = false

    private var isCancelled: Bool {
        cancellationLock.lock()
        let v = _isCancelled
        cancellationLock.unlock()
        return v
    }

    private var userCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return _userCancelled
    }

    private func setCancelled(_ v: Bool, byUser: Bool = false) {
        cancellationLock.lock()
        _isCancelled = v
        _userCancelled = v && (byUser || _userCancelled)
        cancellationLock.unlock()
    }

    private let operationQueue = DispatchQueue(label: "com.screenshottool.longscreenshot", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "com.screenshottool.longscreenshot.capture", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "com.screenshottool.longscreenshot.preview", qos: .userInitiated)
    private let previewPermit = DispatchSemaphore(value: 1)
    /// Accessed only on previewQueue. Stable segments are reduced once, not redrawn
    /// from full-resolution captures every time the preview changes.
    private var previewThumbnailCache: [ObjectIdentifier: CGImage] = [:]
    private let samplingLock = NSLock()
    private var unchangedFrameCount = 0

    private func noteFrameChange(_ changed: Bool) {
        samplingLock.lock()
        unchangedFrameCount = changed ? 0 : min(unchangedFrameCount + 1, 100)
        samplingLock.unlock()
    }

    private func samplingInterval(queuedFrames: Int) -> TimeInterval {
        samplingLock.lock()
        defer { samplingLock.unlock() }
        return LongScreenshotCapturePolicy.interval(
            unchangedFrameCount: unchangedFrameCount,
            queuedFrames: queuedFrames
        )
    }

    private var controlPanel: NSPanel?
    private var excludedWindowNumbers: Set<Int> = []
    private var escapeMonitors: [Any] = []

    /// Window number of the overlay to exclude from captures
    var overlayWindowNumber: Int?

    // MARK: - Cached Capture Context

    private var cachedFilter: SCContentFilter?
    private var cachedConfig: SCStreamConfiguration?
    private var cachedCaptureScale: CGFloat = 1.0
    private var cachedRegionRect: CGRect = .zero
    private var cachedDisplayID: CGDirectDisplayID = 0
    private var pixelDataBuffer: Data?
    private var pixelDataBufferSize: Int = 0
    private let matcher = LongScreenshotMatcher()

    func cancel() {
        setCancelled(true, byUser: true)
        setCaptureFinished()
        DispatchQueue.main.async {
            self.closePanels()
        }
    }

    // MARK: - Capture Context Setup

    private func setupCaptureContext(region: CGRect, displayID: CGDirectDisplayID) {
        cachedRegionRect = region
        cachedDisplayID = displayID

        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        let scale = screen.backingScaleFactor
        cachedCaptureScale = scale

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

                let excluded = content.windows.filter { self.excludedWindowNumbers.contains(Int($0.windowID)) }
                self.cachedFilter = SCContentFilter(display: display, excludingWindows: excluded)

                let config = SCStreamConfiguration()
                config.showsCursor = false

                let relX = region.origin.x - screen.frame.origin.x
                let relY = region.origin.y - screen.frame.origin.y
                let sourceRect = CGRect(
                    x: relX,
                    y: screen.frame.height - relY - region.height,
                    width: region.width,
                    height: region.height
                )
                config.sourceRect = sourceRect
                config.width = Int(round(region.width * scale))
                config.height = Int(round(region.height * scale))
                self.cachedConfig = config
            } catch {
                NSLog("[ScreenshotTool] setupCaptureContext error: \(error)")
            }
        }
        semaphore.wait()
    }

    private func invalidateCaptureContext() {
        cachedFilter = nil
        cachedConfig = nil
        cachedRegionRect = .zero
        cachedDisplayID = 0
    }

    func startManualCapture(region: CGRect, windowInfo: WindowInfo) {
        setCancelled(false)
        resetCaptureState()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.showControlPanel(region: region)
            self.installEscapeCancelMonitor()
            self.rebuildExcludedWindowNumbers()

            self.operationQueue.async {
                self.setupCaptureContext(region: region, displayID: windowInfo.displayID)
                self.manualScrollCaptureLoop(region: region)
                self.invalidateCaptureContext()
            }
        }
    }

    private func rebuildExcludedWindowNumbers() {
        excludedWindowNumbers = []
        if let overlayWindowNumber, overlayWindowNumber != 0 {
            excludedWindowNumbers.insert(overlayWindowNumber)
        }
        if let number = controlPanel?.windowNumber, number != 0 {
            excludedWindowNumbers.insert(number)
        }
        cachedFilter = nil
    }

    // MARK: - Control Panel

    private func showControlPanel(region: CGRect) {
        let iconSize = ScreenshotToolbarMetrics.buttonSize
        let iconGap = ScreenshotToolbarMetrics.buttonGap
        let buttonTotal = iconSize * 3 + iconGap * 2
        let panelW = buttonTotal + ScreenshotToolbarMetrics.horizontalPadding * 2
        let panelH = ScreenshotToolbarMetrics.height
        let padding = ScreenshotToolbarMetrics.horizontalPadding

        let panel = ControlPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let margin: CGFloat = 8
        let screen = NSScreen.screens.first { $0.frame.contains(region) } ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero
        let panelX = max(screenFrame.minX + margin, min(region.midX - panelW / 2, screenFrame.maxX - panelW - margin))
        let belowY = region.minY - panelH - 12
        let aboveY = region.maxY + 12
        let preferredY = belowY >= screenFrame.minY + margin ? belowY : aboveY
        let panelY = max(screenFrame.minY + margin, min(preferredY, screenFrame.maxY - panelH - margin))
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))

        let vPad = (panelH - iconSize) / 2

        let view = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
        view.layer?.cornerRadius = ScreenshotToolbarMetrics.cornerRadius
        view.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.borderWidth = ScreenshotToolbarMetrics.borderWidth
        view.layer?.shadowOpacity = 0.24
        view.layer?.shadowRadius = 8
        view.layer?.shadowOffset = CGSize(width: 0, height: -2)

        let doneBtn = makeSymbolButton(symbol: "checkmark", color: .black, action: #selector(finishCaptureAndCopy), target: self)
        doneBtn.frame = NSRect(x: padding, y: vPad, width: iconSize, height: iconSize)
        styleToolbarIconButton(doneBtn, tooltip: "完成并复制")
        view.addSubview(doneBtn)

        let saveBtn = makeSymbolButton(symbol: "arrow.down.to.line", color: .black, action: #selector(finishCaptureAndSave), target: self)
        saveBtn.frame = NSRect(x: doneBtn.frame.maxX + iconGap, y: vPad, width: iconSize, height: iconSize)
        styleToolbarIconButton(saveBtn, tooltip: "完成并下载")
        view.addSubview(saveBtn)

        let cancelBtn = makeSymbolButton(symbol: "xmark", color: .black, action: #selector(cancelCapture), target: self)
        cancelBtn.frame = NSRect(x: saveBtn.frame.maxX + iconGap, y: vPad, width: iconSize, height: iconSize)
        styleToolbarIconButton(cancelBtn, tooltip: "取消截图")
        view.addSubview(cancelBtn)

        panel.contentView = view
        controlPanel = panel
        panel.orderFrontRegardless()
    }

    private func styleToolbarIconButton(_ button: NSButton, tooltip: String) {
        button.wantsLayer = true
        button.layer?.cornerRadius = ScreenshotToolbarMetrics.cornerRadius
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.toolTip = tooltip
    }

    @objc private func finishCaptureAndSave() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        captureFinished = true
        completionAction = .save
    }

    @objc private func finishCaptureAndCopy() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        captureFinished = true
        completionAction = .copy
    }

    @objc private func cancelCapture() {
        setCancelled(true, byUser: true)
        closePanels()
        DispatchQueue.main.async { self.onCancel?() }
    }

    private func closePanels() {
        for monitor in escapeMonitors {
            NSEvent.removeMonitor(monitor)
        }
        escapeMonitors = []
        controlPanel?.orderOut(nil)
        controlPanel = nil
    }

    private func installEscapeCancelMonitor() {
        for monitor in escapeMonitors {
            NSEvent.removeMonitor(monitor)
        }
        escapeMonitors = []

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53 else { return }
            self?.cancelCapture()
        }

        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if event.keyCode == 53 {
                handler(event)
                return nil
            }
            return event
        })
        if let local {
            escapeMonitors.append(local)
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) {
            escapeMonitors.append(global)
        }
    }

    private var captureFinished = false
    private var completionAction: LongScreenshotCompletionAction = .annotate
    private var capturedSegments: [CGImage] = []
    private var finalFixedSegment: CGImage?
    private var lastCapturedFrame: CGImage?
    private var lastFrameSignature: LongScreenshotFrameSignature?
    private var captureDirection: LongScreenshotScrollDirection?
    private var lastMatchDistance: Int?
    private var lastPreviewPublishedAt = Date.distantPast
    private var acceptedFrameCount = 0
    private var stitchingAnchor: LongScreenshotStitchingAnchor?

    private func resetCaptureState() {
        objc_sync_enter(self)
        captureFinished = false
        completionAction = .annotate
        objc_sync_exit(self)

        capturedSegments = []
        finalFixedSegment = nil
        lastCapturedFrame = nil
        lastFrameSignature = nil
        captureDirection = nil
        lastMatchDistance = nil
        lastPreviewPublishedAt = .distantPast
        previewQueue.async { self.previewThumbnailCache.removeAll() }
        acceptedFrameCount = 0
        stitchingAnchor = nil
        noteFrameChange(true)
        excludedWindowNumbers = []
        for monitor in escapeMonitors {
            NSEvent.removeMonitor(monitor)
        }
        escapeMonitors = []
    }

    private func setCaptureFinished() {
        objc_sync_enter(self)
        captureFinished = true
        objc_sync_exit(self)
    }

    private func shouldFinishCapture() -> Bool {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return captureFinished
    }

    private func completionActionSnapshot() -> LongScreenshotCompletionAction {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return completionAction
    }

    // MARK: - Manual Scroll Capture Loop

    private func captureFrames(into buffer: LongScreenshotFrameBuffer<LongScreenshotCapturedFrame>) {
        defer { buffer.close() }
        var consecutiveCaptureFailures = 0
        var lastBufferWarning = Date.distantPast
        var lastQueuedThumbnail: Data?
        var dropsBeforeLastQueuedFrame = 0

        while !isCancelled && !shouldFinishCapture() {
            if let frame = captureRegion(cachedRegionRect, displayID: cachedDisplayID) {
                consecutiveCaptureFailures = 0
                // Most captured frames are identical while the page is still.
                // Discard those here so they never occupy the matcher queue.
                let thumbnail = captureThumbnail(frame)
                let droppedBeforeCapture = buffer.droppedFrameCount
                if let thumbnail, thumbnail == lastQueuedThumbnail,
                   droppedBeforeCapture == dropsBeforeLastQueuedFrame {
                    noteFrameChange(false)
                } else if !isCancelled && buffer.offer(LongScreenshotCapturedFrame(
                    image: frame, droppedBeforeCapture: droppedBeforeCapture
                )) {
                    lastQueuedThumbnail = thumbnail
                    dropsBeforeLastQueuedFrame = droppedBeforeCapture
                    noteFrameChange(true)
                } else if !isCancelled {
                    let now = Date()
                    if now.timeIntervalSince(lastBufferWarning) >= 1 {
                        lastBufferWarning = now
                        publishStatus("采集跟不上滚动，请稍慢滚动")
                    }
                }
            } else {
                consecutiveCaptureFailures += 1
                if consecutiveCaptureFailures > 10 {
                    setCancelled(true)
                    reportError("连续截取画面失败")
                    return
                }
            }

            // Sampling stays independent of signature matching and preview composition.
            Thread.sleep(forTimeInterval: samplingInterval(queuedFrames: buffer.bufferedFrameCount))
        }
    }

    private func captureThumbnail(_ image: CGImage) -> Data? {
        let side = 128
        var pixels = Data(count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }

    private func manualScrollCaptureLoop(region: CGRect) {
        let pixelWidth = Int((region.width * cachedCaptureScale).rounded())
        let pixelHeight = Int((region.height * cachedCaptureScale).rounded())
        let bufferCapacity = LongScreenshotCapturePolicy.frameCapacity(
            width: pixelWidth, height: pixelHeight
        )
        let frameBuffer = LongScreenshotFrameBuffer<LongScreenshotCapturedFrame>(capacity: bufferCapacity)
        let captureStopped = DispatchSemaphore(value: 0)
        captureQueue.async {
            self.captureFrames(into: frameBuffer)
            captureStopped.signal()
        }
        defer { captureStopped.wait() }

        var scale: CGFloat = 1
        var alignment = LongScreenshotAlignmentState()
        var observedDroppedFrameCount = 0
        while !isCancelled {
            guard let captured = frameBuffer.take(timeout: 0.1) else {
                if frameBuffer.isDrained { break }
                continue
            }
            let frame = captured.image
            if captured.droppedBeforeCapture > observedDroppedFrameCount {
                observedDroppedFrameCount = captured.droppedBeforeCapture
                alignment.recordDroppedFrames()
            }

            if lastCapturedFrame == nil {
                guard let firstSignature = frameSignature(cgImage: frame) else {
                    setCancelled(true)
                    reportError("分析画面失败")
                    return
                }
                scale = CGFloat(frame.height) / max(region.height, 1)
                capturedSegments = [frame]
                lastCapturedFrame = frame
                lastFrameSignature = firstSignature
                acceptedFrameCount = 1
                publishStatus("等待滚动…")
                publishPreview(regionWidth: region.width, scale: scale, force: true)
                continue
            }

            guard let signature = frameSignature(cgImage: frame),
                  let previousSignature = lastFrameSignature else { continue }

            if signaturesAreNearlyEqual(previousSignature, signature) {
                if !alignment.canFinalizeSafely {
                    alignment.recordReturnedToCapturedArea()
                    publishStatus("已回到采集位置，请继续向原方向滚动")
                }
                continue
            }

            guard let match = matcher.match(
                previous: previousSignature,
                current: signature,
                expectedDistance: lastMatchDistance
            ) else {
                alignment.recordMatchFailure()
                if !alignment.canFinalizeSafely {
                    publishStatus("无法对齐，请滚回预览中的最后采集位置")
                }
                continue
            }
            guard !isCancelled else { break }

            if let direction = captureDirection, direction != match.direction {
                if !alignment.canFinalizeSafely {
                    alignment.recordReturnedToCapturedArea()
                }
                publishStatus("已回到采集区域，请继续向原方向滚动")
                continue
            }

            if append(frame: frame, match: match) {
                alignment.recordAcceptedFrame()
                captureDirection = match.direction
                lastMatchDistance = match.scrollDistance
                lastCapturedFrame = frame
                lastFrameSignature = signature
                acceptedFrameCount += 1
                publishStatus("已采集 \(acceptedFrameCount) 段")
                publishPreview(regionWidth: region.width, scale: scale)
            } else {
                alignment.recordRejectedDistance()
                publishStatus("滚动距离过大，请稍慢滚动")
            }
        }

        guard !isCancelled else { return }
        guard lastCapturedFrame != nil else {
            reportError("未采集到画面")
            return
        }
        if frameBuffer.droppedFrameCount > observedDroppedFrameCount {
            alignment.recordDroppedFrames()
        }
        let action = completionActionSnapshot()
        if !alignment.canFinalizeSafely {
            if case .annotate = action {
                reportError("画面未能完整对齐；请稍慢滚动后重试")
                return
            }
            // Explicit copy/save should still yield the contiguous portion already
            // accepted by the matcher, rather than discarding the entire capture.
            NSLog("[ScreenshotTool] exporting aligned portion after dropped or unmatched frames")
        }

        DispatchQueue.main.async {
            guard !self.isCancelled else { return }
            self.closePanels()
            self.onProgress?("正在合成最终图片...")
        }

        guard !capturedSegments.isEmpty else { return }

        let finalImage = makeComposite(
            segments: resultSegments(includeFinalFixed: true),
            regionWidth: region.width,
            scale: scale
        )
        guard !isCancelled else { return }
        guard finalImage.size.width > 0, finalImage.size.height > 0 else {
            reportError("合成长截图失败")
            return
        }

        DispatchQueue.main.async {
            guard !self.isCancelled else { return }
            if let cb = self.onCompleteWithAction {
                cb(finalImage, region, action)
            } else {
                self.onComplete?(finalImage, region)
            }
        }
    }

    private func append(frame: CGImage, match: LongScreenshotMatch) -> Bool {
        let candidateAnchor: LongScreenshotStitchingAnchor
        if let stitchingAnchor {
            candidateAnchor = stitchingAnchor
        } else {
            let bodyHeight = max(1, frame.height - match.fixedTopRows - match.fixedBottomRows)
            let trailingGuardRows = min(
                bodyHeight / 3,
                max(Int(80 * cachedCaptureScale), bodyHeight / 8)
            )
            candidateAnchor = LongScreenshotStitchingAnchor(
                frameHeight: frame.height,
                firstMatch: match,
                trailingGuardRows: trailingGuardRows
            )
        }

        guard let plan = LongScreenshotSegmentPlanner.plan(
                frameHeight: frame.height,
                match: match,
                anchor: candidateAnchor
              ),
              let newSegment = crop(frame, rows: plan.newFrameRows) else { return false }

        if acceptedFrameCount == 1, let firstFrame = lastCapturedFrame {
            guard let initialSegment = crop(firstFrame, rows: plan.initialFrameRows) else { return false }
            capturedSegments = [initialSegment]
        }

        stitchingAnchor = candidateAnchor
        switch match.direction {
        case .down:
            capturedSegments.append(newSegment)
        case .up:
            capturedSegments.insert(newSegment, at: 0)
        }
        finalFixedSegment = crop(frame, rows: plan.finalFixedRows)
        return true
    }

    private func crop(_ image: CGImage, rows: Range<Int>) -> CGImage? {
        guard !rows.isEmpty, rows.lowerBound >= 0, rows.upperBound <= image.height else { return nil }
        return image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count))
    }

    private func resultSegments(includeFinalFixed: Bool) -> [CGImage] {
        guard includeFinalFixed, let fixed = finalFixedSegment else { return capturedSegments }
        if captureDirection == .up {
            return [fixed] + capturedSegments
        }
        return capturedSegments + [fixed]
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async {
            guard !self.isCancelled else { return }
            self.onProgress?(message)
        }
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async {
            guard !self.userCancelled else { return }
            self.closePanels()
            self.onError?(message)
        }
    }

    private func publishPreview(regionWidth: CGFloat, scale: CGFloat, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPreviewPublishedAt) >= 0.1 else { return }
        guard previewPermit.wait(timeout: .now()) == .success else { return }
        lastPreviewPublishedAt = now
        let segments = resultSegments(includeFinalFixed: true)
        guard !segments.isEmpty else {
            previewPermit.signal()
            return
        }
        let fixedIndex: Int? = finalFixedSegment == nil ? nil
            : (captureDirection == .up ? 0 : segments.count - 1)

        previewQueue.async {
            var thumbnails: [CGImage] = []
            thumbnails.reserveCapacity(segments.count)
            for (index, segment) in segments.enumerated() {
                let key = ObjectIdentifier(segment)
                if index != fixedIndex, let cached = self.previewThumbnailCache[key] {
                    thumbnails.append(cached)
                    continue
                }
                guard let thumbnail = LongScreenshotImageComposer.compose(
                    segments: [segment], maximumPixelWidth: 320
                ) else { continue }
                if index != fixedIndex { self.previewThumbnailCache[key] = thumbnail }
                thumbnails.append(thumbnail)
            }
            let preview = LongScreenshotImageComposer.compose(
                segments: thumbnails, maximumPixelWidth: 320, maximumPixelHeight: 1800
            )
            self.previewPermit.signal()
            guard let preview else { return }
            let sourceHeight = segments.reduce(0) { $0 + $1.height }
            let logicalHeight = CGFloat(sourceHeight) / max(scale, 0.01)
            let image = NSImage(cgImage: preview, size: NSSize(width: regionWidth, height: logicalHeight))
            DispatchQueue.main.async {
                guard !self.isCancelled && !self.shouldFinishCapture() else { return }
                self.onPreviewUpdate?(image)
            }
        }
    }

    // MARK: - Screen Capture

    private func captureRegion(_ region: CGRect, displayID: CGDirectDisplayID) -> CGImage? {
        if let filter = cachedFilter, let config = cachedConfig {
            let semaphore = DispatchSemaphore(value: 0)
            var result: CGImage?
            Task {
                defer { semaphore.signal() }
                do {
                    let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    result = cgImage
                } catch {
                    NSLog("[ScreenshotTool] SCK capture error: \(error)")
                }
            }
            semaphore.wait()
            return result
        }

        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: CGImage?

        Task {
            defer { semaphore.signal() }
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

                let excluded = content.windows.filter { self.excludedWindowNumbers.contains(Int($0.windowID)) }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)

                let config = SCStreamConfiguration()
                config.showsCursor = false

                let relX = region.origin.x - screen.frame.origin.x
                let relY = region.origin.y - screen.frame.origin.y
                let sourceRect = CGRect(
                    x: relX,
                    y: screen.frame.height - relY - region.height,
                    width: region.width,
                    height: region.height
                )
                config.sourceRect = sourceRect
                config.width = Int(round(region.width * screen.backingScaleFactor))
                config.height = Int(round(region.height * screen.backingScaleFactor))

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                result = cgImage
            } catch {
                NSLog("[ScreenshotTool] SCK capture error: \(error)")
            }
        }

        semaphore.wait()
        return result
    }

    // MARK: - Frame Signatures

    private static let signatureBlockCount = 32
    private static let signatureSampleStep = 4

    private func frameSignature(cgImage: CGImage) -> LongScreenshotFrameSignature? {
        guard let data = pixelData(cgImage: cgImage) else { return nil }
        let h = cgImage.height
        let w = cgImage.width
        let bytesPerRow = w * 4
        let blockW = max(1, w / Self.signatureBlockCount)

        return data.withUnsafeBytes { rawBuffer in
            let pixels = rawBuffer.bindMemory(to: UInt8.self)
            var sigs: [[Int]] = []
            sigs.reserveCapacity(h)

            for row in 0..<h {
                let rowStart = row * bytesPerRow
                var blockSigs: [Int] = []
                blockSigs.reserveCapacity(Self.signatureBlockCount)

                for b in 0..<Self.signatureBlockCount {
                    let startX = b * blockW
                    let endX = b == Self.signatureBlockCount - 1 ? w : min(startX + blockW, w)
                    var luminanceSum = 0
                    var sampleCount = 0

                    for col in stride(from: startX, to: endX, by: Self.signatureSampleStep) {
                        let idx = rowStart + col * 4
                        let red = Int(pixels[idx])
                        let green = Int(pixels[idx + 1])
                        let blue = Int(pixels[idx + 2])
                        luminanceSum += (red * 54 + green * 183 + blue * 19) >> 8
                        sampleCount += 1
                    }
                    blockSigs.append(sampleCount > 0 ? luminanceSum / sampleCount : 0)
                }
                sigs.append(blockSigs)
            }
            return LongScreenshotFrameSignature(rows: sigs)
        }
    }

    private func signaturesAreNearlyEqual(
        _ lhs: LongScreenshotFrameSignature,
        _ rhs: LongScreenshotFrameSignature
    ) -> Bool {
        guard lhs.rows.count == rhs.rows.count,
              let blockCount = lhs.rows.first?.count,
              blockCount > 0 else { return false }

        let rowStep = max(1, lhs.rows.count / 32)
        let blockStep = max(1, blockCount / 8)
        var totalDifference = 0
        var sampleCount = 0
        for row in stride(from: 0, to: lhs.rows.count, by: rowStep) {
            for block in stride(from: 0, to: blockCount, by: blockStep) {
                totalDifference += abs(lhs.rows[row][block] - rhs.rows[row][block])
                sampleCount += 1
            }
        }
        return sampleCount > 0 && Double(totalDifference) / Double(sampleCount) < 1.5
    }

    // MARK: - Pixel Data

    private func pixelData(cgImage: CGImage) -> Data? {
        let w = cgImage.width; let h = cgImage.height
        let bytesPerRow = w * 4; let totalSize = bytesPerRow * h

        if pixelDataBuffer == nil || pixelDataBufferSize < totalSize {
            pixelDataBuffer = Data(count: totalSize)
            pixelDataBufferSize = totalSize
        }

        var rendered = false
        pixelDataBuffer!.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cgImage.colorSpace
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            rendered = true
        }
        guard rendered else { return nil }
        return pixelDataBuffer!
    }

    // MARK: - Stitching

    private func makeComposite(
        segments: [CGImage],
        regionWidth: CGFloat,
        scale: CGFloat,
        maximumPixelWidth: Int? = nil,
        maximumPixelHeight: Int? = nil
    ) -> NSImage {
        guard let image = LongScreenshotImageComposer.compose(
            segments: segments,
            maximumPixelWidth: maximumPixelWidth,
            maximumPixelHeight: maximumPixelHeight
        ) else { return NSImage(size: .zero) }
        let sourceHeight = segments.reduce(0) { $0 + $1.height }
        let logicalHeight = CGFloat(sourceHeight) / max(scale, 0.01)
        return NSImage(cgImage: image, size: NSSize(width: regionWidth, height: logicalHeight))
    }
}
