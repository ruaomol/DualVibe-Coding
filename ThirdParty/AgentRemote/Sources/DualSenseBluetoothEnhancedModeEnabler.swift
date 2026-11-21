import CoreFoundation
import CryptoKit
import Foundation
import IOKit.hid

public struct DualSenseHIDDevice: Sendable, Equatable {
    public let id: String
    public let isBluetooth: Bool
    public let stableID: Bool
    public let acceptsInput: Bool
}

/// Opens the Bluetooth DualSense, enables full input reports, and owns the
/// controller side of Sony's proprietary audio-over-HID stream. The device is
/// kept seized while this bridge is running so proprietary microphone packets
/// can never leak into GameController or macOS's controller shortcuts.
public final class DualSenseBluetoothEnhancedModeEnabler {
    private struct MicrophoneCaptureProfile {
        let name: String
        let audioControl: UInt8
        let audioControl2: UInt8
    }

    private static let microphoneCaptureProfiles = [
        MicrophoneCaptureProfile(
            name: "Natural internal array (beamforming, no controller noise cancellation)",
            audioControl: 0x01,
            audioControl2: 0x08
        ),
        MicrophoneCaptureProfile(
            name: "Sony Voice Chat (controller noise cancellation)",
            audioControl: 0x09,
            audioControl2: 0x0a
        ),
        MicrophoneCaptureProfile(
            name: "Natural internal array without beamforming",
            audioControl: 0x01,
            audioControl2: 0x00
        ),
        MicrophoneCaptureProfile(
            name: "legacy internal DSP",
            audioControl: 0x0d,
            audioControl2: 0x02
        ),
        MicrophoneCaptureProfile(
            name: "internal CHAT/CHAT",
            audioControl: 0x49,
            audioControl2: 0x0a
        ),
        MicrophoneCaptureProfile(
            name: "internal ASR/ASR",
            audioControl: 0x89,
            audioControl2: 0x0a
        ),
        MicrophoneCaptureProfile(
            name: "raw internal CHAT/CHAT",
            audioControl: 0x41,
            audioControl2: 0x08
        ),
        MicrophoneCaptureProfile(
            name: "raw internal ASR/ASR",
            audioControl: 0x81,
            audioControl2: 0x08
        )
    ]

    public var onMicrophoneOpusFrame: ((Data, UInt8) -> Void)?
    var onFaceButtonMaskChanged: ((UInt8) -> Void)?
    var onGamepadState: ((DualSenseBluetoothGamepadState) -> Void)?
    public var onConnectionChanged: ((Bool) -> Void)?
    public var onDevicesChanged: (() -> Void)?

    public var onInputReport: ((DualSenseHIDDevice, UInt32, UnsafeBufferPointer<UInt8>) -> Void)?
    public var includesUSBDevices = false
    public var handlesPhysicalMicrophoneButton = true

    private var manager: IOHIDManager
    private let microphoneQueue = DispatchQueue(
        label: "local.controllerproject.DualSenseBridge.bluetooth-audio",
        qos: .userInteractive
    )
    private var configuredDevices: Set<ObjectIdentifier> = []
    private var explicitlySeizedDevices: Set<ObjectIdentifier> = []
    private var devices: [ObjectIdentifier: IOHIDDevice] = [:]
    private var deviceInfo: [ObjectIdentifier: DualSenseHIDDevice] = [:]
    private var selectedID: String?
    private var followsFirstDevice = true
    private var isStarted = false
    private var managerIsOpen = false
    private var microphoneTimer: DispatchSourceTimer?
    private var microphoneDevice: IOHIDDevice?
    private var packetBuilder = DualSenseBluetoothAudioPacketBuilder()
    private var microphoneSessionGeneration: UInt64 = 0
    private var microphoneCleanupPending = false
    private var microphoneInputCount = 0
    private var microphoneOutputCount = 0
    private var microphoneControlKeepaliveCount = 0
    private var microphoneEncodedSignalFrameCount = 0
    private var microphoneCaptureProfileIndex = 0
    // Voice-chat DSP is the reliable default for speech recognition. The
    // natural beamforming profile preserves more room ambience but sends
    // controller noise and Bluetooth reconstruction artefacts straight into
    // dictation. Keep the preset API so advanced users can still choose the
    // natural profiles explicitly.
    private var preferredMicrophoneCaptureProfileIndex = MicrophoneCapturePreset.sonyVoiceChat.rawValue
    private var microphoneVolume: UInt8 = 24
    private var lastMicrophoneInputNanos: UInt64 = 0
    private var lastMicrophoneArmingNanos: UInt64 = 0
    private var lastMicrophoneControlNanos: UInt64 = 0
    private var lastMicrophoneProfileChangeNanos: UInt64 = 0
    private var normalInputCountDuringMicrophone = 0
    private var microphoneUnmuteReassertionCount = 0
    private var lastMicrophoneUnmuteReassertionNanos: UInt64 = 0
    private var lastRateReportNanos: UInt64 = 0
    private var lastRateReportMicrophoneCount = 0
    private var lastRateReportGamepadCount = 0
    private var lastFaceButtonMask: UInt8?
    private var lastMicrophoneButtonPressed = false
    private var requestedMicrophoneMuted: Bool?
    private var pausesMicrophoneArming = false // Only accessed on microphoneQueue.
    private var isSeizingDevice = false
    private var hasLoggedContainedStaleMicrophoneFeedback = false
    // Raw-input cadence instrumentation for one microphone session. Records
    // in memory only; the summary is written to the log after the stream
    // stops so the measurement cannot cause the loss it measures.
    private var inputTap = DualSenseMicrophoneInputTap()

