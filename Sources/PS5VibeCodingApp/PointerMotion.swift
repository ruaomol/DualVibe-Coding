import CoreGraphics
import Foundation

/// Keeps Quartz's pending absolute position ahead of the asynchronous event queue.
struct PointerMotion {
    private static let frameInterval: TimeInterval = 1 / 120
    private static let idleInterval: TimeInterval = 0.10

    private var target: CGPoint?
    private var lastPostedPosition: CGPoint?
    private var lastSampleAt: TimeInterval?
    private var lastPostedAt: TimeInterval?
    private var pending = false

    mutating func add(
        _ delta: CGPoint,
        at time: TimeInterval,
        displays: [CGRect],
        readCursor: () -> CGPoint?
    ) {
        guard delta.x.isFinite, delta.y.isFinite, delta != .zero else { return }
        if target == nil || (!pending && !isRecent(at: time)) {
            target = readCursor()
            lastPostedPosition = target
            lastPostedAt = nil
        }
        guard let target else { return }
        let next = Self.clamp(CGPoint(x: target.x + delta.x, y: target.y + delta.y), to: displays)
        self.target = next
        lastSampleAt = time
        pending = next != lastPostedPosition
    }

    func timeUntilPost(at time: TimeInterval) -> TimeInterval? {
        guard pending else { return nil }
        guard let lastPostedAt else { return 0 }
        return max(0, Self.frameInterval - (time - lastPostedAt))
    }

    mutating func takePosition(at time: TimeInterval) -> CGPoint? {
        guard pending, let target else { return nil }
        pending = false
        lastPostedPosition = target
        lastPostedAt = time
        return target
    }

    func positionForButton(at time: TimeInterval, readCursor: () -> CGPoint?) -> CGPoint? {
        if isRecent(at: time), let lastPostedPosition { return lastPostedPosition }
        return readCursor() ?? lastPostedPosition
    }

    mutating func discardPending() {
        pending = false
        target = lastPostedPosition
    }

    private func isRecent(at time: TimeInterval) -> Bool {
        lastSampleAt.map { time - $0 <= Self.idleInterval } ?? false
    }

    private static func clamp(_ point: CGPoint, to displays: [CGRect]) -> CGPoint {
        if displays.contains(where: { $0.contains(point) }) { return point }
        return displays.map { bounds in
            CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                    y: min(max(point.y, bounds.minY), bounds.maxY - 1))
        }.min { lhs, rhs in
            hypot(lhs.x - point.x, lhs.y - point.y) < hypot(rhs.x - point.x, rhs.y - point.y)
        } ?? point
    }
}
