import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingLauncherController: NSObject, NSWindowDelegate {
    private var panel: LauncherWheelPanel?
    private var selection: LauncherWheelSelection?
    private var isClosing = false
    private var observation = Set<AnyCancellable>()
    private var eventMonitors: [Any] = []
    private weak var store: ControllerStore?
    private weak var previousKeyWindow: NSWindow?

    func toggle(store: ControllerStore, launcher: ApplicationLaunchStore, wheel: LauncherWheelStore,
                appearance: AppAppearance, onManage: @escaping () -> Void) {
        guard !isClosing else { return }
        if panel != nil { close() }
        else { present(store: store, launcher: launcher, wheel: wheel, appearance: appearance, onManage: onManage) }
    }

    func present(store: ControllerStore, launcher: ApplicationLaunchStore, wheel: LauncherWheelStore,
                 appearance: AppAppearance, onManage: @escaping () -> Void) {
        guard panel == nil else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        let atPointer = wheel.position == .pointer
        let anchor = atPointer ? pointer : CGPoint(x: bounds.midX, y: bounds.midY)
        let frame = LauncherWheelGeometry.frame(near: anchor, inside: bounds, maximumDimension: atPointer ? 248 : 300)
        guard !frame.isEmpty else { return }
        // Resolve icons and validation once on open instead of on each analog input.
        wheel.seedAppsIfNeeded(launcher.applications)
        let entries = wheel.slots.map { slot -> LauncherWheelEntry in
            let application: LauncherApplication?
            if case .application(let id) = slot.payload {
                application = launcher.applications.first { $0.id == id }
            } else {
                application = nil
            }
            let url = application?.installedURL
            let enabled: Bool
            switch slot.payload {
            case .empty: enabled = false
            case .application: enabled = url != nil
            case .mapping: enabled = slot.binding.map(store.canRunLauncherAction) ?? false
            }
            return LauncherWheelEntry(slot: slot, application: application,
                                      title: slot.displayTitle(applications: launcher.applications, combos: store.combos),
                                      symbol: slot.symbolName, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                                      enabled: enabled)
        }
        let selection = LauncherWheelSelection(entries: entries)
        let window = LauncherWheelPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        window.title = "快捷轮盘"
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.delegate = self
        previousKeyWindow = NSApp.isActive ? NSApp.keyWindow : nil
        self.store = store
        self.selection = selection
        panel = window
        updateAppearance(appearance)

        let invoke = { [weak self, weak store, weak window] (entry: LauncherWheelEntry) -> Void in
            guard let self, let store, let window, self.panel === window, entry.enabled else { return }
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.close {
                switch entry.slot.payload {
                case .empty: break
                case .application:
                    if let application = entry.application { launcher.launch(application) {} }
                case .mapping:
                    if let frontmostPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID,
                       let binding = entry.slot.binding {
                        store.runLauncherAction(binding)
                    }
                }
            }
        }
        let manage: () -> Void = { [weak self] in
            self?.close(then: onManage)
        }
        let cancel = { [weak self, weak window] in
            if let self, let window, self.panel === window { self.close() }
        }
        window.contentView = NSHostingView(rootView: LauncherWheelView(
            selection: selection,
            invoke: invoke,
            manage: manage,
            cancel: cancel
        ))

        store.launcherAim
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak window] point in
                guard window?.isVisible == true else { return }
                selection.aim(point)
            }
            .store(in: &observation)

        store.$physicalInput
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak window] frame in
                guard window?.isVisible == true, let frame else { return }
                if frame.navigationInputs.contains("circle") {
                    cancel()
                    return
                }
                selection.navigate(frame)
                if frame.navigationInputs.contains("cross"), let entry = selection.selectedEntry { invoke(entry) }
            }
            .store(in: &observation)

        installMonitors(window, selection: selection, invoke: invoke, cancel: cancel)
        window.orderFrontRegardless()
        // A nonactivating panel receives keyboard input without changing the frontmost application.
        window.makeKey()
        if window.isVisible {
            store.isLauncherActive = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.panel === window, !self.isClosing else { return }
                let motion: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? nil : .spring(duration: 0.29, bounce: 0.12)
                withAnimation(motion) { selection.isPresented = true }
            }
        } else {
            close()
        }
    }

    func updateAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system: panel?.appearance = nil
        case .light: panel?.appearance = NSAppearance(named: .aqua)
        case .dark: panel?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func close(then completion: (() -> Void)? = nil) {
        guard let window = panel, let selection, !isClosing else { return }
        isClosing = true
        window.ignoresMouseEvents = true
        observation.removeAll()
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()

        let motion: Animation? = selection.isPresented && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeInOut(duration: 0.16) : nil
        withAnimation(motion, completionCriteria: .removed) {
            selection.isPresented = false
        } completion: { [weak self] in
            guard let self, self.panel === window else { return }
            self.finishClosing(window)
            // Return focus before sending a shortcut or opening an app.
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    private func finishClosing(_ window: NSPanel) {
        let restoreKeyWindow = window.isKeyWindow || NSApp.keyWindow == nil
        panel = nil
        selection = nil
        store?.isLauncherActive = false
        store = nil
        window.delegate = nil
        window.orderOut(nil)
        if restoreKeyWindow, NSApp.isActive, let previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKey()
        }
        previousKeyWindow = nil
        window.close()
        isClosing = false
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel { close() }
    }

    private func installMonitors(_ window: NSPanel, selection: LauncherWheelSelection,
                                 invoke: @escaping (LauncherWheelEntry) -> Void, cancel: @escaping () -> Void) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak window] event in
            guard let window else { return event }
            if event.type != .keyDown {
                if event.window !== window { cancel() }
                return event
            }
            guard window.isKeyWindow, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
                return event
            }
            switch event.keyCode {
            case 53: cancel()
            case 36, 49, 76:
                if let entry = selection.selectedEntry, !event.isARepeat { invoke(entry) }
            case 123: selection.move(CGPoint(x: -1, y: 0))
            case 124: selection.move(CGPoint(x: 1, y: 0))
            case 125: selection.move(CGPoint(x: 0, y: -1))
            case 126: selection.move(CGPoint(x: 0, y: 1))
            default: return event
            }
            return nil
        }) { eventMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in
            Task { @MainActor in cancel() }
        }) { eventMonitors.append(global) }
    }
}

