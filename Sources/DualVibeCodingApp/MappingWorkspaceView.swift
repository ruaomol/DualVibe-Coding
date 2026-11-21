import AppKit
import SwiftUI

struct MappingWorkspaceView: View {
    @EnvironmentObject private var store: ControllerStore
    @Binding var showMappingEditor: Bool
    let applications: [LauncherApplication]
    let selectProfile: (String) -> Void
    @StateObject private var previewState = ControllerPreviewState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var face: ControllerFace { previewState.face }

    private var mappingsByID: [String: ButtonMapping] {
        Dictionary(uniqueKeysWithValues: store.mappings.map { ($0.id, $0) })
    }

    private var families: [ControllerControlFamily] {
        ControllerControlFamily.all.filter { family in
            family.mappingIDs.contains { mappingsByID[$0] != nil }
        }
    }

    private var selectedFamily: ControllerControlFamily? {
        families.first { $0.mappingIDs.contains(store.selectedMappingID) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                board
                if let family = selectedFamily, let mapping = mappingsByID[store.selectedMappingID] {
                    inspector(family: family, mapping: mapping, mappings: mappingsByID,
                              conflicts: MappingConflicts(store.mappings))
                }
            }
            .frame(maxWidth: 1220)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: store.lastPhysicalPress) { _, press in
            guard let press,
                  let side = families.first(where: { $0.mappingIDs.contains(press.id) })?.preferredFace else { return }
            showFace(side)
        }
        .onChange(of: store.physicalInput) { _, frame in
            guard previewState.isCapturing,
                  NSApp.isActive,
                  let id = frame?.newlyPressed.last,
                  let family = families.first(where: { $0.mappingIDs.contains(id) }) else { return }
            stopCapture()
            select(id, from: family)
            showMappingEditor = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopCapture() }
        }
        .onDisappear { stopCapture() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("按键映射").font(.title.weight(.semibold))
            Spacer(minLength: 4)
            MappingProfilePicker(applications: applications, select: selectProfile)
            Toggle("启用自定义映射", isOn: Binding(
                get: { store.isMouseMode },
                set: { enabled in
                    if enabled != store.isMouseMode { store.toggleMouseMode() }
                }
            ))
            .toggleStyle(.switch)
        }
    }

    private var board: some View {
        let mappings = mappingsByID
        let conflicts = MappingConflicts(store.mappings)
        return VStack(spacing: 0) {
            previewToolbar
            Divider()
            ControllerBoardLayout {
                rail("左侧按键", lane: .left, mappings: mappings, conflicts: conflicts)
                preview
                rail("右侧按键", lane: .right, mappings: mappings, conflicts: conflicts)
            }
            .padding(14)
            .overlayPreferenceValue(BoardAnchorsKey.self) { anchors in
                GeometryReader { coordinateSpace in
                    if let photo = anchors[.photo] {
                        let rect = coordinateSpace[photo]
                        ControllerPreviewSurface(
                            rect: rect,
                            face: face,
                            hotspots: previewHotspots(size: rect.size, mappings: mappings),
                            links: previewLinks(rect: rect, anchors: anchors, geometry: coordinateSpace),
                            animatesTurn: !reduceMotion,
                            floats: !reduceMotion && scenePhase == .active
                        ) { id in
                            if let family = families.first(where: { $0.mappingIDs.contains(id) }) {
                                select(id, from: family)
                            }
                        }
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary).allowsHitTesting(false) }
    }

    private func previewHotspots(size: CGSize, mappings: [String: ButtonMapping]) -> [ControllerFace: [PreviewHotspot]] {
        Dictionary(uniqueKeysWithValues: ControllerFace.allCases.map { side in
            let controls = families.flatMap { family in
                family.hotspots(for: side).compactMap { hotspot -> PreviewHotspot? in
                    let id = mappings[hotspot.id] != nil ? hotspot.id : family.id
                    guard let mapping = mappings[id] else { return nil }
                    let selection = store.selectedMappingID
                    let active = store.activeInput ?? ""
                    let isSelected = family.mappingIDs.contains(selection) && family.hotspot(for: selection, face: side)?.id == hotspot.id
                    let isActive = family.mappingIDs.contains(active) && family.hotspot(for: active, face: side)?.id == hotspot.id
                    return PreviewHotspot(id: id, name: hotspot.accessibleName ?? mapping.name,
                                          path: hotspot.contour.path(in: hotspot.destination(in: size)).cgPath,
                                          tone: isSelected ? .selected : isActive ? .active : nil)
                }
            }
            return (side, controls)
        })
    }

    private func previewLinks(rect: CGRect, anchors: [BoardAnchorKey: Anchor<CGRect>],
                              geometry: GeometryProxy) -> [PreviewLink] {
        func link(_ family: ControllerControlFamily, id: String, tone: PreviewTone) -> PreviewLink? {
            guard let hotspot = family.hotspot(for: id, face: face), let row = anchors[.row(family.id)] else { return nil }
            let bounds = geometry[row]
            let target = hotspot.destination(in: rect.size).offsetBy(dx: rect.minX, dy: rect.minY)
            let onLeft = family.lane == .left
            return PreviewLink(start: CGPoint(x: onLeft ? bounds.maxX : bounds.minX, y: bounds.midY),
                               end: CGPoint(x: onLeft ? target.minX : target.maxX, y: target.midY),
                               tone: tone)
        }

        var links: [PreviewLink] = []
        if store.testMode, let id = store.activeInput,
           let family = families.first(where: { $0.mappingIDs.contains(id) }),
           family.id != selectedFamily?.id,
           let link = link(family, id: id, tone: .active) {
            links.append(link)
        }
        if let selectedFamily, let link = link(selectedFamily, id: store.selectedMappingID, tone: .selected) {
            links.append(link)
        }
        return links
    }

    private func rail(_ title: String, lane: ControlLane, mappings: [String: ButtonMapping],
                      conflicts: MappingConflicts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            let columnFamilies = families.filter { $0.lane == lane }
            VStack(spacing: 0) {
                ForEach(columnFamilies) { family in
                    let isSelected = family.id == selectedFamily?.id
                    let mapping = (isSelected ? mappings[store.selectedMappingID] : nil)
                        ?? mappings[family.id]
                        ?? family.mappingIDs.compactMap { mappings[$0] }.first
                    if let mapping {
                        MappingControlRow(
                            title: family.variants.isEmpty ? mapping.name : family.title,
                            symbol: family.symbol,
                            mapping: mapping,
                            isSelected: isSelected,
                            isActive: store.testMode && family.mappingIDs.contains(store.activeInput ?? ""),
                            hasConflict: family.mappingIDs.contains { conflicts.hasConflict(for: $0) },
                            conflicts: conflicts
                        ) {
                            select(mapping.id, from: family)
                        }
                        .anchorPreference(key: BoardAnchorsKey.self, value: .bounds) { [.row(family.id): $0] }
                        if family.id != columnFamilies.last?.id {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary).allowsHitTesting(false) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var previewToolbar: some View {
        HStack(spacing: 10) {
            Picker("手柄视角", selection: Binding(get: { face }, set: showFace)) {
                Text("正面").tag(ControllerFace.front)
                Text("背面").tag(ControllerFace.rear)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 116)

            Spacer(minLength: 6)
            if store.testMode {
                Text(store.lastInput)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("最近输入：\(store.lastInput)")
            }
            Toggle(isOn: $store.testMode) {
                Label("测试输入", systemImage: "waveform.path")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("暂时暂停映射输出，观察手柄输入")
            Button {
                if previewState.isCapturing {
                    stopCapture()
                } else {
                    store.isEditingMapping = true
                    previewState.isCapturing = true
                }
            } label: {
                Label(previewState.isCapturing ? "按下手柄键…" : "录入手柄键",
                      systemImage: previewState.isCapturing ? "record.circle.fill" : "gamecontroller")
            }
            .controlSize(.small)
            .disabled(!store.connected)
            .help(previewState.isCapturing ? "取消录入" : "按下实体按键，打开对应的映射编辑器")
            Menu {
                Toggle("按下手柄时选中映射", isOn: $store.followHardwareSelection)
                Divider()
                Button("恢复当前配置默认值…", role: .destructive) { previewState.confirmsRestore = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("预览选项")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .confirmationDialog("恢复当前配置的默认映射？", isPresented: $previewState.confirmsRestore, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { store.restoreDefaults() }
        }
    }

    private var preview: some View {
        Color.clear
            .aspectRatio(ControllerFace.pixels.width / ControllerFace.pixels.height, contentMode: .fit)
            .anchorPreference(key: BoardAnchorsKey.self, value: .bounds) { [.photo: $0] }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func inspector(family: ControllerControlFamily, mapping: ButtonMapping,
                           mappings: [String: ButtonMapping], conflicts: MappingConflicts) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: family.symbol)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(mapping.name).font(.headline).lineLimit(1)
                Spacer(minLength: 6)
                Button("编辑映射…") { showMappingEditor = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            let options = family.mappingIDs.compactMap { mappings[$0] }
            if options.count > 1 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(options) { option in
                        let hasConflict = conflicts.hasConflict(for: option.id)
                        Button {
                            select(option.id, from: family)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: option.id == mapping.id ? "smallcircle.filled.circle" : "circle")
                                    .foregroundStyle(option.id == mapping.id ? Color.accentColor : Color.secondary)
                                    .accessibilityHidden(true)
                                Text(family.id == "touchpad" ? String(option.name.dropFirst("触控板".count)) : option.name)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 0)
                                if hasConflict {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .background(option.id == mapping.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel(option.name)
                        .accessibilityHint(hasConflict ? "有映射冲突" : "")
                        .accessibilityAddTraits(option.id == mapping.id ? [.isSelected] : [])
                        .help(store.title(for: option, gesture: .tap))
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(mapping.editableGestures) { gesture in
                    MappingGestureTile(title: mapping.gestureTitle(gesture),
                                       value: store.title(for: mapping, gesture: gesture),
                                       conflict: conflicts.reason(for: mapping.id, gesture: gesture))
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary).allowsHitTesting(false) }
    }

    private func select(_ id: String, from family: ControllerControlFamily) {
        guard mappingsByID[id] != nil else { return }
        store.selectedMappingID = id
        if let side = family.preferredFace { showFace(side) }
    }

    private func stopCapture() {
        guard previewState.isCapturing else { return }
        previewState.isCapturing = false
        store.isEditingMapping = false
    }

    private func showFace(_ next: ControllerFace) {
        if face != next { previewState.face = next }
    }
}

private struct ControllerBoardLayout: Layout {
    private let spacing: CGFloat = 15

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 950
        let widths = columnWidths(for: width)
        let height = subviews.enumerated().map { index, view in
            view.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(for: bounds.width)
        var x = bounds.minX
        for (index, view) in subviews.enumerated() {
            let childProposal = ProposedViewSize(width: widths[index], height: nil)
            let height = view.sizeThatFits(childProposal).height
            let y = bounds.minY + (index == 1 ? max(0, (bounds.height - height) / 2) : 0)
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: childProposal)
            x += widths[index] + spacing
        }
    }

    private func columnWidths(for width: CGFloat) -> [CGFloat] {
        let available = max(0, width - spacing * 2)
        let center = min(500, available * 0.49)
        let rail = (available - center) / 2
        return [rail, center, rail]
    }
}

private struct MappingControlRow: View {
    @EnvironmentObject private var store: ControllerStore
    let title: String
    let symbol: String
    let mapping: ButtonMapping
    let isSelected: Bool
    let isActive: Bool
    let hasConflict: Bool
    let conflicts: MappingConflicts
    let select: () -> Void

    private var summaryGesture: GestureKind? {
        mapping.editableGestures.first { conflicts.reason(for: mapping.id, gesture: $0) != nil }
            ?? mapping.editableGestures.first { mapping[$0].isConfigured }
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let gesture = summaryGesture {
                    Text(store.title(for: mapping, gesture: gesture))
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(conflicts.reason(for: mapping.id, gesture: gesture) == nil ? Color.secondary : .red)
                }
                if hasConflict {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("有映射冲突")
                } else if isActive {
                    Circle().fill(.green)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("收到输入")
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct MappingGestureTile: View {
    let title: String
    let value: String
    let conflict: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if conflict != nil {
                    Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                }
                Text(value).lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(conflict == nil ? Color.primary : .red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(conflict == nil ? Color.primary.opacity(0.045) : .red.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 6))
        .help(conflict ?? "\(title)：\(value)")
        .accessibilityHint(conflict ?? "")
    }
}

private enum ControlLane {
    case left, right
}

@MainActor
private final class ControllerPreviewState: ObservableObject {
    @Published var face = ControllerFace.front
    @Published var confirmsRestore = false
    @Published var isCapturing = false
}

private struct ControllerControlFamily: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let lane: ControlLane
    var variants: [String] = []
    var front: [PhotoHotspot] = []
    var rear: [PhotoHotspot] = []

    var mappingIDs: [String] { [id] + variants }
    var preferredFace: ControllerFace? {
        if rear.isEmpty { return .front }
        return front.isEmpty ? .rear : nil
    }

    func hotspots(for face: ControllerFace) -> [PhotoHotspot] {
        face == .front ? front : rear
    }

    func hotspot(for mappingID: String, face: ControllerFace) -> PhotoHotspot? {
        let available = hotspots(for: face)
        return available.first { $0.id == mappingID } ?? available.first
    }

    static let all: [Self] = [
        .init(id: "l2", title: "L2", symbol: "l2.rectangle.roundedtop", lane: .left,
              rear: [.init("l2", 1149, 51, 219, 183, .trigger(mirrored: true))]),
        .init(id: "l1", title: "L1", symbol: "l1.rectangle.roundedbottom", lane: .left,
              front: [.init("l1", 169, 12, 229, 78, .bumper(mirrored: false))],
              rear: [.init("l1", 1132, 17, 247, 78, .bumper(mirrored: true))]),
        .init(id: "create", title: "Create", symbol: "plus.square", lane: .left,
              front: [.init("create", 380, 98, 47, 76, .capsule)]),
        .init(id: "dpad", title: "方向键", symbol: "dpad", lane: .left,
              variants: ["dpadUp", "dpadRight", "dpadDown", "dpadLeft"],
              front: [
                .init("dpadUp", 225, 165, 99, 116, .direction(.up)),
                .init("dpadRight", 293, 249, 118, 99, .direction(.right)),
                .init("dpadDown", 222, 315, 103, 121, .direction(.down)),
                .init("dpadLeft", 133, 248, 122, 100, .direction(.left))
              ]),
        .init(id: "leftStick", title: "左摇杆", symbol: "l.joystick", lane: .left,
              variants: ["l3", "leftStickUp", "leftStickRight", "leftStickDown", "leftStickLeft"],
              front: [.init("l3", 408, 407, 220, 220, .circle)]),
        .init(id: "touchpad", title: "触控板", symbol: "rectangle.and.hand.point.up.left", lane: .left,
              variants: ["touchMove", "touchTap", "touchScroll", "touchSecondaryTap",
                         "touchPressRight", "touchPressTwoFinger", "touchDrag", "touchSwipeLeft", "touchSwipeRight"],
              front: [.init("touchpad", 451, 38, 634, 315, .trackpad)]),
        .init(id: "mute", title: "麦克风静音", symbol: "mic.slash", lane: .left,
              front: [.init("mute", 723, 581, 90, 36, .capsule)]),

        // In the rear photograph, the user's right shoulder is on the left side of the image.
        .init(id: "r2", title: "R2", symbol: "r2.rectangle.roundedtop", lane: .right,
              rear: [.init("r2", 166, 51, 219, 183, .trigger(mirrored: false))]),
        .init(id: "r1", title: "R1", symbol: "r1.rectangle.roundedbottom", lane: .right,
              front: [.init("r1", 1136, 12, 232, 79, .bumper(mirrored: true))],
              rear: [.init("r1", 157, 17, 247, 78, .bumper(mirrored: false))]),
        .init(id: "options", title: "Options", symbol: "line.3.horizontal", lane: .right,
              front: [.init("options", 1110, 98, 47, 76, .capsule)]),
        .init(id: "triangle", title: "三角键", symbol: "triangle", lane: .right,
              front: [.init("triangle", 1213, 142, 105, 105, .circle)]),
        .init(id: "square", title: "方键", symbol: "square", lane: .right,
              front: [.init("square", 1103, 248, 105, 105, .circle)]),
        .init(id: "circle", title: "圆键", symbol: "circle", lane: .right,
              front: [.init("circle", 1322, 248, 105, 105, .circle)]),
        .init(id: "cross", title: "叉键", symbol: "xmark", lane: .right,
              front: [.init("cross", 1214, 356, 108, 108, .circle)]),
        .init(id: "rightStick", title: "右摇杆", symbol: "r.joystick", lane: .right,
              variants: ["r3", "rightStickUp", "rightStickRight", "rightStickDown", "rightStickLeft"],
              front: [.init("r3", 909, 407, 220, 220, .circle)]),
        .init(id: "ps", title: "PS", symbol: "house", lane: .right,
              front: [.init("ps", 709, 449, 119, 96, .capsule)])
    ]
}

private struct PhotoHotspot: Identifiable {
    let id: String
    let rect: CGRect
    let contour: HotspotContour

    init(_ id: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ contour: HotspotContour) {
        self.id = id
        self.rect = CGRect(x: x, y: y, width: width, height: height)
        self.contour = contour
    }

    func destination(in size: CGSize) -> CGRect {
        let xScale = size.width / ControllerFace.pixels.width
        let yScale = size.height / ControllerFace.pixels.height
        return CGRect(x: rect.minX * xScale, y: rect.minY * yScale,
                      width: rect.width * xScale, height: rect.height * yScale)
    }

    var accessibleName: String? {
        if id == "touchpad" { return "触控板" }
        guard case .direction(let direction) = contour else { return nil }
        switch direction {
        case .up: return "方向键上"
        case .right: return "方向键右"
        case .down: return "方向键下"
        case .left: return "方向键左"
        }
    }
}

private enum PadDirection {
    case up, right, down, left

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        switch self {
        case .up: return CGPoint(x: x, y: y)
        case .right: return CGPoint(x: 1 - y, y: x)
        case .down: return CGPoint(x: 1 - x, y: 1 - y)
        case .left: return CGPoint(x: y, y: 1 - x)
        }
    }
}

private enum HotspotContour: Shape {
    case circle, capsule, trackpad
    case bumper(mirrored: Bool)
    case trigger(mirrored: Bool)
    case direction(PadDirection)

    func path(in rect: CGRect) -> Path {
        switch self {
        case .circle:
            return Ellipse().path(in: rect)
        case .capsule:
            return Capsule().path(in: rect)
        case .bumper(let mirrored):
            return scaledPath(in: rect, mirrored: mirrored) { path in
                path.move(to: CGPoint(x: 0.015, y: 0.92))
                path.addCurve(to: CGPoint(x: 0.88, y: 0.03),
                              control1: CGPoint(x: -0.01, y: 0.3), control2: CGPoint(x: 0.33, y: -0.06))
                path.addQuadCurve(to: CGPoint(x: 0.99, y: 0.52), control: CGPoint(x: 0.98, y: 0.02))
                path.addCurve(to: CGPoint(x: 0.015, y: 0.92),
                              control1: CGPoint(x: 0.8, y: 0.31), control2: CGPoint(x: 0.29, y: 0.45))
            }
        case .trackpad:
            return scaledPath(in: rect) { path in
                path.move(to: CGPoint(x: 0.08, y: 0.02))
                path.addQuadCurve(to: CGPoint(x: 0.01, y: 0.15), control: CGPoint(x: 0, y: 0.02))
                path.addLine(to: CGPoint(x: 0.08, y: 0.76))
                path.addQuadCurve(to: CGPoint(x: 0.2, y: 0.985), control: CGPoint(x: 0.11, y: 0.985))
                path.addLine(to: CGPoint(x: 0.8, y: 0.985))
                path.addQuadCurve(to: CGPoint(x: 0.92, y: 0.76), control: CGPoint(x: 0.89, y: 0.985))
                path.addLine(to: CGPoint(x: 0.99, y: 0.15))
                path.addQuadCurve(to: CGPoint(x: 0.92, y: 0.02), control: CGPoint(x: 1, y: 0.02))
            }
        case .trigger(let mirrored):
            return scaledPath(in: rect, mirrored: mirrored) { path in
                path.move(to: CGPoint(x: 0.015, y: 0.24))
                path.addQuadCurve(to: CGPoint(x: 0.93, y: 0.06), control: CGPoint(x: 0.43, y: -0.055))
                path.addQuadCurve(to: CGPoint(x: 0.89, y: 0.7), control: CGPoint(x: 1.02, y: 0.23))
                path.addQuadCurve(to: CGPoint(x: 0.27, y: 0.99), control: CGPoint(x: 0.76, y: 1.02))
                path.addQuadCurve(to: CGPoint(x: 0.015, y: 0.24), control: CGPoint(x: 0, y: 0.94))
            }
        case .direction(let direction):
            return scaledPath(in: rect) { path in
                path.move(to: direction.point(0.15, 0.1))
                path.addQuadCurve(to: direction.point(0.84, 0.1), control: direction.point(0.5, -0.045))
                path.addQuadCurve(to: direction.point(0.92, 0.64), control: direction.point(1.04, 0.24))
                path.addQuadCurve(to: direction.point(0.5, 0.985), control: direction.point(0.71, 0.93))
                path.addQuadCurve(to: direction.point(0.08, 0.64), control: direction.point(0.29, 0.93))
                path.addQuadCurve(to: direction.point(0.15, 0.1), control: direction.point(-0.035, 0.24))
            }
        }
    }

    private func scaledPath(in rect: CGRect, mirrored: Bool = false, build: (inout Path) -> Void) -> Path {
        var path = Path()
        build(&path)
        path.closeSubpath()
        return path.applying(CGAffineTransform(a: mirrored ? -rect.width : rect.width, b: 0, c: 0,
                                               d: rect.height, tx: mirrored ? rect.maxX : rect.minX, ty: rect.minY))
    }
}

private enum BoardAnchorKey: Hashable {
    case row(String)
    case photo
}

private struct BoardAnchorsKey: PreferenceKey {
    static var defaultValue: [BoardAnchorKey: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [BoardAnchorKey: Anchor<CGRect>],
                       nextValue: () -> [BoardAnchorKey: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
