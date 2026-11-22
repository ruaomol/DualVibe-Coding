import AppKit
import SwiftUI

struct LauncherWheelEditor: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var i18n: LocalizationStore
    @ObservedObject var wheel: LauncherWheelStore
    @ObservedObject var launcher: ApplicationLaunchStore
    var onPreview: (() -> Void)? = nil
    @StateObject private var editing = WheelEditorState()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = i18n.language
        HStack(spacing: 0) {
            wheelStage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspectorPane
                .frame(width: 368)
                .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            wheel.seedAppsIfNeeded(launcher.applications)
            if editing.draft == nil { editing.reload(wheel.slots, position: wheel.position) }
        }
    }

    private var wheelStage: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)

            interactiveRadialCompass
                .frame(width: 344, height: 344)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text(L("出现位置", "Position"))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker(L("出现位置", "Position"), selection: $editing.position) {
                        ForEach(WheelPosition.allCases) { position in
                            Text(position.localizedTitle).tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }

                if let onPreview {
                    Button {
                        onPreview()
                    } label: {
                        Label(L("预览快捷轮盘", "Preview Quick Wheel"), systemImage: "viewfinder.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help(L("立即弹出快捷轮盘预览当前已保存配置", "Open the floating Quick Wheel preview"))
                }
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var interactiveRadialCompass: some View {
        let accent = DualVibePalette.lightBar(for: colorScheme)
        let selectedSlot = editing.draft

        return ZStack {
            // Outer glass/material chassis ring
            Circle()
                .fill(.regularMaterial)
                .overlay {
                    Circle()
                        .strokeBorder(DualVibePalette.hairlineBorder(for: colorScheme), lineWidth: 1)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.08), radius: 22, y: 10)
                .accessibilityHidden(true)

            // 8 sculpted radial sectors matching FloatingLauncher's geometry
            ForEach(wheel.slots) { saved in
                let slot = editing.displaySlot(saved)
                let isSelected = editing.draft?.id == slot.id
                let isHovered = editing.hoveredSlotID == slot.id
                let isDirty = slot != saved
                let reason = slot.unavailableReason(applications: launcher.applications, combos: store.combos)
                editorSector(slot: slot, isSelected: isSelected, isHovered: isHovered, isDirty: isDirty, reason: reason)
            }

            // Luminous PS5 outer rim arc gliding along shortest angular path
            if selectedSlot != nil {
                EditorSectorRimArc()
                    .stroke(
                        DualVibePalette.lightBarGradient(for: colorScheme),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .shadow(color: DualVibePalette.lightBarGlow(for: colorScheme), radius: 6)
                    .rotationEffect(.radians(editing.indicatorAngle))
                    .animation(DualVibeMotion.resolve(DualVibeMotion.glide, reduceMotion: reduceMotion), value: editing.indicatorAngle)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            // Central hub
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .strokeBorder(DualVibePalette.hairlineBorder(for: colorScheme), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.07), radius: 8, y: 2)

                // Directional pointer tick on hub rim
                VStack {
                    Capsule()
                        .fill(accent)
                        .frame(width: 4, height: 10)
                        .shadow(color: DualVibePalette.lightBarGlow(for: colorScheme), radius: 3)
                    Spacer()
                }
                .padding(5)
                .rotationEffect(.radians(editing.indicatorAngle))
                .animation(DualVibeMotion.resolve(DualVibeMotion.glide, reduceMotion: reduceMotion), value: editing.indicatorAngle)

                VStack(spacing: 4) {
                    if let slot = selectedSlot {
                        Text(L("\(slot.localizedDirectionName)方向", slot.localizedDirectionName))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                            .contentTransition(.opacity)

                        Text(slot.localizedDisplayTitle(applications: launcher.applications, combos: store.combos))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(slot.payload == .empty ? .secondary : .primary)
                            .lineLimit(1)
                            .frame(maxWidth: 96)
                            .contentTransition(.opacity)
                    }
                }
            }
            .frame(width: 122, height: 122)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: selectedSlot?.id)
    }

    private func editorSector(slot: WheelSlot, isSelected: Bool, isHovered: Bool,
                              isDirty: Bool, reason: String?) -> some View {
        let accent = DualVibePalette.lightBar(for: colorScheme)
        let angle = LauncherWheelGeometry.angle(slot.id)
        let radius: CGFloat = 172
        let canvas = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        let outline = EditorWheelSector(id: slot.id).path(in: canvas)
        let bounds = outline.boundingRect
        let shape = outline.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let contentX = radius + radius * 0.71 * sin(angle) - bounds.minX
        let contentY = radius - radius * 0.71 * cos(angle) - bounds.minY
        let title = slot.localizedDisplayTitle(applications: launcher.applications, combos: store.combos)
        let isEmpty = slot.payload == .empty

        return Button {
            select(slot.id)
        } label: {
            ZStack {
                shape
                    .fill(sectorFill(isSelected: isSelected, isHovered: isHovered, isEmpty: isEmpty, accent: accent))
                    .overlay {
                        shape.stroke(
                            isSelected
                                ? accent.opacity(0.65)
                                : (isHovered ? accent.opacity(0.32) : DualVibePalette.hairlineBorder(for: colorScheme)),
                            lineWidth: isSelected ? 1.4 : 0.8
                        )
                    }

                VStack(spacing: 3) {
                    if case .application(let id) = slot.payload,
                       let app = launcher.applications.first(where: { $0.id == id }) {
                        LauncherArtwork(application: app, size: 28)
                            .shadow(color: .black.opacity(0.14), radius: 3, y: 1.5)
                    } else {
                        Image(systemName: isEmpty ? "plus" : slot.symbolName)
                            .font(.system(size: isEmpty ? 14 : 18, weight: .semibold))
                            .foregroundStyle(iconColor(slot, isSelected: isSelected, reason: reason, accent: accent))
                            .frame(height: 28)
                    }

                    Text(isEmpty ? slot.localizedDirectionName : title)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 64)
                }
                .scaleEffect((isSelected || isHovered) && !reduceMotion ? 1.055 : 1.0)
                .position(x: contentX, y: contentY)
            }
            .frame(width: bounds.width, height: bounds.height)
            .contentShape(shape)
        }
        .buttonStyle(DualVibeTactileButtonStyle(scale: 0.985))
        .onHover { hovering in
            withAnimation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion)) {
                editing.hoveredSlotID = hovering ? slot.id : (editing.hoveredSlotID == slot.id ? nil : editing.hoveredSlotID)
            }
        }
        .accessibilityLabel("\(slot.directionName)，\(title)\(isDirty ? "，未保存" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(reason ?? title)
        .position(x: bounds.midX, y: bounds.midY)
    }

    private func sectorFill(isSelected: Bool, isHovered: Bool, isEmpty: Bool, accent: Color) -> Color {
        if isSelected {
            return accent.opacity(colorScheme == .dark ? 0.24 : 0.14)
        }
        if isHovered {
            return accent.opacity(colorScheme == .dark ? 0.12 : 0.07)
        }
        return Color.primary.opacity(isEmpty ? 0.018 : (colorScheme == .dark ? 0.05 : 0.032))
    }

    private func iconColor(_ slot: WheelSlot, isSelected: Bool, reason: String?, accent: Color) -> Color {
        if slot.payload == .empty { return isSelected ? accent : .secondary }
        return reason == nil ? accent : .orange
    }

    private var inspectorPane: some View {
        let changes = editing.pendingChanges.filter { wheel.slots[$0.id] != $0 }
        let hasChanges = !changes.isEmpty || wheel.position != editing.position

        return VStack(spacing: 0) {
            if let slot = editing.draft {
                HStack(spacing: 12) {
                    DualVibeDirectionDial(angle: editing.indicatorAngle, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("\(slot.localizedDirectionName)方向", "\(slot.localizedDirectionName) Direction"))
                            .font(.headline)
                        HStack(spacing: 5) {
                            if case .application(let id) = slot.payload,
                               let app = launcher.applications.first(where: { $0.id == id }) {
                                LauncherArtwork(application: app, size: 14)
                            }
                            Text(slot.payload == .empty ? L("未配置动作", "Not configured") : slot.localizedDisplayTitle(applications: launcher.applications, combos: store.combos))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if hasChanges {
                        DualVibeStatusBadge(text: L("未保存", "Unsaved"), systemImage: "pencil", tone: .accent)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(.bar)

                Divider()

                Form {
                    Section(L("方向内容", "Slot Content")) {
                        Picker(L("类型", "Type"), selection: payloadKind) {
                            ForEach(WheelEditorState.Kind.allCases) { kind in
                                Text(kind.localizedTitle).tag(kind)
                            }
                        }

                        if editing.draftKind != .empty {
                            TextField(L("显示名称", "Display Name"), text: draftValue(\.name, fallback: ""),
                                      prompt: Text(L("留空自动使用默认名", "Auto if left blank")))
                        }
                    }

                    if editing.draftKind == .application {
                        Section {
                            Picker(L("应用", "Application"), selection: applicationChoice) {
                                Text(L("选择应用", "Choose App")).tag(nil as String?)
                                ForEach(launcher.applications) { app in
                                    Text(app.name).tag(Optional(app.id))
                                }
                            }
                        } footer: {
                            if launcher.applications.isEmpty {
                                Text(L("先切换到顶部「应用库」添加常用 App。", "Switch to “App Library” above to add apps first."))
                            }
                        }
                    } else if editing.draftKind == .combo {
                        Section {
                            Picker(L("组合键", "Combo"), selection: comboChoice) {
                                Text(L("选择组合键", "Choose Combo")).tag(nil as UUID?)
                                ForEach(availableCombos) { combo in
                                    Text(combo.name).tag(Optional(combo.id))
                                }
                            }
                        } footer: {
                            if availableCombos.isEmpty {
                                Text(L("当前配置还没有可用的自定义组合键。", "No custom combos available in this profile yet."))
                            }
                        }
                    } else if editing.draftKind == .action {
                        Section(L("动作详情", "Action Details")) {
                            Picker(L("执行动作", "Action"), selection: actionChoice) {
                                ForEach(WheelSlot.allowedActions) { action in
                                    Text(action.localizedTitle).tag(action)
                                }
                            }
                            LabeledContent(L("快速录入", "Quick Record")) {
                                MappingOutputRecorder(binding: actionBinding) { recorded in
                                    setMapping(recorded.applying(to: actionBinding))
                                }
                            }
                        }
                    }

                    if slot.payload != .empty,
                       let reason = slot.localizedUnavailableReason(applications: launcher.applications, combos: store.combos) {
                        Section {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollBounceBehavior(.basedOnSize)
                .id(slot.id)
                .transition(reduceMotion ? .opacity : .opacity)

                Divider()

                HStack(spacing: 8) {
                    Button(L("清空此格", "Clear Slot"), role: .destructive) {
                        withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                            editing.setKind(.empty)
                        }
                    }
                    .disabled(editing.draftKind == .empty)

                    Spacer()

                    Button(L("还原", "Revert")) {
                        withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                            editing.reload(wheel.slots, position: wheel.position)
                        }
                    }
                    .disabled(!hasChanges)

                    Button(L("保存", "Save")) {
                        withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                            wheel.updateSlots(changes, position: editing.position)
                            editing.reload(wheel.slots, position: wheel.position)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || !changes.allSatisfy(canSave))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: editing.draftKind)
        .animation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion), value: hasChanges)
    }

    private var availableCombos: [ControllerCombo] {
        store.combos.filter { $0.actionIsValid && $0.binding.action != .showLauncher }
    }

    private func select(_ id: Int) {
        guard wheel.slots.indices.contains(id), editing.draft?.id != id else { return }
        withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
            editing.select(wheel.slots[id])
        }
    }

    private func canSave(_ slot: WheelSlot) -> Bool {
        slot.payload == .empty || slot.unavailableReason(applications: launcher.applications, combos: store.combos) == nil
    }

    private var payloadKind: Binding<WheelEditorState.Kind> {
        Binding(get: { editing.draftKind }, set: { kind in
            withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                editing.setKind(kind)
            }
        })
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

private struct EditorWheelSector: Shape {
    let id: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let outer = radius * 0.945
        let inner = radius * 0.42
        let corner = radius * 0.042
        guard radius > 0 else { return Path() }
        let angle = LauncherWheelGeometry.angle(id) - .pi / 2
        let half = LauncherWheelGeometry.step / 2 - 0.045
        let start = angle - half
        let end = angle + half
        let outerInset = corner / outer
        let innerInset = corner / inner
        func point(_ distance: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + distance * cos(angle), y: center.y + distance * sin(angle))
        }

        var path = Path()
        path.move(to: point(outer, start + outerInset))
        path.addArc(center: center, radius: outer, startAngle: .radians(start + outerInset),
                    endAngle: .radians(end - outerInset), clockwise: false)
        path.addQuadCurve(to: point(outer - corner, end), control: point(outer, end))
        path.addLine(to: point(inner + corner, end))
        path.addQuadCurve(to: point(inner, end - innerInset), control: point(inner, end))
        path.addArc(center: center, radius: inner, startAngle: .radians(end - innerInset),
                    endAngle: .radians(start + innerInset), clockwise: true)
        path.addQuadCurve(to: point(inner + corner, start), control: point(inner, start))
        path.addLine(to: point(outer - corner, start))
        path.addQuadCurve(to: point(outer, start + outerInset), control: point(outer, start))
        path.closeSubpath()
        return path
    }
}

private struct EditorSectorRimArc: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * 0.965
        guard radius > 0 else { return Path() }
        let angle = -Double.pi / 2
        let half = LauncherWheelGeometry.step / 2 - 0.075
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .radians(angle - half),
                    endAngle: .radians(angle + half),
                    clockwise: false)
        return path
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

        @MainActor
        var localizedTitle: String {
            switch self {
            case .empty: return L("未设置", "Empty")
            case .application: return L("应用", "Application")
            case .combo: return L("已保存的组合键", "Saved Combo")
            case .action: return L("快捷键或动作", "Shortcut or Action")
            }
        }
    }

    @Published var draft: WheelSlot?
    @Published private(set) var draftKind: Kind = .empty
    @Published var position: WheelPosition = .screenCenter
    @Published var hoveredSlotID: Int?
    @Published private(set) var indicatorAngle: Double = 0
    private var otherDrafts: [Int: WheelSlot] = [:]

    var pendingChanges: [WheelSlot] {
        Array(otherDrafts.values) + (draft.map { [$0] } ?? [])
    }

    func reload(_ slots: [WheelSlot], position: WheelPosition) {
        self.position = position
        let currentID = draft?.id ?? 0
        otherDrafts.removeAll()
        if let selected = slots.first(where: { $0.id == currentID }) ?? slots.first {
            setDraft(selected, animateAngle: false)
        }
    }

    func displaySlot(_ saved: WheelSlot) -> WheelSlot {
        if let draft, draft.id == saved.id { return draft }
        return otherDrafts[saved.id] ?? saved
    }

    func select(_ slot: WheelSlot) {
        if let draft { otherDrafts[draft.id] = draft }
        setDraft(otherDrafts.removeValue(forKey: slot.id) ?? slot, animateAngle: true)
    }

    private func setDraft(_ slot: WheelSlot, animateAngle: Bool = false) {
        draft = slot
        let target = LauncherWheelGeometry.angle(slot.id)
        if animateAngle {
            let delta = atan2(sin(target - indicatorAngle), cos(target - indicatorAngle))
            indicatorAngle += delta
        } else {
            indicatorAngle = target
        }
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
