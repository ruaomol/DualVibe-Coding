import AgentRemoteBridge
import Combine
import CoreAudio
import Foundation
import IOKit

@MainActor
final class DualSenseBluetoothBridge: ObservableObject {
    @Published private(set) var ownsController = false
    @Published private(set) var controllerDetected = false
    @Published private(set) var devices: [DualSenseHIDDevice] = []
    private(set) var selectedDeviceID: String?
    var onDevicesChanged: (() -> Void)?
    var onInputSample: ((String, DualSenseInputSample) -> Void)?
    var onAudioLevel: ((Double) -> Void)?
    var onAudioAvailabilityChanged: (() -> Void)?

    private let hid = DualSenseBluetoothEnhancedModeEnabler()
    private let audio = BluetoothAudioPipeline()
    private var audioGeneration = 0
    private var lastDeliveredInput: [String: DualSenseInputSample] = [:]

    var canAccessBluetooth: Bool { devices.contains { $0.isBluetooth && $0.acceptsInput } }
    var selectedDevice: DualSenseHIDDevice? { devices.first { $0.id == selectedDeviceID } }

    init() {
        // The app owns the mute-button mapping and updates the latch itself.
        hid.handlesPhysicalMicrophoneButton = false
        hid.includesUSBDevices = true
        hid.selectDevice(id: nil)
        hid.onDevicesChanged = { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        hid.onInputReport = { [weak self] device, reportID, bytes in
            MainActor.assumeIsolated {
                guard let self,
                      let sample = DualSenseInputSample.parse(reportID: reportID, bytes: bytes) else { return }
                self.deliverInput(sample, from: device.id)
            }
        }
        hid.onMicrophoneOpusFrame = { [weak self] frame, counter in
            MainActor.assumeIsolated { self?.receiveAudio(frame, counter: counter) }
        }
    }

    func start() {
        lastDeliveredInput.removeAll()
        hid.start()
        refreshDevices()
    }

    func stop() {
        lastDeliveredInput.removeAll()
        stopAudio()
        hid.stop()
        refreshDevices()
    }

    func selectDevice(id: String?) {
        guard selectedDeviceID != id else { return }
        stopAudio()
        selectedDeviceID = id
        if let id { lastDeliveredInput.removeValue(forKey: id) }
        hid.selectDevice(id: id)
        refreshOwnership()
        onAudioAvailabilityChanged?()
    }

    func startAudio(virtualDevice: AudioInputDevice? = nil, muted: Bool = false) throws {
        guard ownsController else { throw BluetoothAudioError.controllerNotOwned }
        try audio.start(device: virtualDevice, muted: muted)
        let result = hid.startMicrophoneStream(muted: muted)
        guard result == kIOReturnSuccess else {
            audio.stop()
            throw BluetoothAudioError.hid(result)
        }
    }

    func stopAudio() {
        audioGeneration &+= 1
        hid.stopMicrophoneStream()
        audio.stop()
    }

    func setAudioMuted(_ muted: Bool) {
        audio.setMuted(muted)
        hid.setMicrophoneMuted(muted)
    }

    private func refreshDevices() {
        let next = hid.connectedDevices
        let detected = next.contains(where: \.isBluetooth)
        let detectionChanged = controllerDetected != detected
        if detectionChanged { controllerDetected = detected }
        if devices != next {
            let connectedIDs = Set(next.map(\.id))
            lastDeliveredInput = lastDeliveredInput.filter { connectedIDs.contains($0.key) }
            devices = next
            onDevicesChanged?()
        }
        refreshOwnership()
        if detectionChanged { onAudioAvailabilityChanged?() }
    }

    private func refreshOwnership() {
        let owned = hid.hasExclusiveBluetoothAccess
        guard ownsController != owned else { return }
        ownsController = owned
        if !owned { stopAudio() }
    }

    private func deliverInput(_ sample: DualSenseInputSample, from id: String) {
        if let previous = lastDeliveredInput[id] {
            if id == selectedDeviceID {
                // The gesture engine observes edges and contact changes, not repeated snapshots.
                guard previous != sample else { return }
            } else {
                guard previous.batteryLevel != sample.batteryLevel ||
                    previous.batteryStatus != sample.batteryStatus else { return }
            }
        }
        lastDeliveredInput[id] = sample
        onInputSample?(id, sample)
    }

    private func receiveAudio(_ frame: Data, counter: UInt8) {
        let generation = audioGeneration
        audio.enqueue(frame, counter: counter) { [weak self] level in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.audioGeneration == generation else { return }
                self.onAudioLevel?(level)
            }
        }
    }
}

private enum BluetoothAudioError: LocalizedError {
    case controllerNotOwned
    case hid(IOReturn)
    case virtualDevice(OSStatus)

    var errorDescription: String? {
        switch self {
        case .controllerNotOwned: return "蓝牙 HID 独占连接不可用。请检查输入监控权限和手柄连接。"
        case let .hid(code): return "手柄拒绝启动蓝牙麦克风（\(code)）。"
        case let .virtualDevice(code): return "无法打开 DualSense Bridge Mic（\(code)）。"
        }
    }
}

private final class BluetoothAudioPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PS5VibeCoding.bluetooth-audio", qos: .userInitiated)
    private let output = VirtualMicrophonePCMOutput()
    private var decoder: BluetoothOpusDecoder?
    private var muted = false
    private var routesAudio = false
    private var lastMeterTime: UInt64 = 0

    func start(device: AudioInputDevice?, muted: Bool) throws {
        try queue.sync {
            guard decoder == nil else { return }
            let preparedDecoder = try BluetoothOpusDecoder()
            if let device {
                let status = output.start(deviceID: device.id, deviceUID: device.uid)
                guard status == noErr else { throw BluetoothAudioError.virtualDevice(status) }
            }
            decoder = preparedDecoder
            routesAudio = device != nil
            lastMeterTime = 0
            self.muted = muted
        }
    }

    func stop() {
        queue.sync {
            decoder = nil
            routesAudio = false
            output.stop()
        }
    }

    func setMuted(_ muted: Bool) {
        queue.sync {
            guard self.muted != muted else { return }
            self.muted = muted
            if muted, routesAudio { output.endSessionKeepingPrepared() }
        }
    }

    func enqueue(_ frame: Data, counter: UInt8, meter: @escaping @Sendable (Double) -> Void) {
        queue.async {
            guard let samples = self.decoder?.decode(frame), !samples.isEmpty, !self.muted else { return }
            if self.routesAudio { self.output.enqueue(samples, counter: counter) }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now &- self.lastMeterTime >= 70_000_000 else { return }
            self.lastMeterTime = now
            let sum = samples.reduce(0.0) { running, sample in
                let amplitude = Double(sample) / 32_768
                return running + amplitude * amplitude
            }
            meter(min(1, sqrt(sum / Double(samples.count))))
        }
    }
}
