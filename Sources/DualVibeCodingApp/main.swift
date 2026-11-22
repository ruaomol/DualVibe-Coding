import SwiftUI
import AppKit
import Combine
import CoreGraphics

enum SidebarSection: String, CaseIterable, Identifiable {
    case launcher = "启动台"
    case mapping = "按键映射"
    case combos = "组合键"
    case devices = "连接与语音"
    case permissions = "权限"

    var id: String { rawValue }

    @MainActor
    var localizedTitle: String {
        switch self {
        case .launcher: return L("启动台", "Launcher")
        case .mapping: return L("按键映射", "Mappings")
        case .combos: return L("组合键", "Combos")
        case .devices: return L("连接与语音", "Devices & Voice")
        case .permissions: return L("权限", "Permissions")
        }
    }

    var symbol: String {
        switch self {
        case .launcher: return "square.grid.2x2.fill"
        case .mapping: return "slider.horizontal.3"
        case .combos: return "command"
        case .devices: return "mic.fill"
        case .permissions: return "checkmark.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .launcher: return Color(red: 0.34, green: 0.33, blue: 0.84)
        case .mapping: return Color(red: 0.04, green: 0.48, blue: 0.98)
        case .combos: return Color(red: 0.66, green: 0.30, blue: 0.86)
        case .devices: return Color(red: 0.12, green: 0.66, blue: 0.82)
        case .permissions: return Color(red: 0.20, green: 0.76, blue: 0.35)
        }
    }
}

@MainActor
final class UIState: ObservableObject {
    @Published var selection: SidebarSection? = .mapping
    @Published var showMappingEditor = false
    @Published var showsWheelEditor = true
    private var applicationProfile: String?
    private var observations = Set<AnyCancellable>()
    private let floatingLauncher = FloatingLauncherController()
    private var openWindow: OpenWindowAction?
    private var appearance = AppAppearance.system

    func connect(store: ControllerStore, launcher: ApplicationLaunchStore, wheel: LauncherWheelStore,
                 openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        guard observations.isEmpty else { return }
        store.$launcherRequest
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self, weak store, weak launcher, weak wheel] _ in
                Task { @MainActor in
                    guard let self, let store, let launcher, let wheel else { return }
                    self.floatingLauncher.toggle(store: store, launcher: launcher, wheel: wheel,
                                                 appearance: self.appearance, onManage: self.showLauncherCatalog)
                }
            }
            .store(in: &observations)
        launcher.$foregroundBundleIdentifier
            .combineLatest(launcher.$applications)
            .sink { [weak self, weak store, weak launcher] _, _ in
                Task { @MainActor in
                    guard let self, let store, let launcher else { return }
                    self.syncProfile(store: store, launcher: launcher)
                }
            }
            .store(in: &observations)
    }

    func selectProfile(_ id: String, store: ControllerStore) {
        if id.hasPrefix("app:") {
            store.initializeApplicationProfile(id)
            applicationProfile = id
            store.applyMappingProfile(id)
        } else {
            applicationProfile = nil
            store.selectGlobalProfile(id)
            store.applyMappingProfile(nil)
        }
    }

    func presentLauncher(store: ControllerStore, launcher: ApplicationLaunchStore, wheel: LauncherWheelStore) {
        floatingLauncher.present(store: store, launcher: launcher, wheel: wheel,
                                 appearance: appearance, onManage: showLauncherCatalog)
    }

    func updateAppearance(_ appearance: AppAppearance) {
        self.appearance = appearance
        floatingLauncher.updateAppearance(appearance)
        applyMainWindowAppearance(appearance)
    }

    private func applyMainWindowAppearance(_ appearance: AppAppearance) {
        let resolved: NSAppearance.Name
        switch appearance {
        case .light:
            resolved = .aqua
        case .dark:
            resolved = .darkAqua
        case .system:
            let systemStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
            resolved = systemStyle?.caseInsensitiveCompare("Dark") == .orderedSame ? .darkAqua : .aqua
        }

        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) && window.contentView != nil {
                window.appearanceSource = nil
                window.appearance = NSAppearance(named: resolved)
                window.displayIfNeeded()
            }
        }
    }

    private func showLauncherCatalog() {
        showMappingEditor = false
        showsWheelEditor = true
        selection = .launcher
        NSApp.activate()
        openWindow?(id: "workspace", value: "main")
    }

    private func syncProfile(store: ControllerStore, launcher: ApplicationLaunchStore) {
        if let applicationProfile,
           !launcher.applications.contains(where: { $0.profileID == applicationProfile && $0.usesOwnMappings }) {
            self.applicationProfile = nil
        }
        store.applyMappingProfile(launcher.isOwnAppForeground ? applicationProfile : launcher.foregroundProfileID)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .system: return L("跟随系统", "Follow System")
        case .light: return L("浅色", "Light")
        case .dark: return L("深色", "Dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon.stars"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class DualVibeApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restoreMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        restoreMainWindow()
    }

    private func restoreMainWindow() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.contentView != nil }) else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKey()
        }
    }
}

