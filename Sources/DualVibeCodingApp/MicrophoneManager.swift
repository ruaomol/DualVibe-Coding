import AppKit
import AVFAudio
import Combine
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    static let bridgeUID = "DualSenseBridgeMic_UID"

    let id: AudioDeviceID
    let name: String
    let uid: String
    let isPhysicalDualSense: Bool

    var isAgentRemoteBridge: Bool { uid == Self.bridgeUID }
    var isSystemMicrophone: Bool { !isAgentRemoteBridge && !isPhysicalDualSense }
}

@MainActor
final class MicrophoneManager: ObservableObject {
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var selectedDeviceID: AudioDeviceID?
    @Published private(set) var status = ""
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var isListening = false
    @Published private(set) var isSystemInputActive = false
    @Published private(set) var automaticallyUsesSystemInput =
        UserDefaults.standard.object(forKey: "automaticDualSenseInput") == nil
        || UserDefaults.standard.bool(forKey: "automaticDualSenseInput")
    @Published private(set) var isMuted = UserDefaults.standard.bool(forKey: "dualSenseInputMuted")
    @Published private(set) var isInstallingDriver = false

    private static let selectedInputUIDKey = "selectedMicrophoneInputUID"

    weak var bluetoothBridge: DualSenseBluetoothBridge? {
        didSet {
            bluetoothBridge?.onAudioLevel = { [weak self] level in
                guard let self, self.bluetoothActive, !self.isMuted else { return }
                self.inputLevel = level
            }
            bluetoothBridge?.onAudioAvailabilityChanged = { [weak self] in
                guard let self else { return }
                let deviceID = self.bluetoothBridge?.selectedDeviceID
                if self.observedControllerID != deviceID {
                    self.observedControllerID = deviceID
                    self.explicitInputSelection = false
                    self.stopListening()
                } else if !self.hasBluetoothSource, self.bluetoothActive {
                    self.stopListening()
                }
                self.scan()
            }
            scan()
        }
    }

    private let driver = BundledMicrophoneDriverManager()
    private var lifecycleObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var previewEngine: AVAudioEngine?
    private var previewDeviceUID: String?
    private var previewRequest: UUID?
    private var bluetoothActive = false
    private var observedControllerID: String?
    private var explicitInputSelection = false
    private enum InputOwner { case automatic, temporary, manual }
    private var route: (active: AudioInputDevice, previousUID: String?, owner: InputOwner)?
    private var suppressAutomaticForUID: String?
    private var suspendsAutomaticInput = false
    private var pendingStop: Task<Void, Never>?

