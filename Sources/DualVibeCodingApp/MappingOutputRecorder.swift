import AppKit
import SwiftUI

enum RecordedMappingOutput {
    case keyboard(RecordedShortcut)
    case mouse(MappingAction)

    init?(event: NSEvent) {
        switch event.type {
        case .keyDown where !event.isARepeat: self = .keyboard(RecordedShortcut(event: event))
        case .flagsChanged:
            guard let shortcut = RecordedShortcut(modifierEvent: event) else { return nil }
            self = .keyboard(shortcut)
        case .leftMouseDown: self = .mouse(.leftClick)
        case .rightMouseDown: self = .mouse(.rightClick)
        case .otherMouseDown where event.buttonNumber == 2: self = .mouse(.middleClick)
        default: return nil
        }
    }

    func applying(to original: MappingBinding) -> MappingBinding {
        var binding = original
        switch self {
        case .keyboard(let shortcut):
            binding.action = .shortcut
            binding.shortcut = shortcut
        case .mouse(let action):
            binding.action = action
        }
        return binding
    }
}

struct MappingOutputRecorder: View {
    let binding: MappingBinding
    let onRecord: (RecordedMappingOutput) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if binding.action == .shortcut, let shortcut = binding.shortcut {
                DualVibeKeycap(text: shortcut.title, prominent: true)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            }
            MappingOutputRecorderControl(onRecord: onRecord)
                .frame(width: 136, height: 24)
        }
        .animation(DualVibeMotion.resolve(DualVibeMotion.tactile, reduceMotion: reduceMotion),
                   value: binding.shortcut?.title)
    }
}

private struct MappingOutputRecorderControl: NSViewRepresentable {
    let onRecord: (RecordedMappingOutput) -> Void

    func makeNSView(context: Context) -> MappingOutputRecorderButton {
        let button = MappingOutputRecorderButton()
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = button
        button.action = #selector(MappingOutputRecorderButton.toggleRecording)
        button.resetAppearance()
        return button
    }

    func updateNSView(_ button: MappingOutputRecorderButton, context: Context) {
        button.onRecord = onRecord
        button.refreshIdleTitleIfNeeded()
    }

    static func dismantleNSView(_ button: MappingOutputRecorderButton, coordinator: ()) {
        button.stopRecording()
    }
}

private final class MappingOutputRecorderButton: NSButton {
    private static weak var activeRecorder: MappingOutputRecorderButton?

    var onRecord: ((RecordedMappingOutput) -> Void)?
    private var monitor: Any?
    private var windowObserver: NSObjectProtocol?
    private var pendingClick: Task<Void, Never>?
    private var leftPress: (startedAt: TimeInterval, isSecondClick: Bool)?
    private var pendingModifier: RecordedShortcut?

    func resetAppearance() {
        title = L("录入快捷键…", "Record Input…")
        bezelColor = nil
        contentTintColor = nil
        toolTip = L("录入键盘快捷键、左键单击／双击／长按，或鼠标右键、中键",
                    "Record keyboard shortcut, left click/double-click/long press, or right/middle click")
    }

    func refreshIdleTitleIfNeeded() {
        if monitor == nil { resetAppearance() }
    }

    @objc func toggleRecording() {
        if monitor != nil {
            stopRecording()
            return
        }
        guard let window else { return }

        Self.activeRecorder?.stopRecording()
        Self.activeRecorder = self
        title = L("等待键盘或鼠标…", "Press Key / Mouse…")
        bezelColor = .controlAccentColor
        toolTip = L("在此窗口内按下键盘或点击鼠标。再次点击按钮可取消。",
                    "Press a key or click the mouse in this window. Click again to cancel.")

        let types: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            guard let self, let window = self.window, NSApp.isActive, window.isKeyWindow,
                  (event.type == .keyDown || event.type == .flagsChanged || event.window === window)
            else { return event }

            switch event.type {
            case .leftMouseDown:
                return self.beginLeftPress(event)
            case .leftMouseUp:
                return self.endLeftPress(event)
            case .flagsChanged:
                if let modifier = RecordedShortcut(modifierEvent: event) {
                    self.pendingModifier = self.pendingModifier?.merging(modifier) ?? modifier
                    return nil
                }
                if let modifier = self.pendingModifier {
                    self.finish(.keyboard(modifier))
                    return nil
                }
                return event
            default:
                guard let recorded = RecordedMappingOutput(event: event) else { return event }
                self.finish(recorded)
                return nil
            }
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        }
    }

    private func beginLeftPress(_ event: NSEvent) -> NSEvent? {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { return event }
        let hadClick = pendingClick != nil
        if hadClick, event.clickCount < 2 {
            finish(.mouse(.leftClick))
            return event
        }
        pendingClick?.cancel()
        pendingClick = nil
        leftPress = (event.timestamp, hadClick)
        return nil
    }

    private func endLeftPress(_ event: NSEvent) -> NSEvent? {
        guard let press = leftPress else { return event }
        leftPress = nil
        if event.timestamp - press.startedAt >= 0.55 {
            finish(.mouse(.leftLongPress))
        } else if press.isSecondClick {
            finish(.mouse(.leftDoubleClick))
        } else {
            pendingClick = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) } catch { return }
                self?.finish(.mouse(.leftClick))
            }
        }
        return nil
    }

    private func finish(_ recorded: RecordedMappingOutput) {
        stopRecording()
        onRecord?(recorded)
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        monitor = nil
        windowObserver = nil
        pendingClick?.cancel()
        pendingClick = nil
        leftPress = nil
        pendingModifier = nil
        if Self.activeRecorder === self { Self.activeRecorder = nil }
        resetAppearance()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
}
