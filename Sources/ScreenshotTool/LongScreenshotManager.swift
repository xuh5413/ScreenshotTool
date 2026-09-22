import Cocoa
import LongScreenshotCore
import ScreenCaptureKit

/// Borderless panel that can become key (needed for the control panel to work correctly)
private class ControlPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Creates a plain NSButton with a symbol image, no border, no bezel
private func makeSymbolButton(symbol: String, color: NSColor, action: Selector, target: AnyObject) -> NSButton {
    let btn = NSButton(frame: .zero)
    btn.isBordered = false
    btn.bezelStyle = .regularSquare
    btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    btn.contentTintColor = color
    btn.action = action
    btn.target = target
    btn.imageScaling = .scaleProportionallyDown
    return btn
}

enum LongScreenshotCompletionAction {
    case annotate   // enter annotation mode (natural end of scroll)
    case copy       // copy result to clipboard
    case save       // save result to file
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

    private var isCancelled: Bool {
        cancellationLock.lock()
        let v = _isCancelled
        cancellationLock.unlock()
        return v
    }

    private func setCancelled(_ v: Bool) {
        cancellationLock.lock()
        _isCancelled = v
        cancellationLock.unlock()
    }

    private let operationQueue = DispatchQueue(label: "com.screenshottool.longscreenshot", qos: .userInitiated)

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
        setCancelled(true)
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
        let iconSize: CGFloat = 36
        let iconGap: CGFloat = 6
        let buttonTotal = iconSize * 3 + iconGap * 2
        let panelW: CGFloat = buttonTotal + 36 // 18px padding each side
        let panelH: CGFloat = 54
        let padding = (panelW - buttonTotal) / 2

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
        view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.20
        view.layer?.shadowRadius = 14
        view.layer?.shadowOffset = CGSize(width: 0, height: -4)

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
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
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
        setCancelled(true)
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
        acceptedFrameCount = 0
        stitchingAnchor = nil
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

    // MARK: - Manual Scroll Capture Loop

    private func manualScrollCaptureLoop(region: CGRect) {
        guard let firstFrame = captureRegion(cachedRegionRect, displayID: cachedDisplayID) else {
            reportError("截取画面失败")
            return
        }
        guard let firstSignature = frameSignature(cgImage: firstFrame) else {
            reportError("分析画面失败")
            return
        }

        let ph = firstFrame.height
        let scale = CGFloat(ph) / CGFloat(region.height)
        capturedSegments = [firstFrame]
        lastCapturedFrame = firstFrame
        lastFrameSignature = firstSignature
        acceptedFrameCount = 1
        publishStatus("等待滚动…")
        publishPreview(regionWidth: region.width, scale: scale, force: true)

        var consecutiveNoChange = 0
        var failedMatchCount = 0
        var captureFailureCount = 0
        var sleepInterval: Double = 0.15

        while !isCancelled && !shouldFinishCapture() {
            Thread.sleep(forTimeInterval: sleepInterval)

            guard !isCancelled, !shouldFinishCapture() else { break }

            guard let frame = captureRegion(cachedRegionRect, displayID: cachedDisplayID) else {
                captureFailureCount += 1
                if captureFailureCount > 10 {
                    reportError("连续截取画面失败")
                    return
                }
                continue
            }
            captureFailureCount = 0

            guard let signature = frameSignature(cgImage: frame),
                  let previousSignature = lastFrameSignature else { continue }

            if signaturesAreNearlyEqual(previousSignature, signature) {
                consecutiveNoChange += 1
                if consecutiveNoChange > 15 {
                    sleepInterval = 0.5
                } else if consecutiveNoChange > 5 {
                    sleepInterval = 0.3
                }
                continue
            }
            consecutiveNoChange = 0
            sleepInterval = 0.08

            guard let match = matcher.match(
                previous: previousSignature,
                current: signature,
                expectedDistance: lastMatchDistance
            ) else {
                failedMatchCount += 1
                if failedMatchCount >= 2 {
                    publishStatus("无法对齐，请回滚一点后慢速滚动")
                }
                continue
            }
            failedMatchCount = 0

            if let direction = captureDirection, direction != match.direction {
                publishStatus("已忽略反向滚动")
                continue
            }

            if append(frame: frame, match: match) {
                captureDirection = match.direction
                lastMatchDistance = match.scrollDistance
                lastCapturedFrame = frame
                lastFrameSignature = signature
                acceptedFrameCount += 1
                publishStatus("已采集 \(acceptedFrameCount) 段")
                publishPreview(regionWidth: region.width, scale: scale)
            } else {
                publishStatus("滚动距离过大，请稍慢滚动")
            }
        }

        DispatchQueue.main.async {
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

        let action = completionAction
        DispatchQueue.main.async {
            if let cb = self.onCompleteWithAction {
                cb(finalImage, region, action)
            } else {
                self.onComplete?(finalImage, region)
            }
        }
    }

    private func append(frame: CGImage, match: LongScreenshotMatch) -> Bool {
        if stitchingAnchor == nil {
            let bodyHeight = max(1, frame.height - match.fixedTopRows - match.fixedBottomRows)
            let trailingGuardRows = min(
                bodyHeight / 3,
                max(Int(80 * cachedCaptureScale), bodyHeight / 8)
            )
            stitchingAnchor = LongScreenshotStitchingAnchor(
                frameHeight: frame.height,
                firstMatch: match,
                trailingGuardRows: trailingGuardRows
            )
        }

        guard let stitchingAnchor else { return false }
        guard let plan = LongScreenshotSegmentPlanner.plan(
                frameHeight: frame.height,
                match: match,
                anchor: stitchingAnchor
              ),
              let newSegment = crop(frame, rows: plan.newFrameRows) else { return false }

        if acceptedFrameCount == 1, let firstFrame = lastCapturedFrame {
            guard let initialSegment = crop(firstFrame, rows: plan.initialFrameRows) else { return false }
            capturedSegments = [initialSegment]
        }

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
            self.onProgress?(message)
        }
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async {
            self.closePanels()
            self.onError?(message)
        }
    }

    private func publishPreview(regionWidth: CGFloat, scale: CGFloat, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPreviewPublishedAt) >= 0.2 else { return }
        lastPreviewPublishedAt = now
        let segments = resultSegments(includeFinalFixed: true)
        guard !segments.isEmpty else { return }

        let image = makeComposite(
            segments: segments,
            regionWidth: regionWidth,
            scale: scale,
            maximumPixelWidth: 320,
            maximumPixelHeight: 1800
        )
        DispatchQueue.main.async {
            self.onPreviewUpdate?(image)
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
                    guard idx + 3 < data.count else { break }
                    let red = Int(data[idx])
                    let green = Int(data[idx + 1])
                    let blue = Int(data[idx + 2])
                    luminanceSum += (red * 54 + green * 183 + blue * 19) >> 8
                    sampleCount += 1
                }
                blockSigs.append(sampleCount > 0 ? luminanceSum / sampleCount : 0)
            }
            sigs.append(blockSigs)
        }
        return LongScreenshotFrameSignature(rows: sigs)
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
