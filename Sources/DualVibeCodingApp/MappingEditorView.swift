import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MappingEditorView: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var i18n: LocalizationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var capture = MappingEditorCapture()

    var body: some View {
        let _ = i18n.language
        VStack(spacing: 0) {
            header
            Divider()
            if let row = store.selectedMapping {
                let conflicts = MappingConflicts(store.mappings)
                Form {
                    ForEach(row.editableGestures) { gesture in
                        gestureSection(row, gesture, conflict: conflicts.reason(for: row.id, gesture: gesture))
                    }
                }
                .formStyle(.grouped)
                .scrollBounceBehavior(.basedOnSize)
                .id(row.id)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity
                ))
            } else {
                ContentUnavailableView(
                    L("未选择按键", "No Control Selected"),
                    systemImage: "gamecontroller",
                    description: Text(L("请从映射面板或手柄上选择一个按键。", "Select a button from the mapping board or press one on the controller."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: preferredHeight)
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: store.selectedMappingID)
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: preferredHeight)
        .animation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion), value: capture.target)
        .onAppear { store.isEditingMapping = true }
        .onDisappear {
            capture.target = nil
            store.isEditingMapping = false
        }
        .onChange(of: store.physicalInput) { _, frame in
            guard NSApp.isActive, let target = capture.target,
                  let id = frame?.newlyPressed.last else { return }
            switch target {
            case .control:
                guard store.mapping(id) != nil else { return }
                withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                    store.selectedMappingID = id
                }
            case let .modifier(rowID, gesture):
                let modifier = ControllerCombo.control(for: id)
                guard let row = store.mapping(rowID),
                      modifiers(for: row).contains(where: { $0.id == modifier }) else { return }
                value(rowID, gesture, \.modifierID).wrappedValue = modifier
            }
            capture.target = nil
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let row = store.selectedMapping {
                DualVibeControlIcon(mappingID: row.id, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.localizedName)
                        .font(.title3.weight(.semibold))
                        .contentTransition(.numericText())
                    Text(subtitle(for: row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("编辑按键映射", "Edit Button Mapping")).font(.title3.weight(.semibold))
                    Text(L("按键动作", "Button Action")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                capture.toggle(.control)
            } label: {
                Label(
                    capture.target == .control ? L("按下手柄按键…", "Press Button…") : L("切换手柄键", "Capture Button"),
                    systemImage: capture.target == .control ? "gamecontroller.fill" : "gamecontroller"
                )
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .tint(capture.target == .control ? DualVibePalette.lightBar(for: colorScheme) : nil)
            .controlSize(.regular)
            .disabled(!store.connected)
            .help(capture.target == .control
                  ? L("取消等待按键", "Cancel capture")
                  : L("直接按下实体手柄上的任意按键以切换编辑对象", "Press any physical button on DualSense to edit it"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let row = store.selectedMapping {
                let hasAnyConfigured = row.editableGestures.contains { row[$0].isConfigured }
                Button(L("清除动作", "Clear Actions"), role: .destructive) {
                    withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                        for gesture in row.editableGestures {
                            store.updateBinding(MappingBinding(.none), for: row.id, gesture: gesture)
                        }
                    }
                }
                .disabled(!hasAnyConfigured)
                .help(L("清除当前按键的所有手势映射", "Clear all gestures on this control"))
            }
            Spacer()
            Button(L("完成", "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func gestureSection(_ row: ButtonMapping, _ gesture: GestureKind,
                                conflict: String?) -> some View {
        let binding = row[gesture]
        let availableModifiers = modifiers(for: row)
        let modifierTarget = MappingEditorCapture.Target.modifier(row.id, gesture)
        let isCapturingModifier = capture.target == modifierTarget

        return Section {
            Picker(L("执行动作", "Action"), selection: value(row.id, gesture, \.action)) {
                ForEach(actions(for: row, gesture)) { action in
                    Text(shortTitle(row, action, gesture)).tag(action)
                }
            }
            .pickerStyle(.menu)

            if !row.isMotion || row.isTouchMotion {
                LabeledContent(L("快速录入", "Quick Record")) {
                    MappingOutputRecorder(binding: binding) { recorded in
                        guard let current = store.mapping(row.id)?[gesture] else { return }
                        store.updateBinding(recorded.applying(to: current), for: row.id, gesture: gesture)
                    }
                    .id("\(row.id)-\(gesture.id)")
                }
            }

            if binding.action == .shortcut {
                Picker(L("独立修饰键", "Standalone Modifier"), selection: Binding(
                    get: { modifierShortcutOption(for: binding.shortcut) },
                    set: { option in
                        guard let shortcut = option.shortcut,
                              var current = store.mapping(row.id)?[gesture] else { return }
                        current.shortcut = shortcut
                        store.updateBinding(current, for: row.id, gesture: gesture)
                    }
                )) {
                    ForEach(ModifierShortcutOption.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .help(L("直接选择左右 Shift / Control / Option / Command / Fn，避免录入独立修饰键失败",
                        "Pick a standalone Left/Right Shift, Control, Option, Command, or Fn key"))
            }

            if binding.action == .openApp {
                LabeledContent(L("目标应用", "Target App")) {
                    HStack(spacing: 8) {
                        if let path = binding.appPath, FileManager.default.fileExists(atPath: path) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                                .accessibilityHidden(true)
                            Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Button(binding.appPath == nil ? L("选择应用…", "Choose App…") : L("更改…", "Change…")) {
                            chooseApp(for: row.id, gesture)
                        }
                    }
                }
            }

            if binding.action == .runCombo {
                Picker(L("目标组合键", "Target Combo"), selection: value(row.id, gesture, \.comboID)) {
                    Text(L("选择组合键", "Choose Combo")).tag(nil as UUID?)
                    ForEach(store.combos) { combo in
                        Text(combo.name).tag(Optional(combo.id))
                    }
                }
            }

            if binding.action != .none, !availableModifiers.isEmpty {
                LabeledContent(L("同时按住", "Hold Modifier")) {
                    HStack(spacing: 8) {
                        Picker(L("同时按住", "Hold Modifier"), selection: value(row.id, gesture, \.modifierID)) {
                            Text(L("无修饰键", "None")).tag(nil as String?)
                            ForEach(availableModifiers) { modifier in
                                Text(modifier.id == "touchpad" ? L("触控板", "Touchpad") : modifier.localizedName)
                                    .tag(Optional(modifier.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()

                        Button {
                            capture.toggle(modifierTarget)
                        } label: {
                            Label(isCapturingModifier ? L("等待按键…", "Waiting…") : L("录入", "Capture"),
                                  systemImage: isCapturingModifier ? "gamecontroller.fill" : "gamecontroller")
                                .labelStyle(.iconOnly)
                                .frame(width: 20)
                        }
                        .buttonStyle(.bordered)
                        .tint(isCapturingModifier ? DualVibePalette.lightBar(for: colorScheme) : nil)
                        .disabled(!store.connected)
                        .help(isCapturingModifier ? L("取消录入修饰键", "Cancel capture") : L("按下手柄键将其设为修饰键", "Press a controller button to assign as modifier"))
                    }
                }
            }

            if [.shortcut, .commandPalette, .terminal].contains(binding.action) {
                Toggle(L("执行前启用手柄麦克风", "Enable Controller Mic First"), isOn: value(row.id, gesture, \.usesMicrophone))
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: gestureSymbol(row, gesture))
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text(row.localizedGestureTitle(gesture))
                Spacer()
                if let conflict {
                    DualVibeStatusBadge(text: L("冲突", "Conflict"), systemImage: "exclamationmark.triangle.fill", tone: .critical)
                        .help(conflict)
                } else if binding.isConfigured {
                    Text(store.localizedTitle(for: row, gesture: gesture))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if let conflict {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if binding.action == .leftHold {
                Text(L("按住按键并移动光标即可拖拽，松开后自动结束。", "Hold to drag while moving the pointer; release to end."))
            }
        }
    }

    private var preferredHeight: CGFloat {
        guard let row = store.selectedMapping else { return 300 }
        let headerAndFooter: CGFloat = 128
        let availableModifiersCount = modifiers(for: row).count
        var content: CGFloat = 24
        for gesture in row.editableGestures {
            let binding = row[gesture]
            var rows = 1
            if !row.isMotion || row.isTouchMotion { rows += 1 }
            if binding.action == .shortcut { rows += 1 }
            if binding.action == .openApp { rows += 1 }
            if binding.action == .runCombo { rows += 1 }
            if binding.action != .none, availableModifiersCount > 0 { rows += 1 }
            if [.shortcut, .commandPalette, .terminal].contains(binding.action) { rows += 1 }
            content += 42 + CGFloat(rows) * 40
            if binding.action == .leftHold { content += 22 }
        }
        return min(620, max(280, headerAndFooter + content))
    }

    private func subtitle(for row: ButtonMapping) -> String {
        if row.isMotion { return L("连续模拟输入动作", "Continuous analog control") }
        if row.isInstantGesture { return L("即时触控手势动作", "Instant touchpad gesture") }
        if row.editableGestures.count == 2 { return L("支持单次与连续轻点", "Supports single and double tap") }
        return L("支持单击、双击与长按手势", "Supports tap, double-tap, and hold")
    }

    private func gestureSymbol(_ row: ButtonMapping, _ gesture: GestureKind) -> String {
        if row.isMotion { return "move.3d" }
        if row.isInstantGesture { return "hand.point.up.left" }
        switch gesture {
        case .tap: return "hand.tap"
        case .doubleTap: return "hand.tap.fill"
        case .hold: return "timer"
        }
    }

    private func shortTitle(_ row: ButtonMapping, _ action: MappingAction,
                            _ gesture: GestureKind) -> String {
        if row.id == "touchTap", gesture == .doubleTap, action == .none {
            return L("沿用单击", "Same as Tap")
        }
        switch action {
        case .leftClick: return L("左键", "Left Click")
        case .leftDoubleClick: return L("左键双击", "Left Double-Click")
        case .leftLongPress: return L("左键长按", "Left Long Press")
        case .leftHold: return L("左键按住", "Hold Left Button")
        case .rightClick: return L("右键", "Right Click")
        case .middleClick: return L("中键", "Middle Click")
        case .shortcut: return L("键盘快捷键", "Keyboard Shortcut")
        case .openApp: return L("打开应用", "Open App")
        case .runCombo: return L("组合键", "Combo")
        case .showLauncher: return L("快捷轮盘", "Quick Wheel")
        case .voice: return L("麦克风", "Hold Mic")
        case .voiceToggle, .microphoneMuteToggle: return L("麦克风开关", "Toggle Mic")
        case .switchSpaceLeft: return L("左侧桌面", "Left Space")
        case .switchSpaceRight: return L("右侧桌面", "Right Space")
        default: return action.localizedTitle
        }
    }

    private func modifierShortcutOption(for shortcut: RecordedShortcut?) -> ModifierShortcutOption {
        guard let shortcut else { return .choose }
        return ModifierShortcutOption.allCases.first { $0.shortcut == shortcut } ?? .current
    }

    private func modifiers(for row: ButtonMapping) -> [ButtonMapping] {
        store.mappings.filter { modifier in
            modifier.id != row.id && ButtonMapping.physicalButtonIDs.contains(modifier.id)
                && (modifier.id != "touchpad" || !ButtonMapping.touchPressIDs.contains(row.id))
        }
    }

    private func actions(for row: ButtonMapping, _ gesture: GestureKind) -> [MappingAction] {
        if row.isTouchMotion || row.id == "touchDrag" {
            return MappingAction.allCases.filter { !$0.followsPress }
        }
        if row.isMotion { return [.none, .moveCursor, .scroll] }
        return MappingAction.allCases.filter {
            !$0.isContinuous && (!$0.followsPress || (!row.isInstantGesture && gesture == .hold))
        }
    }

    private func value<T>(_ id: String, _ gesture: GestureKind,
                          _ keyPath: WritableKeyPath<MappingBinding, T>) -> Binding<T> {
        Binding {
            (store.mapping(id)?[gesture] ?? MappingBinding())[keyPath: keyPath]
        } set: { newValue in
            guard var binding = store.mapping(id)?[gesture] else { return }
            binding[keyPath: keyPath] = newValue
            withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                store.updateBinding(binding, for: id, gesture: gesture)
            }
        }
    }

    private func chooseApp(for id: String, _ gesture: GestureKind) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            value(id, gesture, \.appPath).wrappedValue = url.path
        }
    }
}

@MainActor
private final class MappingEditorCapture: ObservableObject {
    enum Target: Equatable {
        case control
        case modifier(String, GestureKind)
    }

    @Published var target: Target?

    func toggle(_ next: Target) {
        target = target == next ? nil : next
    }
}

extension ControllerStore {
    func title(for mapping: ButtonMapping, gesture: GestureKind) -> String {
        let binding = mapping[gesture]
        return binding.action == .runCombo ? title(for: binding) : mapping.bindingTitle(gesture)
    }

    @MainActor
    func localizedTitle(for mapping: ButtonMapping, gesture: GestureKind) -> String {
        let binding = mapping[gesture]
        if binding.action == .runCombo {
            return combos.first { $0.id == binding.comboID }?.name ?? L("选择组合键", "Choose Combo")
        }
        return mapping.localizedBindingTitle(gesture)
    }

    @MainActor
    func localizedTitle(for binding: MappingBinding) -> String {
        if binding.action == .runCombo {
            return combos.first { $0.id == binding.comboID }?.name ?? L("选择组合键", "Choose Combo")
        }
        return binding.localizedTitle
    }
}