    init() {
        var address = Self.devicesAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        if AudioObjectAddPropertyListenerBlock(Self.systemObject, &address, .main, listener) == noErr {
            deviceListener = listener
        }
        var defaultInputAddress = Self.defaultInputAddress
        let onDefaultInputChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultInputDidChange() }
        }
        if AudioObjectAddPropertyListenerBlock(Self.systemObject, &defaultInputAddress, .main, onDefaultInputChanged) == noErr {
            defaultInputListener = onDefaultInputChanged
        }
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendInput()
                self?.bluetoothBridge?.stop()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.automaticallyUsesSystemInput, self.route == nil else { return }
                self.scan()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendInput() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendsAutomaticInput = false
                self?.scan()
            }
        }
        scan()
    }

    deinit {
        if let lifecycleObserver { NotificationCenter.default.removeObserver(lifecycleObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let deviceListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, .main, deviceListener)
        }
        if let defaultInputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &address, .main, defaultInputListener)
        }
    }

    var choices: [AudioInputDevice] {
        // Keep the bridge and DualSense devices in the same picker as the
        // regular macOS inputs. The selected system input is what speech
        // input and other apps see as the default device.
        inputDevices
    }

    var selectedDevice: AudioInputDevice? {
        choices.first { $0.id == selectedDeviceID }
    }

    var hasBluetoothSource: Bool { bluetoothBridge?.ownsController == true }
    var isAvailable: Bool { selectedDevice != nil || hasBluetoothSource }
    var isDriverActive: Bool { inputDevices.contains(where: \.isAgentRemoteBridge) }
    var canInstallDriver: Bool { driver.canInstall }
    var showsInputLevel: Bool { bluetoothActive || previewEngine != nil }
    var canMute: Bool {
        if let device = route?.active ?? (isListening ? selectedDevice : nil) {
            if device.isAgentRemoteBridge { return bluetoothActive }
            return Self.nativeMuteAddress(device.id) != nil
        }
        return false
    }
    var canStartSystemInput: Bool { selectedDevice != nil }

    func scan() {
        refreshDevices()
        startAutomaticInputIfAvailable()
    }

    private func refreshDevices() {
        inputDevices = Self.enumerateInputDevices()
        if let activeUID = route?.active.uid ?? previewDeviceUID,
           !inputDevices.contains(where: { $0.uid == activeUID }) {
            stopListening()
        }
        if selectedDevice == nil {
            let savedUID = UserDefaults.standard.string(forKey: Self.selectedInputUIDKey)
            if let savedUID, let savedDevice = choices.first(where: { $0.uid == savedUID }) {
                selectedDeviceID = savedDevice.id
                explicitInputSelection = true
            } else {
                selectedDeviceID = Self.defaultInputID().flatMap { id in choices.first(where: { $0.id == id })?.id }
                    ?? choices.first(where: \.isPhysicalDualSense)?.id
                    ?? choices.first?.id
            }
        }
        if selectedDevice?.uid != suppressAutomaticForUID { suppressAutomaticForUID = nil }
        updateStatus()
    }

    func selectDevice(id: AudioDeviceID?) {
        if let id, !choices.contains(where: { $0.id == id }) { return }
        stopListening()
        selectedDeviceID = id
        explicitInputSelection = id != nil
        if let id, let device = choices.first(where: { $0.id == id }) {
            UserDefaults.standard.set(device.uid, forKey: Self.selectedInputUIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedInputUIDKey)
        }
        suppressAutomaticForUID = nil
        updateStatus()
        startAutomaticInputIfAvailable()
    }

    func setAutomaticallyUsesSystemInput(_ enabled: Bool) {
        guard automaticallyUsesSystemInput != enabled else { return }
        automaticallyUsesSystemInput = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticDualSenseInput")
        if enabled {
            suppressAutomaticForUID = nil
            if route != nil {
                pendingStop?.cancel()
                pendingStop = nil
                route?.owner = .automatic
                isSystemInputActive = true
                updateStatus()
            } else {
                if isListening || previewRequest != nil { stopListening() }
                scan()
            }
        } else if route?.owner == .automatic {
            stopListening()
        }
    }

    private func startAutomaticInputIfAvailable() {
        guard automaticallyUsesSystemInput, !suspendsAutomaticInput, route == nil,
              !isListening, previewRequest == nil, let device = selectedDevice,
              device.uid != suppressAutomaticForUID else { return }
        if device.isPhysicalDualSense {
            guard AVAudioApplication.shared.recordPermission == .granted else { return }
            if choices.count > 1, !explicitInputSelection {
                status = "有多个 USB 手柄麦克风。请选择输入设备。"
                return
            }
        }
        _ = activateSystemInput(owner: .automatic, device: device)
    }

    private func suspendInput() {
        suspendsAutomaticInput = true
        stopListening()
    }

    private func defaultInputDidChange() {
        guard let route, let current = Self.defaultInputID(), current != route.active.id else { return }
        suppressAutomaticForUID = route.active.uid
        stopListening()
    }

    func startListening() {
        guard !isListening, route == nil, previewRequest == nil else { return }
        if let device = selectedDevice, device.isAgentRemoteBridge {
            do {
                try startBluetoothAudio()
                isListening = true
                updateStatus()
            } catch {
                status = error.localizedDescription
            }
            return
        }
        guard let device = selectedDevice else { return }
        let request = UUID()
        previewRequest = request
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewRequest == request else { return }
                self.previewRequest = nil
                guard granted else {
                    self.status = "请在系统设置 → 隐私与安全性 → 麦克风中授权。"
                    return
                }
                self.startNativePreview(device)
            }
        }
    }

    @discardableResult
    func startSystemInput() -> Bool {
        beginSystemInput(owner: .temporary)
    }

    func toggleSystemInput() {
        if isSystemInputActive {
            setAutomaticallyUsesSystemInput(false)
            if isSystemInputActive { stopListening() }
        } else {
            _ = beginSystemInput(owner: automaticallyUsesSystemInput ? .automatic : .manual)
        }
    }

    private func beginSystemInput(owner: InputOwner) -> Bool {
        refreshDevices()
        guard let device = selectedDevice ?? choices.first else {
            status = hasBluetoothSource
                ? "请先安装 DualSense Bridge Mic，再通过蓝牙向其他 App 提供语音。"
                : "未发现可用的麦克风输入。"
            return false
        }
        suppressAutomaticForUID = nil
        return activateSystemInput(owner: owner, device: device)
    }

    private func activateSystemInput(owner: InputOwner, device: AudioInputDevice) -> Bool {
        if let route, route.active.uid == device.uid, Self.defaultInputID() == route.active.id {
            pendingStop?.cancel()
            pendingStop = nil
            if owner != .temporary { self.route?.owner = owner }
            isSystemInputActive = true
            updateStatus()
            return true
        }
        stopListening()

        guard let previous = inputDevices.first(where: { $0.id == Self.defaultInputID() }) else {
            status = "无法读取当前系统输入，未启动系统麦克风路由。"
            return false
        }

        if device.isAgentRemoteBridge {
            do {
                try startBluetoothAudio(virtualDevice: device)
            } catch {
                status = error.localizedDescription
                return false
            }
        } else if isMuted {
            // Some system microphones expose no writable mute property. Keep
            // the route usable and apply the mute when Core Audio supports it.
            _ = Self.setNativeMute(true, device: device.id)
        }

        let previousUID = previous.uid == device.uid ? nil : previous.uid
        if previousUID != nil {
            let result = Self.setDefaultInput(device.id)
            guard result == noErr else {
                stopListening()
                status = "无法切换 macOS 输入设备（\(result)）。"
                return false
            }
        }
        route = (device, previousUID, owner)
        isSystemInputActive = true
        isListening = true
        updateStatus()
        return true
    }

    func endSystemInput() {
        guard let route, route.owner == .temporary, isSystemInputActive else { return }
        isSystemInputActive = false
        if !route.active.isAgentRemoteBridge {
            stopListening()
            return
        }
        pendingStop = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) }
            catch { return }
            self?.stopListening()
        }
    }

    func stopListening() {
        pendingStop?.cancel()
        pendingStop = nil
        previewRequest = nil
        if let previewEngine {
            previewEngine.stop()
            previewEngine.inputNode.removeTap(onBus: 0)
            self.previewEngine = nil
            previewDeviceUID = nil
        }
        if bluetoothActive {
            bluetoothBridge?.stopAudio()
            bluetoothActive = false
        }
        var error: String?
        if let route, let previousUID = route.previousUID, Self.defaultInputID() == route.active.id {
            let devices = Self.enumerateInputDevices()
            if let previous = devices.first(where: { $0.uid == previousUID }) {
                let result = Self.setDefaultInput(previous.id)
                if result != noErr { error = "无法恢复 macOS 原输入设备（\(result)）。" }
            } else {
                error = "原输入设备已断开。请在系统设置 → 声音中选择输入。"
            }
        }
        route = nil
        isSystemInputActive = false
        isListening = false
        inputLevel = 0
        updateStatus()
        if let error { status = error }
    }

    func toggleMuted() {
        guard canMute else { return }
        let muted = !isMuted
        if let device = route?.active ?? (isListening ? selectedDevice : nil),
           !device.isAgentRemoteBridge,
           !Self.setNativeMute(muted, device: device.id) {
            status = "无法更改麦克风静音。"
            return
        }
        isMuted = muted
        UserDefaults.standard.set(muted, forKey: "dualSenseInputMuted")
        inputLevel = 0
        if bluetoothActive {
            bluetoothBridge?.setAudioMuted(muted)
        }
        updateStatus()
    }

    func installDriver() {
        guard canInstallDriver, !isInstallingDriver, !isDriverActive else { return }
        stopListening()
        isInstallingDriver = true
        defer { isInstallingDriver = false }
        do {
            try driver.install()
            scan()
            if !isDriverActive { status = "驱动已安装。等待 Core Audio 加载后可重新扫描。" }
        } catch {
            status = "驱动安装未完成。\(error.localizedDescription)"
        }
    }

    private func startBluetoothAudio(virtualDevice: AudioInputDevice? = nil) throws {
        guard let bluetoothBridge else { throw MicrophoneError.missingBridge }
        try bluetoothBridge.startAudio(virtualDevice: virtualDevice, muted: isMuted)
        bluetoothActive = true
    }

    private func updateStatus() {
        if isSystemInputActive {
            status = isMuted ? "系统语音输入已静音" : "系统语音输入已启用"
        } else if isListening {
            status = isMuted ? "监听已静音" : (bluetoothActive ? "正在监听 DualSense 蓝牙麦克风" : "正在监听 DualSense USB 麦克风")
        } else if selectedDevice?.isPhysicalDualSense == true {
            status = "DualSense USB 麦克风已就绪"
        } else if let selectedDevice, selectedDevice.isSystemMicrophone {
            status = "系统麦克风“\(selectedDevice.name)”已就绪"
        } else if hasBluetoothSource {
            status = isDriverActive ? "蓝牙麦克风与虚拟音频设备已就绪" : "蓝牙麦克风可预览，系统语音输入需要安装驱动"
        } else if bluetoothBridge?.controllerDetected == true {
            status = "蓝牙输入监控未就绪。请检查系统设置中的输入监控权限。"
        } else {
            status = "未发现 DualSense 音频输入"
        }
    }

    private func startNativePreview(_ device: AudioInputDevice) {
        guard choices.contains(device) else { return }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        guard let unit = node.audioUnit else {
            status = "无法打开麦克风音频端点"
            return
        }
        var deviceID = device.id
        let result = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard result == noErr else {
            status = "无法选择麦克风音频端点（\(result)）"
            return
        }
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            status = "麦克风没有可读的输入流"
            return
        }
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            let sum = UnsafeBufferPointer(start: channel, count: count).reduce(0.0) { $0 + Double($1 * $1) }
            let level = min(1, sqrt(sum / Double(count)))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewEngine != nil, !self.isMuted else { return }
                self.inputLevel = level
            }
        }
        do {
            try engine.start()
            previewEngine = engine
            previewDeviceUID = device.uid
            isListening = true
            updateStatus()
        } catch {
            node.removeTap(onBus: 0)
            status = "无法开始读取麦克风音频。\(error.localizedDescription)"
        }
    }
}

