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
    var symbol: String {
        switch self {
        case .launcher: return "square.grid.2x2"
        case .mapping: return "slider.horizontal.3"
        case .combos: return "command"
        case .devices: return "mic.and.signal.meter"
        case .permissions: return "checkmark.shield"
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
            for window in NSApp.windows where window.title == "DualVibe Coding" {
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

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
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
            guard let window = NSApp.windows.first(where: { $0.title == "DualVibe Coding" }) else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKey()
        }
    }
}

struct AppShellView: View {
    @EnvironmentObject private var store: ControllerStore
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var ui: UIState
    @ObservedObject var launcher: ApplicationLaunchStore
    @ObservedObject var wheel: LauncherWheelStore
    @Binding var appearance: AppAppearance

    var body: some View {
        NavigationSplitView {
            List(selection: $ui.selection) {
                Section("工作台") {
                    sidebarItem(.launcher)
                    sidebarItem(.mapping)
                    sidebarItem(.combos)
                }
                Section("设备与权限") {
                    sidebarItem(.devices)
                    sidebarItem(.permissions)
                }
            }
            .listStyle(.sidebar)
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
                case .combos: CombosView(showMappingEditor: $ui.showMappingEditor)
                case .devices: DevicesView()
                case .permissions: PermissionsView(bridge: store.bluetoothBridge)
                }
            }
            .frame(minWidth: 850, minHeight: 650)
            .toolbar {
                if ui.selection == .combos {
                    ToolbarItem(placement: .automatic) {
                        MappingProfilePicker(applications: launcher.applications.filter(\.usesOwnMappings)) {
                            ui.selectProfile($0, store: store)
                        }
                    }
                }
                ToolbarItem(placement: .automatic) { ConnectionStatus() }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("外观", selection: $appearance) {
                            ForEach(AppAppearance.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("外观", systemImage: "circle.lefthalf.filled")
                    }
                    .help("切换外观")
                }
            }
        }
        .sheet(isPresented: $ui.showMappingEditor) { MappingEditorView() }
        .alert("无法启动应用", isPresented: Binding(
            get: { launcher.launchError != nil },
            set: { if !$0 { launcher.launchError = nil } }
        )) {
            Button("好") { launcher.launchError = nil }
        } message: {
            Text(launcher.launchError ?? "")
        }
        .onAppear { ui.connect(store: store, launcher: launcher, wheel: wheel, openWindow: openWindow) }
        .onChange(of: appearance, initial: true) { _, option in ui.updateAppearance(option) }
    }

    private func sidebarItem(_ section: SidebarSection) -> some View {
        Label(section.rawValue, systemImage: section.symbol).tag(section)
    }

    private var launcherWorkspace: some View {
        Group {
            if ui.showsWheelEditor {
                LauncherWheelEditor(wheel: wheel, launcher: launcher)
            } else {
                LauncherView(launcher: launcher, onEditMapping: { application in
                    ui.selectProfile(application.profileID, store: store)
                    ui.selection = .mapping
                })
            }
        }
        .navigationTitle("启动台")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("启动台页面", selection: $ui.showsWheelEditor) {
                    Text("快捷轮盘").tag(true)
                    Text("应用库").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Button("打开轮盘", systemImage: "circle.dotted") {
                    ui.presentLauncher(store: store, launcher: launcher, wheel: wheel)
                }
                .help("打开快捷轮盘")
            }
        }
    }
}

struct ConnectionStatus: View {
    @EnvironmentObject private var store: ControllerStore

    var body: some View {
        if store.controllerDevices.count > 1 {
            Menu {
                ForEach(store.controllerDevices) { device in
                    Button { store.selectController(id: device.id) } label: {
                        Label("\(device.name) · \(device.batteryText)",
                              systemImage: device.id == store.selectedControllerID ? "checkmark" : device.batterySymbol)
                    }
                }
            } label: {
                currentDevice
            }
            .accessibilityLabel("切换手柄")
        } else {
            currentDevice
        }
    }

