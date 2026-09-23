import CoreGraphics

public enum ScreenshotAnnotationGeometry {
    public static func taperedArrowPolygon(start: CGPoint, end: CGPoint) -> [CGPoint] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return [] }

        let direction = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -direction.y, y: direction.x)

        let headLength = min(min(48, max(14, length * 0.28)), length * 0.48)
        let shaftHalfWidth = min(min(10, length * 0.12), max(2, length * 0.06))
        let headHalfWidth = min(min(26, length * 0.32), max(6, shaftHalfWidth * 2.4))
        let neck = CGPoint(
            x: end.x - direction.x * headLength,
            y: end.y - direction.y * headLength
        )

        func offset(_ point: CGPoint, by amount: CGFloat) -> CGPoint {
            CGPoint(x: point.x + normal.x * amount, y: point.y + normal.y * amount)
        }

        return [
            start,
            offset(neck, by: shaftHalfWidth),
            offset(neck, by: headHalfWidth),
            end,
            offset(neck, by: -headHalfWidth),
            offset(neck, by: -shaftHalfWidth),
        ]
    }
}
