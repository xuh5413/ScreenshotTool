import CoreGraphics
import ScreenshotToolbarCore

@main
struct ScreenshotToolbarChecks {
    static func main() {
        expect(ScreenshotToolbarMetrics.height == 46 &&
               ScreenshotToolbarMetrics.buttonSize == 36 &&
               ScreenshotToolbarMetrics.buttonGap == 3 &&
               ScreenshotToolbarMetrics.iconPointSize == 20,
               "all screenshot toolbars must share the same visual metrics")
        let quick = ScreenshotToolbarConfiguration.buttons(for: .quick)
        expect(quick.map(\.id) == ["annotate", "longscreenshot", "pin", "save", "cancel", "copy"],
               "quick capture must expose save, cancel, and completion directly")
        expect(quick.allSatisfy { $0.title == nil },
               "the flat toolbar must use icon-only controls")
        expect(quick.first(where: { $0.id == "annotate" })?.symbol == "custom.annotate",
               "annotation entry must use the consistent thin-line pen icon")
        expect(quick.first(where: { $0.id == "longscreenshot" })?.symbol == "custom.long-screenshot",
               "long screenshot must use the capture-frame and scissors icon")
        expect(ScreenshotToolbarConfiguration.showsHoverTooltips(for: .quick),
               "icon-only quick controls must retain hover tooltips")
        expect(quick.last?.isPrimary == true && quick.first(where: { $0.id == "pin" })?.isPrimary == false,
               "copy must remain the single primary action")

        let editing = ScreenshotToolbarConfiguration.buttons(for: .annotating)
        expect(editing.first?.id == "back", "annotation tools must offer a way back")
        let annotationButtons = Array(editing.dropFirst().prefix(7))
        expect(annotationButtons.map(\.id) == [
            "tool_arrow", "tool_text", "tool_number", "tool_rectangle",
            "tool_ellipse", "tool_mosaic", "tool_highlight",
        ], "annotation controls must use stable semantic identifiers")
        expect(annotationButtons.map(\.symbol) == [
            "arrow.up.right", "custom.text.a", "1.circle", "rectangle",
            "circle", "square.grid.3x3.fill", "rectangle.inset.filled",
        ], "every annotation function must use its matching icon")
        expect(editing.contains(where: { $0.id == "color_picker" }) &&
               editing.contains(where: { $0.id == "undo" }),
               "annotation mode must expose current color and undo")
        expect(editing.suffix(4).map(\.id) == ["pin", "save", "cancel", "copy"],
               "annotation completion actions must remain directly accessible")
        expect(ScreenshotToolbarConfiguration.showsHoverTooltips(for: .annotating),
               "icon-only annotation tools must retain hover tooltips")

        let arrow = ScreenshotAnnotationGeometry.taperedArrowPolygon(
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 100, y: 0)
        )
        expect(arrow.count == 6, "tapered arrow must produce a six-point filled polygon")
        expect(arrow.first == CGPoint(x: 0, y: 0), "tapered arrow must begin at a sharp tail")
        expect(arrow[3] == CGPoint(x: 100, y: 0), "drag end must be the arrow tip")
        expect(abs(arrow[2].y) > abs(arrow[1].y),
               "arrow head must be wider than its tapered shaft")
        expect(ScreenshotAnnotationGeometry.taperedArrowPolygon(
            start: CGPoint(x: 5, y: 5), end: CGPoint(x: 5, y: 5)
        ).isEmpty, "zero-length arrow must not produce invalid geometry")
        print("✅ ScreenshotToolbarChecks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("❌ \(message)") }
    }
}
