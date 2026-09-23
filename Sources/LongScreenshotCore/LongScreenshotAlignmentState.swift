public struct LongScreenshotAlignmentState {
    private var consecutiveFailures = 0
    private var unresolvedGap = false

    public init() {}

    public mutating func recordMatchFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= 2 { unresolvedGap = true }
    }

    public mutating func recordAcceptedFrame() {
        consecutiveFailures = 0
        unresolvedGap = false
    }

    public mutating func recordRejectedDistance() {
        unresolvedGap = true
    }

    public mutating func recordDroppedFrames() {
        unresolvedGap = true
    }

    public mutating func recordReturnedToCapturedArea() {
        consecutiveFailures = 0
        unresolvedGap = false
    }

    public var canFinalizeSafely: Bool { !unresolvedGap }
}
