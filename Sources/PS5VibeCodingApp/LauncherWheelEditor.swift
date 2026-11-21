import SwiftUI

struct LauncherWheelEditor: View {
    @EnvironmentObject private var store: ControllerStore
    @ObservedObject var wheel: LauncherWheelStore
    @ObservedObject var launcher: ApplicationLaunchStore
    @StateObject private var editing = WheelEditorState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                preview
                    .frame(width: 248)
                    .padding(.top, 18)
                Divider()
                if editing.draft != nil {
                    slotInspector
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(maxWidth: 760)
        .frame(height: 370)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
                .allowsHitTesting(false)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            wheel.seedAppsIfNeeded(launcher.applications)
            if editing.draft == nil { editing.reload(wheel.slots, position: wheel.position) }
        }
    }

    private var header: some View {
        HStack {
            Label("快捷轮盘", systemImage: "circle.grid.3x3")
                .font(.title3.weight(.semibold))
            Spacer()
            Picker("出现位置", selection: $editing.position) {
                ForEach(WheelPosition.allCases) { position in
                    Text(position.title).tag(position)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var preview: some View {
        ZStack {
            Circle()
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(width: 158, height: 158)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Image(systemName: editing.draft?.directionSymbol ?? "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(editing.draft?.directionName ?? "")
                    .font(.caption.weight(.medium))
                if let slot = editing.draft, slot.payload != .empty {
                    Text(slot.displayTitle(applications: launcher.applications, combos: store.combos))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 82)
                }
            }
            .accessibilityHidden(true)
            ForEach(wheel.slots) { saved in
                let slot = editing.displaySlot(saved)
                let angle = Double(slot.id) * .pi / 4
                directionButton(slot)
                    .offset(x: 80 * sin(angle), y: -80 * cos(angle))
            }
        }
        .frame(width: 216, height: 216)
    }

    private func directionButton(_ slot: WheelSlot) -> some View {
        let selected = editing.draft?.id == slot.id
        let reason = slot.unavailableReason(applications: launcher.applications, combos: store.combos)
        return Button { select(slot.id) } label: {
            Group {
                if case .application(let id) = slot.payload,
                   let app = launcher.applications.first(where: { $0.id == id }) {
                    LauncherArtwork(application: app, size: 24)
                } else {
                    Image(systemName: slot.symbolName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(iconColor(slot, reason: reason))
                }
            }
            .frame(width: 42, height: 42)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.044), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.075), lineWidth: selected ? 1.6 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(slot.directionName)，\(slot.displayTitle(applications: launcher.applications, combos: store.combos))")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(reason ?? slot.displayTitle(applications: launcher.applications, combos: store.combos))
    }

    private func iconColor(_ slot: WheelSlot, reason: String?) -> Color {
        if slot.payload == .empty { return .secondary }
        return reason == nil ? .accentColor : .orange
    }

    @ViewBuilder private var slotInspector: some View {
        if let slot = editing.draft {
            Form {
                Section("\(slot.directionName)方向") {
                    Picker("内容", selection: payloadKind) {
                        ForEach(WheelEditorState.Kind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    if editing.draftKind != .empty {
                        TextField("显示名称", text: draftValue(\.name, fallback: ""), prompt: Text("自动"))
                    }
                }
                if editing.draftKind == .application {
                    Section {
                        Picker("应用", selection: applicationChoice) {
                            Text("选择应用").tag(nil as String?)
                            ForEach(launcher.applications) { app in
                                Text(app.name).tag(Optional(app.id))
                            }
                        }
                        if launcher.applications.isEmpty {
                            Text("先在应用库中添加 App。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if editing.draftKind == .combo {
                    Section {
                        Picker("组合键", selection: comboChoice) {
                            Text("选择组合键").tag(nil as UUID?)
                            ForEach(availableCombos) { combo in
                                Text(combo.name).tag(Optional(combo.id))
                            }
                        }
                        if availableCombos.isEmpty {
                            Text("当前配置还没有可用的组合键。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if editing.draftKind == .action {
                    Section {
                        Picker("动作", selection: actionChoice) {
                            ForEach(WheelSlot.allowedActions) { action in Text(action.rawValue).tag(action) }
                        }
                        LabeledContent("录入输出") {
                            MappingOutputRecorder(binding: actionBinding) { recorded in
                                setMapping(recorded.applying(to: actionBinding))
                            }
                        }
                    }
                }
                if slot.payload != .empty, let reason = slot.unavailableReason(applications: launcher.applications, combos: store.combos) {
                    Section {
                        Label(reason, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var footer: some View {
        let changes = editing.pendingChanges.filter { wheel.slots[$0.id] != $0 }
        let hasChanges = !changes.isEmpty || wheel.position != editing.position
        return HStack {
            Button("清空此格") { editing.setKind(.empty) }
                .disabled(editing.draftKind == .empty)
            Spacer()
            Button("还原更改") { editing.reload(wheel.slots, position: wheel.position) }
                .disabled(!hasChanges)
            Button("保存") {
                wheel.updateSlots(changes, position: editing.position)
                editing.reload(wheel.slots, position: wheel.position)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges || !changes.allSatisfy(canSave))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var availableCombos: [ControllerCombo] {
        store.combos.filter { $0.actionIsValid && $0.binding.action != .showLauncher }
    }

    private func select(_ id: Int) {
        guard wheel.slots.indices.contains(id), editing.draft?.id != id else { return }
        editing.select(wheel.slots[id])
    }

    private func canSave(_ slot: WheelSlot) -> Bool {
        slot.payload == .empty || slot.unavailableReason(applications: launcher.applications, combos: store.combos) == nil
    }

    private var payloadKind: Binding<WheelEditorState.Kind> {
        Binding(get: { editing.draftKind }, set: { editing.setKind($0) })
    }

    private var applicationChoice: Binding<String?> {
        Binding {
            if case .application(let bundleID) = editing.draft?.payload,
               launcher.applications.contains(where: { $0.id == bundleID }) {
                return bundleID
            }
            return nil
        } set: { value in
            editing.draft?.payload = .application(bundleID: value ?? "")
        }
    }

    private var comboChoice: Binding<UUID?> {
        Binding {
            guard let id = editing.draft?.binding?.comboID,
                  availableCombos.contains(where: { $0.id == id }) else { return nil }
            return id
        } set: { value in
            var binding = MappingBinding(.runCombo)
            binding.comboID = value
            setMapping(binding)
        }
    }

    private var actionChoice: Binding<MappingAction> {
        Binding(get: { actionBinding.action }, set: { action in
            setMapping(MappingBinding(action))
        })
    }

    private var actionBinding: MappingBinding {
        guard case .mapping(let binding) = editing.draft?.payload else { return MappingBinding(.shortcut) }
        return binding
    }

    private func setMapping(_ binding: MappingBinding) {
        editing.draft?.payload = .mapping(binding)
    }

    private func draftValue<Value>(_ path: WritableKeyPath<WheelSlot, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { editing.draft?[keyPath: path] ?? fallback }, set: { editing.draft?[keyPath: path] = $0 })
    }
}

@MainActor
private final class WheelEditorState: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case empty = "未设置"
        case application = "应用"
        case combo = "已保存的组合键"
        case action = "快捷键或动作"
        var id: Self { self }
    }

    @Published var draft: WheelSlot?
    @Published private(set) var draftKind: Kind = .empty
    @Published var position: WheelPosition = .screenCenter
    private var otherDrafts: [Int: WheelSlot] = [:]

    var pendingChanges: [WheelSlot] {
        Array(otherDrafts.values) + (draft.map { [$0] } ?? [])
    }

    func reload(_ slots: [WheelSlot], position: WheelPosition) {
        self.position = position
        let currentID = draft?.id ?? 0
        otherDrafts.removeAll()
        if let selected = slots.first(where: { $0.id == currentID }) ?? slots.first {
            setDraft(selected)
        }
    }

    func displaySlot(_ saved: WheelSlot) -> WheelSlot {
        if let draft, draft.id == saved.id { return draft }
        return otherDrafts[saved.id] ?? saved
    }

    func select(_ slot: WheelSlot) {
        if let draft { otherDrafts[draft.id] = draft }
        setDraft(otherDrafts.removeValue(forKey: slot.id) ?? slot)
    }

    private func setDraft(_ slot: WheelSlot) {
        draft = slot
        switch slot.payload {
        case .empty: draftKind = .empty
        case .application: draftKind = .application
        case .mapping(let binding): draftKind = binding.action == .runCombo ? .combo : .action
        }
    }

    func setKind(_ kind: Kind) {
        guard var slot = draft, kind != draftKind else { return }
        switch kind {
        case .empty: slot = WheelSlot(id: slot.id)
        case .application: slot.payload = .application(bundleID: "")
        case .combo: slot.payload = .mapping(MappingBinding(.runCombo))
        case .action: slot.payload = .mapping(MappingBinding(.shortcut))
        }
        setDraft(slot)
    }
}
