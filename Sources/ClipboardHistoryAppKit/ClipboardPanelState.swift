import ClipboardHistoryCore
import Foundation

public struct ClipboardPanelState: Sendable {
    public private(set) var items: [ClipboardItem]
    public private(set) var selectedID: UUID?
    public private(set) var hasAnyHistory: Bool

    public init(items: [ClipboardItem] = [], hasAnyHistory: Bool? = nil) {
        self.items = items
        selectedID = items.first?.id
        self.hasAnyHistory = hasAnyHistory ?? !items.isEmpty
    }

    public var selectedItem: ClipboardItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    public mutating func apply(
        items: [ClipboardItem],
        hasAnyHistory: Bool? = nil,
        preservingSelection: Bool
    ) {
        let previousID = selectedID
        self.items = items
        self.hasAnyHistory = hasAnyHistory ?? !items.isEmpty
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

    @discardableResult
    public mutating func select(row: Int) -> Bool {
        guard items.indices.contains(row) else { return false }
        selectedID = items[row].id
        return true
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
