import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MappingEditorView: View {
    @EnvironmentObject private var store: ControllerStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var capture = MappingEditorCapture()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let row = store.selectedMapping {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(row.editableGestures) { gesture in
                            gestureCard(row, gesture,
                                        conflict: MappingConflicts(store.mappings)
                                            .reason(for: row.id, gesture: gesture))
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("未选择按键", systemImage: "gamecontroller")
            }
        }
        .frame(width: 620, height: editorHeight)
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
                store.selectedMappingID = id
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
        HStack(spacing: 12) {
            if let row = store.selectedMapping {
                Text(row.glyph)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.title3.weight(.semibold))
                    Text("按键动作").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(capture.target == .control ? "按下按键…" : "录入手柄键",
                   systemImage: "gamecontroller") {
                capture.toggle(.control)
            }
            .controlSize(.small)
            .disabled(!store.connected)
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var editorHeight: CGFloat {
        switch store.selectedMapping?.editableGestures.count {
        case 1: return 300
        case 2: return 370
        default: return 470
        }
    }

    private func gestureCard(_ row: ButtonMapping, _ gesture: GestureKind,
                             conflict: String?) -> some View {
        let binding = row[gesture]
        let availableModifiers = modifiers(for: row)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(row.gestureTitle(gesture))
                    .font(.headline)
                if let conflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help(conflict)
                        .accessibilityLabel(conflict)
                }
                Spacer()
                Picker("", selection: value(row.id, gesture, \.action)) {
                    ForEach(actions(for: row, gesture)) { action in
                        Text(shortTitle(row, action, gesture)).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            HStack(spacing: 8) {
                if !row.isMotion || row.isTouchMotion {
                    MappingOutputRecorder(binding: binding) { recorded in
                        guard let current = store.mapping(row.id)?[gesture] else { return }
                        store.updateBinding(recorded.applying(to: current), for: row.id, gesture: gesture)
                    }
                    .id("\(row.id)-\(gesture.id)")
                }

                if binding.action == .shortcut {
                    Picker("修饰键", selection: Binding(
                        get: { modifierShortcutOption(for: binding.shortcut) },
                        set: { option in
                            guard let shortcut = option.shortcut,
                                  var current = store.mapping(row.id)?[gesture] else { return }
                            current.shortcut = shortcut
                            store.updateBinding(current, for: row.id, gesture: gesture)
                        }
                    )) {
                        ForEach(ModifierShortcutOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .help("直接选择左右修饰键，避免录入 Shift 等独立按键失败")
                }

                switch binding.action {
                case .openApp:
                    Button(binding.appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                           ?? "选择应用") {
                        chooseApp(for: row.id, gesture)
                    }
                    .controlSize(.small)
                case .runCombo:
                    Picker("组合键", selection: value(row.id, gesture, \.comboID)) {
                        Text("选择组合键").tag(nil as UUID?)
                        ForEach(store.combos) { combo in
                            Text(combo.name).tag(Optional(combo.id))
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                default:
                    EmptyView()
                }

                if binding.action != .none, !availableModifiers.isEmpty {
                    Picker("同时按住", selection: value(row.id, gesture, \.modifierID)) {
                        Text("无修饰键").tag(nil as String?)
                        ForEach(availableModifiers) { modifier in
                            Text(modifier.id == "touchpad" ? "触控板" : modifier.name)
                                .tag(Optional(modifier.id))
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()

                    let target = MappingEditorCapture.Target.modifier(row.id, gesture)
                    Button {
                        capture.toggle(target)
                    } label: {
                        Image(systemName: capture.target == target ? "record.circle.fill" : "gamecontroller")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(!store.connected)
                    .help(capture.target == target ? "取消录入修饰键" : "按手柄录入修饰键")
                }
                Spacer(minLength: 0)
            }

            if [.shortcut, .commandPalette, .terminal].contains(binding.action) {
                Toggle("启用手柄麦克风", isOn: value(row.id, gesture, \.usesMicrophone))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            if binding.action == .leftHold {
                Text("按住移动，松开结束")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(conflict == nil ? Color.secondary.opacity(0.22) : Color.red.opacity(0.6), lineWidth: 1)
        }
    }

    private func shortTitle(_ row: ButtonMapping, _ action: MappingAction,
                            _ gesture: GestureKind) -> String {
        if row.id == "touchTap", gesture == .doubleTap, action == .none {
            return "沿用单击"
        }
        switch action {
        case .leftClick: return "左键"
        case .leftDoubleClick: return "左键双击"
        case .leftLongPress: return "左键长按"
        case .leftHold: return "左键按住"
        case .rightClick: return "右键"
        case .middleClick: return "中键"
        case .shortcut: return "键盘快捷键"
        case .openApp: return "打开应用"
        case .runCombo: return "组合键"
        case .showLauncher: return "快捷轮盘"
        case .voice: return "麦克风"
        case .voiceToggle, .microphoneMuteToggle: return "麦克风开关"
        case .switchSpaceLeft: return "左侧桌面"
        case .switchSpaceRight: return "右侧桌面"
        default: return action.displayTitle
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
            store.updateBinding(binding, for: id, gesture: gesture)
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
}