    private(set) var isMicrophoneStreaming = false

    public var connectedDevices: [DualSenseHIDDevice] {
        deviceInfo.values.sorted { $0.id < $1.id }
    }

    public var isBluetoothConnected: Bool { deviceInfo.values.contains(where: \.isBluetooth) }

    public var hasExclusiveBluetoothAccess: Bool {
        guard let device = activeDevice, let info = deviceInfo[ObjectIdentifier(device)] else { return false }
        return info.isBluetooth && info.acceptsInput
    }

    private var activeDevice: IOHIDDevice? {
        if followsFirstDevice { return devices.values.first }
        guard let id = selectedID, let key = deviceInfo.first(where: { $0.value.id == id })?.key else { return nil }
        return devices[key]
    }

    public func selectDevice(id: String?) {
        if !followsFirstDevice, selectedID == id { return }
        stopMicrophoneStream()
        followsFirstDevice = false
        selectedID = id
        lastFaceButtonMask = nil
        lastMicrophoneButtonPressed = false
        requestedMicrophoneMuted = nil
    }

    func setMicrophoneVolume(_ volume: UInt8) {
        let clampedVolume = min(volume, 64)
        microphoneQueue.async { [weak self] in
            guard let self else { return }
            self.microphoneVolume = clampedVolume

            guard self.isMicrophoneStreaming,
                  let device = self.microphoneDevice else {
                return
            }
            let profile = Self.microphoneCaptureProfiles[
                self.microphoneCaptureProfileIndex
            ]
            let result = self.send(
                self.packetBuilder.internalMicrophoneSourceReport(
                    microphoneVolume: clampedVolume,
                    audioControl: profile.audioControl,
                    audioControl2: profile.audioControl2
                ),
                to: device
            )
            DiagnosticLog.write(
                "Bluetooth microphone level changed to \(clampedVolume), result=\(result)"
            )
        }
    }

    /// User-selectable controller-side capture DSP. Indices match the first
    /// three `microphoneCaptureProfiles` entries.
    enum MicrophoneCapturePreset: Int {
        case naturalBeamforming = 0
        case sonyVoiceChat = 1
        case naturalNoBeamforming = 2
    }

    /// Chooses the controller's capture DSP before encoding: whether the
    /// aggressive voice-chat noise cancellation runs, and whether the internal
    /// array is beamformed to one voice channel. Natural capture leaves
    /// denoising and tone shaping to the Mac. A change made during capture
    /// deliberately takes effect on the next take so the controller cannot
    /// reset its encoder halfway through a sentence.
    func setMicrophoneCapturePreset(_ preset: MicrophoneCapturePreset) {
        microphoneQueue.async { [weak self] in
            guard let self else { return }
            self.preferredMicrophoneCaptureProfileIndex = preset.rawValue
            let profile = Self.microphoneCaptureProfiles[
                self.preferredMicrophoneCaptureProfileIndex
            ]
            DiagnosticLog.write(
                "Bluetooth microphone preferred capture profile set to: \(profile.name)"
                    + (self.isMicrophoneStreaming ? " (applies to next take)" : "")
            )
        }
    }

    /// Leaves repeated microphone cycles in a deterministic, visible state.
    /// The report owns only AllowLedColor, so the amber finished/playback
    /// indicator cannot overwrite the microphone route or mute latch.
    func showMicrophoneFinishedIndicator() {
        guard let device = activeDevice else { return }
        microphoneQueue.async { [weak self, weak device] in
            guard let self, let device else { return }
            let result = self.send(
                self.packetBuilder.lightbarColorReport(
                    red: 0xff,
                    green: 0xd7,
                    blue: 0x00
                ),
                to: device
            )
            DiagnosticLog.write(
                "Bluetooth microphone lightbar set to amber finished state with LED-only report, result=\(result)"
            )
        }
    }

