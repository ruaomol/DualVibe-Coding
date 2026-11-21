import CoreAudio
import SwiftUI

struct DeviceMicrophoneSection: View {
    @EnvironmentObject private var microphone: MicrophoneManager

    var body: some View {
        Section("麦克风") {
            Toggle("自动使用选定麦克风", isOn: Binding(
                get: { microphone.automaticallyUsesSystemInput },
                set: { microphone.setAutomaticallyUsesSystemInput($0) }
            ))
            LabeledContent("状态") {
                Text(microphone.status)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if microphone.choices.count > 1 {
                Picker("系统输入", selection: Binding(
                    get: { microphone.selectedDeviceID },
                    set: { microphone.selectDevice(id: $0) }
                )) {
                    ForEach(microphone.choices) { device in
                        Text(device.isAgentRemoteBridge
                             ? "DualSense 蓝牙"
                             : device.isPhysicalDualSense
                             ? "\(device.name)（DualSense）"
                             : "\(device.name)（系统）")
                            .tag(Optional(device.id))
                    }
                }
            }

            if microphone.isAvailable {
                if microphone.showsInputLevel {
                    LabeledContent("输入电平") {
                        ProgressView(value: microphone.inputLevel)
                            .frame(width: 160)
                            .accessibilityLabel("麦克风输入电平")
                    }
                }
                HStack {
                    if !microphone.isSystemInputActive {
                        Button(microphone.isListening ? "结束测试" : "测试麦克风") {
                            if microphone.isListening {
                                microphone.stopListening()
                                microphone.scan()
                            } else {
                                microphone.startListening()
                            }
                        }
                    }

                    Button(microphone.isMuted ? "取消静音" : "静音") {
                        microphone.toggleMuted()
                    }
                    .disabled(!microphone.canMute)

                    Button(microphone.isSystemInputActive ? "恢复系统输入" : "启用系统输入") {
                        microphone.toggleSystemInput()
                    }
                    .disabled(!microphone.isSystemInputActive && !microphone.canStartSystemInput)

                    Spacer()
                    Button("重新扫描") { microphone.scan() }
                }
            } else {
                Button("重新扫描") { microphone.scan() }
            }

            if microphone.hasBluetoothSource, !microphone.isDriverActive, microphone.canInstallDriver {
                HStack {
                    Text("将蓝牙语音提供给听写和其他 App 需要虚拟麦克风。安装时 macOS 会请求管理员授权并重新加载音频服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("安装蓝牙麦克风驱动…") { microphone.installDriver() }
                        .disabled(microphone.isInstallingDriver)
                }
            }
        }
    }
}
