import AppKit
import Combine

enum WheelPosition: String, Codable, CaseIterable, Identifiable {
    case screenCenter
    case pointer

    var id: Self { self }
    var title: String { self == .screenCenter ? "当前屏幕中心" : "鼠标附近" }
}

enum WheelSlotPayload: Codable, Equatable {
    case empty
    case application(bundleID: String)
    case mapping(MappingBinding)
}

struct WheelSlot: Codable, Equatable, Identifiable {
    static let count = 8
    private static let directions = ["上", "右上", "右", "右下", "下", "左下", "左", "左上"]
    private static let arrows = ["arrow.up", "arrow.up.right", "arrow.right", "arrow.down.right",
                                 "arrow.down", "arrow.down.left", "arrow.left", "arrow.up.left"]

    let id: Int
    var name: String = ""
    var payload: WheelSlotPayload = .empty

    var directionName: String { Self.directions.indices.contains(id) ? Self.directions[id] : "方向" }
    var directionSymbol: String { Self.arrows.indices.contains(id) ? Self.arrows[id] : "questionmark" }

    static let allowedActions = MappingAction.comboOutputActions.filter {
        $0 != .showLauncher && $0 != .openApp
    }

    /// A slot executes one action. Its direction is the trigger, so no
    /// controller modifier or previously recorded combo input is carried over.
    var binding: MappingBinding? {
        guard case var .mapping(binding) = payload else { return nil }
        guard Self.allowedActions.contains(binding.action) || binding.action == .runCombo,
              binding.isConfigured else { return nil }
        binding.modifierID = nil
        return binding
    }

    func displayTitle(applications: [LauncherApplication], combos: [ControllerCombo]) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        switch payload {
        case .empty:
            return "未设置"
        case .application(let bundleID):
            return applications.first { $0.id == bundleID }?.name ?? "应用"
        case .mapping(let mapping):
            if mapping.action == .runCombo { return combo(matching: mapping, in: combos)?.name ?? "组合键" }
            return mapping.title
        }
    }

    func unavailableReason(applications: [LauncherApplication], combos: [ControllerCombo]) -> String? {
        switch payload {
        case .empty:
            return "未设置"
        case .application(let bundleID):
            if bundleID.isEmpty { return "请选择应用" }
            guard let application = applications.first(where: { $0.id == bundleID }) else {
                return "应用已从启动台移除"
            }
            return application.installedURL == nil ? "找不到此应用" : nil
        case .mapping:
            guard let binding else {
                if case .mapping(let draft) = payload, draft.action == .runCombo { return "请选择组合键" }
                return "动作未设置完整"
            }
            if binding.action == .runCombo {
                guard let combo = combo(matching: binding, in: combos), combo.actionIsValid else {
                    return "当前配置中没有此组合键"
                }
                if combo.binding.action == .showLauncher { return "该组合键会再次打开启动台" }
            }
            return nil
        }
    }

    var symbolName: String {
        switch payload {
        case .empty: return "plus"
        case .application: return "app"
        case .mapping(let binding):
            switch binding.action {
            case .runCombo: return "command"
            case .shortcut: return "keyboard"
            case .leftClick, .leftDoubleClick, .leftLongPress, .rightClick, .middleClick: return "computermouse"
            case .screenshot: return "viewfinder"
            case .terminal: return "terminal"
            case .switchSpaceLeft: return "rectangle.lefthalf.inset.filled"
            case .switchSpaceRight: return "rectangle.righthalf.inset.filled"
            case .voiceToggle, .microphoneMuteToggle: return "mic"
            case .commandPalette: return "command.square"
            default: return "bolt"
            }
        }
    }

    private func combo(matching binding: MappingBinding, in combos: [ControllerCombo]) -> ControllerCombo? {
        combos.first { $0.id == binding.comboID }
    }
}

@MainActor
final class LauncherWheelStore: ObservableObject {
    private static let key = "dualVibeLauncherWheel"

    @Published private(set) var slots: [WheelSlot]
    @Published private(set) var position: WheelPosition

    private let defaults: UserDefaults
    private var hasSeededSlots: Bool

    private struct SavedWheel: Codable {
        let position: WheelPosition
        let slots: [WheelSlot]
        let hasSeededSlots: Bool?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(SavedWheel.self, from: $0) }
        let byID = Dictionary((saved?.slots ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        slots = (0..<WheelSlot.count).map { byID[$0] ?? WheelSlot(id: $0) }
        position = saved?.position ?? .screenCenter
        hasSeededSlots = saved?.hasSeededSlots ?? (saved != nil)
    }

    func update(_ slot: WheelSlot) {
        updateSlots([slot])
    }

    func updateSlots(_ changes: [WheelSlot], position: WheelPosition? = nil) {
        var next = slots
        for slot in changes where next.indices.contains(slot.id) {
            next[slot.id] = slot
        }
        let nextPosition = position ?? self.position
        guard next != slots || nextPosition != self.position else { return }
        if next != slots {
            hasSeededSlots = true
            slots = next
        }
        if nextPosition != self.position { self.position = nextPosition }
        persist()
    }

    func clear(_ id: Int) { update(WheelSlot(id: id)) }

    func seedAppsIfNeeded(_ applications: [LauncherApplication]) {
        guard !hasSeededSlots, !applications.isEmpty else { return }
        hasSeededSlots = true
        for (index, application) in applications.prefix(WheelSlot.count).enumerated() {
            slots[index] = WheelSlot(id: index, payload: .application(bundleID: application.id))
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(SavedWheel(position: position, slots: slots, hasSeededSlots: hasSeededSlots)) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
