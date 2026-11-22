import AppKit
import SwiftUI

/// Shared Apple macOS + PlayStation 5 DualSense aesthetic tokens and motion curves.
enum DualVibeMotion {
    static let tactile = Animation.spring(response: 0.22, dampingFraction: 0.84)
    static let snappy = Animation.spring(response: 0.30, dampingFraction: 0.86)
    static let glide = Animation.spring(response: 0.38, dampingFraction: 0.88)
    static let stage = Animation.spring(response: 0.48, dampingFraction: 0.85)
    static let wheelPresent = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let wheelDismiss = Animation.easeOut(duration: 0.16)

    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

enum DualVibePalette {
    /// PS5 DualSense light-bar inspired cobalt/ice-blue accent adapted for macOS light & dark modes.
    static func lightBar(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.32, green: 0.66, blue: 1.0)
            : Color(red: 0.04, green: 0.40, blue: 0.92)
    }

    static func lightBarGlow(for scheme: ColorScheme) -> Color {
        lightBar(for: scheme).opacity(scheme == .dark ? 0.36 : 0.22)
    }

    static func lightBarGradient(for scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.48, green: 0.78, blue: 1.0), Color(red: 0.18, green: 0.48, blue: 1.0)]
                : [Color(red: 0.12, green: 0.50, blue: 1.0), Color(red: 0.02, green: 0.32, blue: 0.84)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func hairlineBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08)
    }

    static func elevatedFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.032)
    }
}

/// Static, non-pulsing semantic status pill using native SF Symbols.
struct DualVibeStatusBadge: View {
    enum Tone {
        case accent
        case positive
        case warning
        case critical
        case neutral

        func foreground(for scheme: ColorScheme) -> Color {
            switch self {
            case .accent: return DualVibePalette.lightBar(for: scheme)
            case .positive: return .green
            case .warning: return .orange
            case .critical: return .red
            case .neutral: return .secondary
            }
        }

        func background(for scheme: ColorScheme) -> Color {
            switch self {
            case .neutral: return Color.primary.opacity(scheme == .dark ? 0.08 : 0.055)
            default: return foreground(for: scheme).opacity(scheme == .dark ? 0.18 : 0.11)
            }
        }
    }

    let text: String
    var systemImage: String? = nil
    var tone: Tone = .neutral

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tone.foreground(for: colorScheme))
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(tone.background(for: colorScheme), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tone.foreground(for: colorScheme).opacity(tone == .neutral ? 0.10 : 0.22), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
    }
}

/// macOS System Settings-style compact sidebar icon squircle with crisp top specular bevel.
struct DualVibeSidebarIcon: View {
    let systemImage: String
    let tint: Color
    var isSelected: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(colorScheme == .dark ? 0.92 : 0.96),
                            tint.opacity(colorScheme == .dark ? 0.72 : 0.80)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isSelected ? 0.55 : (colorScheme == .dark ? 0.28 : 0.42)),
                            Color.white.opacity(isSelected ? 0.18 : 0.06)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: isSelected ? 0.9 : 0.65
                )

            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: isSelected && !reduceMotion)
        }
        .frame(width: 22, height: 22)
        .shadow(color: Color.black.opacity(isSelected ? 0.18 : 0.08), radius: 1.5, y: 0.75)
        .accessibilityHidden(true)
    }
}

/// Apple Hardware × PlayStation 5 DualSense ceramic control medallion.
/// Renders official macOS SF Symbols for DualSense buttons inside a machined porcelain/obsidian platter.
struct DualVibeControlIcon: View {
    let mappingID: String
    var size: CGFloat = 46

    @Environment(\.colorScheme) private var colorScheme

    private var isFaceButton: Bool {
        ["cross", "circle", "square", "triangle"].contains(mappingID)
    }

    private var isPlayStationButton: Bool {
        mappingID == "ps"
    }

    private var symbolName: String {
        ButtonMapping.hardwareSymbolName(for: mappingID)
    }

    private var cornerRadius: CGFloat {
        size * 0.28
    }

