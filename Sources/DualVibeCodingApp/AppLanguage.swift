import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case en

    var id: Self { self }

    @MainActor
    var label: String {
        switch self {
        case .system: return L("跟随系统", "Follow System")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

@MainActor
final class LocalizationStore: ObservableObject {
    static let shared = LocalizationStore()
    private static let key = "dualVibeLanguage"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.key)
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        language = AppLanguage(rawValue: raw) ?? .system
    }

    var isEnglish: Bool {
        switch language {
        case .en: return true
        case .zhHans: return false
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "zh"
            return !preferred.lowercased().hasPrefix("zh")
        }
    }
}

@MainActor
func L(_ zh: String, _ en: String) -> String {
    LocalizationStore.shared.isEnglish ? en : zh
}

// MARK: - Localized Model Display Helpers (preserves Codable rawValues intact)

@MainActor
extension MappingAction {
    var localizedTitle: String {
        switch self {
        case .none: return L("未设置", "None")
        case .moveCursor: return L("移动光标", "Move Cursor")
        case .scroll: return L("滚动页面", "Scroll Page")
        case .leftClick: return L("鼠标左键", "Left Click")
        case .leftDoubleClick: return L("鼠标左键双击", "Left Double-Click")
        case .leftLongPress: return L("鼠标左键长按", "Left Long Press")
        case .leftHold: return L("按住鼠标左键", "Hold Left Button")
        case .rightClick: return L("鼠标右键", "Right Click")
        case .middleClick: return L("鼠标中键", "Middle Click")
        case .shortcut: return L("键盘快捷键", "Keyboard Shortcut")
        case .openApp: return L("打开应用", "Open App")
        case .screenshot: return L("区域截图", "Area Screenshot")
        case .commandPalette: return L("命令面板", "Command Palette")
        case .terminal: return L("切换终端", "Toggle Terminal")
        case .switchSpaceLeft: return L("切换到左侧桌面", "Switch to Left Space")
        case .switchSpaceRight: return L("切换到右侧桌面", "Switch to Right Space")
        case .sensitivityDown: return L("降低灵敏度", "Decrease Sensitivity")
        case .sensitivityUp: return L("提高灵敏度", "Increase Sensitivity")
        case .precision: return L("按住精确移动", "Hold for Precision")
        case .voice: return L("按住使用手柄麦克风", "Hold for Controller Mic")
        case .voiceToggle: return L("开启或关闭手柄麦克风", "Toggle Controller Mic")
        case .microphoneMuteToggle: return L("切换手柄麦克风静音", "Toggle Mic Mute")
        case .runCombo: return L("运行组合键动作", "Run Combo")
        case .showLauncher: return L("打开／关闭快捷轮盘", "Toggle Quick Wheel")
        }
    }
}

@MainActor
extension GestureKind {
    var localizedTitle: String {
        switch self {
        case .tap: return L("单击", "Tap")
        case .doubleTap: return L("双击", "Double-Tap")
        case .hold: return L("长按", "Hold")
        }
    }
}

@MainActor
extension ModifierShortcutOption {
    var localizedTitle: String {
        switch self {
        case .choose: return L("选择修饰键", "Choose Modifier")
        case .leftShift: return L("左 Shift", "Left Shift")
        case .rightShift: return L("右 Shift", "Right Shift")
        case .leftControl: return L("左 Control", "Left Control")
        case .rightControl: return L("右 Control", "Right Control")
        case .leftOption: return L("左 Option", "Left Option")
        case .rightOption: return L("右 Option", "Right Option")
        case .leftCommand: return L("左 Command", "Left Command")
        case .rightCommand: return L("右 Command", "Right Command")
        case .function: return "Fn"
        case .current: return L("当前快捷键", "Current Shortcut")
        }
    }
}

@MainActor
extension MappingBinding {
    var localizedTitle: String {
        switch action {
        case .shortcut: return shortcut?.title ?? L("录入快捷键", "Record Shortcut")
        case .openApp:
            return appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? L("选择应用", "Choose App")
        default: return action.localizedTitle
        }
    }
}

@MainActor
extension ButtonMapping {
    var localizedName: String {
        guard LocalizationStore.shared.isEnglish else { return name }
        switch id {
        case "leftStick": return "Left Stick Move"
        case "rightStick": return "Right Stick Move"
        case "l3": return "Left Stick Press (L3)"
        case "r3": return "Right Stick Press (R3)"
        case "leftStickUp": return "Left Stick Up"
        case "leftStickRight": return "Left Stick Right"
        case "leftStickDown": return "Left Stick Down"
        case "leftStickLeft": return "Left Stick Left"
        case "rightStickUp": return "Right Stick Up"
        case "rightStickRight": return "Right Stick Right"
        case "rightStickDown": return "Right Stick Down"
        case "rightStickLeft": return "Right Stick Left"
        case "dpadUp": return "D-Pad Up"
        case "dpadRight": return "D-Pad Right"
        case "dpadDown": return "D-Pad Down"
        case "dpadLeft": return "D-Pad Left"
        case "cross": return "Cross (×)"
        case "circle": return "Circle (○)"
        case "square": return "Square (□)"
        case "triangle": return "Triangle (△)"
        case "l1": return "L1 Bumper"
        case "l2": return "L2 Trigger"
        case "r1": return "R1 Bumper"
        case "r2": return "R2 Trigger"
        case "create": return "Create"
        case "options": return "Options"
        case "ps": return "PS Button"
        case "mute": return "Mic Mute Button"
        case "touchpad": return "Touchpad Left Press"
        case "touchPressRight": return "Touchpad Right Press"
        case "touchPressTwoFinger": return "Touchpad Two-Finger Press"
        case "touchMove": return "Touchpad 1-Finger Move"
        case "touchScroll": return "Touchpad 2-Finger Scroll"
        case "touchTap": return "Touchpad 1-Finger Tap"
        case "touchSecondaryTap": return "Touchpad 2-Finger Tap"
        case "touchDrag": return "Touchpad Press & Drag"
        case "touchSwipeLeft": return "Touchpad 2-Finger Swipe Left"
        case "touchSwipeRight": return "Touchpad 2-Finger Swipe Right"
        default: return name
        }
    }

