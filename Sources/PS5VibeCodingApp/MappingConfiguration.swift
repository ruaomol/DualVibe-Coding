import AppKit
import CoreGraphics

enum MappingAction: String, CaseIterable, Identifiable, Codable {
    case none = "未设置"
    case moveCursor = "移动光标"
    case scroll = "滚动页面"
    case leftClick = "鼠标左键"
    case leftDoubleClick = "鼠标左键双击"
    case leftLongPress = "鼠标左键长按"
    case leftHold = "按住鼠标左键"
    case rightClick = "鼠标右键"
    case middleClick = "鼠标中键"
    case shortcut = "键盘快捷键"
    case openApp = "打开应用"
    case screenshot = "区域截图"
    case commandPalette = "命令面板"
    case terminal = "切换终端"
    case switchSpaceLeft = "切换到左侧桌面"
    case switchSpaceRight = "切换到右侧桌面"
    case sensitivityDown = "降低灵敏度"
    case sensitivityUp = "提高灵敏度"
    case precision = "按住精确移动"
    case voice = "按住使用手柄麦克风"
    case voiceToggle = "开启或关闭手柄麦克风"
    case microphoneMuteToggle = "切换手柄麦克风静音"
    case runCombo = "运行组合键动作"
    case showLauncher = "打开应用启动器"

    var id: Self { self }
    var displayTitle: String { self == .showLauncher ? "打开／关闭快捷轮盘" : rawValue }
    var isContinuous: Bool { self == .moveCursor || self == .scroll }
    var followsPress: Bool { self == .voice || self == .precision || self == .leftHold }
    static var comboOutputActions: [Self] {
        allCases.filter { $0 != .none && $0 != .runCombo && !$0.isContinuous && !$0.followsPress }
    }
}

enum GestureKind: String, CaseIterable, Identifiable, Codable {
    case tap = "单击"
    case doubleTap = "双击"
    case hold = "长按"

    var id: Self { self }
}

struct RecordedShortcut: Codable, Hashable {
    let code: UInt16
    let flags: UInt64
    let title: String

    init(_ code: UInt16, _ flags: CGEventFlags = [], _ title: String) {
        self.code = code
        self.flags = flags.rawValue
        self.title = title
    }

    func merging(_ other: RecordedShortcut) -> RecordedShortcut {
        let combinedFlags = CGEventFlags(rawValue: flags | other.flags)
        let combinedTitle = title.contains(other.title) ? title : title + other.title
        return RecordedShortcut(other.code, combinedFlags, combinedTitle)
    }

    init(event: NSEvent) {
        let modifiers = event.modifierFlags
        var flags = CGEventFlags()
        var symbols = ""
        for (modifier, flag, symbol) in [
            (NSEvent.ModifierFlags.control, CGEventFlags.maskControl, "⌃"),
            (.option, .maskAlternate, "⌥"), (.shift, .maskShift, "⇧"),
            (.command, .maskCommand, "⌘")
        ] where modifiers.contains(modifier) {
            flags.insert(flag)
            symbols += symbol
        }
        if modifiers.contains(.function), !Self.functionKeys.contains(event.keyCode) {
            flags.insert(.maskSecondaryFn)
            symbols = "fn " + symbols
        }
        let names: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "Esc",
            115: "Home", 116: "PgUp", 117: "⌦", 119: "End", 121: "PgDn",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        let key = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let display = key.isEmpty ? "键码 \(event.keyCode)" : key
        self.init(event.keyCode, flags, symbols + display)
    }

