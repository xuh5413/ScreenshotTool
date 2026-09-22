public enum ScreenshotToolbarMode: Sendable {
    case quick
    case annotating
}

public struct ScreenshotToolbarButton: Sendable {
    public let id: String
    public let symbol: String
    public let title: String?
    public let isPrimary: Bool

    public init(id: String, symbol: String, title: String? = nil, isPrimary: Bool = false) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.isPrimary = isPrimary
    }
}

public enum ScreenshotToolbarConfiguration {
    public static let moreActions = ["save", "cancel"]

    public static func showsHoverTooltips(for mode: ScreenshotToolbarMode) -> Bool {
        switch mode {
        case .quick: return false
        case .annotating: return true
        }
    }

    public static func buttons(for mode: ScreenshotToolbarMode) -> [ScreenshotToolbarButton] {
        let completion = [
            ScreenshotToolbarButton(id: "pin", symbol: "pin", title: "固定"),
            ScreenshotToolbarButton(id: "more", symbol: "", title: "更多"),
            ScreenshotToolbarButton(id: "copy", symbol: "doc.on.doc", title: "复制", isPrimary: true),
        ]

        switch mode {
        case .quick:
            return [
                ScreenshotToolbarButton(id: "annotate", symbol: "pencil.tip", title: "标注"),
                ScreenshotToolbarButton(id: "longscreenshot", symbol: "rectangle.expand.vertical", title: "长截图"),
            ] + completion
        case .annotating:
            return [
                ScreenshotToolbarButton(id: "back", symbol: "chevron.left", title: "返回"),
                ScreenshotToolbarButton(id: "tool_0", symbol: "arrow.up.right"),
                ScreenshotToolbarButton(id: "tool_1", symbol: "textformat"),
                ScreenshotToolbarButton(id: "tool_3", symbol: "square.grid.3x3.fill"),
                ScreenshotToolbarButton(id: "tool_4", symbol: "rectangle"),
                ScreenshotToolbarButton(id: "tool_5", symbol: "circle"),
                ScreenshotToolbarButton(id: "tool_6", symbol: "sun.max"),
                ScreenshotToolbarButton(id: "tool_2", symbol: "textformat.123"),
                ScreenshotToolbarButton(id: "color_picker", symbol: "circle.fill"),
                ScreenshotToolbarButton(id: "undo", symbol: "arrow.uturn.backward"),
            ] + completion
        }
    }
}
