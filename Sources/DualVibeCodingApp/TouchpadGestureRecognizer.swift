import CoreGraphics
import Foundation

/// Converts HID contact snapshots into gestures before any user mapping is applied.
struct TouchpadGestureRecognizer {
    enum Event: Equatable {
        case beganPress(String)
        case endedPress(String, isClick: Bool)
        case tap(String)
        case move(String, delta: CGPoint, crossedThreshold: Bool)
        case swipe(String)
    }

    private struct ContactSession {
        let startedAt: TimeInterval
        var origins: [Int: CGPoint] = [:]
        var mostFingers = 0
        var canTap = true
    }

    private struct PressSession {
        let id: String
        var origins: [Int: CGPoint]
        var isClick = true
        var canSwipe = true
        var didSwipe = false
        var didDrag = false

        init(_ contacts: [Int: CGPoint]) {
            if contacts.count == 2 {
                id = "touchPressTwoFinger"
            } else if let contact = contacts.values.first, contact.x > 0 {
                id = "touchPressRight"
            } else {
                id = "touchpad"
            }
            origins = contacts
        }
    }

    private struct MotionSegment {
        let origins: [Int: CGPoint]
        var crossedThreshold = false
    }

    private var previous: [Int: CGPoint] = [:]
    private var contactSession: ContactSession?
    private var press: PressSession?
    private var motionSegment: MotionSegment?
    private var ignoreUntilIdle = false
    private var filteredMotion = CGPoint.zero
    private var hasFilteredMotion = false

    var pressedMappingID: String? { press?.id }
    var hasContacts: Bool { !previous.isEmpty }

    mutating func cancel(suppressUntilIdle: Bool = false) {
        let isInProgress = !previous.isEmpty || press != nil || ignoreUntilIdle
        self = Self()
        ignoreUntilIdle = suppressUntilIdle || isInProgress
    }

    mutating func update(_ contacts: [Int: CGPoint], pressed: Bool,
                         at time: TimeInterval) -> [Event] {
        if ignoreUntilIdle {
            if contacts.isEmpty, !pressed { ignoreUntilIdle = false }
            return []
        }
        guard contacts != previous || pressed != (press != nil) else { return [] }
        defer { previous = contacts }
        var events: [Event] = []

        let deltas = offsets(from: previous, to: contacts)
        updateTap(contacts, deltas: deltas, interruptedByPress: pressed || press != nil,
                  at: time, events: &events)

        if var current = press {
            if !pressed {
                events.append(.endedPress(current.id, isClick: current.isClick))
                press = nil
            } else {
                trackPress(&current, contacts: contacts, deltas: deltas, events: &events)
                press = current
            }
        } else if pressed {
            press = PressSession(contacts)
            motionSegment = nil
            if let id = press?.id { events.append(.beganPress(id)) }
        } else if !contacts.isEmpty {
            trackUnpressedMotion(contacts, deltas: deltas, events: &events)
        }

        if contacts.isEmpty {
            motionSegment = nil
            filteredMotion = .zero
            hasFilteredMotion = false
        }
        return events
    }

    private mutating func updateTap(_ contacts: [Int: CGPoint], deltas: [Int: CGPoint],
                                    interruptedByPress: Bool, at time: TimeInterval,
                                    events: inout [Event]) {
        if contacts.isEmpty {
            if let current = contactSession, current.canTap, !interruptedByPress,
               time - current.startedAt <= 0.30 {
                events.append(.tap(current.mostFingers == 2 ? "touchSecondaryTap" : "touchTap"))
            }
            contactSession = nil
            return
        }

        var current = contactSession ?? ContactSession(startedAt: time)
        current.mostFingers = max(current.mostFingers, contacts.count)
        for (id, point) in contacts where current.origins[id] == nil { current.origins[id] = point }
        let travel = offsets(from: current.origins, to: contacts)
        if interruptedByPress || deltas.values.contains(where: { magnitude($0) > 0.35 })
            || travel.values.contains(where: { magnitude($0) > 0.06 })
            || current.origins.count > current.mostFingers {
            current.canTap = false
        }
        contactSession = current
    }

