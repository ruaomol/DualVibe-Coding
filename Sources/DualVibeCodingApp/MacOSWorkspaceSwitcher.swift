import CoreGraphics

/// Posts the native horizontal Space gesture independently of the user's shortcut bindings.
/// Adapted from Agent Remote's MacOSWorkspaceSwitcher, which credits yabai
/// (MIT, see ThirdParty/AgentRemote/THIRD_PARTY_NOTICES.md).
enum MacOSWorkspaceSwitcher {
    static func switchSpace(toRight: Bool) -> Bool {
        guard let event = CGEvent(source: nil),
              let eventType = CGEventField(rawValue: 55),
              let hidType = CGEventField(rawValue: 110),
              let motion = CGEventField(rawValue: 123),
              let progress = CGEventField(rawValue: 124),
              let velocityX = CGEventField(rawValue: 129),
              let phase = CGEventField(rawValue: 132) else { return false }

        let destinationSign = toRight ? 1.0 : -1.0
        event.setIntegerValueField(eventType, value: 30) // Dock gesture control
        event.setIntegerValueField(hidType, value: 23) // Swipe
        event.setIntegerValueField(motion, value: 1) // Horizontal
        event.setDoubleValueField(progress, value: destinationSign)
        event.setDoubleValueField(velocityX, value: destinationSign * 9_999.0)
        event.setIntegerValueField(phase, value: 1) // Began
        event.post(tap: .cgSessionEventTap)
        event.setIntegerValueField(phase, value: 4) // Ended
        event.post(tap: .cgSessionEventTap)
        return true
    }
}
