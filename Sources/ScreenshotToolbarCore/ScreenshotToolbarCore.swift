import CoreGraphics

public enum ScreenshotToolbarMode: Sendable {
    case quick
    case annotating
}

public enum ScreenshotToolbarMetrics {
    public static let height: CGFloat = 46
    public static let horizontalPadding: CGFloat = 8
    public static let buttonSize: CGFloat = 36
    public static let buttonGap: CGFloat = 3
    public static let iconPointSize: CGFloat = 20
    public static let cornerRadius: CGFloat = 8
    public static let borderWidth: CGFloat = 0.8
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
        true
    }

    public static func buttons(for mode: ScreenshotToolbarMode) -> [ScreenshotToolbarButton] {
        let completion = [
            ScreenshotToolbarButton(id: "pin", symbol: "pin"),
            ScreenshotToolbarButton(id: "save", symbol: "arrow.down.to.line"),
            ScreenshotToolbarButton(id: "cancel", symbol: "xmark"),
            ScreenshotToolbarButton(id: "copy", symbol: "checkmark", isPrimary: true),
        ]

        switch mode {
        case .quick:
            return [
                ScreenshotToolbarButton(id: "annotate", symbol: "custom.annotate"),
                ScreenshotToolbarButton(id: "longscreenshot", symbol: "custom.long-screenshot"),
            ] + completion
        case .annotating:
            return [
                ScreenshotToolbarButton(id: "back", symbol: "chevron.left"),
                ScreenshotToolbarButton(id: "tool_arrow", symbol: "arrow.up.right"),
                ScreenshotToolbarButton(id: "tool_text", symbol: "custom.text.a"),
                ScreenshotToolbarButton(id: "tool_number", symbol: "1.circle"),
                ScreenshotToolbarButton(id: "tool_rectangle", symbol: "rectangle"),
                ScreenshotToolbarButton(id: "tool_ellipse", symbol: "circle"),
                ScreenshotToolbarButton(id: "tool_mosaic", symbol: "square.grid.3x3.fill"),
                ScreenshotToolbarButton(id: "tool_highlight", symbol: "rectangle.inset.filled"),
                ScreenshotToolbarButton(id: "color_picker", symbol: "circle.fill"),
                ScreenshotToolbarButton(id: "undo", symbol: "arrow.uturn.backward"),
            ] + completion
        }
    }
}