    /// Agent-status lightbar updates reuse the LED-only report proven safe
    /// during microphone bring-up: only AllowLedColor is marked valid, so a
    /// status color can never disturb audio routing or the mute latch.
    func setAgentLightbar(red: UInt8, green: UInt8, blue: UInt8) {
        guard let device = activeDevice else { return }
        microphoneQueue.async { [weak self, weak device] in
            guard let self, let device else { return }
            let result = self.send(
                self.packetBuilder.lightbarColorReport(
                    red: red,
                    green: green,
                    blue: blue
                ),
                to: device
            )
            DiagnosticLog.write(
                "Bluetooth agent lightbar set to #\(String(format: "%02x%02x%02x", red, green, blue)), result=\(result)"
            )
        }
    }

    /// Session-slot player LEDs. Deferred while the microphone streams:
    /// unlike the lightbar report, the player-indicator validity bit was
    /// never exercised during audio bring-up, and unproven report combos
    /// stay out of live captures on principle.
    func setPlayerLEDs(mask: UInt8, immediate: Bool = false) {
        guard let device = activeDevice else { return }
        microphoneQueue.async { [weak self, weak device] in
            guard let self, let device else { return }
            guard !self.isMicrophoneStreaming else { return }
            let result = self.send(
                self.packetBuilder.playerLEDReport(
                    mask: mask,
                    immediate: immediate
                ),
                to: device
            )
            if result == kIOReturnSuccess {
                DiagnosticLog.write(
                    "Bluetooth player LEDs mask=0x\(String(format: "%02x", mask & 0x1f)), immediate=\(immediate)"
                )
            } else {
                DiagnosticLog.write("Bluetooth player LED report failed: \(result)")
            }
        }
    }

    /// Agent-alert rumble. Deferred while the microphone streams: rumble
    /// reports select the vibration-emulation haptics path, and switching
    /// haptic modes mid-capture risks the encoded-silence failure the audio
    /// bring-up work spent four rounds eliminating. The controller is in the
    /// user's hands during dictation anyway.
    func setAgentRumble(lowFrequencyMotor: UInt8, highFrequencyMotor: UInt8) {
        guard let device = activeDevice else { return }
        microphoneQueue.async { [weak self, weak device] in
            guard let self, let device else { return }
            guard !self.isMicrophoneStreaming else {
                DiagnosticLog.write(
                    "Bluetooth agent rumble skipped during microphone capture"
                )
                return
            }
            let result = self.send(
                self.packetBuilder.rumbleReport(
                    lowFrequencyMotor: lowFrequencyMotor,
                    highFrequencyMotor: highFrequencyMotor
                ),
                to: device
            )
            if result != kIOReturnSuccess {
                DiagnosticLog.write("Bluetooth agent rumble report failed: \(result)")
            }
        }
    }

    public init() {
        manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        // Keep exclusive ownership for the app's entire lifetime. The
        // controller's Bluetooth mic stream is sticky and Sony has no proven
        // mid-session stop command; isolation keeps any residual proprietary
        // audio reports away from GameController without sending a bogus
        // disable transition that some firmware cannot re-arm afterward.
        let isolatedResult = openFreshManager(exclusive: true)
        if isolatedResult == kIOReturnSuccess {
            DiagnosticLog.write("Bluetooth HID isolated; sticky microphone feedback contained")
        } else {
            let fallbackResult = openFreshManager(exclusive: false)
            guard fallbackResult == kIOReturnSuccess else {
                DiagnosticLog.write(
                    "Bluetooth enhanced-mode HID open failed: isolated=\(isolatedResult), normal=\(fallbackResult)"
                )
                return
            }
            DiagnosticLog.write(
                "Bluetooth startup isolation unavailable (\(isolatedResult)); opened normally"
            )
        }
        DiagnosticLog.write("Bluetooth enhanced-mode HID monitor started")
    }

    public func stop() {
        guard isStarted else { return }
        stopMicrophoneStream()
        // Agent lightbar/rumble sends are queued asynchronously; the quit-time
        // zero-motor and lightbar-release reports must reach the device
        // before the HID manager closes underneath them.
        microphoneQueue.sync {}
        isStarted = false
        closeCurrentManager()
        devices.removeAll()
        deviceInfo.removeAll()
        configuredDevices.removeAll()
        explicitlySeizedDevices.removeAll()
        lastFaceButtonMask = nil
        lastMicrophoneButtonPressed = false
        requestedMicrophoneMuted = nil
        hasLoggedContainedStaleMicrophoneFeedback = false
        onDevicesChanged?()
    }

