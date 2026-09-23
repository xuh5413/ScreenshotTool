import AppKit
import ClipboardHistoryCore
import Foundation

@MainActor
public final class ClipboardMonitor {
    public var onHistoryChanged: (@MainActor () -> Void)?
    public var onError: (@MainActor (Error) -> Void)?

    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private let privacyPolicy: ClipboardPrivacyPolicy
    private let pollingInterval: TimeInterval
    private var timer: Timer?
    private var lastObservedChangeCount: Int
    private var suppressedChangeCount: Int?
    private var isPolling = false

    public init(
        pasteboard: NSPasteboard = .general,
        store: ClipboardStore,
        privacyPolicy: ClipboardPrivacyPolicy = .default,
        pollingInterval: TimeInterval = 0.35
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.privacyPolicy = privacyPolicy
        self.pollingInterval = pollingInterval
        lastObservedChangeCount = pasteboard.changeCount
    }

    deinit {
        timer?.invalidate()
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollNow()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func suppress(changeCount: Int) {
        suppressedChangeCount = changeCount
    }

    public func pollNow() async {
        guard !isPolling else { return }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = changeCount

        if suppressedChangeCount == changeCount {
            suppressedChangeCount = nil
            return
        }

        let application = NSWorkspace.shared.frontmostApplication
        let source = ClipboardSource(
            appName: application?.localizedName,
            bundleID: application?.bundleIdentifier
        )
        guard let candidate = ClipboardPasteboardCodec.readCandidate(
            from: pasteboard,
            source: source,
            capturedAt: Date(),
            policy: privacyPolicy
        ) else {
            return
        }

        isPolling = true
        defer { isPolling = false }
        do {
            let normalized = try ClipboardContentNormalizer.normalized(candidate: candidate)
            _ = try await store.upsert(normalized)
            _ = try await store.prune()
            onHistoryChanged?()
        } catch {
            NSLog("[ScreenshotTool] clipboard item skipped: \(error)")
            onError?(error)
        }
    }
}
