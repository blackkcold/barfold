import AppKit
import BarFoldProtocol
import SwiftUI

struct HotkeyRecorder: View {
    let combo: KeyCombo?
    let onChange: (KeyCombo?) -> Void
    var errorMessage: String?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: startRecording) {
                    HStack(spacing: 5) {
                        if isRecording {
                            Text(L10n.t("按下快捷键…", "Press a shortcut…"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else if let combo {
                            ForEach(Array(components(for: combo).enumerated()), id: \.offset) { _, part in
                                KeyCap(text: part)
                            }
                        } else {
                            Text(L10n.t("未设置", "Not set"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: BarFoldTheme.controlRadius, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: BarFoldTheme.controlRadius, style: .continuous)
                            .stroke(
                                isRecording ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: isRecording ? 1.5 : 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("录制全局快捷键", "Record global shortcut"))

                if combo != nil {
                    Button {
                        onChange(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("清除快捷键", "Clear shortcut"))
                }

                if isRecording {
                    Button(L10n.t("取消", "Cancel")) {
                        stopRecording()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(L10n.t("点击后按下组合键", "Click, then press a combination"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func components(for combo: KeyCombo) -> [String] {
        var parts: [String] = []
        if combo.hasControl { parts.append("⌃") }
        if combo.hasOption { parts.append("⌥") }
        if combo.hasShift { parts.append("⇧") }
        if combo.hasCommand { parts.append("⌘") }
        parts.append(KeyCodeMap.displayName(for: combo.keyCode))
        return parts
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording()
            return
        }

        if event.keyCode == 51,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onChange(nil)
            stopRecording()
            return
        }

        let newCombo = KeyCombo(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers(event.modifierFlags)
        )
        guard newCombo.isValid else {
            NSSound.beep()
            return
        }
        onChange(newCombo)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= KeyCombo.controlModifier }
        if flags.contains(.option) { result |= KeyCombo.optionModifier }
        if flags.contains(.shift) { result |= KeyCombo.shiftModifier }
        if flags.contains(.command) { result |= KeyCombo.commandModifier }
        return result
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}
