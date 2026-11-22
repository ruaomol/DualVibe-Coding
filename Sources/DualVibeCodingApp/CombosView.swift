import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CombosView: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var i18n: LocalizationStore
    @StateObject private var state = CombosPageState()
    @Binding var showMappingEditor: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var buttonMappings: [ButtonMapping] {
        store.mappings.filter { row in
            row.editableGestures.contains { row[$0].isConfigured && row[$0].modifierID != nil }
        }
    }

    private var hasAnyCombos: Bool {
        !store.combos.isEmpty || !buttonMappings.isEmpty
    }

    var body: some View {
        let _ = i18n.language
        Group {
            if !hasAnyCombos {
                ContentUnavailableView {
                    Label(L("还没有组合键", "No Combos Yet"), systemImage: "command.square")
                } description: {
                    Text(L("将两颗手柄按键组合成快捷操作，例如按住 L1 再按方键执行截图、快捷键或打开应用。",
                           "Combine two controller buttons into one shortcut — for example, hold L1 and press Square to capture a screenshot or open an app."))
                } actions: {
                    Button {
                        createNewCombo()
                    } label: {
                        Label(L("新建组合键", "New Combo"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                Form {
                    Section {
                        if store.combos.isEmpty {
                            HStack(spacing: 12) {
                                Image(systemName: "command.square")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("还没有自定义组合键", "No Custom Combos Yet"))
                                        .font(.body.weight(.medium))
                                    Text(L("点击右上角「新建组合键」创建可复用的双键触发动作。",
                                           "Click “New Combo” in the toolbar to create a reusable two-button trigger."))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L("新建组合键", "New Combo")) { createNewCombo() }
                                    .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        } else {
                            ForEach(store.combos) { combo in
                                customRow(combo)
                            }
                        }
                    } header: {
                        Text(L("自定义组合键", "Custom Combos"))
                    } footer: {
                        if !store.combos.isEmpty {
                            Text(L("自定义组合键可在按键映射与快捷轮盘中复用。",
                                   "Custom combos can be reused in both Mappings and the Quick Wheel."))
                        }
                    }

                    if !buttonMappings.isEmpty {
                        let conflicts = MappingConflicts(store.mappings)
                        Section {
                            ForEach(buttonMappings) { row in
                                ForEach(row.editableGestures) { gesture in
                                    if let modifier = row[gesture].modifierID, row[gesture].isConfigured {
                                        existingRow(row, gesture: gesture, modifier: modifier, conflicts: conflicts)
                                    }
                                }
                            }
                        } header: {
                            Text(L("按键映射中的组合", "Modifier Chords in Mappings"))
                        } footer: {
                            Text(L("这些组合在「按键映射」中通过「同时按住」修饰键配置，点击可直接编辑。",
                                   "Configured via Hold Modifier in Mappings. Click Edit to modify."))
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(L("组合键", "Combos"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createNewCombo()
                } label: {
                    Label(L("新建组合键", "New Combo"), systemImage: "plus")
                }
                .help(L("新建自定义手柄组合键", "Create a new custom controller combo"))
            }
        }
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: store.combos)
        .sheet(item: $state.editing) { combo in
            ComboEditorView(combo: combo, isExisting: store.combos.contains { $0.id == combo.id })
        }
        .confirmationDialog(L("删除组合键？", "Delete Combo?"), isPresented: $state.showsRemoval, titleVisibility: .visible,
                            presenting: state.removing) { combo in
            Button(L("删除「\(combo.name)」", "Delete “\(combo.name)”"), role: .destructive) {
                withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                    store.removeCombo(id: combo.id)
                }
            }
        } message: { combo in
            if store.mappings.contains(where: { mapping in
                mapping.editableGestures.contains { mapping[$0].comboID == combo.id }
            }) {
                Text(L("引用此组合键的按键动作也会清除。", "Button actions referencing this combo will also be cleared."))
            }
        }
    }

    private func createNewCombo() {
        state.editing = ControllerCombo(name: "", modifierID: "", triggerID: "",
                                        gesture: .tap, binding: .init(.shortcut))
    }

    private func customRow(_ combo: ControllerCombo) -> some View {
        let conflict = store.comboConflict(combo)
        let accent = DualVibePalette.lightBar(for: colorScheme)
        return HStack(spacing: 12) {
            DualVibeIconBadge(
                systemImage: conflict == nil ? "command" : "exclamationmark.triangle.fill",
                tint: conflict == nil ? accent : .red,
                size: 30,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(combo.name)
                    .font(.body.weight(.semibold))
                HStack(spacing: 5) {
                    DualVibeKeycap(text: buttonName(combo.modifierID))
                    Text("+")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    DualVibeKeycap(text: store.mapping(combo.triggerID)?.localizedName ?? L("不可用按键", "Unavailable"))
                    Text("· \(combo.gesture.localizedTitle)")
                        .font(.caption)
                        .foregroundStyle(conflict == nil ? Color.secondary : Color.red)
                }
            }
            .help(conflict ?? "")
            .accessibilityHint(conflict ?? "")

            Spacer(minLength: 10)

            if let conflict {
                DualVibeStatusBadge(text: L("冲突", "Conflict"), systemImage: "exclamationmark.triangle.fill", tone: .critical)
                    .help(conflict)
            } else {
                DualVibeKeycap(text: combo.binding.localizedTitle, prominent: combo.binding.action == .shortcut)
            }

            Button(L("编辑…", "Edit…")) { state.editing = combo }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button(role: .destructive) {
                state.removing = combo
                state.showsRemoval = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L("删除「\(combo.name)」", "Delete “\(combo.name)”"))
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(L("编辑…", "Edit…"), systemImage: "pencil") { state.editing = combo }
            Divider()
            Button(L("删除", "Delete"), systemImage: "trash", role: .destructive) {
                state.removing = combo
                state.showsRemoval = true
            }
        }
    }

    private func existingRow(_ row: ButtonMapping, gesture: GestureKind, modifier: String,
                             conflicts: MappingConflicts) -> some View {
        let conflict = conflicts.reason(for: row.id, gesture: gesture)
        let title = store.localizedTitle(for: row[gesture])
        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                DualVibeKeycap(text: buttonName(modifier))
                Text("+")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                DualVibeKeycap(text: row.localizedName)
                Text("· \(row.localizedGestureTitle(gesture))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if conflict != nil {
                DualVibeStatusBadge(text: title, systemImage: "exclamationmark.triangle.fill", tone: .critical)
            } else {
                DualVibeKeycap(text: title, prominent: row[gesture].action == .shortcut)
            }

            Button(L("编辑…", "Edit…")) {
                store.selectedMappingID = row.id
                showMappingEditor = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint(conflict ?? "")
            .help(conflict ?? title)
        }
        .padding(.vertical, 2)
    }

    private func buttonName(_ id: String) -> String {
        id == "touchpad" ? L("触控板按下", "Touchpad Press") : store.mapping(id)?.localizedName ?? L("不可用按键", "Unavailable")
    }
}

@MainActor
private final class CombosPageState: ObservableObject {
    @Published var editing: ControllerCombo?
    @Published var removing: ControllerCombo?
    @Published var showsRemoval = false
}

@MainActor
private final class ComboEditorState: ObservableObject {
    @Published var draft: ControllerCombo
    @Published var waitsForInput = false
    @Published var firstButton: String?

    init(_ combo: ControllerCombo) { draft = combo }

    func toggleCapture() {
        waitsForInput.toggle()
        firstButton = nil
    }

    func capture(_ frame: ControllerButtonFrame) {
        guard waitsForInput else { return }
        let newButtons = frame.newlyPressed
        let newPhysical = Set(newButtons.map(ControllerCombo.control(for:)))
        let alreadyHeld = frame.held.subtracting(newPhysical)
        let modifier = firstButton.flatMap { alreadyHeld.contains($0) ? $0 : nil }
            ?? alreadyHeld.sorted().first
            ?? (newPhysical.count > 1 ? newButtons.first.map(ControllerCombo.control(for:)) : nil)
        if let modifier, let trigger = newButtons.first(where: { ControllerCombo.control(for: $0) != modifier }) {
            draft.modifierID = modifier
            draft.triggerID = trigger
            waitsForInput = false
            firstButton = nil
        } else if let button = newButtons.first {
            firstButton = ControllerCombo.control(for: button)
        }
    }
}

private struct ComboEditorView: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var i18n: LocalizationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var state: ComboEditorState
    let isExisting: Bool

    init(combo: ControllerCombo, isExisting: Bool) {
        _state = StateObject(wrappedValue: ComboEditorState(combo))
        self.isExisting = isExisting
    }

    var body: some View {
        let _ = i18n.language
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            Divider()

            Form {
                Section {
                    TextField(L("名称", "Name"), text: $state.draft.name, prompt: Text(L("例如：快速截图", "e.g., Quick Screenshot")))
                }

                Section {
                    LabeledContent(L("实体手柄录入", "Hardware Capture")) {
                        HStack(spacing: 8) {
                            if state.waitsForInput {
                                Text(captureHint)
                                    .foregroundStyle(DualVibePalette.lightBar(for: colorScheme))
                                    .font(.caption.weight(.medium))
                            } else if !store.connected {
                                Text(L("手柄未连接", "Disconnected"))
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Button {
                                state.toggleCapture()
                            } label: {
                                Label(state.waitsForInput ? L("取消录入", "Cancel") : L("按手柄录入…", "Capture…"),
                                      systemImage: state.waitsForInput ? "gamecontroller.fill" : "gamecontroller")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.bordered)
                            .tint(state.waitsForInput ? DualVibePalette.lightBar(for: colorScheme) : nil)
                            .disabled(!store.connected && !state.waitsForInput)
                        }
                    }

                    Picker(L("按住修饰键", "Hold Modifier"), selection: $state.draft.modifierID) {
                        Text(L("选择按键", "Choose Button")).tag("")
                        ForEach(store.mappings.filter { ButtonMapping.physicalButtonIDs.contains($0.id) }) { row in
                            Text(row.id == "touchpad" ? L("触控板按下", "Touchpad Press") : row.localizedName).tag(row.id)
                        }
                    }

                    Picker(L("再按触发键", "Then Press"), selection: $state.draft.triggerID) {
                        Text(L("选择按键", "Choose Button")).tag("")
                        ForEach(store.mappings.filter {
                            ButtonMapping.physicalButtonIDs.contains($0.id) || ButtonMapping.touchPressIDs.contains($0.id)
                        }) { row in
                            Text(row.localizedName).tag(row.id)
                        }
                    }

                    Picker(L("触发手势", "Gesture"), selection: $state.draft.gesture) {
                        ForEach(GestureKind.allCases) { gesture in
                            Text(gesture.localizedTitle).tag(gesture)
                        }
                    }
                } header: {
                    Text(L("手柄输入", "Controller Input"))
                } footer: {
                    if let conflict {
                        Label(conflict, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section(L("执行输出", "Output Action")) {
                    Picker(L("执行动作", "Action"), selection: $state.draft.binding.action) {
                        ForEach(MappingAction.comboOutputActions) { action in
                            Text(action.localizedTitle).tag(action)
                        }
                    }

                    LabeledContent(L("快速录入", "Quick Record")) {
                        MappingOutputRecorder(binding: state.draft.binding) { recorded in
                            state.draft.binding = recorded.applying(to: state.draft.binding)
                        }
                    }

                    if state.draft.binding.action == .openApp {
                        LabeledContent(L("目标应用", "Target App")) {
                            HStack(spacing: 8) {
                                if let path = state.draft.binding.appPath, FileManager.default.fileExists(atPath: path) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 20, height: 20)
                                        .accessibilityHidden(true)
                                    Text(state.draft.binding.localizedTitle)
                                        .lineLimit(1)
                                }
                                Button(state.draft.binding.appPath == nil ? L("选择应用…", "Choose App…") : L("更改…", "Change…"), action: chooseApp)
                            }
                        }
                    }

                    if [.shortcut, .commandPalette, .terminal].contains(state.draft.binding.action) {
                        Toggle(L("执行前启用 DualSense 麦克风", "Enable DualSense Mic First"), isOn: $state.draft.binding.usesMicrophone)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: 460)

            Divider()

            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存", "Save")) {
                    if store.saveCombo(state.draft) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(state.waitsForInput || !store.canSaveCombo(state.draft))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 520)
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: state.draft.binding.action)
        .animation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion), value: state.waitsForInput)
        .onAppear { store.isEditingMapping = true }
        .onDisappear { store.isEditingMapping = false }
        .onChange(of: store.physicalInput) { _, frame in
            if let frame { state.capture(frame) }
        }
        .onChange(of: store.connected) { _, connected in
            if !connected && state.waitsForInput { state.toggleCapture() }
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            DualVibeIconBadge(systemImage: "command", tint: DualVibePalette.lightBar(for: colorScheme), size: 38, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(isExisting ? L("编辑组合键", "Edit Combo") : L("新建组合键", "New Combo"))
                    .font(.title3.weight(.semibold))
                if !state.draft.modifierID.isEmpty || !state.draft.triggerID.isEmpty {
                    HStack(spacing: 4) {
                        Text(displayButton(state.draft.modifierID))
                        Text("+")
                        Text(displayButton(state.draft.triggerID))
                        Text("· \(state.draft.gesture.localizedTitle)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(L("设置两颗手柄按键的组合触发规则", "Configure a two-button DualSense trigger"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func displayButton(_ id: String) -> String {
        guard !id.isEmpty else { return L("未选择", "None") }
        if id == "touchpad" { return L("触控板按下", "Touchpad Press") }
        return store.mapping(id)?.localizedName ?? L("未选择", "None")
    }

    private var conflict: String? {
        guard !state.draft.modifierID.isEmpty, !state.draft.triggerID.isEmpty else { return nil }
        return store.comboConflict(state.draft)
    }

    private var captureHint: String {
        if let id = state.firstButton, let row = store.mapping(id) {
            return L("按住「\(row.localizedName)」，再按另一颗键", "Hold \(row.localizedName), then press another button")
        }
        return L("按住第一颗键，再按第二颗键", "Hold the first button, then press a second")
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.draft.binding.appPath = url.path
        }
    }
}