    /// Modifier-only shortcuts arrive as flagsChanged events instead of
    /// keyDown. Keep the physical modifier key code so playback can emit the
    /// same key on macOS.
    init?(modifierEvent event: NSEvent) {
        let keyNames: [UInt16: (CGEventFlags, String)] = [
            54: (.maskCommand, "⌘"), 55: (.maskCommand, "⌘"),
            56: (.maskShift, "⇧"), 60: (.maskShift, "⇧"),
            58: (.maskAlternate, "⌥"), 61: (.maskAlternate, "⌥"),
            59: (.maskControl, "⌃"), 62: (.maskControl, "⌃"),
            63: (.maskSecondaryFn, "fn")
        ]
        guard let (flag, title) = keyNames[event.keyCode] else { return nil }
        let isActive: Bool
        switch flag {
        case .maskCommand: isActive = event.modifierFlags.contains(.command)
        case .maskShift: isActive = event.modifierFlags.contains(.shift)
        case .maskAlternate: isActive = event.modifierFlags.contains(.option)
        case .maskControl: isActive = event.modifierFlags.contains(.control)
        default: isActive = event.modifierFlags.contains(.function)
        }
        guard isActive else { return nil }
        self.init(event.keyCode, flag, title)
    }

    private static let functionKeys: Set<UInt16> = [
        64, 79, 80, 90, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120, 122,
        115, 116, 117, 119, 121, 123, 124, 125, 126
    ]
}

/// Explicit modifier-only outputs. Modifier keys arrive through
/// `flagsChanged`, so keeping these as predefined values also gives the
/// editor a reliable path when macOS does not expose a standalone key press
/// to the recorder.
enum ModifierShortcutOption: String, CaseIterable, Identifiable {
    case choose
    case leftShift
    case rightShift
    case leftControl
    case rightControl
    case leftOption
    case rightOption
    case leftCommand
    case rightCommand
    case function
    case current

    var id: Self { self }

    var title: String {
        switch self {
        case .choose: return "选择修饰键"
        case .leftShift: return "左 Shift"
        case .rightShift: return "右 Shift"
        case .leftControl: return "左 Control"
        case .rightControl: return "右 Control"
        case .leftOption: return "左 Option"
        case .rightOption: return "右 Option"
        case .leftCommand: return "左 Command"
        case .rightCommand: return "右 Command"
        case .function: return "Fn"
        case .current: return "当前快捷键"
        }
    }

    var shortcut: RecordedShortcut? {
        switch self {
        case .leftShift: return RecordedShortcut(56, .maskShift, "左 Shift")
        case .rightShift: return RecordedShortcut(60, .maskShift, "右 Shift")
        case .leftControl: return RecordedShortcut(59, .maskControl, "左 Control")
        case .rightControl: return RecordedShortcut(62, .maskControl, "右 Control")
        case .leftOption: return RecordedShortcut(58, .maskAlternate, "左 Option")
        case .rightOption: return RecordedShortcut(61, .maskAlternate, "右 Option")
        case .leftCommand: return RecordedShortcut(55, .maskCommand, "左 Command")
        case .rightCommand: return RecordedShortcut(54, .maskCommand, "右 Command")
        case .function: return RecordedShortcut(63, .maskSecondaryFn, "Fn")
        case .choose, .current: return nil
        }
    }
}

struct MappingBinding: Hashable, Codable {
    var action: MappingAction = .none
    var shortcut: RecordedShortcut?
    var appPath: String?
    var modifierID: String?
    var usesMicrophone = false
    var comboID: UUID?

    init(_ action: MappingAction = .none, modifierID: String? = nil) {
        self.action = action
        self.modifierID = modifierID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(MappingAction.self, forKey: .action)
        shortcut = try container.decodeIfPresent(RecordedShortcut.self, forKey: .shortcut)
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
        modifierID = try container.decodeIfPresent(String.self, forKey: .modifierID)
        usesMicrophone = try container.decodeIfPresent(Bool.self, forKey: .usesMicrophone) ?? false
        comboID = try container.decodeIfPresent(UUID.self, forKey: .comboID)
    }

    var title: String {
        switch action {
        case .shortcut: return shortcut?.title ?? "录入快捷键"
        case .openApp:
            return appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "选择应用"
        default: return action.displayTitle
        }
    }

    var isConfigured: Bool {
        switch action {
        case .none: return false
        case .shortcut: return shortcut != nil
        case .openApp: return appPath != nil
        case .runCombo: return comboID != nil
        default: return true
        }
    }
}

