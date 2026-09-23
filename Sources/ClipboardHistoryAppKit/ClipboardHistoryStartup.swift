import AppKit
import ClipboardHistoryCore
import Foundation

@MainActor
public final class ClipboardHistoryRuntime {
    public let hotkeyAvailable: Bool

    private let monitor: ClipboardMonitor
    private let panel: ClipboardPanelController
    private let hotkeyManager: ClipboardHotkeyManager

    init(
        monitor: ClipboardMonitor,
        panel: ClipboardPanelController,
        hotkeyManager: ClipboardHotkeyManager,
        hotkeyAvailable: Bool
    ) {
        self.monitor = monitor
        self.panel = panel
        self.hotkeyManager = hotkeyManager
        self.hotkeyAvailable = hotkeyAvailable
    }

    public func showPanel() {
        panel.show()
    }

    public func togglePanel() {
        panel.toggle()
    }

    public func shutdown() {
        panel.close()
        monitor.stop()
        hotkeyManager.unregister()
    }
}

public enum ClipboardHistoryStartupResult {
    case available(ClipboardHistoryRuntime)
    case unavailable(String)
}

@MainActor
public enum ClipboardHistoryStartup {
    public typealias StoreFactory = (URL, URL) async throws -> ClipboardStore

    public static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenshotTool/ClipboardHistory", isDirectory: true)
    }

    public static func start(
        rootURL: URL? = nil,
        pasteboard: NSPasteboard = .general,
        storeFactory: StoreFactory? = nil
    ) async -> ClipboardHistoryStartupResult {
        let resolvedRootURL = rootURL ?? defaultRootURL
        let databaseURL = resolvedRootURL.appendingPathComponent("history.sqlite")
        let assetsURL = resolvedRootURL.appendingPathComponent("assets", isDirectory: true)
        do {
            let store: ClipboardStore
            if let storeFactory {
                store = try await storeFactory(databaseURL, assetsURL)
            } else {
                let created = ClipboardStore(
                    databaseURL: databaseURL,
                    assetsDirectoryURL: assetsURL
                )
                try await created.open()
                store = created
            }

            let monitor = ClipboardMonitor(
                pasteboard: pasteboard,
                store: store,
                privacyPolicy: .default
            )
            let panel = ClipboardPanelController(
                store: store,
                monitor: monitor,
                pasteboard: pasteboard
            )
            let hotkeyManager = ClipboardHotkeyManager()
            let hotkeyAvailable = hotkeyManager.register { [weak panel] in
                panel?.toggle()
            }
            monitor.start()
            return .available(ClipboardHistoryRuntime(
                monitor: monitor,
                panel: panel,
                hotkeyManager: hotkeyManager,
                hotkeyAvailable: hotkeyAvailable
            ))
        } catch {
            return .unavailable(String(describing: error))
        }
    }
}