    private var currentDevice: some View {
        HStack(spacing: 8) {
            if let device = store.activeControllerDevice {
                Text(device.name).lineLimit(1)
                    .accessibilityValue(device.transport.title)
                DeviceBatteryIndicator(device: device)
            } else {
                Label("未连接手柄", systemImage: "battery.0percent")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
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

    var batteryStatus: String {
        switch batteryState {
        case .charging: return "充电中"
        case .full: return "已充满"
        case .discharging, .unknown: return battery == nil ? "电量未知" : ""
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
            Text(device.batteryText)
                .monospacedDigit()
            if showsStatus, !device.batteryStatus.isEmpty {
                Text(device.batteryStatus)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(device.batteryText) \(device.batteryStatus)")
    }

    private var symbolColor: Color {
        if device.batteryState == .charging { return .green }
        if let battery = device.battery, battery <= 0.15 { return .red }
        return .secondary
    }
}

struct DevicesView: View {
    @EnvironmentObject private var store: ControllerStore

    var body: some View {
        Form {
            Section("手柄") {
                if store.controllerDevices.isEmpty {
                    Label("等待连接手柄", systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.controllerDevices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "gamecontroller")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.headline)
                            Text(device.transport.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        DeviceBatteryIndicator(device: device, showsStatus: true)
                        if device.id == store.selectedControllerID {
                            Label("当前", systemImage: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .font(.caption.weight(.semibold))
                        } else {
                            Button("切换") { store.selectController(id: device.id) }
                                .controlSize(.small)
                                .accessibilityLabel("切换到\(device.name)")
                        }
                    }
                }
            }

            DeviceMicrophoneSection()

            Section("指针与滚动") {
                Slider(value: $store.cursorSpeed, in: 0.2...2.0) { Text("光标灵敏度") }
                Slider(value: $store.scrollSpeed, in: 0.2...2.0) { Text("滚动灵敏度") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("连接与语音")
    }
}

struct MappingProfilePicker: View {
    @EnvironmentObject private var store: ControllerStore
    let applications: [LauncherApplication]
    let select: (String) -> Void

    var body: some View {
        Picker("映射配置", selection: Binding(get: { store.activeProfile }, set: select)) {
            Section("全局配置") {
                Text("Vibe Coding").tag("vibe")
                Text("桌面导航").tag("desktop")
            }
            if !applications.isEmpty {
                Section("App 专用") {
                    ForEach(applications) { application in
                        Text(application.name).tag(application.profileID)
                    }
                }
            }
        }
        .labelsHidden()
        .frame(width: 148)
        .help("选择要编辑的映射配置")
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var store: ControllerStore
    @ObservedObject var bridge: DualSenseBluetoothBridge

    private var inputAvailable: Bool { store.inputMonitoringTrusted || bridge.canAccessBluetooth }

    private var inputStatus: String {
        if store.inputMonitoringTrusted { return "已授权" }
        if bridge.canAccessBluetooth { return "HID 可用" }
        return store.inputMonitoringAuthorization == .denied ? "未开启" : "待授权"
    }

    private var outputStatus: String {
        if store.canPostSystemEvents { return store.accessibilityTrusted ? "已授权" : "输出可用" }
        return store.accessibilityTrusted ? "输出未就绪" : "待授权"
    }

    private var showsSetupHelp: Bool {
        !store.canPostSystemEvents || !store.inputMonitoringTrusted
    }

    var body: some View {
        Form {
            Section("macOS 权限") {
                outputRow
                inputRow
                permissionActions
            }
            if showsSetupHelp {
                Section {
                    Text("列表里没有 DualVibe Coding 时，点「+」并选择当前 App。开关已开但检查仍未通过时，移除旧条目，再添加当前 App。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(28)
        .navigationTitle("权限")
    }

    private var outputRow: some View {
        PermissionRow(title: "辅助功能", detail: "控制系统光标、鼠标和快捷键",
                      status: outputStatus, available: store.canPostSystemEvents,
                      showsRequest: !store.canPostSystemEvents,
                      request: { store.requestOutputAuthorization() },
                      openSettings: { store.openAccessibilitySettings() })
    }

    private var inputRow: some View {
        PermissionRow(title: "输入监控", detail: "读取 DualSense 蓝牙 HID",
                      status: inputStatus, available: inputAvailable,
                      showsRequest: !store.inputMonitoringTrusted,
                      request: { store.requestInputAuthorization() },
                      openSettings: { store.openInputMonitoringSettings() })
    }

    private var permissionActions: some View {
        HStack {
            Button("重新检查") { store.refreshPermissions() }
            if showsSetupHelp {
                Button("在访达中显示当前 App") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
        }
        .controlSize(.small)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let status: String
    let available: Bool
    let showsRequest: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(status, systemImage: available ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(available ? Color.green : Color.secondary)
            if showsRequest {
                Button("申请授权…", action: request)
                    .accessibilityLabel("申请\(title)授权")
            }
            Button("打开设置", action: openSettings)
                .accessibilityLabel("打开\(title)设置")
        }
    }
}

@main
struct DualVibeCodingApp: App {
    @NSApplicationDelegateAdaptor(DualVibeApplicationDelegate.self) private var appDelegate
    @StateObject private var store = ControllerStore()
    @StateObject private var ui = UIState()
    @StateObject private var launcher = ApplicationLaunchStore()
    @StateObject private var wheel = LauncherWheelStore()
    @AppStorage("dualVibeAppearance") private var appearance = AppAppearance.system

    var body: some Scene {
        WindowGroup("DualVibe Coding", id: "workspace", for: String.self) { _ in
            AppShellView(ui: ui, launcher: launcher, wheel: wheel, appearance: $appearance)
                .environmentObject(store)
                .environmentObject(store.microphone)
                .preferredColorScheme(appearance.scheme)
        } defaultValue: {
            "main"
        }
        .defaultSize(width: 1120, height: 760)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
