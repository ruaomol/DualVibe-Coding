struct DualSenseInputSample: Equatable, Sendable {
    enum Button: String, CaseIterable, Sendable {
        case cross, circle, square, triangle
        case dpadUp, dpadRight, dpadDown, dpadLeft
        case l1, l2, r1, r2, l3, r3
        case create, options, ps, touchpad, mute
    }

    struct Touch: Equatable, Sendable {
        let contactID: UInt8
        let x: Float
        let y: Float
    }

    enum BatteryStatus: Equatable, Sendable {
        case discharging, charging, full
    }

    let buttons: Set<Button>
    let leftStickX: Float
    let leftStickY: Float
    let rightStickX: Float
    let rightStickY: Float
    let leftTrigger: Float
    let rightTrigger: Float
    let primaryTouch: Touch?
    let secondaryTouch: Touch?
    let batteryLevel: Float?
    let batteryStatus: BatteryStatus?
    let isMicrophoneMuted: Bool

    private static let hats: [[Button]] = [
        [.dpadUp], [.dpadUp, .dpadRight], [.dpadRight], [.dpadRight, .dpadDown],
        [.dpadDown], [.dpadDown, .dpadLeft], [.dpadLeft], [.dpadLeft, .dpadUp]
    ]
    private static let faceButtons: [(mask: UInt8, button: Button)] = [
        (0x10, .square), (0x20, .cross), (0x40, .circle), (0x80, .triangle)
    ]
    private static let shoulderButtons: [(mask: UInt8, button: Button)] = [
        (0x01, .l1), (0x02, .r1), (0x04, .l2), (0x08, .r2),
        (0x10, .create), (0x20, .options), (0x40, .l3), (0x80, .r3)
    ]
    private static let centerButtons: [(mask: UInt8, button: Button)] = [
        (0x01, .ps), (0x02, .touchpad), (0x04, .mute)
    ]

    static func parse(reportID: UInt32, bytes: [UInt8]) -> Self? {
        bytes.withUnsafeBufferPointer { parse(reportID: reportID, bytes: $0) }
    }

    /// Axes and touches are in -1...1, right and up are positive, and
    /// analog triggers are in 0...1. Only pass reports from a matched DualSense.
    static func parse(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>) -> Self? {
        let payloadStart: Int
        switch (reportID, bytes.count) {
        case (0x01, 64) where bytes[0] == 0x01:
            payloadStart = 1
        case (0x01, 63):
            payloadStart = 0
        case (0x31, 78) where bytes[0] == 0x31:
            payloadStart = 2
        case (0x31, 77):
            payloadStart = 1
        default:
            return nil
        }

        // The Bluetooth controller flags and Opus frames share report 0x31.
        // The frame length identifies whether IOKit stripped the report ID.
        if reportID == 0x31, bytes[payloadStart - 1] & 0x02 != 0 {
            return nil
        }

        let faceAndHat = bytes[payloadStart + 7]
        let shoulders = bytes[payloadStart + 8]
        let center = bytes[payloadStart + 9]
        let hat = Int(faceAndHat & 0x0F)
        var buttons = Set(hats.indices.contains(hat) ? hats[hat] : [])
        for (mask, button) in faceButtons where faceAndHat & mask != 0 {
            buttons.insert(button)
        }
        for (mask, button) in shoulderButtons where shoulders & mask != 0 {
            buttons.insert(button)
        }
        for (mask, button) in centerButtons where center & mask != 0 {
            buttons.insert(button)
        }

        let battery = batteryReading(from: bytes[payloadStart + 52])
        return Self(
            buttons: buttons,
            leftStickX: stickAxis(bytes[payloadStart]),
            leftStickY: -stickAxis(bytes[payloadStart + 1]),
            rightStickX: stickAxis(bytes[payloadStart + 2]),
            rightStickY: -stickAxis(bytes[payloadStart + 3]),
            leftTrigger: Float(bytes[payloadStart + 4]) / 255,
            rightTrigger: Float(bytes[payloadStart + 5]) / 255,
            primaryTouch: touch(at: payloadStart + 32, in: bytes),
            secondaryTouch: touch(at: payloadStart + 36, in: bytes),
            batteryLevel: battery?.level,
            batteryStatus: battery?.status,
            isMicrophoneMuted: bytes[payloadStart + 53] & 0x04 != 0
        )
    }

    private static func stickAxis(_ raw: UInt8) -> Float {
        let centered = Float(raw) - 128
        return centered / (centered < 0 ? 128 : 127)
    }

    private static func touch(at offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Touch? {
        let contact = bytes[offset]
        guard contact & 0x80 == 0 else { return nil }
        let combined = Int(bytes[offset + 2])
        let rawX = Int(bytes[offset + 1]) | ((combined & 0x0F) << 8)
        let rawY = (combined >> 4) | (Int(bytes[offset + 3]) << 4)
        guard rawX < 1_920, rawY < 1_080 else { return nil }
        return Touch(
            contactID: contact & 0x7F,
            x: Float(rawX) * 2 / 1_919 - 1,
            y: 1 - Float(rawY) * 2 / 1_079
        )
    }

    private static func batteryReading(from status: UInt8) -> (level: Float, status: BatteryStatus)? {
        let bucket = Int(status & 0x0F)
        let charging = status >> 4
        switch charging {
        case 0x00, 0x01:
            guard bucket <= 10 else { return nil }
            // The controller reports 10% bands. Display the midpoint.
            return (Float(min(bucket * 10 + 5, 100)) / 100, charging == 0 ? .discharging : .charging)
        case 0x02:
            return (1, .full)
        default:
            return nil
        }
    }
}
