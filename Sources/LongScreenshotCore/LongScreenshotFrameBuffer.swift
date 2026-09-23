import Foundation

public final class LongScreenshotFrameBuffer<Frame>: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var frames: [Frame] = []
    private var closed = false
    private var dropped = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func offer(_ frame: Frame) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return false }
        guard frames.count < capacity else {
            dropped += 1
            return false
        }
        frames.append(frame)
        condition.signal()
        return true
    }

    public func take(timeout: TimeInterval) -> Frame? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        while frames.isEmpty && !closed {
            guard condition.wait(until: deadline) else { return nil }
        }
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    public func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    public var isDrained: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed && frames.isEmpty
    }

    public var bufferedFrameCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return frames.count
    }

    public var droppedFrameCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return dropped
    }

    public var canFinalizeSafely: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed && frames.isEmpty && dropped == 0
    }
}
