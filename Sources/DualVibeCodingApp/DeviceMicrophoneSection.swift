import CoreAudio
import SwiftUI

struct DeviceMicrophoneSection: View {
    @EnvironmentObject private var microphone: MicrophoneManager
    @EnvironmentObject private var i18n: LocalizationStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusTone: DualVibeStatusBadge.Tone {
        if microphone.isMuted { return .neutral }
        if microphone.isSystemInputActive || microphone.isListening { return .positive }
        return microphone.isAvailable ? .accent : .neutral
    }

    private var statusSymbol: String {
        if microphone.isMuted { return "mic.slash.fill" }
        if microphone.isSystemInputActive || microphone.isListening { return "mic.fill" }
        return "mic"
    }

    var body: some View {
        let _ = i18n.language
        Section {
            Toggle(isOn: Binding(
                get: { microphone.automaticallyUsesSystemInput },
                set: { microphone.setAutomaticallyUsesSystemInput($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("自动使用选定麦克风", "Auto-Select Microphone"))
                    Text(L("手柄连接或触发语音动作时自动切换系统输入源",
                           "Automatically switch system input when controller connects or voice activates"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent(L("当前状态", "Status")) {
                DualVibeStatusBadge(
                    text: localizedMicrophoneStatus(microphone.status),
                    systemImage: statusSymbol,
                    tone: statusTone
                )
            }

            if microphone.choices.count > 1 {
                Picker(L("系统输入设备", "System Input"), selection: Binding(
                    get: { microphone.selectedDeviceID },
                    set: { microphone.selectDevice(id: $0) }
                )) {
                    ForEach(microphone.choices) { device in
                        Text(device.isAgentRemoteBridge
                             ? L("DualSense 蓝牙", "DualSense Bluetooth")
                             : device.isPhysicalDualSense
                             ? "\(device.name)（DualSense）"
                             : L("\(device.name)（系统）", "\(device.name) (System)"))
                            .tag(Optional(device.id))
                    }
                }
            }

            if microphone.isAvailable, microphone.showsInputLevel {
                LabeledContent(L("输入电平", "Input Level")) {
                    DualVibeLevelMeter(level: microphone.inputLevel)
                        .frame(width: 196)
                        .accessibilityLabel(L("麦克风输入电平", "Microphone Input Level"))
                }
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                if microphone.isAvailable {
                    if !microphone.isSystemInputActive {
                        Button {
                            if microphone.isListening {
                                microphone.stopListening()
                                microphone.scan()
                            } else {
                                microphone.startListening()
                            }
                        } label: {
                            Label(microphone.isListening ? L("结束测试", "Stop Test") : L("测试麦克风", "Test Mic"),
                                  systemImage: microphone.isListening ? "stop.circle" : "waveform")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .tint(microphone.isListening ? DualVibePalette.lightBar(for: colorScheme) : nil)
                    }

                    Button {
                        microphone.toggleMuted()
                    } label: {
                        Label(microphone.isMuted ? L("取消静音", "Unmute") : L("静音", "Mute"),
                              systemImage: microphone.isMuted ? "mic.fill" : "mic.slash")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .disabled(!microphone.canMute)

                    Button {
                        microphone.toggleSystemInput()
                    } label: {
                        Label(microphone.isSystemInputActive ? L("恢复系统输入", "Restore System Input") : L("启用系统输入", "Enable System Input"),
                              systemImage: microphone.isSystemInputActive ? "arrow.uturn.backward" : "checkmark.circle")
                    }
                    .disabled(!microphone.isSystemInputActive && !microphone.canStartSystemInput)
                }

                Spacer()

                Button {
                    microphone.scan()
                } label: {
                    Label(L("重新扫描", "Rescan"), systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if microphone.hasBluetoothSource, !microphone.isDriverActive, microphone.canInstallDriver {
                HStack(alignment: .center, spacing: 12) {
                    DualVibeIconBadge(systemImage: "waveform.badge.plus", tint: .orange, size: 30, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("需要虚拟音频驱动", "Virtual Audio Driver Required"))
                            .font(.subheadline.weight(.semibold))
                        Text(L("将蓝牙语音提供给听写和其他 App 需要虚拟麦克风。安装时 macOS 会请求管理员授权并重新加载音频服务。",
                               "A virtual microphone is needed to route DualSense Bluetooth voice to dictation and other apps."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(L("安装驱动…", "Install Driver…")) { microphone.installDriver() }
                        .buttonStyle(.borderedProminent)
                        .disabled(microphone.isInstallingDriver)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text(L("麦克风与语音", "Microphone & Voice"))
        }
        .animation(DualVibeMotion.resolve(DualVibeMotion.snappy, reduceMotion: reduceMotion), value: microphone.showsInputLevel)
        .animation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion), value: microphone.isMuted)
        .animation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion), value: microphone.isSystemInputActive)
    }
}