    private mutating func trackUnpressedMotion(_ contacts: [Int: CGPoint], deltas: [Int: CGPoint],
                                               events: inout [Event]) {
        // A finger lifting at the end of a two-finger gesture should not move the cursor.
        guard (contactSession?.mostFingers ?? 0) == contacts.count else { return }
        guard var segment = motionSegment, segment.origins.keys == contacts.keys else {
            motionSegment = MotionSegment(origins: contacts)
            return
        }
        guard deltas.count == contacts.count, let delta = average(deltas), delta != .zero else { return }

        let travel = offsets(from: segment.origins, to: contacts)
        let totalDelta = average(travel) ?? .zero
        let isScroll = contacts.count == 2
        let threshold: CGFloat = isScroll ? 0.035 : 0.07
        let triggered = !segment.crossedThreshold && magnitude(totalDelta) >= threshold
        if triggered {
            segment.crossedThreshold = true
            motionSegment = segment
            if isScroll { contactSession?.canTap = false }
        }
        // Let small one-finger corrections through while keeping a stationary
        // two-finger tap from dispatching scroll events.
        if !isScroll || segment.crossedThreshold {
            let motion = isScroll && triggered ? totalDelta : filtered(delta, isScroll: isScroll)
            guard motion != .zero else { return }
            events.append(.move(isScroll ? "touchScroll" : "touchMove",
                                delta: motion, crossedThreshold: triggered))
        }
    }

    /// Smooth only the high-frequency quantisation noise from the controller's
    /// 1,920 × 1,080 touch grid. The filter is deliberately one-pole and
    /// stateful, so it adds no timer latency and still forwards every real
    /// movement sample. Two-finger scroll keeps a lighter blend to preserve
    /// intentional wheel detail.
    private mutating func filtered(_ delta: CGPoint, isScroll: Bool) -> CGPoint {
        let blend: CGFloat = isScroll ? 0.72 : 0.84
        if !hasFilteredMotion {
            filteredMotion = delta
            hasFilteredMotion = true
        } else {
            filteredMotion = CGPoint(
                x: filteredMotion.x * (1 - blend) + delta.x * blend,
                y: filteredMotion.y * (1 - blend) + delta.y * blend
            )
        }
        let deadband: CGFloat = isScroll ? 0.0014 : 0.001
        return CGPoint(
            x: abs(filteredMotion.x) < deadband ? 0 : filteredMotion.x,
            y: abs(filteredMotion.y) < deadband ? 0 : filteredMotion.y
        )
    }

    private func trackPress(_ current: inout PressSession, contacts: [Int: CGPoint],
                            deltas: [Int: CGPoint], events: inout [Event]) {
        if current.id == "touchPressTwoFinger" {
            guard current.canSwipe, !current.didSwipe else { return }
            guard current.origins.keys == contacts.keys else {
                current.canSwipe = false
                return
            }
            let travel = offsets(from: current.origins, to: contacts)
            if travel.values.contains(where: { magnitude($0) > 0.06 }) { current.isClick = false }
            guard let middle = average(travel), abs(middle.x) >= 0.22,
                  abs(middle.x) >= abs(middle.y) * 1.25,
                  travel.values.allSatisfy({ middle.x < 0 ? $0.x <= -0.14 : $0.x >= 0.14 }) else { return }
            current.didSwipe = true
            events.append(.swipe(middle.x < 0 ? "touchSwipeLeft" : "touchSwipeRight"))
            return
        }

        guard contacts.count == 1, let (id, point) = contacts.first else { return }
        guard let origin = current.origins[id], let delta = deltas[id] else {
            current.origins = contacts
            return
        }
        let totalDelta = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let started = !current.didDrag && magnitude(totalDelta) >= 0.025
        if started {
            current.didDrag = true
            current.isClick = false
        }
        let movement = started ? totalDelta : delta
        if current.didDrag, movement != .zero {
            events.append(.move("touchDrag", delta: movement, crossedThreshold: started))
        }
    }

    private func offsets(from origins: [Int: CGPoint], to contacts: [Int: CGPoint]) -> [Int: CGPoint] {
        contacts.reduce(into: [:]) { result, contact in
            guard let origin = origins[contact.key] else { return }
            result[contact.key] = CGPoint(x: contact.value.x - origin.x, y: contact.value.y - origin.y)
        }
    }

    private func magnitude(_ point: CGPoint) -> CGFloat {
        hypot(point.x, point.y)
    }

    private func average(_ deltas: [Int: CGPoint]) -> CGPoint? {
        guard !deltas.isEmpty else { return nil }
        let sum = deltas.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(deltas.count), y: sum.y / CGFloat(deltas.count))
    }
}