    /// Starts microphone capture. The stream contains only silence on the
    /// controller's speaker and haptic channels.
    public func startMicrophoneStream(muted: Bool = false) -> IOReturn {
        guard !isMicrophoneStreaming else { return kIOReturnSuccess }
        guard hasExclusiveBluetoothAccess else { return kIOReturnNotPermitted }
        guard !microphoneCleanupPending else {
            DiagnosticLog.write(
                "Bluetooth microphone is still draining its previous audio session"
            )
            return kIOReturnBusy
        }

        // The duplex mic packets intentionally reuse the gamepad report ID.
        // Seizing the HID device prevents macOS's GameController service from
        // interpreting encoded audio as sticks or the system/Home button.
        guard let device = activeDevice else {
            return kIOReturnNotFound
        }

        requestedMicrophoneMuted = muted
        microphoneEncodedSignalFrameCount = 0
        inputTap.begin()
        var setupResult = kIOReturnError
        microphoneQueue.sync {
            pausesMicrophoneArming = muted
            // An agent haptic pattern may have driven the motors moments ago,
            // and its trailing zero step will be suppressed once streaming
            // starts. Force the motors off here — with one retry, so a single
            // transient write failure cannot leave a cancelled pattern
            // buzzing through the whole dictation session.
            for attempt in 1...2 {
                let zeroResult = send(
                    packetBuilder.rumbleReport(
                        lowFrequencyMotor: 0,
                        highFrequencyMotor: 0
                    ),
                    to: device
                )
                if zeroResult == kIOReturnSuccess { break }
                DiagnosticLog.write(
                    "Bluetooth pre-capture motor zero attempt #\(attempt) failed: \(zeroResult)"
                )
            }
            microphoneCaptureProfileIndex = preferredMicrophoneCaptureProfileIndex
            // Set the physical mute latch before enabling the proprietary
            // return stream. Use Sony's minimal state update and repeat it
            // across a few HID intervals so a controller just leaving its
            // previous audio mode cannot miss the transition.
            for attempt in 1...3 {
                setupResult = send(nextMicrophoneStateReport(muted: muted), to: device)
                DiagnosticLog.write(
                    "Bluetooth physical microphone state report #\(attempt), result=\(setupResult)"
                )
                guard setupResult == kIOReturnSuccess else { return }
                Thread.sleep(forTimeInterval: 0.012)
            }
            let profile = Self.microphoneCaptureProfiles[microphoneCaptureProfileIndex]
            setupResult = send(packetBuilder.internalMicrophoneSourceReport(
                microphoneVolume: microphoneVolume,
                audioControl: profile.audioControl,
                audioControl2: profile.audioControl2
            ), to: device)
            DiagnosticLog.write(
                "Bluetooth microphone capture profile selected: \(profile.name), gain=\(microphoneVolume), result=\(setupResult)"
            )
            guard setupResult == kIOReturnSuccess else { return }
            Thread.sleep(forTimeInterval: 0.012)
            // A compact 0x32 control report requests mic feedback.
            setupResult = send(
                packetBuilder.audioReport(microphoneEnabled: true),
                to: device
            )
            guard setupResult == kIOReturnSuccess else { return }
            Thread.sleep(forTimeInterval: 0.012)
            // Keep visual feedback independent from the load-bearing audio
            // state so LED UX cannot overwrite microphone routing.
            setupResult = send(
                packetBuilder.lightbarColorReport(
                    red: 0x00,
                    green: 0x40,
                    blue: 0xff
                ),
                to: device
            )
            DiagnosticLog.write(
                "Bluetooth microphone lightbar set to blue with LED-only report, result=\(setupResult)"
            )
        }
        guard setupResult == kIOReturnSuccess else {
            DiagnosticLog.write("Bluetooth microphone setup report failed: \(setupResult)")
            return setupResult
        }

        microphoneDevice = device
        microphoneInputCount = 0
        microphoneOutputCount = 0
        microphoneControlKeepaliveCount = 0
        lastMicrophoneInputNanos = 0
        lastMicrophoneArmingNanos = 0
        lastMicrophoneControlNanos = 0
        lastMicrophoneProfileChangeNanos = DispatchTime.now().uptimeNanoseconds
        normalInputCountDuringMicrophone = 0
        microphoneUnmuteReassertionCount = 0
        lastMicrophoneUnmuteReassertionNanos = 0
        lastRateReportNanos = DispatchTime.now().uptimeNanoseconds
        lastRateReportMicrophoneCount = 0
        lastRateReportGamepadCount = 0
        microphoneSessionGeneration &+= 1
        isMicrophoneStreaming = true
        microphoneOutputCount = 1
        startMicrophoneKeepalive(to: device)
        DiagnosticLog.write("Bluetooth microphone HID return stream enabled")
        return kIOReturnSuccess
    }