struct ButtonMapping: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let glyph: String
    var gestures: [GestureKind: MappingBinding]

    init(_ id: String, _ name: String, _ glyph: String, _ action: MappingAction = .none, modifier: String? = nil) {
        self.id = id
        self.name = name
        self.glyph = glyph
        gestures = [.tap: MappingBinding(action, modifierID: modifier)]
    }

    subscript(_ gesture: GestureKind) -> MappingBinding {
        get { gestures[gesture] ?? MappingBinding() }
        set { gestures[gesture] = newValue }
    }

    var tapDisplay: String { bindingTitle(.tap) }
    var doubleTapDisplay: String { bindingTitle(.doubleTap) }
    var holdDisplay: String { bindingTitle(.hold) }

    var isMotion: Bool { Self.motionIDs.contains(id) }
    var isTouchMotion: Bool { Self.touchMotionIDs.contains(id) }
    var isInstantGesture: Bool { Self.instantGestureIDs.contains(id) }
    var editableGestures: [GestureKind] {
        if id == "touchTap" { return [.tap, .doubleTap] }
        if isMotion || isInstantGesture { return [.tap] }
        return GestureKind.allCases
    }

    func gestureTitle(_ gesture: GestureKind) -> String {
        if id == "touchTap" { return gesture == .doubleTap ? "连续轻点两次" : "单次轻点" }
        if isMotion { return "移动时" }
        if isInstantGesture { return "触发时" }
        return gesture.rawValue
    }

    func actionTitle(_ action: MappingAction, for gesture: GestureKind = .tap) -> String {
        if id == "touchTap", gesture == .doubleTap, action == .none { return "沿用单次轻点" }
        if id == "touchDrag", action == .moveCursor { return "鼠标拖拽" }
        return action.displayTitle
    }

    func bindingTitle(_ gesture: GestureKind) -> String {
        let binding = self[gesture]
        return binding.action == .shortcut || binding.action == .openApp
            ? binding.title : actionTitle(binding.action, for: gesture)
    }

    static let motionIDs: Set<String> = touchMotionIDs.union(["leftStick", "rightStick"])
    private static let touchMotionIDs: Set<String> = ["touchMove", "touchScroll"]
    static let instantGestureIDs: Set<String> = [
        "touchTap", "touchSecondaryTap", "touchDrag", "touchSwipeLeft", "touchSwipeRight"
    ]
    static let touchPressIDs: Set<String> = ["touchpad", "touchPressRight", "touchPressTwoFinger"]
    static let physicalButtonIDs: Set<String> = [
        "cross", "circle", "square", "triangle", "dpadUp", "dpadRight", "dpadDown", "dpadLeft",
        "l1", "l2", "r1", "r2", "l3", "r3", "create", "options", "ps", "touchpad", "mute"
    ]

    static func restoring(_ saved: [ButtonMapping], to defaults: [ButtonMapping]) -> [ButtonMapping] {
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousPress = savedByID["touchpad"]
        let previousPressAction = previousPress?[.tap].action
        let previousPressUsedMouse = previousPressAction == .leftClick || previousPressAction == .rightClick
            || previousPressAction == .middleClick
        let previousPressHadGestures = previousPress?[.doubleTap].isConfigured == true
            || previousPress?[.hold].isConfigured == true

        return defaults.map { row in
            var restored = row
            if let previous = savedByID[row.id] {
                let legacyMicrophoneDefault = row.id == "mute" &&
                    previous[.tap] == MappingBinding() &&
                    previous[.doubleTap] == MappingBinding() &&
                    previous[.hold] == MappingBinding(.voice)
                if !legacyMicrophoneDefault { restored.gestures = previous.gestures }
                return restored
            }

            // Older profiles shared one physical click mapping across the pad
            // and used the finger movement mapping during a drag.
            switch row.id {
            case "touchPressRight":
                if let previousPress { restored.gestures = previousPress.gestures }
            case "touchPressTwoFinger":
                if previousPressUsedMouse, !previousPressHadGestures,
                   let previousTap = savedByID["touchSecondaryTap"] {
                    restored[.tap] = previousTap[.tap]
                } else if let previousPress, !previousPressUsedMouse || previousPressHadGestures {
                    restored.gestures = previousPress.gestures
                }
            case "touchDrag":
                if let previousMovement = savedByID["touchMove"] { restored[.tap] = previousMovement[.tap] }
            default:
                break
            }
            return restored
        }
    }

    static let defaults: [ButtonMapping] = {
        var rows = [
            ButtonMapping("leftStick", "左摇杆移动", "L", .moveCursor),
            ButtonMapping("rightStick", "右摇杆移动", "R", .scroll),
            ButtonMapping("l3", "左摇杆按下", "L3"),
            ButtonMapping("r3", "右摇杆按下", "R3"),
            ButtonMapping("dpadUp", "方向键上", "↑"),
            ButtonMapping("dpadRight", "方向键右", "→"),
            ButtonMapping("dpadDown", "方向键下", "↓"),
            ButtonMapping("dpadLeft", "方向键左", "←"),
            ButtonMapping("cross", "叉键", "×", .leftClick),
            ButtonMapping("circle", "圆键", "○", .rightClick),
            ButtonMapping("square", "方键", "□", .screenshot, modifier: "l1"),
            ButtonMapping("triangle", "三角键", "△", .commandPalette),
            ButtonMapping("l1", "L1 肩键", "L1"),
            ButtonMapping("l2", "L2 扳机", "L2", .sensitivityDown),
            ButtonMapping("r1", "R1 肩键", "R1", .terminal),
            ButtonMapping("r2", "R2 扳机", "R2", .sensitivityUp),
            ButtonMapping("create", "Create", "☰", .screenshot),
            ButtonMapping("options", "Options", "⋯", .shortcut),
            ButtonMapping("ps", "PS 键", "PS", .showLauncher),
            ButtonMapping("touchpad", "触控板左侧按压", "▭", .leftClick),
            ButtonMapping("mute", "麦克风键", "♪", .microphoneMuteToggle),
            ButtonMapping("touchMove", "触控板单指移动", "↗", .moveCursor),
            ButtonMapping("touchScroll", "触控板双指移动", "↕", .scroll),
            ButtonMapping("touchTap", "触控板单指轻点", "•", .leftClick),
            ButtonMapping("touchSecondaryTap", "触控板双指轻点", "••", .rightClick),
            ButtonMapping("touchPressRight", "触控板右侧按压", "▭", .leftClick),
            ButtonMapping("touchPressTwoFinger", "触控板双指按压", "••", .rightClick),
            ButtonMapping("touchDrag", "触控板按住拖拽", "↔", .moveCursor),
            ButtonMapping("touchSwipeLeft", "触控板双指按住左滑", "←", .switchSpaceRight),
            ButtonMapping("touchSwipeRight", "触控板双指按住右滑", "→", .switchSpaceLeft)
        ]
        for (id, title) in [("leftStick", "左摇杆"), ("rightStick", "右摇杆")] {
            for (direction, symbol, name) in [("Up", "↑", "上"), ("Right", "→", "右"), ("Down", "↓", "下"), ("Left", "←", "左")] {
                rows.append(ButtonMapping(id + direction, title + name, symbol))
            }
        }
        let shortcuts: [String: RecordedShortcut] = [
            "dpadUp": .init(126, [], "↑"), "dpadRight": .init(124, [], "→"),
            "dpadDown": .init(125, [], "↓"), "dpadLeft": .init(123, [], "←"),
            "options": .init(53, [], "Esc")
        ]
        for index in rows.indices {
            if rows[index].id == "l1" { rows[index][.hold] = MappingBinding(.precision) }
            if let shortcut = shortcuts[rows[index].id] {
                var binding = MappingBinding(.shortcut)
                binding.shortcut = shortcut
                rows[index][.tap] = binding
            }
        }
        return rows
    }()
}
