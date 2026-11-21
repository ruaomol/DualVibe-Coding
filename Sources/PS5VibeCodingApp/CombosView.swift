import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CombosView: View {
    @EnvironmentObject private var store: ControllerStore
    @StateObject private var state = CombosPageState()
    @Binding var showMappingEditor: Bool

    private var buttonMappings: [ButtonMapping] {
        store.mappings.filter { row in
            row.editableGestures.contains { row[$0].isConfigured && row[$0].modifierID != nil }
        }
    }

    var body: some View {
        Form {
            Section {
                if store.combos.isEmpty {
                    Label("还没有自定义组合键", systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ForEach(store.combos) { combo in
                        customRow(combo)
                    }
                }
            } header: {
                HStack {
                    Text("自定义组合键")
                    Spacer()
                    Button {
                        state.editing = ControllerCombo(name: "", modifierID: "", triggerID: "",
                                                        gesture: .tap, binding: .init(.shortcut))
                    } label: {
                        Label("新建组合键", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if !buttonMappings.isEmpty {
                let conflicts = MappingConflicts(store.mappings)
                Section("按键映射中的组合") {
                    ForEach(buttonMappings) { row in
                        ForEach(row.editableGestures) { gesture in
                            if let modifier = row[gesture].modifierID, row[gesture].isConfigured {
                                existingRow(row, gesture: gesture, modifier: modifier, conflicts: conflicts)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("组合键")
        .sheet(item: $state.editing) { combo in
            ComboEditorView(combo: combo, isExisting: store.combos.contains { $0.id == combo.id })
        }
        .confirmationDialog("删除组合键？", isPresented: $state.showsRemoval, titleVisibility: .visible,
                            presenting: state.removing) { combo in
            Button("删除「\(combo.name)」", role: .destructive) { store.removeCombo(id: combo.id) }
        } message: { combo in
            if store.mappings.contains(where: { mapping in
                mapping.editableGestures.contains { mapping[$0].comboID == combo.id }
            }) {
                Text("引用此组合键的按键动作也会清除。")
            }
        }
    }

    private func customRow(_ combo: ControllerCombo) -> some View {
        let conflict = store.comboConflict(combo)
        return HStack(spacing: 12) {
            Image(systemName: conflict == nil ? "gamecontroller" : "exclamationmark.circle.fill")
                .foregroundStyle(conflict == nil ? Color.accentColor : Color.red)
                .font(.body.weight(.medium))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(combo.name).font(.body.weight(.medium))
                Text("\(buttonName(combo.modifierID)) + \(store.mapping(combo.triggerID)?.name ?? "不可用按键") · \(combo.gesture.rawValue)")
                    .font(.caption)
                    .foregroundStyle(conflict == nil ? Color.secondary : Color.red)
            }
            .help(conflict ?? "")
            .accessibilityHint(conflict ?? "")
            Spacer()
            Text(combo.binding.title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("编辑…") { state.editing = combo }
                .accessibilityLabel("编辑\(combo.name)")
            Button(role: .destructive) {
                state.removing = combo
                state.showsRemoval = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("删除\(combo.name)")
        }
        .padding(.vertical, 4)
    }

    private func existingRow(_ row: ButtonMapping, gesture: GestureKind, modifier: String,
                             conflicts: MappingConflicts) -> some View {
        let conflict = conflicts.reason(for: row.id, gesture: gesture)
        let title = store.title(for: row[gesture])
        return LabeledContent("\(buttonName(modifier)) + \(row.name) · \(row.gestureTitle(gesture))") {
            Button {
                store.selectedMappingID = row.id
                showMappingEditor = true
            } label: {
                if conflict != nil {
                    Label(title, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                } else {
                    Text(title)
                }
            }
            .accessibilityHint(conflict ?? "")
            .help(conflict ?? title)
        }
    }

    private func buttonName(_ id: String) -> String {
        id == "touchpad" ? "触控板按下" : store.mapping(id)?.name ?? "不可用按键"
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
        // Prefer the first button recorded by this sheet. A control already held
        // when recording started can also act as the modifier.
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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: ComboEditorState
    let isExisting: Bool

    init(combo: ControllerCombo, isExisting: Bool) {
        _state = StateObject(wrappedValue: ComboEditorState(combo))
        self.isExisting = isExisting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isExisting ? "编辑组合键" : "新建组合键")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)

            Form {
                Section {
                    TextField("名称", text: $state.draft.name, prompt: Text("快速截图"))
                }
                Section("手柄输入") {
                    HStack {
                        Button(state.waitsForInput ? "取消录入" : "按手柄录入…") {
                            state.toggleCapture()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!store.connected && !state.waitsForInput)
                        Spacer()
                        if state.waitsForInput {
                            Text(captureHint)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } else if !store.connected {
                            Text("手柄未连接")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    Picker("按住", selection: $state.draft.modifierID) {
                        Text("选择按键").tag("")
                        ForEach(store.mappings.filter { ButtonMapping.physicalButtonIDs.contains($0.id) }) { row in
                            Text(row.id == "touchpad" ? "触控板按下" : row.name).tag(row.id)
                        }
                    }
                    Picker("再按", selection: $state.draft.triggerID) {
                        Text("选择按键").tag("")
                        ForEach(store.mappings.filter {
                            ButtonMapping.physicalButtonIDs.contains($0.id) || ButtonMapping.touchPressIDs.contains($0.id)
                        }) { row in
                            Text(row.name).tag(row.id)
                        }
                    }
                    Picker("手势", selection: $state.draft.gesture) {
                        ForEach(GestureKind.allCases) { gesture in
                            Text(gesture.rawValue).tag(gesture)
                        }
                    }
                    if let conflict {
                        Label(conflict, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section("输出") {
                    Picker("动作", selection: $state.draft.binding.action) {
                        ForEach(MappingAction.comboOutputActions) { action in
                            Text(action.displayTitle).tag(action)
                        }
                    }
                    LabeledContent("录入输出") {
                        MappingOutputRecorder(binding: state.draft.binding) { recorded in
                            state.draft.binding = recorded.applying(to: state.draft.binding)
                        }
                    }
                    if state.draft.binding.action == .openApp {
                        LabeledContent("目标应用") {
                            Button(state.draft.binding.appPath == nil ? "选择应用…" : state.draft.binding.title,
                                   action: chooseApp)
                        }
                    }
                    if [.shortcut, .commandPalette, .terminal].contains(state.draft.binding.action) {
                        Toggle("执行前启用 DualSense 麦克风", isOn: $state.draft.binding.usesMicrophone)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: 490)

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if store.saveCombo(state.draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.waitsForInput || !store.canSaveCombo(state.draft))
            }
            .padding(16)
        }
        .frame(width: 510)
        .onAppear { store.isEditingMapping = true }
        .onDisappear { store.isEditingMapping = false }
        .onChange(of: store.physicalInput) { _, frame in
            if let frame { state.capture(frame) }
        }
        .onChange(of: store.connected) { _, connected in
            if !connected && state.waitsForInput { state.toggleCapture() }
        }
    }

    private var conflict: String? {
        guard !state.draft.modifierID.isEmpty, !state.draft.triggerID.isEmpty else { return nil }
        return store.comboConflict(state.draft)
    }

    private var captureHint: String {
        if let id = state.firstButton, let row = store.mapping(id) {
            return "按住\(row.name)，再按另一颗键"
        }
        return "按住一颗键，再按另一颗键"
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