    /// Stops routing microphone feedback without transmitting an undocumented
    /// controller-side disable. Exclusive HID ownership keeps sticky feedback
    /// from being interpreted as pointer or button input.
    public func stopMicrophoneStream() {
        guard isMicrophoneStreaming || microphoneTimer != nil else { return }
        isMicrophoneStreaming = false
        microphoneTimer?.cancel()
        microphoneTimer = nil
        // Wait only for the serial control producer. Healthy capture has no
        // periodic outbound reports, so there is no asynchronous write tail.
        microphoneQueue.sync {}

        microphoneDevice = nil
        microphoneCleanupPending = false
        hasLoggedContainedStaleMicrophoneFeedback = false
        DiagnosticLog.write(
            "Bluetooth microphone HID duplex stream stopped; inputFrames=\(microphoneInputCount), controlOutputFrames=\(microphoneOutputCount)"
        )
        if inputTap.isActive {
            let summary = inputTap.finish()
            for line in DualSenseMicrophoneInputTap.summaryLines(summary) {
                DiagnosticLog.write(line)
            }
        }
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice) {
        configure(device)
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let identifier = ObjectIdentifier(device)
        guard deviceInfo[identifier] != nil else { return }
        let wasConnected = isBluetoothConnected
        let wasActive = activeDevice === device
        if microphoneDevice === device {
            stopMicrophoneStream()
        }
        if explicitlySeizedDevices.remove(identifier) != nil {
            _ = IOHIDDeviceClose(
                device,
                IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            )
        }
        devices.removeValue(forKey: identifier)
        deviceInfo.removeValue(forKey: identifier)
        configuredDevices.remove(identifier)
        if wasActive {
            lastFaceButtonMask = nil
            lastMicrophoneButtonPressed = false
            requestedMicrophoneMuted = nil
            hasLoggedContainedStaleMicrophoneFeedback = false
        }
        DiagnosticLog.write("Bluetooth DualSense HID device removed")
        if wasConnected && !isBluetoothConnected {
            onConnectionChanged?(false)
        }
        onDevicesChanged?()
    }

    fileprivate func inputReport(
        result: IOReturn,
        device: IOHIDDevice,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex
    ) {
        let identifier = ObjectIdentifier(device)
        guard result == kIOReturnSuccess, var info = deviceInfo[identifier], reportLength > 0 else {
            return
        }
        if !info.acceptsInput {
            // In shared USB mode, only replace the system fallback after a
            // real gamepad packet confirms that this process can read it.
            guard !info.isBluetooth, reportID == 0x01,
                  reportLength == 63 || reportLength == 64 else { return }
            info = DualSenseHIDDevice(id: info.id, isBluetooth: false,
                                      stableID: info.stableID, acceptsInput: true)
            deviceInfo[identifier] = info
            onDevicesChanged?()
        }

        let bytes = UnsafeBufferPointer(start: report, count: Int(reportLength))
        onInputReport?(info, reportID, bytes)
        guard info.isBluetooth, activeDevice === device else { return }
        if inputTap.isActive {
            inputTap.record(
                timestampNanos: DispatchTime.now().uptimeNanoseconds,
                reportID: reportID,
                bytes: bytes
            )
        }
        if let packet = DualSenseBluetoothAudioPacketBuilder.microphonePacket(
            reportID: reportID,
            bytes: bytes
        ) {
            guard isMicrophoneStreaming, microphoneDevice === device else {
                recoverStaleMicrophoneModeIfNeeded()
                return
            }
            let frame = packet.opusFrame
            microphoneInputCount += 1
            lastMicrophoneInputNanos = DispatchTime.now().uptimeNanoseconds
            let hasEncodedSignal = frame.dropFirst(3).contains { $0 != 0 }
            if hasEncodedSignal {
                microphoneEncodedSignalFrameCount += 1
                if microphoneEncodedSignalFrameCount == 1 {
                    let profile = Self.microphoneCaptureProfiles[
                        microphoneCaptureProfileIndex
                    ]
                    DiagnosticLog.write(
                        "Bluetooth microphone real encoded signal detected on profile: \(profile.name)"
                    )
                }
            }
            if microphoneInputCount <= 3 || microphoneInputCount.isMultiple(of: 100) {
                DiagnosticLog.write(
                    "Bluetooth microphone Opus frame #\(microphoneInputCount), bytes=\(frame.count), " +
                    "prefix=\(Self.hexPrefix(frame, length: 12))"
                )
            }
            onMicrophoneOpusFrame?(frame, packet.counter)
            return
        }

        // The app parses its own input already. The vendor state is only
        // needed for mic control or opted-in legacy callbacks.
        guard isMicrophoneStreaming || handlesPhysicalMicrophoneButton || requestedMicrophoneMuted == nil ||
                onFaceButtonMaskChanged != nil || onGamepadState != nil,
              let state = DualSenseBluetoothAudioPacketBuilder.gamepadState(
            reportID: reportID,
            bytes: bytes
        ) else {
            return
        }
        let mask = state.faceButtonMask
        if requestedMicrophoneMuted == nil {
            requestedMicrophoneMuted = state.microphoneMuted
        }
        if handlesPhysicalMicrophoneButton {
            handlePhysicalMicrophoneButton(state: state)
        }
        if isMicrophoneStreaming {
            normalInputCountDuringMicrophone += 1
            if normalInputCountDuringMicrophone <= 8 {
                DiagnosticLog.write(
                    "Bluetooth genuine gamepad report #\(normalInputCountDuringMicrophone), length=\(bytes.count), " +
                    "faceMask=0x\(String(format: "%02x", mask)), micButton=\(state.microphoneButtonPressed), " +
                    "micMuted=\(state.microphoneMuted), headphones=\(state.headphonesConnected), " +
                    "micConnected=\(state.microphoneConnected), externalMic=\(state.externalMicrophoneActive), " +
                    "prefix=\(Self.hexPrefix(bytes, length: 16))"
                )
            }
            reassertMicrophoneUnmutedIfNeeded(state: state)
        }
        if mask != lastFaceButtonMask {
            lastFaceButtonMask = mask
            onFaceButtonMaskChanged?(mask)
        }
        onGamepadState?(state)
    }

