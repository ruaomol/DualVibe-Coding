import AppKit
import ApplicationServices
import Combine
import GameController
import IOKit.hidsystem
import SwiftUI

enum InputMonitoringAuthorization: Equatable {
    case granted
    case denied
    case notDetermined

    static var current: Self {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }
}

private struct ControllerPermissions: Equatable {
    let accessibilityTrusted = AXIsProcessTrusted()
    let canPostSystemEvents = CGPreflightPostEventAccess()
    let inputMonitoringAuthorization = InputMonitoringAuthorization.current
}

@MainActor
final class ControllerStore: ObservableObject {
    @Published private(set) var controllerDevices: [ControllerDevice] = []
    @Published private(set) var selectedControllerID: String?
    @Published var isMouseMode = true {
        didSet {
            UserDefaults.standard.set(isMouseMode, forKey: "mappingsEnabled")
            if oldValue != isMouseMode {
                cancelOutput()
                updateRealtimeActivity()
            }
        }
    }
    @Published var testMode = false {
        didSet { if oldValue != testMode { cancelOutput() } }
    }
    var isEditingMapping = false {
        didSet { if oldValue != isEditingMapping { cancelOutput() } }
    }
    var isLauncherActive = false {
        didSet {
            guard oldValue != isLauncherActive else { return }
            cancelOutput()
            resetLauncherStick()
        }
    }
    @Published private(set) var launcherRequest: UUID?
    private let launcherStickSubject = CurrentValueSubject<CGPoint, Never>(.zero)
    var launcherStick: CGPoint { launcherStickSubject.value }
    var launcherAim: AnyPublisher<CGPoint, Never> { launcherStickSubject.eraseToAnyPublisher() }
    @Published private(set) var lastInput = "等待手柄输入"
    @Published private(set) var activeInput: String?
    @Published private(set) var lastPhysicalPress: PhysicalPress?
    @Published private(set) var physicalInput: ControllerButtonFrame?
    @Published var cursorSpeed: Double = 1
    @Published var scrollSpeed: Double = 1
    @Published private var permissions = ControllerPermissions()
    var accessibilityTrusted: Bool { permissions.accessibilityTrusted }
    var canPostSystemEvents: Bool { permissions.canPostSystemEvents }
    var inputMonitoringAuthorization: InputMonitoringAuthorization { permissions.inputMonitoringAuthorization }
    var inputMonitoringTrusted: Bool { inputMonitoringAuthorization == .granted }
    @Published var selectedMappingID = "leftStick"
    @Published var followHardwareSelection = false
    @Published private(set) var globalProfile = "vibe"
    @Published private(set) var activeProfile = "vibe"
    @Published private(set) var mappings = ButtonMapping.defaults {
        didSet { mappingConflicts = MappingConflicts(mappings) }
    }
    @Published private(set) var combos: [ControllerCombo] = []

    let microphone = MicrophoneManager()
    let bluetoothBridge = DualSenseBluetoothBridge()

    private var controller: GCController?
    private var fallbackIDs: [ObjectIdentifier: String] = [:]
    private var fallbackControllers: [String: GCController] = [:]
    private var deviceNumbers: [String: Int] = [:]
    private var preferredControllerID = UserDefaults.standard.string(forKey: "preferredControllerDevice")
    private var lastBatteryCheck: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var waitingForPrivacySettingsReturn = false
    private var permissionRefreshAfterSettings: Task<Void, Never>?
    private var stickTimer: DispatchSourceTimer?
    private var lastStickTickAt: TimeInterval?
    private var batteryTimer: Timer?
    private var pointer = PointerMotion()
    private var pointerTimer: DispatchSourceTimer?
    private var realtimeActivity: NSObjectProtocol?
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private lazy var displayBounds = Self.activeDisplayBounds()
    private var leftStick = CGPoint.zero
    private var rightStick = CGPoint.zero
    private enum LauncherStickSide { case left, right }
    private var launcherStickSide: LauncherStickSide?
    private var pressed = Set<String>()
    // Keep analog direction edges independent from physical button edges.
    // A stick can stay active while a button is pressed without the two
    // streams competing for chord ordering or click recognition.
    private var axisDirections = Set<String>()
    private var pressBatch: UInt64 = 0
    private var buttonPressOrder: [String: UInt64] = [:]
    private var lastTouchpadPressMappingID: String?
    private var touchpadUsedAsModifier = false
    private var mappingConflicts = MappingConflicts(ButtonMapping.defaults)
    private var applicationProfile: String?
    private var inputPrimed = false
    private var holds: [String: Task<Void, Never>] = [:]
    private var pendingTaps: [String: Task<Void, Never>] = [:]
    private var comboPresses: [String: ComboPress] = [:]
    private var pendingComboTaps: [ComboInput: Task<Void, Never>] = [:]
    private var consumedPresses = Set<String>()
    private var precisionSources = Set<String>()
    private var voiceSources = Set<String>()
    private enum MousePressOwner: Equatable {
        case controller(trigger: String, modifier: String?)
        case touchpadDrag
        case timed
    }

    private struct MousePress {
        let owner: MousePressOwner
        let button: CGMouseButton
        let eventNumber: Int64
        let clickCount: Int
        let clickStart: (time: TimeInterval, point: CGPoint)?
        var movedBeyondClickDistance = false
    }

    private var mousePress: MousePress?
    private var mouseEventNumber: Int64 = 0
    private var mouseReleaseTask: Task<Void, Never>?
    private var touch = TouchpadGestureRecognizer()
    private var touchHoldFired = false
    private var touchScrollRemainder = CGPoint.zero
    private var lastMouseClick: (time: TimeInterval, point: CGPoint, button: CGMouseButton, count: Int)?

    var selectedMapping: ButtonMapping? { mapping(selectedMappingID) }
    var activeControllerDevice: ControllerDevice? { controllerDevices.first { $0.id == selectedControllerID } }
    var connected: Bool { activeControllerDevice != nil }
    var controllerName: String {
        activeControllerDevice.map { "\($0.name) · \($0.transport.title)" } ?? "等待连接"
    }
    var batteryText: String { activeControllerDevice?.batteryText ?? "—" }

    init() {
        let defaults = UserDefaults.standard
        globalProfile = defaults.string(forKey: "activeMappingProfile") == "desktop" ? "desktop" : "vibe"
        activeProfile = globalProfile
        mappings = Self.loadMappings(activeProfile)
        combos = Self.loadCombos(activeProfile)
        mappingConflicts = MappingConflicts(mappings)
        isMouseMode = defaults.object(forKey: "mappingsEnabled") as? Bool ?? true
        microphone.bluetoothBridge = bluetoothBridge
        bluetoothBridge.onDevicesChanged = { [weak self] in
            self?.refreshControllers()
        }
        bluetoothBridge.onInputSample = { [weak self] id, sample in
            self?.receiveInput(sample, controllerID: id)
        }
        GCController.shouldMonitorBackgroundEvents = true
        observeApplicationActivation()
        observeControllers()
        observeDisplays()
        bluetoothBridge.start()
        refreshControllers()
        updateRealtimeActivity()
    }

