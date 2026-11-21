import CoreGraphics
import Foundation

enum LauncherWheelGeometry {
    static let count = 8
    static let step = 2 * Double.pi / Double(count)

    static func angle(_ slot: Int) -> Double { Double(slot) * step }

    // Direction uses the controller coordinate system: positive Y is up.
    static func slot(for direction: CGPoint, retaining current: Int?) -> Int? {
        guard hypot(direction.x, direction.y) >= 0.29 else { return nil }
        let turn = atan2(direction.x, direction.y)
        if let current {
            let difference = turn - angle(current)
            if abs(atan2(sin(difference), cos(difference))) <= step * 0.59 { return current }
        }
        return (Int((turn / step).rounded()) + count) % count
    }

    static func move(_ direction: CGPoint, from selected: Int?, among candidates: [Int]) -> Int? {
        guard let direct = slot(for: direction, retaining: nil), !candidates.isEmpty else { return selected }
        let diagonal = direction.x != 0 && direction.y != 0
        if diagonal && candidates.contains(direct) { return direct }

        func point(_ slot: Int) -> CGPoint {
            CGPoint(x: sin(angle(slot)), y: cos(angle(slot)))
        }
        func score(_ slot: Int, from origin: CGPoint) -> Double? {
            let destination = point(slot)
            let delta = CGPoint(x: destination.x - origin.x, y: destination.y - origin.y)
            let along = direction.x * delta.x + direction.y * delta.y
            let across = direction.x * delta.y - direction.y * delta.x
            guard along > 0.01 else { return nil }
            return atan2(abs(across), along) + hypot(delta.x, delta.y) * 0.035
        }
        let origin = selected.map(point) ?? .zero
        return candidates.sorted()
            .compactMap { slot in score(slot, from: origin).map { (slot, $0) } }
            .min { $0.1 < $1.1 - 0.0001 }?.0 ?? selected
    }

    static func frame(near anchor: CGPoint, inside visibleFrame: CGRect, maximumDimension: CGFloat = 300) -> CGRect {
        let visibleFrame = visibleFrame.standardized
        guard !visibleFrame.isNull, !visibleFrame.isInfinite, !visibleFrame.isEmpty,
              maximumDimension.isFinite, maximumDimension > 0 else {
            return .zero
        }
        let limit = min(visibleFrame.width, visibleFrame.height)
        let margin = min(12, limit / 6)
        let dimension = min(maximumDimension, limit - 2 * margin)
        let radius = dimension / 2
        let inset = visibleFrame.insetBy(dx: margin, dy: margin)
        let anchorX = anchor.x.isFinite ? anchor.x : inset.midX
        let anchorY = anchor.y.isFinite ? anchor.y : inset.midY
        let x = min(max(anchorX - radius, inset.minX), inset.maxX - dimension)
        let y = min(max(anchorY - radius, inset.minY), inset.maxY - dimension)
        return CGRect(x: x, y: y, width: dimension, height: dimension)
    }
}