    var body: some View {
        let accent = DualVibePalette.lightBar(for: colorScheme)
        ZStack {
            // DualSense white porcelain / midnight-black machined ceramic platter
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(white: 0.23), Color(white: 0.145)]
                            : [Color.white, Color(white: 0.945)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Subtle inner top specular highlight
            RoundedRectangle(cornerRadius: cornerRadius - 0.5, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white.opacity(0.20), Color.white.opacity(0.03)]
                            : [Color.white.opacity(0.95), Color.black.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .padding(0.5)

            // Crisp outer hairline contour
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.11),
                    lineWidth: 0.75
                )

            // For DualSense face buttons (□ △ ○ ×), render the iconic recessed crystal button cap
            if isFaceButton {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color(white: 0.16), Color(white: 0.25)]
                                : [Color(white: 0.92), Color.white],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        accent.opacity(colorScheme == .dark ? 0.34 : 0.22),
                                        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.85
                            )
                    }
                    .frame(width: size * 0.72, height: size * 0.72)
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06), radius: 1.5, y: 0.75)
            }

            Image(systemName: symbolName)
                .font(.system(size: symbolPointSize, weight: isFaceButton ? .semibold : .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(symbolForeground(accent: accent))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.36 : 0.09), radius: size * 0.14, y: size * 0.05)
        .accessibilityHidden(true)
    }

    private var symbolPointSize: CGFloat {
        if isFaceButton { return size * 0.34 }
        if isPlayStationButton { return size * 0.44 }
        return size * 0.46
    }

    private func symbolForeground(accent: Color) -> Color {
        if isPlayStationButton { return accent }
        if colorScheme == .dark { return Color(white: 0.94) }
        return Color(red: 0.13, green: 0.14, blue: 0.17)
    }
}

extension ButtonMapping {
    static func hardwareSymbolName(for id: String) -> String {
        switch id {
        case "cross": return "xmark"
        case "circle": return "circle"
        case "square": return "square"
        case "triangle": return "triangle"
        case "l1": return "l1.button.roundedbottom.horizontal"
        case "r1": return "r1.button.roundedbottom.horizontal"
        case "l2": return "l2.button.roundedtop.horizontal"
        case "r2": return "r2.button.roundedtop.horizontal"
        case "dpadUp": return "dpad.up.filled"
        case "dpadRight": return "dpad.right.filled"
        case "dpadDown": return "dpad.down.filled"
        case "dpadLeft": return "dpad.left.filled"
        case "dpad": return "dpad"
        case "leftStick": return "l.joystick"
        case "l3": return "l.joystick.press.down"
        case "leftStickUp": return "l.joystick.tilt.up"
        case "leftStickRight": return "l.joystick.tilt.right"
        case "leftStickDown": return "l.joystick.tilt.down"
        case "leftStickLeft": return "l.joystick.tilt.left"
        case "rightStick": return "r.joystick"
        case "r3": return "r.joystick.press.down"
        case "rightStickUp": return "r.joystick.tilt.up"
        case "rightStickRight": return "r.joystick.tilt.right"
        case "rightStickDown": return "r.joystick.tilt.down"
        case "rightStickLeft": return "r.joystick.tilt.left"
        case "ps": return "logo.playstation"
        case "create": return "plus.square"
        case "options": return "line.3.horizontal"
        case "mute": return "mic.slash.fill"
        case "touchpad": return "rectangle.lefthalf.filled"
        case "touchPressRight": return "rectangle.righthalf.filled"
        case "touchPressTwoFinger": return "rectangle.and.hand.point.up.left"
        case "touchMove", "touchDrag": return "hand.draw"
        case "touchScroll": return "hand.point.up.left"
        case "touchTap", "touchSecondaryTap": return "hand.tap"
        case "touchSwipeLeft", "touchSwipeRight": return "arrow.left.and.right"
        default: return "gamecontroller.fill"
        }
    }
}

