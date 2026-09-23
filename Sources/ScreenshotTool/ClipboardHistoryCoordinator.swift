import ClipboardHistoryAppKit
import Foundation

enum ClipboardHistoryCoordinatorError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return "剪贴板历史初始化失败：\(message)"
        }
    }
}

@MainActor
final class ClipboardHistoryCoordinator {
    private var runtime: ClipboardHistoryRuntime?

    var hotkeyAvailable: Bool {
        runtime?.hotkeyAvailable ?? false
    }

    func start() async throws {
        guard runtime == nil else { return }
        switch await ClipboardHistoryStartup.start() {
        case .available(let runtime):
            self.runtime = runtime
        case .unavailable(let message):
            throw ClipboardHistoryCoordinatorError.unavailable(message)
        }
    }

    func showPanel() {
        runtime?.showPanel()
    }

    func shutdown() {
        runtime?.shutdown()
        runtime = nil
    }
}