    var localizedShortTouchName: String {
        guard LocalizationStore.shared.isEnglish else {
            return name.hasPrefix("触控板") ? String(name.dropFirst("触控板".count)) : name
        }
        let full = localizedName
        return full.hasPrefix("Touchpad ") ? String(full.dropFirst("Touchpad ".count)) : full
    }

    func localizedGestureTitle(_ gesture: GestureKind) -> String {
        if id == "touchTap" {
            return gesture == .doubleTap ? L("连续轻点两次", "Double Tap") : L("单次轻点", "Single Tap")
        }
        if isMotion { return L("移动时", "On Move") }
        if isInstantGesture { return L("触发时", "On Trigger") }
        return gesture.localizedTitle
    }

    func localizedActionTitle(_ action: MappingAction, for gesture: GestureKind = .tap) -> String {
        if id == "touchTap", gesture == .doubleTap, action == .none { return L("沿用单次轻点", "Same as Tap") }
        if id == "touchDrag", action == .moveCursor { return L("鼠标拖拽", "Mouse Drag") }
        return action.localizedTitle
    }

    func localizedBindingTitle(_ gesture: GestureKind) -> String {
        let binding = self[gesture]
        return binding.action == .shortcut || binding.action == .openApp
            ? binding.localizedTitle : localizedActionTitle(binding.action, for: gesture)
    }
}

@MainActor
extension WheelPosition {
    var localizedTitle: String {
        self == .screenCenter ? L("当前屏幕中心", "Screen Center") : L("鼠标附近", "Near Pointer")
    }
}

@MainActor
extension WheelSlot {
    var localizedDirectionName: String {
        let names = LocalizationStore.shared.isEnglish
            ? ["Up", "Up-Right", "Right", "Down-Right", "Down", "Down-Left", "Left", "Up-Left"]
            : ["上", "右上", "右", "右下", "下", "左下", "左", "左上"]
        return names.indices.contains(id) ? names[id] : L("方向", "Direction")
    }

    func localizedDisplayTitle(applications: [LauncherApplication], combos: [ControllerCombo]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch payload {
        case .empty:
            return L("未设置", "Empty")
        case .application(let bundleID):
            return applications.first { $0.id == bundleID }?.name ?? L("应用", "App")
        case .mapping(let mapping):
            if mapping.action == .runCombo {
                return combos.first { $0.id == mapping.comboID }?.name ?? L("组合键", "Combo")
            }
            return mapping.localizedTitle
        }
    }

    func localizedUnavailableReason(applications: [LauncherApplication], combos: [ControllerCombo]) -> String? {
        guard let zh = unavailableReason(applications: applications, combos: combos) else { return nil }
        guard LocalizationStore.shared.isEnglish else { return zh }
        switch zh {
        case "未设置": return "Not configured"
        case "请选择应用": return "Choose an app"
        case "应用已从启动台移除": return "App was removed from Library"
        case "找不到此应用": return "App not found on disk"
        case "请选择组合键": return "Choose a combo"
        case "动作未设置完整": return "Action is incomplete"
        case "当前配置中没有此组合键": return "Combo not found in active profile"
        case "该组合键会再次打开启动台": return "This combo re-opens the Quick Wheel"
        default: return zh
        }
    }
}

@MainActor
extension ControllerDevice.Transport {
    var localizedTitle: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .usb: return "USB"
        case .system: return L("系统连接", "System")
        }
    }
}

@MainActor
func localizedMicrophoneStatus(_ raw: String) -> String {
    guard LocalizationStore.shared.isEnglish else { return raw }
    if raw.isEmpty { return "Detecting…" }
    let exact: [String: String] = [
        "系统语音输入已静音": "System voice input muted",
        "系统语音输入已启用": "System voice input active",
        "正在测试麦克风": "Testing microphone",
        "等待连接麦克风": "Waiting for microphone",
        "未找到可用麦克风": "No microphone found",
        "已就绪": "Ready",
        "已静音": "Muted"
    ]
    if let mapped = exact[raw] { return mapped }
    if raw.contains("静音") { return "Muted" }
    if raw.contains("已启用") || raw.contains("使用中") { return "Voice input active" }
    if raw.contains("测试") { return "Testing microphone" }
    if raw.contains("等待") || raw.contains("未") { return "Standby" }
    return raw
}