/// Machined Apple Compass × PS5 DualSense directional dial icon for radial wheel slots.
struct DualVibeDirectionDial: View {
    let angle: Double
    var size: CGFloat = 38

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Machined ceramic dial base
            Circle()
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(white: 0.23), Color(white: 0.145)]
                            : [Color.white, Color(white: 0.945)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Inner specular rim
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white.opacity(0.20), Color.white.opacity(0.03)]
                            : [Color.white.opacity(0.95), Color.black.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .padding(0.5)

            // Outer hairline border
            Circle()
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.11),
                    lineWidth: 0.75
                )

            // 8 precision radial compass ticks
            ForEach(0..<8, id: \.self) { index in
                VStack {
                    Capsule()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.14))
                        .frame(width: 1.2, height: index % 2 == 0 ? 3.2 : 2.2)
                    Spacer()
                }
                .padding(3.2)
                .rotationEffect(.degrees(Double(index) * 45))
            }

            // Smooth shortest-arc gliding PS5 cobalt directional arc
            DialActiveArc()
                .stroke(
                    DualVibePalette.lightBarGradient(for: colorScheme),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                )
                .padding(1.2)
                .shadow(color: DualVibePalette.lightBarGlow(for: colorScheme), radius: 3)
                .rotationEffect(.radians(angle))
                .animation(DualVibeMotion.resolve(DualVibeMotion.glide, reduceMotion: reduceMotion), value: angle)

            // Precision rotating directional arrow
            Image(systemName: "arrow.up")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color(white: 0.95) : Color(red: 0.13, green: 0.14, blue: 0.17))
                .rotationEffect(.radians(angle))
                .animation(DualVibeMotion.resolve(DualVibeMotion.glide, reduceMotion: reduceMotion), value: angle)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.08), radius: 5, y: 2)
        .accessibilityHidden(true)
    }
}

private struct DialActiveArc: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let top = -Double.pi / 2
        let half = Double.pi / 8 * 0.88
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .radians(top - half),
                    endAngle: .radians(top + half),
                    clockwise: false)
        return path
    }
}

/// macOS System Settings-style rounded icon squircle with refined depth.
struct DualVibeIconBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 30
    var cornerRadius: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.gradient)
                .opacity(colorScheme == .dark ? 0.88 : 0.94)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.34), lineWidth: 0.6)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(colorScheme == .dark ? 0.26 : 0.18), radius: 4, y: 1.5)
        .accessibilityHidden(true)
    }
}

/// Tactile macOS keyboard keycap / controller badge pill.
struct DualVibeKeycap: View {
    let text: String
    var prominent: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(prominent ? DualVibePalette.lightBar(for: colorScheme) : Color.primary)
            .padding(.horizontal, 7.5)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent
                          ? DualVibePalette.lightBar(for: colorScheme).opacity(colorScheme == .dark ? 0.18 : 0.11)
                          : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        prominent
                            ? DualVibePalette.lightBar(for: colorScheme).opacity(0.35)
                            : DualVibePalette.hairlineBorder(for: colorScheme),
                        lineWidth: 0.8
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.05), radius: 1, y: 1)
    }
}

/// Thin PS5 DualSense light-bar accent strip (static illumination, never pulsing).
struct DualVibeLightBar: View {
    var orientation: Axis = .vertical
    var length: CGFloat? = nil
    var thickness: CGFloat = 2.5

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill(DualVibePalette.lightBarGradient(for: colorScheme))
            .frame(
                width: orientation == .vertical ? thickness : length,
                height: orientation == .horizontal ? thickness : length
            )
            .shadow(color: DualVibePalette.lightBarGlow(for: colorScheme), radius: 4, x: 0, y: 0)
    }
}

/// Subtle tactile press scale style inspired by Apple & PlayStation 5 UI feedback.
struct DualVibeTactileButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.975
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .animation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}

/// Lightweight observable hover state (avoids SwiftUIMacros `@State` dependency on CommandLineTools SDKs).
@MainActor
final class DualVibeHoverState: ObservableObject {
    @Published var isHovered = false
}

/// Smooth continuous audio level bar for DualSense / system microphone monitoring.
struct DualVibeLevelMeter: View {
    let level: Double
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(level, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = max(0, proxy.size.width * clamped)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DualVibePalette.elevatedFill(for: colorScheme))
                    .overlay {
                        Capsule()
                            .strokeBorder(DualVibePalette.hairlineBorder(for: colorScheme), lineWidth: 0.6)
                    }
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                DualVibePalette.lightBar(for: colorScheme),
                                Color.cyan,
                                Color.green
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 260, damping: 24), value: clamped)
            }
        }
        .frame(height: 7)
    }
}