    private static func hexPrefix(_ bytes: some Sequence<UInt8>, length: Int) -> String {
        bytes.prefix(length).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func configure(_ device: IOHIDDevice) {
        let identifier = ObjectIdentifier(device)
        guard !configuredDevices.contains(identifier) else { return }
        let isBluetooth = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) == "Bluetooth"
        guard isBluetooth || IOHIDDeviceConformsTo(device, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_GamePad)) else { return }

        var pairingInfo = [UInt8](repeating: 0, count: 64)
        pairingInfo[0] = 0x09
        var reportLength = pairingInfo.count
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            0x09,
            &pairingInfo,
            &reportLength
        )

        if isBluetooth, result != kIOReturnSuccess {
            DiagnosticLog.write("Bluetooth full-report handshake failed: \(result)")
        }

        let wasDisconnected = !isBluetoothConnected
        if isBluetooth, !isSeizingDevice, result == kIOReturnSuccess {
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess {
                explicitlySeizedDevices.insert(identifier)
            }
        }
        configuredDevices.insert(identifier)
        devices[identifier] = device
        let acceptsInput = isBluetooth ? result == kIOReturnSuccess &&
            (isSeizingDevice || explicitlySeizedDevices.contains(identifier)) : isSeizingDevice
        let info = Self.makeDeviceInfo(
            device, isBluetooth: isBluetooth, acceptsInput: acceptsInput,
            pairingInfo: result == kIOReturnSuccess ? pairingInfo.prefix(reportLength) : []
        )
        deviceInfo[identifier] = deviceInfo.values.contains(where: { $0.id == info.id })
            ? Self.sessionDeviceInfo(device, isBluetooth: isBluetooth, acceptsInput: acceptsInput) : info
        if wasDisconnected, isBluetooth {
            microphoneQueue.sync {
                packetBuilder = DualSenseBluetoothAudioPacketBuilder()
            }
            onConnectionChanged?(true)
        }
        onDevicesChanged?()
    }

    private static func makeDeviceInfo(
        _ device: IOHIDDevice, isBluetooth: Bool, acceptsInput: Bool, pairingInfo: ArraySlice<UInt8>
    ) -> DualSenseHIDDevice {
        let address = pairingInfo.dropFirst().prefix(6)
        let hasAddress = pairingInfo.first == 0x09 && address.count == 6 &&
            address.contains(where: { $0 != 0 }) && address.contains(where: { $0 != 0xff })
        let serial = (IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = hasAddress ? Data(address) : Data((serial ?? "").utf8)
        let transport = isBluetooth ? "bt" : "usb"
        if !identity.isEmpty {
            let fingerprint = SHA256.hash(data: identity).prefix(16).map { String(format: "%02x", $0) }.joined()
            return DualSenseHIDDevice(id: "\(transport):\(fingerprint)", isBluetooth: isBluetooth,
                                      stableID: true, acceptsInput: acceptsInput)
        }
        return sessionDeviceInfo(device, isBluetooth: isBluetooth, acceptsInput: acceptsInput)
    }

    private static func sessionDeviceInfo(
        _ device: IOHIDDevice, isBluetooth: Bool, acceptsInput: Bool
    ) -> DualSenseHIDDevice {
        var registryID: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        let transport = isBluetooth ? "bt" : "usb"
        let sessionID = registryID == 0 ? String(describing: ObjectIdentifier(device)) : String(registryID)
        return DualSenseHIDDevice(id: "\(transport):session:\(sessionID)", isBluetooth: isBluetooth,
                                  stableID: false, acceptsInput: acceptsInput)
    }

    private func send(_ report: [UInt8], to device: IOHIDDevice) -> IOReturn {
        report.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(report[0]),
                baseAddress,
                report.count
            )
        }
    }

    private func nextMicrophoneStateReport(muted: Bool) -> [UInt8] {
        packetBuilder.microphoneStateReport(muted: muted)
    }

    public func setMicrophoneMuted(_ muted: Bool) {
        guard hasExclusiveBluetoothAccess, let device = microphoneDevice ?? activeDevice else { return }
        requestedMicrophoneMuted = muted
        microphoneQueue.async { [weak self, weak device] in
            guard let self, let device else { return }
            self.pausesMicrophoneArming = muted
            _ = self.send(self.nextMicrophoneStateReport(muted: muted), to: device)
        }
    }

    /// The controller has a hardware mute latch as well as an audio-stream
    /// enable bit. Reassert unmute when its own status byte says the latch is
    /// still active, throttled so control traffic cannot starve Opus packets.
    private func reassertMicrophoneUnmutedIfNeeded(
        state: DualSenseBluetoothGamepadState
    ) {
        guard requestedMicrophoneMuted != true,
              state.microphoneMuted,
              let device = microphoneDevice else {
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let minimumInterval: UInt64 = 250_000_000
        guard lastMicrophoneUnmuteReassertionNanos == 0
                || now &- lastMicrophoneUnmuteReassertionNanos >= minimumInterval else {
            return
        }
        lastMicrophoneUnmuteReassertionNanos = now

        microphoneQueue.async { [weak self, weak device] in
            guard let self, let device, self.isMicrophoneStreaming, !self.pausesMicrophoneArming else { return }
            let result = self.send(
                self.nextMicrophoneStateReport(muted: false),
                to: device
            )
            self.microphoneUnmuteReassertionCount += 1
            if self.microphoneUnmuteReassertionCount <= 3
                || self.microphoneUnmuteReassertionCount.isMultiple(of: 10) {
                DiagnosticLog.write(
                    "Bluetooth controller still reported mic muted; unmute reassertion #\(self.microphoneUnmuteReassertionCount), result=\(result)"
                )
            }
        }
    }

    /// The controller's microphone switch reports a button edge; the host is
    /// responsible for sending the matching hardware mute command. Since this
    /// bridge seizes the HID device, macOS cannot perform that response for us.
    private func handlePhysicalMicrophoneButton(
        state: DualSenseBluetoothGamepadState
    ) {
        let wasPressed = lastMicrophoneButtonPressed
        lastMicrophoneButtonPressed = state.microphoneButtonPressed
        guard state.microphoneButtonPressed, !wasPressed else {
            return
        }
        setMicrophoneMuted(!state.microphoneMuted)
    }

    /// Re-arm the controller only if microphone feedback stalls, and sample
    /// transport diagnostics at a low rate. A measured 100 Hz inert-output
    /// experiment consumed outbound HID capacity without increasing incoming
    /// microphone or gamepad delivery, so healthy capture sends no keepalive.
    private func startMicrophoneKeepalive(to device: IOHIDDevice) {
        let generation = microphoneSessionGeneration
        let timer = DispatchSource.makeTimerSource(queue: microphoneQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(250),
            repeating: .milliseconds(250),
            leeway: .milliseconds(25)
        )
        timer.setEventHandler { [weak self, weak device] in
            guard let self, let device,
                  self.isMicrophoneStreaming,
                  self.microphoneSessionGeneration == generation else {
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds

            if now &- self.lastRateReportNanos >= 2_000_000_000 {
                let elapsed = Double(now &- self.lastRateReportNanos)
                    / 1_000_000_000.0
                let microphoneDelta = self.microphoneInputCount
                    - self.lastRateReportMicrophoneCount
                let gamepadDelta = self.normalInputCountDuringMicrophone
                    - self.lastRateReportGamepadCount
                DiagnosticLog.write(
                    String(
                        format: "Bluetooth live transport: mic=%.1f/s, gamepad=%.1f/s, total=%.1f/s",
                        Double(microphoneDelta) / elapsed,
                        Double(gamepadDelta) / elapsed,
                        Double(microphoneDelta + gamepadDelta) / elapsed
                    )
                )
                self.lastRateReportNanos = now
                self.lastRateReportMicrophoneCount = self.microphoneInputCount
                self.lastRateReportGamepadCount = self.normalInputCountDuringMicrophone
            }

            let feedbackIsStalled = self.lastMicrophoneInputNanos == 0
                || now &- self.lastMicrophoneInputNanos >= 1_000_000_000
            let armingIsDue = self.lastMicrophoneArmingNanos == 0
                || now &- self.lastMicrophoneArmingNanos >= 250_000_000
            if feedbackIsStalled, armingIsDue, !self.pausesMicrophoneArming {
                self.lastMicrophoneArmingNanos = now
                self.lastMicrophoneControlNanos = now
                self.microphoneControlKeepaliveCount += 1
                let result = self.send(
                    self.packetBuilder.microphoneArmingReport(
                        microphoneVolume: self.microphoneVolume
                    ),
                    to: device
                )
                if result == kIOReturnSuccess {
                    self.microphoneOutputCount += 1
                    if self.microphoneOutputCount <= 3
                        || self.microphoneOutputCount.isMultiple(of: 20) {
                        DiagnosticLog.write(
                            "Bluetooth microphone control-only 0x36 arming report #\(self.microphoneOutputCount) sent"
                        )
                    }
                } else {
                    DiagnosticLog.write(
                        "Bluetooth microphone 0x36 arming report failed: \(result)"
                    )
                }
            }
        }
        microphoneTimer = timer
        timer.resume()
    }

    /// A sticky audio frame outside an intentional route is harmless while the
    /// bridge owns the HID device exclusively. Drop it here; attempting to
    /// "disable" it with an undocumented transition can prevent re-arming
    /// until the controller reconnects.
    private func recoverStaleMicrophoneModeIfNeeded() {
        guard !hasLoggedContainedStaleMicrophoneFeedback else { return }
        hasLoggedContainedStaleMicrophoneFeedback = true
        DiagnosticLog.write(
            "Sticky Bluetooth microphone feedback safely contained under explicit HID isolation"
        )
    }

    /// IOHIDManager does not reliably resume raw report delivery after the
    /// same instance is closed and reopened with different seize options.
    /// Rebuilding the manager gives each normal/exclusive session its own
    /// input-report connection and keeps both audio and button-up reports live.
    private func openFreshManager(exclusive: Bool) -> IOReturn {
        closeCurrentManager()
        configuredDevices.removeAll()
        explicitlySeizedDevices.removeAll()
        devices.removeAll()
        deviceInfo.removeAll()
        lastFaceButtonMask = nil
        lastMicrophoneButtonPressed = false
        requestedMicrophoneMuted = nil

        manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        let sonyController: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x054c,
            kIOHIDProductIDKey as String: 0x0ce6
        ]
        let transports = includesUSBDevices ? ["Bluetooth", "USB"] : ["Bluetooth"]
        let matching = transports.map { transport -> [String: Any] in
            var match = sonyController
            match[kIOHIDTransportKey as String] = transport
            if transport == "USB" {
                match[kIOHIDDeviceUsagePageKey as String] = kHIDPage_GenericDesktop
                match[kIOHIDDeviceUsageKey as String] = kHIDUsage_GD_GamePad
            }
            return match
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            dualSenseBluetoothDeviceMatched,
            context
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            dualSenseBluetoothDeviceRemoved,
            context
        )
        IOHIDManagerRegisterInputReportCallback(
            manager,
            dualSenseBluetoothInputReport,
            context
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        let options = exclusive
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        isSeizingDevice = exclusive
        let result = IOHIDManagerOpen(manager, options)
        guard result == kIOReturnSuccess else {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            isSeizingDevice = false
            managerIsOpen = false
            return result
        }

        managerIsOpen = true
        isSeizingDevice = exclusive
        if let matched = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in matched {
                configure(device)
            }
        }
        return result
    }

    private func closeCurrentManager() {
        guard managerIsOpen else { return }
        for (identifier, device) in devices
            where explicitlySeizedDevices.contains(identifier) {
            _ = IOHIDDeviceClose(
                device,
                IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            )
        }
        explicitlySeizedDevices.removeAll()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        let options = isSeizingDevice
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        IOHIDManagerClose(manager, options)
        managerIsOpen = false
        isSeizingDevice = false
    }

}

private func dualSenseBluetoothDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<DualSenseBluetoothEnhancedModeEnabler>
        .fromOpaque(context)
        .takeUnretainedValue()
        .deviceMatched(device)
}

private func dualSenseBluetoothDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<DualSenseBluetoothEnhancedModeEnabler>
        .fromOpaque(context)
        .takeUnretainedValue()
        .deviceRemoved(device)
}

private func dualSenseBluetoothInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard type == kIOHIDReportTypeInput, let context, let sender else { return }
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    guard CFGetTypeID(device) == IOHIDDeviceGetTypeID() else { return }
    Unmanaged<DualSenseBluetoothEnhancedModeEnabler>
        .fromOpaque(context)
        .takeUnretainedValue()
        .inputReport(
            result: result,
            device: device,
            reportID: reportID,
            report: report,
            reportLength: reportLength
        )
}