struct AppShellView: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var i18n: LocalizationStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var ui: UIState
    @ObservedObject var launcher: ApplicationLaunchStore
    @ObservedObject var wheel: LauncherWheelStore
    @Binding var appearance: AppAppearance

    private var permissionsNeedAttention: Bool {
        !store.canPostSystemEvents || (!store.inputMonitoringTrusted && !store.bluetoothBridge.canAccessBluetooth)
    }

    var body: some View {
        let _ = i18n.language
        NavigationSplitView {
            List(selection: $ui.selection) {
                Section(L("工作台", "Workspace")) {
                    sidebarItem(.launcher)
                    sidebarItem(.mapping)
                    sidebarItem(.combos)
                }
                Section(L("设备与权限", "Device & Permissions")) {
                    sidebarItem(.devices)
                    sidebarItem(.permissions)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 252)
            .navigationTitle("DualVibe Coding")
        } detail: {
            Group {
                switch ui.selection ?? .mapping {
                case .launcher:
                    launcherWorkspace
                case .mapping:
                    MappingWorkspaceView(showMappingEditor: $ui.showMappingEditor,
                                         applications: launcher.applications.filter(\.usesOwnMappings),
                                         selectProfile: { ui.selectProfile($0, store: store) })
                case .combos:
                    CombosView(showMappingEditor: $ui.showMappingEditor)
                case .devices:
                    DevicesView()
                case .permissions:
                    PermissionsView(bridge: store.bluetoothBridge)
                }
            }
            .id("\(ui.selection?.rawValue ?? "mapping")-\(i18n.language.rawValue)")
            .transition(reduceMotion ? .identity : .opacity)
            .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: ui.selection)
            .frame(minWidth: 850, minHeight: 650)
            .toolbar {
                if ui.selection == .combos {
                    ToolbarItem(placement: .automatic) {
                        MappingProfilePicker(applications: launcher.applications.filter(\.usesOwnMappings)) {
                            ui.selectProfile($0, store: store)
                        }
                    }
                }
                ToolbarItem(placement: .automatic) {
                    ConnectionStatus(onOpenDevices: { ui.selection = .devices })
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker(L("外观", "Appearance"), selection: $appearance) {
                            ForEach(AppAppearance.allCases) { option in
                                Label(option.title, systemImage: option.symbol).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: appearance.symbol)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help(L("切换外观（当前：\(appearance.title)）", "Switch Appearance (\(appearance.title))"))
                    .accessibilityLabel(L("切换外观", "Switch Appearance"))
                }
            }
        }
        .sheet(isPresented: $ui.showMappingEditor) { MappingEditorView() }
        .alert(L("无法启动应用", "Unable to Open App"), isPresented: Binding(
            get: { launcher.launchError != nil },
            set: { if !$0 { launcher.launchError = nil } }
        )) {
            Button(L("好", "OK")) { launcher.launchError = nil }
        } message: {
            Text(launcher.launchError ?? "")
        }
        .onAppear { ui.connect(store: store, launcher: launcher, wheel: wheel, openWindow: openWindow) }
        .onChange(of: appearance, initial: true) { _, option in ui.updateAppearance(option) }
    }

    @ViewBuilder
    private func sidebarItem(_ section: SidebarSection) -> some View {
        let isSelected = (ui.selection ?? .mapping) == section
        HStack(spacing: 9) {
            DualVibeSidebarIcon(systemImage: section.symbol, tint: section.tint, isSelected: isSelected)
            Text(section.localizedTitle)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if section == .combos, !store.combos.isEmpty {
                Text("\(store.combos.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isSelected ? .white.opacity(0.92) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08), in: Capsule())
            } else if section == .permissions, permissionsNeedAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white : .orange)
                    .accessibilityLabel(L("需要授权", "Permission Required"))
            }
        }
        .padding(.vertical, 2.5)
        .tag(section)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            Button {
                ui.selection = .devices
            } label: {
                HStack(spacing: 10) {
                    DualVibeControlIcon(mappingID: "ps", size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        if let device = store.activeControllerDevice {
                            Text(device.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(store.isMouseMode ? L("映射已启用", "Mapping On") : L("映射已暂停", "Paused"))
                                Text("·")
                                Text(device.batteryText).monospacedDigit()
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(L("未连接手柄", "No Controller"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(L("连接 DualSense 自动识别", "Connect DualSense to start"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("查看 DualSense 连接与语音设置", "View DualSense connection and voice settings"))
        }
        .background(.ultraThinMaterial.opacity(0.55))
    }

    private var launcherWorkspace: some View {
        Group {
            if ui.showsWheelEditor {
                LauncherWheelEditor(wheel: wheel, launcher: launcher) {
                    ui.presentLauncher(store: store, launcher: launcher, wheel: wheel)
                }
                .transition(reduceMotion ? .identity : .opacity)
            } else {
                LauncherView(launcher: launcher, onEditMapping: { application in
                    ui.selectProfile(application.profileID, store: store)
                    ui.selection = .mapping
                })
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: ui.showsWheelEditor)
        .navigationTitle(L("启动台", "Launcher"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(L("启动台页面", "Launcher Mode"), selection: $ui.showsWheelEditor) {
                    Text(L("快捷轮盘", "Quick Wheel")).tag(true)
                    Text(L("应用库", "App Library")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 196)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    ui.presentLauncher(store: store, launcher: launcher, wheel: wheel)
                } label: {
                    Label(L("预览轮盘", "Preview Wheel"), systemImage: "viewfinder.circle")
                }
                .help(L("弹出快捷轮盘预览", "Open floating Quick Wheel preview"))
            }
        }
    }
}

struct ConnectionStatus: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var i18n: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme
    var onOpenDevices: (() -> Void)? = nil

    var body: some View {
        let _ = i18n.language
        if store.controllerDevices.count > 1 {
            Menu {
                ForEach(store.controllerDevices) { device in
                    Button { store.selectController(id: device.id) } label: {
                        Label("\(device.name) · \(device.batteryText)",
                              systemImage: device.id == store.selectedControllerID ? "checkmark" : device.batterySymbol)
                    }
                }
            } label: {
                statusPill
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L("切换手柄", "Switch Controller"))
        } else {
            Button {
                onOpenDevices?()
            } label: {
                statusPill
            }
            .buttonStyle(.plain)
            .help(store.activeControllerDevice.map { "\($0.name) · \($0.transport.localizedTitle)" }
                  ?? L("前往「连接与语音」查看手柄连接状态", "Open Devices & Voice to view controller status"))
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            if let device = store.activeControllerDevice {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DualVibePalette.lightBar(for: colorScheme))
                Text(device.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .accessibilityValue(device.transport.localizedTitle)
                DeviceBatteryIndicator(device: device)
            } else {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(L("未连接", "Disconnected"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(DualVibePalette.elevatedFill(for: colorScheme), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(DualVibePalette.hairlineBorder(for: colorScheme), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension ControllerDevice {
    var batterySymbol: String {
        if batteryState == .charging { return "battery.100percent.bolt" }
        if batteryState == .full { return "battery.100percent" }
        guard let battery else { return "battery.0percent" }
        switch battery {
        case ..<0.06: return "battery.0percent"
        case ..<0.36: return "battery.25percent"
        case ..<0.61: return "battery.50percent"
        case ..<0.86: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    @MainActor
    var localizedBatteryStatus: String {
        switch batteryState {
        case .charging: return L("充电中", "Charging")
        case .full: return L("已充满", "Full")
        case .discharging, .unknown: return battery == nil ? L("电量未知", "Battery Unknown") : ""
        }
    }
}

private struct DeviceBatteryIndicator: View {
    let device: ControllerDevice
    var showsStatus = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: device.batterySymbol)
                .foregroundStyle(symbolColor)
                .contentTransition(.symbolEffect(.replace))
            Text(device.batteryText)
                .monospacedDigit()
                .contentTransition(.numericText())
            if showsStatus, !device.localizedBatteryStatus.isEmpty {
                Text(device.localizedBatteryStatus)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(device.batteryText) \(device.localizedBatteryStatus)")
    }

    private var symbolColor: Color {
        if device.batteryState == .charging { return .green }
        if let battery = device.battery, battery <= 0.15 { return .red }
        return .secondary
    }
}

struct DevicesView: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var i18n: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCustomSpeed: Bool {
        abs(store.cursorSpeed - 1.0) > 0.01 || abs(store.scrollSpeed - 1.0) > 0.01
    }

    var body: some View {
        let _ = i18n.language
        Form {
            Section {
                if store.controllerDevices.isEmpty {
                    HStack(spacing: 14) {
                        DualVibeIconBadge(systemImage: "gamecontroller", tint: .secondary, size: 36, cornerRadius: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("等待连接 DualSense 手柄", "Waiting for DualSense Controller"))
                                .font(.headline)
                            Text(L("通过 USB-C 连接或在 macOS 蓝牙中配对后将自动识别，支持多手柄无缝切换。",
                                   "Connect via USB-C or pair in macOS Bluetooth. Multiple controllers can switch seamlessly."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 10)
                        Button(L("蓝牙设置…", "Bluetooth Settings…")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(store.controllerDevices) { device in
                        let isActive = device.id == store.selectedControllerID
                        let accent = DualVibePalette.lightBar(for: colorScheme)
                        HStack(spacing: 12) {
                            if isActive {
                                DualVibeLightBar(orientation: .vertical, length: 28, thickness: 2.5)
                            }
                            DualVibeIconBadge(
                                systemImage: "gamecontroller.fill",
                                tint: isActive ? accent : .secondary,
                                size: 34,
                                cornerRadius: 9
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.headline)
                                HStack(spacing: 6) {
                                    Text(device.transport.localizedTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("·")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    DeviceBatteryIndicator(device: device, showsStatus: true)
                                }
                            }
                            Spacer()
                            if isActive {
                                DualVibeStatusBadge(text: L("当前使用", "Active"), systemImage: "checkmark", tone: .accent)
                            } else {
                                Button(L("切换使用", "Use")) {
                                    withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                                        store.selectController(id: device.id)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel(L("切换到\(device.name)", "Switch to \(device.name)"))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text(L("DualSense 手柄", "DualSense Controllers"))
            }

            DeviceMicrophoneSection()

            Section {
                LabeledContent {
                    HStack(spacing: 12) {
                        Slider(value: $store.cursorSpeed, in: 0.2...2.0, step: 0.05)
                            .frame(maxWidth: 260)
                        Text(String(format: "%.2f×", store.cursorSpeed))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .frame(width: 46, alignment: .trailing)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("光标灵敏度", "Cursor Sensitivity"))
                        Text(L("控制摇杆与触控板移动指针的速度", "Pointer speed for analog sticks and touchpad"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    HStack(spacing: 12) {
                        Slider(value: $store.scrollSpeed, in: 0.2...2.0, step: 0.05)
                            .frame(maxWidth: 260)
                        Text(String(format: "%.2f×", store.scrollSpeed))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .frame(width: 46, alignment: .trailing)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("滚动灵敏度", "Scroll Sensitivity"))
                        Text(L("控制右摇杆与双指滑动的页面滚动速度", "Scroll speed for right stick and two-finger drag"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if isCustomSpeed {
                    HStack {
                        Spacer()
                        Button(L("恢复默认灵敏度", "Reset to Default")) {
                            withAnimation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion)) {
                                store.cursorSpeed = 1.0
                                store.scrollSpeed = 1.0
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            } header: {
                Text(L("指针与滚动", "Pointer & Scrolling"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("连接与语音", "Devices & Voice"))
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: store.controllerDevices)
        .animation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion), value: isCustomSpeed)
    }
}

struct MappingProfilePicker: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var i18n: LocalizationStore
    let applications: [LauncherApplication]
    let select: (String) -> Void

    var body: some View {
        let _ = i18n.language
        Picker(L("映射配置", "Mapping Profile"), selection: Binding(get: { store.activeProfile }, set: select)) {
            Section(L("全局配置", "Global Profiles")) {
                Text("Vibe Coding").tag("vibe")
                Text(L("桌面导航", "Desktop Navigation")).tag("desktop")
            }
            if !applications.isEmpty {
                Section(L("App 专用", "Per-App Profiles")) {
                    ForEach(applications) { application in
                        Text(application.name).tag(application.profileID)
                    }
                }
            }
        }
        .labelsHidden()
        .frame(width: 152)
        .help(L("选择要编辑的映射配置", "Select mapping profile to edit"))
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var store: ControllerStore
    @EnvironmentObject private var i18n: LocalizationStore
    @ObservedObject var bridge: DualSenseBluetoothBridge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var inputAvailable: Bool { store.inputMonitoringTrusted || bridge.canAccessBluetooth }

    private var allReady: Bool { store.canPostSystemEvents && inputAvailable }

    private var inputStatus: String {
        if store.inputMonitoringTrusted { return L("已授权", "Granted") }
        if bridge.canAccessBluetooth { return L("HID 可用", "HID Ready") }
        return store.inputMonitoringAuthorization == .denied ? L("未开启", "Disabled") : L("待授权", "Required")
    }

    private var outputStatus: String {
        if store.canPostSystemEvents { return store.accessibilityTrusted ? L("已授权", "Granted") : L("输出可用", "Ready") }
        return store.accessibilityTrusted ? L("输出未就绪", "Not Ready") : L("待授权", "Required")
    }

    private var showsSetupHelp: Bool {
        !store.canPostSystemEvents || !store.inputMonitoringTrusted
    }

    var body: some View {
        let _ = i18n.language
        Form {
            Section {
                HStack(spacing: 14) {
                    DualVibeIconBadge(
                        systemImage: allReady ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                        tint: allReady ? .green : .orange,
                        size: 38,
                        cornerRadius: 10
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(allReady
                             ? L("所有系统权限已就绪", "All macOS Permissions Ready")
                             : L("需要完成 macOS 权限授权", "macOS Permissions Required"))
                            .font(.headline)
                        Text(allReady
                             ? L("DualVibe Coding 可以正常读取 DualSense 输入并发送系统光标与快捷键事件。",
                                 "DualVibe Coding can read DualSense input and post cursor and keyboard events.")
                             : L("开启下方权限后，即可通过 DualSense 控制系统光标、快捷键与蓝牙音频。",
                                 "Enable the permissions below to control pointer, shortcuts, and Bluetooth audio."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 10)
                    Button {
                        store.refreshPermissions()
                    } label: {
                        Label(L("重新检查", "Recheck"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 6)
            }

            Section(L("macOS 系统权限", "macOS Permissions")) {
                outputRow
                inputRow
            }

            Section(L("应用语言", "Language")) {
                HStack(spacing: 12) {
                    DualVibeIconBadge(systemImage: "globe", tint: .blue, size: 32, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 2.5) {
                        Text(L("界面语言", "Interface Language"))
                            .font(.headline)
                        Text(L("立即切换简体中文或英文界面，无需重启应用",
                               "Switch between Simplified Chinese and English instantly"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 10)
                    Picker(L("界面语言", "Interface Language"), selection: $i18n.language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 156)
                }
                .padding(.vertical, 4)
            }

            if showsSetupHelp {
                Section(L("授权排查说明", "Troubleshooting")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text(L("列表里没有 DualVibe Coding 时，点击系统设置底部的「+」并选择当前 App。如果开关已打开但检查仍未通过，请先移除旧条目，再重新添加当前 App。",
                                   "If DualVibe Coding is missing from the list, click “+” in System Settings and select this app. If enabled yet still unverified, remove the old entry and add it again."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Spacer()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            } label: {
                                Label(L("在访达中显示当前 App", "Show App in Finder"), systemImage: "folder")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("权限", "Permissions"))
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: allReady)
    }

    private var outputRow: some View {
        PermissionRow(title: L("辅助功能", "Accessibility"),
                      detail: L("控制系统光标、鼠标点击与全局快捷键", "Control cursor, mouse clicks, and global shortcuts"),
                      icon: "accessibility", tint: .blue,
                      status: outputStatus, available: store.canPostSystemEvents,
                      showsRequest: !store.canPostSystemEvents,
                      request: { store.requestOutputAuthorization() },
                      openSettings: { store.openAccessibilitySettings() })
    }

    private var inputRow: some View {
        PermissionRow(title: L("输入监控", "Input Monitoring"),
                      detail: L("读取 DualSense 蓝牙与 USB HID 按键及触控板信号", "Read DualSense Bluetooth & USB HID buttons and touchpad"),
                      icon: "gamecontroller.fill", tint: .indigo,
                      status: inputStatus, available: inputAvailable,
                      showsRequest: !store.inputMonitoringTrusted,
                      request: { store.requestInputAuthorization() },
                      openSettings: { store.openInputMonitoringSettings() })
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let status: String
    let available: Bool
    let showsRequest: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            DualVibeIconBadge(systemImage: icon, tint: tint, size: 32, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2.5) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            DualVibeStatusBadge(
                text: status,
                systemImage: available ? "checkmark.circle.fill" : "exclamationmark.circle",
                tone: available ? .positive : .warning
            )
            if showsRequest {
                Button(L("申请授权…", "Request…"), action: request)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityLabel(L("申请\(title)授权", "Request \(title)"))
            }
            Button(L("打开设置", "Open Settings"), action: openSettings)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityLabel(L("打开\(title)设置", "Open \(title) Settings"))
        }
        .padding(.vertical, 4)
    }
}

@main
struct DualVibeCodingApp: App {
    @NSApplicationDelegateAdaptor(DualVibeApplicationDelegate.self) private var appDelegate
    @StateObject private var store = ControllerStore()
    @StateObject private var ui = UIState()
    @StateObject private var launcher = ApplicationLaunchStore()
    @StateObject private var wheel = LauncherWheelStore()
    @ObservedObject private var i18n = LocalizationStore.shared
    @AppStorage("dualVibeAppearance") private var appearance = AppAppearance.system

    var body: some Scene {
        WindowGroup("DualVibe Coding", id: "workspace", for: String.self) { _ in
            AppShellView(ui: ui, launcher: launcher, wheel: wheel, appearance: $appearance)
                .environmentObject(store)
                .environmentObject(store.microphone)
                .environmentObject(i18n)
                .preferredColorScheme(appearance.scheme)
        } defaultValue: {
            "main"
        }
        .defaultSize(width: 1120, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
