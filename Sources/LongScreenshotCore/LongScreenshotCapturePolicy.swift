public enum LongScreenshotCapturePolicy {
    public static func frameCapacity(width: Int, height: Int) -> Int {
        let frameBytes = Double(max(1, width)) * Double(max(1, height)) * 4
        let memoryBudget = Double(160 * 1024 * 1024)
        return max(2, min(12, Int(memoryBudget / frameBytes)))
    }

    public static func interval(unchangedFrameCount: Int, queuedFrames: Int = 0) -> Double {
        let baseInterval: Double
        if unchangedFrameCount >= 6 {
            baseInterval = 0.12
        } else if unchangedFrameCount >= 3 {
            baseInterval = 0.06
        } else {
            baseInterval = 0.015
        }
        if queuedFrames >= 4 { return max(baseInterval, 0.09) }
        if queuedFrames >= 2 { return max(baseInterval, 0.05) }
        return baseInterval
    }
}