private final class LauncherWheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct LauncherWheelEntry: Identifiable {
    let slot: WheelSlot
    let application: LauncherApplication?
    let title: String
    let symbol: String
    let icon: NSImage?
    let enabled: Bool
    var id: Int { slot.id }
}

@MainActor
private final class LauncherWheelSelection: ObservableObject {
    let entries: [LauncherWheelEntry]
    @Published var isPresented = false
    @Published private(set) var selected: Int?
    private var lastAim: Int?

    init(entries: [LauncherWheelEntry]) { self.entries = entries }

    var selectedEntry: LauncherWheelEntry? { entries.first { $0.id == selected && $0.enabled } }
    var hasActions: Bool { entries.contains(where: \.enabled) }

    func aim(_ direction: CGPoint) {
        lastAim = LauncherWheelGeometry.slot(for: direction, retaining: lastAim)
        if let lastAim { select(lastAim) }
    }

    func navigate(_ frame: ControllerButtonFrame) {
        let directions: Set<String> = ["dpadLeft", "dpadRight", "dpadDown", "dpadUp"]
        guard !directions.isDisjoint(with: frame.navigationInputs) else { return }
        let held = frame.held
        let x = CGFloat((held.contains("dpadRight") ? 1 : 0) - (held.contains("dpadLeft") ? 1 : 0))
        let y = CGFloat((held.contains("dpadUp") ? 1 : 0) - (held.contains("dpadDown") ? 1 : 0))
        move(CGPoint(x: x, y: y))
    }

    func move(_ direction: CGPoint) {
        if let next = LauncherWheelGeometry.move(direction, from: selected, among: entries.filter(\.enabled).map(\.id)) {
            select(next)
        }
    }

    func select(_ id: Int) {
        if selected != id { selected = id }
    }
}

private struct LauncherWheelView: View {
    @ObservedObject var selection: LauncherWheelSelection
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let invoke: (LauncherWheelEntry) -> Void
    let manage: () -> Void
    let cancel: () -> Void

    private var activeInk: Color {
        colorScheme == .dark ? Color(red: 0.69, green: 0.86, blue: 1) : Color(red: 0.07, green: 0.32, blue: 0.64)
    }

    var body: some View {
        GeometryReader { geometry in
            let diameter = max(0, min(geometry.size.width, geometry.size.height) - 20)
            let radius = diameter / 2
            if diameter > 0 {
                compass(radius: radius)
                    .frame(width: diameter, height: diameter)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.23), value: selection.selected)
                    .scaleEffect(selection.isPresented || reduceMotion ? 1 : 0.92)
                    .opacity(selection.isPresented ? 1 : 0)
                    .allowsHitTesting(selection.isPresented)
                    .accessibilityHidden(!selection.isPresented)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }

    @ViewBuilder
    private func compass(radius: CGFloat) -> some View {
        compassFace(radius: radius)
    }

    private func compassFace(radius: CGFloat) -> some View {
        ZStack {
            glass(Circle(), interactive: true)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ForEach(selection.entries) { entry in
                sector(entry, radius: radius)
            }

            hub(radius: radius)
        }
    }

    @ViewBuilder
    private func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            // Clear glass keeps the backdrop optically integrated without the
            // raised drop shadow that regular glass adds on white windows.
            Color.clear.glassEffect(.clear.interactive(interactive), in: shape)
        } else {
            shape
                .fill(.thinMaterial)
                .overlay { shape.stroke(.primary.opacity(0.12), lineWidth: 0.6) }
        }
    }

    private func sector(_ entry: LauncherWheelEntry, radius: CGFloat) -> some View {
        let angle = LauncherWheelGeometry.angle(entry.id)
        let active = selection.selected == entry.id
        let scale = radius / 140
        let titleWidth = abs(cos(angle)) > 0.95 ? 56.0 : 68.0
        let canvas = CGRect(x: 0, y: 0, width: 2 * radius, height: 2 * radius)
        let outline = LauncherWheelSector(id: entry.id).path(in: canvas)
        let bounds = outline.boundingRect
        let shape = outline.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let x = radius + radius * 0.713 * sin(angle) - bounds.minX
        let y = radius - radius * 0.713 * cos(angle) - bounds.minY
        let activation = UnitPoint(x: x / max(1, bounds.width), y: y / max(1, bounds.height))
        let tint = entry.enabled ? 0.22 : 0.13
        return Button {
            invoke(entry)
        } label: {
            ZStack {
                shape
                    .fill(active ? activeInk.opacity(tint) : Color.primary.opacity(entry.enabled ? 0.028 : 0.012))
                    .overlay {
                        shape.stroke(active ? activeInk.opacity(0.6) : Color.primary.opacity(0.15), lineWidth: 0.65)
                    }
                    .allowsHitTesting(false)

                Group {
                    if entry.enabled {
                        VStack(spacing: 3 * scale) {
                            if let icon = entry.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 25 * scale, height: 25 * scale)
                            } else {
                                Image(systemName: entry.symbol)
                                    .font(.system(size: 18 * scale, weight: .medium))
                                    .frame(height: 25 * scale)
                            }
                            Text(entry.title)
                                .font(.system(size: max(9, 10 * scale), weight: .medium))
                                .lineLimit(1)
                                    .frame(maxWidth: titleWidth * scale)
                        }
                        .foregroundStyle(.primary)
                        .scaleEffect(active && !reduceMotion ? 1.065 : 1)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: max(9, 11 * scale), weight: .medium))
                            .rotationEffect(.radians(angle))
                            .foregroundStyle(active ? activeInk : Color.secondary.opacity(0.62))
                    }
                }
                .position(x: x, y: y)
                .allowsHitTesting(false)
            }
            .frame(width: bounds.width, height: bounds.height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!entry.enabled)
        .help(entry.title)
        .accessibilityLabel(entry.title)
        .accessibilityActivationPoint(activation)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityHidden(!entry.enabled)
        .position(x: bounds.midX, y: bounds.midY)
    }

    private func hub(radius: CGFloat) -> some View {
        let scale = radius / 140
        let width = radius * 0.75
        return VStack(spacing: 4 * scale) {
            Text(selection.selectedEntry?.title ?? (selection.hasActions ? "快捷轮盘" : "添加动作"))
                .font(.system(size: max(10, 12 * scale), weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .contentTransition(reduceMotion ? .identity : .opacity)
            if selection.hasActions {
                Text("× 执行  ○ 取消")
                    .font(.system(size: max(8, 9 * scale), weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Button(action: manage) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 22 * scale, height: 18 * scale)
                        .contentShape(Rectangle())
                }
                .help("编辑轮盘")
                .accessibilityLabel("编辑轮盘")
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .frame(width: 22 * scale, height: 18 * scale)
                        .contentShape(Rectangle())
                }
                .help("关闭轮盘")
                .accessibilityLabel("关闭轮盘")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.system(size: max(10, 11 * scale), weight: .medium))
        }
        .frame(width: width, height: width)
        .background {
            glass(Circle())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct LauncherWheelSector: Shape {
    let id: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let outer = radius * 0.99
        let inner = radius * 0.455
        let corner = radius * 0.043
        guard radius > 0 else { return Path() }
        let angle = LauncherWheelGeometry.angle(id) - .pi / 2
        let half = LauncherWheelGeometry.step / 2 - 0.057
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
