import ClipboardHistoryCore
import Foundation

public struct ClipboardPanelState: Sendable {
    public private(set) var items: [ClipboardItem]
    public private(set) var selectedID: UUID?

    public init(items: [ClipboardItem] = []) {
        self.items = items
        selectedID = items.first?.id
    }

    public var selectedItem: ClipboardItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    public mutating func apply(items: [ClipboardItem], preservingSelection: Bool) {
        let previousID = selectedID
        self.items = items
        if preservingSelection,
           let previousID,
           items.contains(where: { $0.id == previousID }) {
            selectedID = previousID
        } else {
            selectedID = items.first?.id
        }
    }

    public mutating func select(id: UUID?) {
        guard let id else {
            selectedID = nil
            return
        }
        selectedID = items.contains(where: { $0.id == id }) ? id : items.first?.id
    }

    public mutating func moveSelection(by offset: Int) {
        guard !items.isEmpty else {
            selectedID = nil
            return
        }
        let currentIndex = selectedID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(0, currentIndex + offset), items.count - 1)
        selectedID = items[nextIndex].id
    }
}

public struct ClipboardFilePreviewEntry: Equatable, Sendable {
    public let url: URL
    public let exists: Bool

    public init(url: URL, exists: Bool) {
        self.url = url
        self.exists = exists
    }
}

public enum ClipboardPreviewModel: Equatable, Sendable {
    case text(String)
    case link(URL)
    case image(Data)
    case files([ClipboardFilePreviewEntry])
    case unavailable(String)

    public init(
        item: ClipboardItem,
        imageData: Data?,
        fileExists: (URL) -> Bool
    ) {
        switch item.kind {
        case .text:
            self = .text(item.plainText)
        case .link:
            if let url = URL(string: item.plainText) {
                self = .link(url)
            } else {
                self = .unavailable("链接无效")
            }
        case .image:
            if let imageData {
                self = .image(imageData)
            } else {
                self = .unavailable("图片资源不存在")
            }
        case .files:
            let entries = item.fileURLs.map { url in
                ClipboardFilePreviewEntry(url: url, exists: fileExists(url))
            }
            if entries.isEmpty || entries.contains(where: { !$0.exists }) {
                self = .unavailable("文件不存在")
            } else {
                self = .files(entries)
            }
        }
    }
}