    deinit {
        permissionRefreshAfterSettings?.cancel()
        pointerTimer?.cancel()
        mouseReleaseTask?.cancel()
        stickTimer?.cancel()
        batteryTimer?.invalidate()
        if let realtimeActivity { ProcessInfo.processInfo.endActivity(realtimeActivity) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func updateRealtimeActivity() {
        let shouldKeepResponsive = connected && isMouseMode
        if shouldKeepResponsive {
            guard realtimeActivity == nil else { return }
            realtimeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Real-time DualSense controller pointer, click, and shortcut mapping"
            )
        } else if let activity = realtimeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            realtimeActivity = nil
        }
    }

    private var needsContinuousStickOutput: Bool {
        guard outputEnabled, connected else { return false }
        return ["leftStick", "rightStick"].contains {
            mapping($0)?[.tap].action.isContinuous == true
        }
    }

    private func updateStickTimer() {
        let stickIsActive = hypot(leftStick.x, leftStick.y) > 0.14
            || hypot(rightStick.x, rightStick.y) > 0.14
        if stickIsActive && needsContinuousStickOutput {
            startStickTimer()
        } else {
            stopStickTimer()
        }
    }

    private func startStickTimer() {
        guard stickTimer == nil else { return }
        lastStickTickAt = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + .nanoseconds(8_333_333),
                       repeating: .nanoseconds(8_333_333),
                       leeway: .nanoseconds(1_000_000))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tickStickOutput() }
        }
        stickTimer = timer
        timer.resume()
    }

    private func stopStickTimer() {
        stickTimer?.cancel()
        stickTimer = nil
        lastStickTickAt = nil
    }

    private func cancelPointerTimer() {
        pointerTimer?.cancel()
        pointerTimer = nil
    }

    func mapping(_ id: String) -> ButtonMapping? { mappings.first { $0.id == id } }

    func selectGlobalProfile(_ profile: String) {
        guard ["vibe", "desktop"].contains(profile), globalProfile != profile else { return }
        globalProfile = profile
        UserDefaults.standard.set(profile, forKey: "activeMappingProfile")
        if applicationProfile == nil { applyMappingProfile(nil) }
    }

    func initializeApplicationProfile(_ profile: String) {
        guard !profile.isEmpty, !["vibe", "desktop"].contains(profile) else { return }
        let defaults = UserDefaults.standard
        let mappingKey = "mappingProfile.\(profile)"
        guard defaults.data(forKey: mappingKey) == nil else { return }
        let encoder = JSONEncoder()
        guard let mappings = try? encoder.encode(Self.loadMappings(globalProfile)),
              let combos = try? encoder.encode(Self.loadCombos(globalProfile)) else { return }
        defaults.set(mappings, forKey: mappingKey)
        defaults.set(combos, forKey: "comboProfile.\(profile)")
    }

    func applyMappingProfile(_ profile: String?) {
        applicationProfile = profile.flatMap { candidate in
            guard !["vibe", "desktop"].contains(candidate),
                  UserDefaults.standard.data(forKey: "mappingProfile.\(candidate)") != nil else { return nil }
            return candidate
        }
        let next = applicationProfile ?? globalProfile
        guard activeProfile != next else { return }
        cancelOutput()
        activeProfile = next
        mappings = Self.loadMappings(next)
        combos = Self.loadCombos(next)
    }

    func title(for binding: MappingBinding) -> String {
        guard binding.action == .runCombo else { return binding.title }
        return combos.first { $0.id == binding.comboID }?.name ?? "选择组合键"
    }

    func canRunLauncherAction(_ binding: MappingBinding) -> Bool {
        guard binding.isConfigured else { return false }
        if binding.action == .runCombo {
            guard let combo = combos.first(where: { $0.id == binding.comboID }), combo.actionIsValid else {
                return false
            }
            return canRunLauncherAction(combo.binding)
        }
        return binding.action != .showLauncher && !binding.action.isContinuous && !binding.action.followsPress
    }

    @discardableResult
    func runLauncherAction(_ binding: MappingBinding) -> Bool {
        guard outputEnabled, canRunLauncherAction(binding) else { return false }
        perform(binding, source: "launcher")
        return true
    }

    func canSaveCombo(_ combo: ControllerCombo) -> Bool {
        !combo.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            combo.actionIsValid && comboValidationIssue(combo) == nil
    }

    func comboConflict(_ combo: ControllerCombo) -> String? {
        if let issue = comboValidationIssue(combo) { return issue }
        let hasReverseCombo = combos.contains {
            $0.id != combo.id && $0.triggerControl == combo.modifierControl &&
                $0.modifierControl == combo.triggerControl
        }
        let hasReverseMapping = mappings.contains { row in
            ControllerCombo.control(for: row.id) == combo.modifierControl &&
                row.editableGestures.contains {
                    row[$0].isConfigured && row[$0].modifierID == combo.triggerControl
                }
        }
        return hasReverseCombo || hasReverseMapping ? "同时按下时与反向组合重叠" : nil
    }

    private func comboValidationIssue(_ combo: ControllerCombo) -> String? {
        guard ControllerCombo.mayPair(combo.modifierID, combo.triggerID),
              mapping(combo.triggerID) != nil else { return "选择可同时按下的两颗按键" }
        let duplicate = combos.contains {
            $0.id != combo.id && $0.triggerID == combo.triggerID &&
                $0.modifierControl == combo.modifierControl && $0.gesture == combo.gesture
        }
        let existing = mapping(combo.triggerID)?[combo.gesture]
        let duplicatesMapping = existing?.isConfigured == true && existing?.modifierID == combo.modifierControl
        return duplicate || duplicatesMapping ? "此组合和手势已有映射" : nil
    }

    @discardableResult
    func saveCombo(_ combo: ControllerCombo) -> Bool {
        guard canSaveCombo(combo) else { return false }
        var combo = combo
        combo.name = combo.name.trimmingCharacters(in: .whitespacesAndNewlines)
        combo.binding.modifierID = nil
        combo.binding.comboID = nil
        cancelOutput()
        if let index = combos.firstIndex(where: { $0.id == combo.id }) {
            combos[index] = combo
        } else {
            combos.append(combo)
        }
        saveCombos()
        return true
    }

    func removeCombo(id: UUID) {
        guard combos.contains(where: { $0.id == id }) else { return }
        cancelOutput()
        combos.removeAll { $0.id == id }
        for index in mappings.indices {
            for gesture in mappings[index].editableGestures {
                let binding = mappings[index][gesture]
                if binding.action == .runCombo, binding.comboID == id {
                    mappings[index][gesture] = MappingBinding()
                }
            }
        }
        saveCombos()
        saveMappings()
    }

    func updateBinding(_ binding: MappingBinding, for id: String, gesture: GestureKind) {
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        cancelOutput()
        mappings[index][gesture] = binding
        saveMappings()
        updateStickTimer()
    }

    func restoreDefaults() {
        cancelOutput()
        mappings = Self.defaultMappings(applicationProfile == nil ? activeProfile : globalProfile)
        saveMappings()
    }

    private func saveMappings() {
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: "mappingProfile.\(activeProfile)")
        }
    }

    private func saveCombos() {
        if let data = try? JSONEncoder().encode(combos) {
            UserDefaults.standard.set(data, forKey: "comboProfile.\(activeProfile)")
        }
    }

    private static func loadCombos(_ profile: String) -> [ControllerCombo] {
        guard let data = UserDefaults.standard.data(forKey: "comboProfile.\(profile)"),
              let saved = try? JSONDecoder().decode([ControllerCombo].self, from: data) else { return [] }
        return saved.filter { $0.actionIsValid && ControllerCombo.mayPair($0.modifierID, $0.triggerID) }
    }

    private static func loadMappings(_ profile: String) -> [ButtonMapping] {
        let defaults = defaultMappings(profile)
        guard let data = UserDefaults.standard.data(forKey: "mappingProfile.\(profile)"),
              let saved = try? JSONDecoder().decode([ButtonMapping].self, from: data) else { return defaults }
        return ButtonMapping.restoring(saved, to: defaults)
    }

    private static func defaultMappings(_ profile: String) -> [ButtonMapping] {
        var rows = ButtonMapping.defaults
        if profile == "desktop" {
            for index in rows.indices where ["triangle", "r1"].contains(rows[index].id) {
                rows[index][.tap] = MappingBinding()
            }
        }
        return rows
    }

    func toggleMouseMode() { isMouseMode.toggle() }

    func refreshPermissions() {
        updatePermissions()
        retryBluetoothIfAuthorized()
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        waitingForPrivacySettingsReturn = NSWorkspace.shared.open(url)
    }

    private func observeApplicationActivation() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelOutput()
                if let activity = self?.realtimeActivity {
                    ProcessInfo.processInfo.endActivity(activity)
                    self?.realtimeActivity = nil
                }
            }
        })
    }

    private func applicationDidBecomeActive() {
        let previouslyAuthorized = inputMonitoringTrusted
        updatePermissions()
        if !previouslyAuthorized { retryBluetoothIfAuthorized() }

        guard waitingForPrivacySettingsReturn else { return }
        waitingForPrivacySettingsReturn = false
        permissionRefreshAfterSettings?.cancel()
        permissionRefreshAfterSettings = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, NSApp.isActive else { return }
            let previouslyAuthorized = self.inputMonitoringTrusted
            self.updatePermissions()
            if !previouslyAuthorized { self.retryBluetoothIfAuthorized() }
        }
    }

    private func updatePermissions() {
        let current = ControllerPermissions()
        if current != permissions { permissions = current }
    }

    private func retryBluetoothIfAuthorized() {
        guard inputMonitoringTrusted, !bluetoothBridge.canAccessBluetooth else { return }
        bluetoothBridge.stop()
        bluetoothBridge.start()
        refreshControllers()
    }

    private func observeControllers() {
        for event in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: event, object: nil, queue: .main) { [weak self] note in
                guard let device = note.object as? GCController else { return }
                MainActor.assumeIsolated {
                    if event == .GCControllerDidConnect {
                        self?.refreshControllers(including: device)
                    } else {
                        self?.refreshControllers(excluding: device)
                    }
                }
            })
        }
    }

    private func refreshControllers(including included: GCController? = nil, excluding excluded: GCController? = nil) {
        let rawDevices = bluetoothBridge.devices.filter(\.acceptsInput)
        let known = Dictionary(controllerDevices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let system = GCController.controllers().filter { $0 !== excluded && $0.extendedGamepad is GCDualSenseGamepad }
        let fallback = if let included, included.extendedGamepad is GCDualSenseGamepad,
                          !system.contains(where: { $0 === included }) {
            system + [included]
        } else { system }

        // GameController doesn't expose a hardware identifier for correlation.
        // Prefer the device-specific HID inventory to avoid listing the same pad twice.
        var list: [ControllerDevice] = rawDevices.map { device in
            known[device.id] ?? describeController(id: device.id, transport: device.isBluetooth ? .bluetooth : .usb)
        }

        let liveObjects = Set(fallback.map(ObjectIdentifier.init))
        fallbackIDs = fallbackIDs.filter { liveObjects.contains($0.key) }
        fallbackControllers.removeAll()
        if rawDevices.isEmpty {
            for device in fallback {
                let object = ObjectIdentifier(device)
                let id = fallbackIDs[object] ?? "system:\(UUID().uuidString)"
                fallbackIDs[object] = id
                fallbackControllers[id] = device
                list.append(known[id] ?? describeController(id: id, transport: .system))
            }
        }

        list.sort { deviceNumbers[$0.id, default: 0] < deviceNumbers[$1.id, default: 0] }
        if list != controllerDevices { controllerDevices = list }
        let next = ControllerDevice.activeID(in: list, preferred: preferredControllerID, current: selectedControllerID)
        setActiveController(next)
        updateBatteryTimer()
        refreshFallbackBattery()
    }

    private func updateBatteryTimer() {
        guard !fallbackControllers.isEmpty else {
            batteryTimer?.invalidate()
            batteryTimer = nil
            return
        }
        guard batteryTimer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFallbackBattery() }
        }
        batteryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func describeController(id: String, transport: ControllerDevice.Transport) -> ControllerDevice {
        let number = deviceNumbers[id] ?? deviceNumbers.count + 1
        deviceNumbers[id] = number
        return ControllerDevice(id: id, name: "DualSense \(number)", transport: transport)
    }

    func selectController(id: String) {
        guard controllerDevices.contains(where: { $0.id == id }) else { return }
        preferredControllerID = id
        if bluetoothBridge.devices.contains(where: { $0.id == id && $0.stableID }) {
            UserDefaults.standard.set(id, forKey: "preferredControllerDevice")
        } else {
            UserDefaults.standard.removeObject(forKey: "preferredControllerDevice")
        }
        setActiveController(id)
    }

    private func setActiveController(_ id: String?) {
        guard selectedControllerID != id else { return }
        resetActiveInput()
        selectedControllerID = id
        let fallback = id.flatMap { fallbackControllers[$0] }
        bluetoothBridge.selectDevice(id: fallback == nil ? id : nil)
        if let fallback { attach(fallback) }
        lastInput = id == nil ? "手柄已断开" : "等待所选手柄输入"
        updatePermissions()
        updateRealtimeActivity()
    }

    private func attach(_ device: GCController) {
        guard let gamepad = device.extendedGamepad as? GCDualSenseGamepad else { return }
        controller = device
        device.handlerQueue = .main

        let buttons: [String: GCControllerButtonInput?] = [
            "cross": gamepad.buttonA, "circle": gamepad.buttonB, "square": gamepad.buttonX,
            "triangle": gamepad.buttonY, "l1": gamepad.leftShoulder, "r1": gamepad.rightShoulder,
            "l2": gamepad.leftTrigger, "r2": gamepad.rightTrigger,
            "l3": gamepad.leftThumbstickButton, "r3": gamepad.rightThumbstickButton,
            "dpadUp": gamepad.dpad.up, "dpadRight": gamepad.dpad.right,
            "dpadDown": gamepad.dpad.down, "dpadLeft": gamepad.dpad.left,
            "create": gamepad.buttonOptions, "options": gamepad.buttonMenu,
            "ps": gamepad.buttonHome, "touchpad": gamepad.touchpadButton
        ]
        let available = buttons.compactMapValues { $0 }
        let report: () -> Void = { [weak self, weak device, weak gamepad] in
            guard let self, let device, self.controller === device, let gamepad else { return }
            let primary = Self.point(gamepad.touchpadPrimary)
            let secondary = Self.point(gamepad.touchpadSecondary)
            let contacts: [Int: CGPoint] = [
                (0, primary), (1, secondary)
            ].filter { $0.1 != .zero }.reduce(into: [:]) { $0[$1.0] = $1.1 }
            let down = Set(available.filter { $0.value.isPressed }.keys)
            self.receiveInput(buttons: down, left: Self.point(gamepad.leftThumbstick),
                              right: Self.point(gamepad.rightThumbstick), contacts: contacts)
        }
        gamepad.valueChangedHandler = { _, _ in
            MainActor.assumeIsolated { report() }
        }
        report()
    }

    private static func point(_ pad: GCControllerDirectionPad) -> CGPoint {
        CGPoint(x: CGFloat(pad.xAxis.value), y: CGFloat(pad.yAxis.value))
    }

    private func resetActiveInput() {
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        cancelOutput()
        microphone.endSystemInput()
        pressed.removeAll()
        axisDirections.removeAll()
        consumedPresses.removeAll()
        pressBatch = 0
        buttonPressOrder.removeAll()
        lastTouchpadPressMappingID = nil
        inputPrimed = false
        leftStick = .zero
        rightStick = .zero
        resetLauncherStick()
        lastMouseClick = nil
        activeInput = nil
        lastPhysicalPress = nil
        physicalInput = nil
    }

    private func refreshFallbackBattery() {
        for (id, device) in fallbackControllers {
            guard let battery = device.battery else { continue }
            let state: ControllerDevice.BatteryState
            switch battery.batteryState {
            case .charging: state = .charging
            case .full: state = .full
            case .discharging: state = .discharging
            default: state = .unknown
            }
            updateBattery(for: id, level: Double(battery.batteryLevel), state: state)
        }
    }

    private func updateBattery(for id: String, level: Double?, state: ControllerDevice.BatteryState) {
        guard let index = controllerDevices.firstIndex(where: { $0.id == id }) else { return }
        let old = controllerDevices[index]
        var next = old
        if let level, (0...1).contains(level) { next.battery = (level * 100).rounded() / 100 }
        if state != .unknown { next.batteryState = state }
        if next != old { controllerDevices[index] = next }
    }

    private func receiveInput(_ sample: DualSenseInputSample, controllerID: String) {
        let batteryState: ControllerDevice.BatteryState
        switch sample.batteryStatus {
        case .charging: batteryState = .charging
        case .full: batteryState = .full
        case .discharging: batteryState = .discharging
        case nil: batteryState = .unknown
        }
        if sample.batteryLevel != nil || batteryState != .unknown {
            updateBattery(for: controllerID, level: sample.batteryLevel.map { Double($0) }, state: batteryState)
        }
        guard selectedControllerID == controllerID else { return }
        let contacts = [sample.primaryTouch, sample.secondaryTouch].compactMap { $0 }.reduce(into: [Int: CGPoint]()) {
            $0[Int($1.contactID)] = CGPoint(x: CGFloat($1.x), y: CGFloat($1.y))
        }
        receiveInput(buttons: Set(sample.buttons.map(\.rawValue)),
                     left: CGPoint(x: CGFloat(sample.leftStickX), y: CGFloat(sample.leftStickY)),
                     right: CGPoint(x: CGFloat(sample.rightStickX), y: CGFloat(sample.rightStickY)),
                     contacts: contacts)
    }

    private func receiveInput(buttons: Set<String>, left: CGPoint, right: CGPoint, contacts: [Int: CGPoint]) {
        if !inputPrimed {
            // A newly selected controller must return to neutral before its
            // held button, deflected stick, or touch can trigger any mapping.
            guard buttons.isEmpty, contacts.isEmpty, hypot(left.x, left.y) <= 0.14,
                  hypot(right.x, right.y) <= 0.14 else { return }
            inputPrimed = true
        }
        let before = pressed
        let beforeButtons = before.intersection(ButtonMapping.physicalButtonIDs)
        let beforeAxes = axisDirections
        let nextAxes = directions(for: left, prefix: "leftStick")
            .union(directions(for: right, prefix: "rightStick"))
        let after = buttons.union(nextAxes)
        let newButtons = buttons.subtracting(beforeButtons)
        let releasedButtons = beforeButtons.subtracting(buttons)
        let newAxes = nextAxes.subtracting(beforeAxes)
        let releasedAxes = beforeAxes.subtracting(nextAxes)
        pressed = after
        axisDirections = nextAxes
        leftStick = left
        rightStick = right
        updateStickTimer()
        if isLauncherActive { updateLauncherStick(left: left, right: right) }

        let padPressed = buttons.contains("touchpad")
        if !newButtons.isEmpty {
            pressBatch &+= 1
            for id in newButtons { buttonPressOrder[id] = pressBatch }
        }
        let liftedTouch = contacts.isEmpty && touch.hasContacts
        if liftedTouch { touchScrollRemainder = .zero }
        let touchEvents = touch.update(contacts, pressed: padPressed, at: ProcessInfo.processInfo.systemUptime)
        if let id = touch.pressedMappingID { lastTouchpadPressMappingID = id }

        let newPhysicalButtons = newButtons.sorted()
        let projectedDirections = isLauncherActive ? newAxes.sorted() : []
        if (!newPhysicalButtons.isEmpty || !projectedDirections.isEmpty),
           (isLauncherActive || isEditingMapping || NSApp.isActive) {
            let inputs = newPhysicalButtons.map { id in
                id == "touchpad" ? touch.pressedMappingID ?? id : id
            }
            let navigationInputs = inputs + projectedDirections
            physicalInput = ControllerButtonFrame(
                newlyPressed: inputs, held: buttons,
                navigationInputs: isLauncherActive ? navigationInputs.filter { !isLauncherToggleInput($0) } : navigationInputs
            )
        }
        // Release and press each stream independently. The axis stream still
        // supports discrete direction mappings, while physical buttons keep
        // their own click, hold and combo state.
        for id in releasedButtons.sorted() where id != "touchpad" { release(id, modifiers: beforeButtons) }
        for id in releasedAxes.sorted() { release(id, modifiers: beforeButtons) }
        for id in newButtons.sorted() where id != "touchpad" { press(id) }
        for id in newAxes.sorted() { press(id) }
        handleTouch(touchEvents, previousButtons: beforeButtons, hasOtherButton: buttons.count > (padPressed ? 1 : 0))
        if liftedTouch { flushCursorMotion() }
        if !padPressed { touchpadUsedAsModifier = false }
    }

    // A smaller release threshold keeps a stick hovering near the boundary from retriggering.
    private func directions(for value: CGPoint, prefix: String) -> Set<String> {
        let axes: [(String, CGFloat)] = [
            ("Up", value.y), ("Right", value.x), ("Down", -value.y), ("Left", -value.x)
        ]
        return Set(axes.compactMap { suffix, magnitude in
            let id = prefix + suffix
            return magnitude >= (pressed.contains(id) ? 0.48 : 0.68) ? id : nil
        })
    }

    private func updateLauncherStick(left: CGPoint, right: CGPoint) {
        let leftLength = hypot(left.x, left.y)
        let rightLength = hypot(right.x, right.y)
        switch launcherStickSide {
        case .left where leftLength < 0.20, .right where rightLength < 0.20:
            launcherStickSide = nil
        default:
            break
        }
        if launcherStickSide == nil, max(leftLength, rightLength) >= 0.32 {
            launcherStickSide = leftLength >= rightLength ? .left : .right
        }
        let next: CGPoint
        switch launcherStickSide {
        case .left: next = left
        case .right: next = right
        case nil: next = .zero
        }
        if launcherStick != next { launcherStickSubject.send(next) }
    }

    private func resetLauncherStick() {
        launcherStickSide = nil
        if launcherStick != .zero { launcherStickSubject.send(.zero) }
    }

    private func markInput(_ id: String) {
        guard NSApp.isActive || testMode || isEditingMapping else { return }
        if activeInput != id { activeInput = id }
        if let row = mapping(id), lastInput != row.name { lastInput = row.name }
        if followHardwareSelection, !isEditingMapping, !isLauncherActive, NSApp.isActive, selectedMappingID != id {
            selectedMappingID = id
        }
    }

    private var mappingInputEnabled: Bool { isMouseMode && !testMode && !isEditingMapping }
    private var outputEnabled: Bool { mappingInputEnabled && !isLauncherActive }

    private func opensLauncher(_ binding: MappingBinding) -> Bool {
        if binding.action == .showLauncher { return true }
        return binding.action == .runCombo &&
            combos.contains { $0.id == binding.comboID && $0.binding.action == .showLauncher }
    }

    private func isLauncherToggleInput(_ id: String) -> Bool {
        guard mappingInputEnabled else { return false }
        let control = ControllerCombo.control(for: id)
        if let row = mapping(id), row.editableGestures.contains(where: { gesture in
            opensLauncher(row[gesture]) && eligible(row[gesture], for: id, gesture: gesture)
        }) { return true }
        if combos.contains(where: { combo in
            opensLauncher(combo.binding) &&
                (combo.modifierControl == control || (combo.triggerID == id && pressed.contains(combo.modifierControl)))
        }) { return true }
        return mappings.contains { row in
            row.editableGestures.contains { row[$0].modifierID == control && opensLauncher(row[$0]) }
        }
    }

    private struct ComboInput: Hashable {
        let triggerID: String
        let modifierID: String
    }

    private struct ComboPress {
        let input: ComboInput
        let actions: [GestureKind: MappingBinding]
        var fired = false
    }

    private func eligible(_ binding: MappingBinding, for id: String, gesture: GestureKind,
                          modifiers: Set<String>? = nil) -> Bool {
        guard binding.isConfigured else { return false }
        if binding.action == .runCombo,
           !combos.contains(where: { $0.id == binding.comboID && $0.actionIsValid }) { return false }
        guard let modifier = binding.modifierID else { return true }
        guard (modifiers ?? pressed).contains(modifier), !mappingConflicts.isInvalid(for: id, gesture: gesture)
        else { return false }

        let reciprocalID = modifier == "touchpad" ? lastTouchpadPressMappingID : modifier
        let control = ButtonMapping.touchPressIDs.contains(id) ? "touchpad" : id
        guard let reciprocalID else { return true }
        let hasReverseMapping = mappingConflicts.reciprocalMappings(for: id, gesture: gesture).contains(reciprocalID)
        let hasReverseCombo = combos.contains {
            $0.triggerID == reciprocalID && $0.modifierControl == control
        }
        guard hasReverseMapping || hasReverseCombo else { return true }
        let controlOrder = buttonPressOrder[control, default: 0]
        let modifierOrder = buttonPressOrder[modifier, default: 0]
        return controlOrder == modifierOrder ? control < modifier : controlOrder > modifierOrder
    }

    private func press(_ id: String) {
        markInput(id)
        // Shoulders are visible on both faces and must not replace a turn request from the same report.
        if NSApp.isActive, ButtonMapping.physicalButtonIDs.contains(id), id != "l1", id != "r1" {
            lastPhysicalPress = PhysicalPress(id: id)
        }
        guard let row = mapping(id) else { return }
        guard mappingInputEnabled else {
            // The factory mic switch remains accessible while ordinary mappings are paused.
            if id == "mute", !isLauncherActive, !testMode, !isEditingMapping,
               row[.tap] == MappingBinding(.microphoneMuteToggle),
               row[.doubleTap].action == .none, row[.hold].action == .none {
                microphone.toggleMuted()
                consumedPresses.insert(id)
            }
            return
        }

        if beginComboPress(id) { return }
        let single = row[.tap]
        let double = row[.doubleTap]
        let hold = row[.hold]
        let waitsForCombo = combos.contains { $0.modifierControl == id }
        if outputEnabled, ButtonMapping.physicalButtonIDs.contains(id), eligible(single, for: id, gesture: .tap),
           !waitsForCombo, !hold.isConfigured, !double.isConfigured, let button = mouseButton(for: single.action) {
            beginMousePress(.controller(trigger: id, modifier: single.modifierID),
                            button: button, countsAsClick: true)
            consumedPresses.insert(id)
            return
        }
        let canHold = eligible(hold, for: id, gesture: .hold)
        let canDoubleTap = eligible(double, for: id, gesture: .doubleTap)
        if hold.action.followsPress, canHold, !single.isConfigured, !double.isConfigured {
            perform(hold, source: id)
            consumedPresses.insert(id)
            return
        }
        guard !consumedPresses.contains(id) else { return }
        if canDoubleTap, let pending = pendingTaps.removeValue(forKey: id) {
            pending.cancel()
            perform(double, source: id)
            consumedPresses.insert(id)
            return
        }

        if canHold {
            holds[id] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
                guard let self, self.pressed.contains(id), self.mappingInputEnabled,
                      self.eligible(hold, for: id, gesture: .hold) else { return }
                self.consumedPresses.insert(id)
                self.perform(hold, source: id)
            }
        }
        if !waitsForCombo, !canHold, !canDoubleTap, eligible(single, for: id, gesture: .tap) {
            perform(single, source: id)
            consumedPresses.insert(id)
        }
    }

    private func beginComboPress(_ id: String) -> Bool {
        let control = ControllerCombo.control(for: id)
        let controlOrder = buttonPressOrder[control, default: 0]
        let matches = combos.filter { combo in
            let modifier = combo.modifierControl
            guard combo.triggerID == id, pressed.contains(modifier) else { return false }
            let modifierOrder = buttonPressOrder[modifier, default: 0]
            guard controlOrder >= modifierOrder else { return false }
            guard controlOrder == modifierOrder else { return true }

            // Same-report reciprocal chords share a stable winner. An already held
            // modifier instead follows the physical order of the two presses.
            let reciprocalID = modifier == "touchpad" ? lastTouchpadPressMappingID ?? modifier : modifier
            let competingCombo = combos.contains {
                $0.triggerID == reciprocalID && $0.modifierControl == control
            }
            let competingMapping = mapping(reciprocalID).map { row in
                row.editableGestures.contains { row[$0].isConfigured && row[$0].modifierID == control }
            } ?? false
            return (!competingCombo && !competingMapping) || control < modifier
        }
        guard let winning = matches.max(by: { first, second in
            let firstOrder = buttonPressOrder[first.modifierControl, default: 0]
            let secondOrder = buttonPressOrder[second.modifierControl, default: 0]
            return firstOrder == secondOrder ? first.modifierControl > second.modifierControl : firstOrder < secondOrder
        }) else { return false }

        let modifier = winning.modifierControl
        let input = ComboInput(triggerID: id, modifierID: modifier)
        var actions: [GestureKind: MappingBinding] = [:]
        if let row = mapping(id) {
            for gesture in row.editableGestures where row[gesture].modifierID == modifier &&
                    eligible(row[gesture], for: id, gesture: gesture) {
                actions[gesture] = row[gesture]
            }
        }
        for match in matches where match.modifierControl == modifier {
            if actions[match.gesture] == nil { actions[match.gesture] = match.binding }
        }

        if modifier == "touchpad" { touchpadUsedAsModifier = true }
        else { consumedPresses.insert(modifier) }
        let modifierMappingID = modifier == "touchpad" ? lastTouchpadPressMappingID ?? modifier : modifier
        holds.removeValue(forKey: modifierMappingID)?.cancel()
        var press = ComboPress(input: input, actions: actions)
        if let double = actions[.doubleTap], let pending = pendingComboTaps.removeValue(forKey: input) {
            pending.cancel()
            press.fired = true
            perform(double, source: id)
        }
        comboPresses[id] = press
        if !press.fired, let hold = actions[.hold] {
            let modifierOrder = buttonPressOrder[modifier]
            holds[id] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
                guard let self, self.mappingInputEnabled, self.pressed.contains(modifier),
                      self.buttonPressOrder[modifier] == modifierOrder,
                      self.comboPresses[id]?.input == input else { return }
                self.comboPresses[id]?.fired = true
                self.perform(hold, source: id)
            }
        }
        return true
    }

    private func finishComboPress(_ press: ComboPress) {
        guard !press.fired, mappingInputEnabled else { return }
        let input = press.input
        let tap = press.actions[.tap]
        if press.actions[.doubleTap] != nil {
            pendingComboTaps[input] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
                guard let self else { return }
                self.pendingComboTaps[input] = nil
                if let tap { self.perform(tap, source: input.triggerID) }
            }
        } else if let tap {
            perform(tap, source: input.triggerID)
        }
    }

    private func release(_ id: String, modifiers: Set<String>) {
        holds.removeValue(forKey: id)?.cancel()
        releaseHeldAction(id)
        if let combo = comboPresses.removeValue(forKey: id) {
            finishComboPress(combo)
            consumedPresses.remove(id)
            return
        }
        guard consumedPresses.remove(id) == nil, mappingInputEnabled, let row = mapping(id) else { return }
        deferSingleTap(row, interval: 0.28, modifiers: modifiers)
    }

    private func releaseHeldAction(_ id: String) {
        precisionSources.remove(id)
        if voiceSources.remove(id) != nil, voiceSources.isEmpty { microphone.endSystemInput() }
        if case let .controller(trigger, modifier)? = mousePress?.owner,
           id == trigger || ControllerCombo.control(for: id) == modifier {
            releaseMouse()
        }
    }

    private func deferSingleTap(_ row: ButtonMapping, interval: TimeInterval, modifiers: Set<String>? = nil) {
        let id = row.id
        let single = row[.tap]
        let canTap = eligible(single, for: id, gesture: .tap, modifiers: modifiers)
        if eligible(row[.doubleTap], for: id, gesture: .doubleTap, modifiers: modifiers) {
            pendingTaps[id]?.cancel()
            pendingTaps[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self else { return }
                self.pendingTaps[id] = nil
                if canTap { self.perform(single, source: id) }
            }
        } else if canTap {
            perform(single, source: id)
        }
    }

    private func cancelOutput() {
        for task in holds.values { task.cancel() }
        for task in pendingTaps.values { task.cancel() }
        holds.removeAll()
        pendingTaps.removeAll()
        comboPresses.removeAll()
        for task in pendingComboTaps.values { task.cancel() }
        pendingComboTaps.removeAll()
        consumedPresses = pressed
        precisionSources.removeAll()
        if !voiceSources.isEmpty { microphone.endSystemInput() }
        voiceSources.removeAll()
        cancelPointerTimer()
        pointer.discardPending()
        releaseMouse()
        pointer = PointerMotion()
        lastMouseClick = nil
        stopStickTimer()
        touch.cancel()
        touchpadUsedAsModifier = false
        touchHoldFired = false
        touchScrollRemainder = .zero
    }

    private func perform(_ binding: MappingBinding, source: String) {
        guard mappingInputEnabled, !isLauncherActive || opensLauncher(binding) else { return }
        if binding.usesMicrophone, [.shortcut, .commandPalette, .terminal].contains(binding.action),
           !microphone.startSystemInput() { return }
        switch binding.action {
        case .none, .moveCursor, .scroll: break
        case .precision: precisionSources.insert(source)
        case .voice:
            if microphone.startSystemInput() { voiceSources.insert(source) }
        case .voiceToggle:
            microphone.toggleSystemInput()
        case .microphoneMuteToggle:
            microphone.toggleMuted()
        case .runCombo:
            guard let combo = combos.first(where: { $0.id == binding.comboID }), combo.actionIsValid else { return }
            perform(combo.binding, source: source)
        case .showLauncher:
            launcherRequest = UUID()
        case .leftClick: click(.left)
        case .leftDoubleClick: doubleClick()
        case .leftLongPress: longPress()
        case .leftHold:
            guard pressed.contains(ControllerCombo.control(for: source)),
                  binding.modifierID.map(pressed.contains) ?? true else { return }
            beginMousePress(.controller(trigger: source, modifier: binding.modifierID), button: .left)
        case .rightClick: click(.right)
        case .middleClick: click(.center)
        case .shortcut:
            if let shortcut = binding.shortcut { sendShortcut(shortcut) }
        case .screenshot: sendShortcut(.init(21, [.maskCommand, .maskShift], "⇧⌘4"))
        case .commandPalette: sendShortcut(.init(35, [.maskCommand, .maskShift], "⇧⌘P"))
        case .terminal: sendShortcut(.init(50, .maskControl, "⌃`"))
        case .switchSpaceLeft: switchSpace(toRight: false)
        case .switchSpaceRight: switchSpace(toRight: true)
        case .openApp:
            if let path = binding.appPath {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init(), completionHandler: nil)
            }
        case .sensitivityDown:
            cursorSpeed = max(0.2, cursorSpeed - 0.1)
            scrollSpeed = max(0.2, scrollSpeed - 0.1)
        case .sensitivityUp:
            cursorSpeed = min(2, cursorSpeed + 0.1)
            scrollSpeed = min(2, scrollSpeed + 0.1)
        }
    }

    private func tickStickOutput() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastStickTickAt.map { min(max(now - $0, 1.0 / 240.0), 1.0 / 24.0) } ?? (1.0 / 120.0)
        lastStickTickAt = now
        let frameScale = CGFloat(dt * 60.0)

        if !fallbackControllers.isEmpty {
            if now - lastBatteryCheck >= 2 {
                lastBatteryCheck = now
                refreshFallbackBattery()
            }
        }
        guard needsContinuousStickOutput else {
            stopStickTimer()
            return
        }
        updateStickTimer()
        for (id, value) in [("leftStick", leftStick), ("rightStick", rightStick)] {
            let length = hypot(value.x, value.y)
            guard length > 0.14, let binding = mapping(id)?[.tap],
                  eligible(binding, for: id, gesture: .tap) else { continue }
            let scale = pow(min(1, (length - 0.14) / 0.86), 1.4) / length * frameScale
            applyMovement(binding.action, dx: value.x * scale, dy: value.y * scale, isTouch: false)
        }
    }

    private func applyMovement(_ action: MappingAction, dx: CGFloat, dy: CGFloat, isTouch: Bool) {
        guard canPostSystemEvents else { return }
        if action == .moveCursor {
            let speed = (isTouch ? 480 : 18) * cursorSpeed * (precisionSources.isEmpty ? 1 : 0.35)
            moveCursor(dx: dx * speed, dy: -dy * speed)
        } else if action == .scroll {
            let speed = (isTouch ? -420 : 12) * scrollSpeed
            let horizontal = dx * speed + (isTouch ? touchScrollRemainder.x : 0)
            let vertical = dy * speed + (isTouch ? touchScrollRemainder.y : 0)
            let x = Int32(horizontal.rounded())
            let y = Int32(vertical.rounded())
            if isTouch {
                touchScrollRemainder = CGPoint(x: horizontal - CGFloat(x), y: vertical - CGFloat(y))
            }
            guard x != 0 || y != 0 else { return }
            let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2,
                                wheel1: y, wheel2: x, wheel3: 0)
            if isTouch { event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
            event?.post(tap: .cghidEventTap)
        }
    }

    private func handleTouch(_ events: [TouchpadGestureRecognizer.Event], previousButtons: Set<String>,
                             hasOtherButton: Bool) {
        for event in events {
            switch event {
            case .beganPress(let id):
                beginTouchPress(id)
            case .endedPress(let id, let isClick):
                holds.removeValue(forKey: id)?.cancel()
                if mousePress?.owner == .touchpadDrag { releaseMouse() }
                releaseHeldAction(id)
                if let combo = comboPresses.removeValue(forKey: id) {
                    if isClick { finishComboPress(combo) }
                } else if isClick, !touchHoldFired, !touchpadUsedAsModifier {
                    touchTap(id, modifiers: previousButtons)
                }
                touchHoldFired = false
            case .tap(let id):
                touchTap(id)
            case .move(let id, let delta, let crossedThreshold):
                if id == "touchDrag", touchPressReserved { continue }
                touchMove(id, delta: delta, crossedThreshold: crossedThreshold, showInput: !hasOtherButton)
            case .swipe(let id):
                guard !touchHoldFired, !touchPressReserved else { continue }
                cancelTouchHold()
                markInput(id)
                if let binding = mapping(id)?[.tap], eligible(binding, for: id, gesture: .tap) {
                    perform(binding, source: id)
                }
            }
        }
    }

    private func beginTouchPress(_ id: String) {
        markInput(id)
        lastPhysicalPress = PhysicalPress(id: id)
        touchHoldFired = false
        guard mappingInputEnabled, !beginComboPress(id), !touchpadUsedAsModifier,
              let row = mapping(id) else { return }
        let hold = row[.hold]
        guard eligible(hold, for: id, gesture: .hold) else { return }
        if hold.action == .leftHold, !row[.tap].isConfigured, !row[.doubleTap].isConfigured {
            touchHoldFired = true
            perform(hold, source: id)
            return
        }
        holds[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            guard let self, self.touch.pressedMappingID == id, self.mappingInputEnabled,
                  self.eligible(hold, for: id, gesture: .hold) else { return }
            self.touchHoldFired = true
            self.perform(hold, source: id)
        }
    }

    private var touchPressReserved: Bool {
        guard let pressedID = touch.pressedMappingID else { return false }
        return comboPresses[pressedID] != nil || touchpadUsedAsModifier
    }

    private func cancelTouchHold() {
        guard let id = touch.pressedMappingID else { return }
        holds.removeValue(forKey: id)?.cancel()
    }

    private func touchTap(_ id: String, modifiers: Set<String>? = nil) {
        markInput(id)
        guard mappingInputEnabled, let row = mapping(id) else { return }
        let double = row[.doubleTap]
        if eligible(double, for: id, gesture: .doubleTap, modifiers: modifiers),
           let prior = pendingTaps.removeValue(forKey: id) {
            prior.cancel()
            perform(double, source: id)
        } else {
            deferSingleTap(row, interval: NSEvent.doubleClickInterval, modifiers: modifiers)
        }
    }

    private func touchMove(_ id: String, delta: CGPoint, crossedThreshold: Bool, showInput: Bool) {
        let continuesTouchHold: Bool
        if id == "touchDrag", case let .controller(trigger, _)? = mousePress?.owner {
            continuesTouchHold = touch.pressedMappingID == trigger
        } else {
            continuesTouchHold = false
        }
        guard !touchHoldFired || continuesTouchHold else { return }
        if id == "touchDrag", crossedThreshold { cancelTouchHold() }
        if showInput, activeInput != id { markInput(id) }
        guard mappingInputEnabled, let binding = mapping(id)?[.tap], eligible(binding, for: id, gesture: .tap) else { return }
        guard !isLauncherActive else {
            if crossedThreshold { perform(binding, source: id) }
            return
        }
        if id == "touchDrag", binding.action == .moveCursor, crossedThreshold, mousePress == nil {
            let button = touch.pressedMappingID.flatMap { pressedID -> CGMouseButton? in
                guard let click = mapping(pressedID)?[.tap], eligible(click, for: pressedID, gesture: .tap)
                else { return nil }
                return mouseButton(for: click.action)
            } ?? .left
            beginMousePress(.touchpadDrag, button: button)
        }
        if binding.action.isContinuous {
            if id != "touchDrag" || binding.action != .moveCursor ||
                mousePress?.owner == .touchpadDrag || continuesTouchHold {
                applyMovement(binding.action, dx: delta.x, dy: delta.y, isTouch: true)
            }
        } else if crossedThreshold, !touchHoldFired {
            perform(binding, source: id)
        }
    }

    private func moveCursor(dx: CGFloat, dy: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        let displays = displayBounds
        pointer.add(CGPoint(x: dx, y: dy), at: now, displays: displays, readCursor: Self.readCursor)
        guard let delay = pointer.timeUntilPost(at: now) else { return }
        if delay <= 0.0005 {
            flushCursorMotion()
        } else if pointerTimer == nil {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.schedule(deadline: .now() + .nanoseconds(Int(delay * 1_000_000_000)),
                           leeway: .nanoseconds(1_000_000))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.flushCursorMotion() }
            }
            pointerTimer = timer
            timer.resume()
        }
    }

    private func flushCursorMotion() {
        cancelPointerTimer()
        guard outputEnabled, canPostSystemEvents else {
            pointer.discardPending()
            return
        }
        guard let next = pointer.takePosition(at: ProcessInfo.processInfo.systemUptime) else { return }
        if var press = mousePress {
            if let start = press.clickStart, hypot(next.x - start.point.x, next.y - start.point.y) >= 5 {
                press.movedBeyondClickDistance = true
                mousePress = press
            }
            sendMouse(mouseTypes(for: press.button).drag, button: press.button, at: next,
                      count: press.clickCount, eventNumber: press.eventNumber)
        } else {
            sendMouse(.mouseMoved, button: .left, at: next)
        }
    }

    private func click(_ button: CGMouseButton) {
        guard mousePress == nil, canPostSystemEvents else { return }
        flushCursorMotion()
        let now = ProcessInfo.processInfo.systemUptime
        guard let point = pointer.positionForButton(at: now, readCursor: Self.readCursor) else { return }
        let count = nextClickCount(button, at: point, time: now)
        lastMouseClick = (now, point, button, count)
        emitClick(button, at: point, count: count)
    }

    private func doubleClick() {
        guard mousePress == nil, canPostSystemEvents else { return }
        flushCursorMotion()
        guard let point = pointer.positionForButton(at: ProcessInfo.processInfo.systemUptime,
                                                    readCursor: Self.readCursor) else { return }
        lastMouseClick = nil
        emitClick(.left, at: point, count: 1)
        emitClick(.left, at: point, count: 2)
    }

    private func longPress() {
        guard beginMousePress(.timed, button: .left) else { return }
        mouseReleaseTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self, self.mousePress?.owner == .timed else { return }
            self.releaseMouse()
        }
    }

    private func nextClickCount(_ button: CGMouseButton, at point: CGPoint, time: TimeInterval) -> Int {
        guard let previous = lastMouseClick, previous.button == button,
              time - previous.time <= NSEvent.doubleClickInterval,
              hypot(point.x - previous.point.x, point.y - previous.point.y) < 5 else { return 1 }
        return previous.count + 1
    }

    private func emitClick(_ button: CGMouseButton, at point: CGPoint, count: Int) {
        mouseEventNumber &+= 1
        let types = mouseTypes(for: button)
        sendMouse(types.down, button: button, at: point, count: count, eventNumber: mouseEventNumber)
        sendMouse(types.up, button: button, at: point, count: count, eventNumber: mouseEventNumber)
    }

    private func mouseButton(for action: MappingAction) -> CGMouseButton? {
        switch action {
        case .leftClick: return .left
        case .rightClick: return .right
        case .middleClick: return .center
        default: return nil
        }
    }

    private func mouseTypes(for button: CGMouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        default: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    @discardableResult
    private func beginMousePress(_ owner: MousePressOwner, button: CGMouseButton, countsAsClick: Bool = false) -> Bool {
        guard mousePress == nil, canPostSystemEvents else { return false }
        flushCursorMotion()
        let now = ProcessInfo.processInfo.systemUptime
        guard let point = pointer.positionForButton(at: now, readCursor: Self.readCursor) else { return false }
        let count = countsAsClick ? nextClickCount(button, at: point, time: now) : 1
        mouseEventNumber &+= 1
        mousePress = MousePress(owner: owner, button: button, eventNumber: mouseEventNumber,
                                clickCount: count, clickStart: countsAsClick ? (now, point) : nil)
        lastMouseClick = nil
        sendMouse(mouseTypes(for: button).down, button: button, at: point,
                  count: count, eventNumber: mouseEventNumber)
        return true
    }

    private func releaseMouse() {
        mouseReleaseTask?.cancel()
        mouseReleaseTask = nil
        guard mousePress != nil else { return }
        flushCursorMotion()
        guard let press = mousePress else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let position = pointer.positionForButton(at: now, readCursor: Self.readCursor)
        mousePress = nil
        sendMouse(mouseTypes(for: press.button).up, button: press.button, at: position,
                  count: press.clickCount, eventNumber: press.eventNumber)
        if let position, let start = press.clickStart, !press.movedBeyondClickDistance,
           now - start.time <= NSEvent.doubleClickInterval, hypot(position.x - start.point.x, position.y - start.point.y) < 5 {
            lastMouseClick = (now, position, press.button, press.clickCount)
        }
    }

    private static func readCursor() -> CGPoint? { CGEvent(source: nil)?.location }

    private func observeDisplays() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelPointerTimer()
                self.pointer = PointerMotion()
                self.displayBounds = Self.activeDisplayBounds()
            }
        })
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }

    private func sendMouse(_ type: CGEventType, button: CGMouseButton, at point: CGPoint? = nil,
                           count: Int = 1, eventNumber: Int64? = nil) {
        guard canPostSystemEvents, let point = point ?? CGEvent(source: eventSource)?.location,
              let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        if let eventNumber { event.setIntegerValueField(.mouseEventNumber, value: eventNumber) }
        event.post(tap: .cghidEventTap)
    }

    private func sendShortcut(_ shortcut: RecordedShortcut) {
        guard canPostSystemEvents else { return }
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: eventSource, virtualKey: shortcut.code, keyDown: pressed)
            event?.flags = CGEventFlags(rawValue: shortcut.flags)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func switchSpace(toRight: Bool) {
        guard canPostSystemEvents, !MacOSWorkspaceSwitcher.switchSpace(toRight: toRight) else { return }
        let shortcut = toRight ? RecordedShortcut(124, .maskControl, "⌃→")
                               : RecordedShortcut(123, .maskControl, "⌃←")
        sendShortcut(shortcut)
    }
}

struct PhysicalPress: Equatable {
    let id: String
    private let occurrence = UUID()
}