private enum MicrophoneError: LocalizedError {
    case missingBridge

    var errorDescription: String? { "未检测到 DualSense 蓝牙连接。" }
}

extension MicrophoneManager {
    private nonisolated static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private nonisolated static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static var devicesAddress: AudioObjectPropertyAddress {
        propertyAddress(kAudioHardwarePropertyDevices)
    }

    private nonisolated static var defaultInputAddress: AudioObjectPropertyAddress {
        propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var address = defaultInputAddress
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id)
        return result == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func setDefaultInput(_ deviceID: AudioDeviceID) -> OSStatus {
        var address = defaultInputAddress
        var id = deviceID
        return AudioObjectSetPropertyData(systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    private static func nativeMuteAddress(_ device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        var address = propertyAddress(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return nil }
        return address
    }

    private static func setNativeMute(_ muted: Bool, device: AudioDeviceID) -> Bool {
        guard var address = nativeMuteAddress(device) else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private static func enumerateInputDevices() -> [AudioInputDevice] {
        var address = devicesAddress
        var size: UInt32 = 0
        let idSize = MemoryLayout<AudioDeviceID>.size
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size >= idSize else { return [] }
        var ids = Array(repeating: AudioDeviceID(0), count: Int(size) / idSize)
        let result = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return [] }

        return ids.prefix(Int(size) / idSize).compactMap { id in
            guard hasStreams(id, scope: kAudioObjectPropertyScopeInput) else { return nil }
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName)
            var transportAddress = propertyAddress(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            let dualSenseName = name.localizedCaseInsensitiveContains("DualSense")
                || name.localizedCaseInsensitiveContains("Wireless Controller")
            let physical = dualSenseName && transport == kAudioDeviceTransportTypeUSB
            return AudioInputDevice(id: id, name: name.isEmpty ? uid : name,
                                    uid: uid, isPhysicalDualSense: physical)
        }
    }

    private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
        return value.map { $0.takeRetainedValue() as String } ?? ""
    }
}
