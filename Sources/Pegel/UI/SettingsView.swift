import SwiftUI

struct SettingsView: View {

    @ObservedObject var state: AppState
    let controller: RecordingController

    @State private var rejection: String?

    var body: some View {
        Form {
            Section(L("settings.section.hotkey")) {
                LabeledContent(L("settings.hotkey.label")) {
                    HotkeyRecorderField(
                        binding: $state.binding,
                        onRejected: { reason in rejection = reason },
                        onCaptureChanged: { controller.setHotkeyCapture($0) })
                    .frame(width: 150, height: 26)
                }

                if let rejection {
                    Text(rejection)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                LabeledContent(L("settings.ptt.label")) {
                    HStack {
                        Slider(value: $state.pushToTalkThreshold, in: 0.15...0.8, step: 0.05)
                            .frame(width: 160)
                        Text("\(Int(state.pushToTalkThreshold * 1000)) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Text(L("settings.ptt.explanation"))
                .font(.callout)
                .foregroundStyle(.secondary)

                Button(L("settings.hotkey.reset", HotkeyBinding.fallback.displayString)) {
                    state.binding = .fallback
                    rejection = nil
                }
            }

            Section(L("settings.section.appearance")) {
                Picker(L("settings.waveform"), selection: $state.waveformStyle) {
                    ForEach(WaveformStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(state.waveformStyle.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(L("settings.showTime"), isOn: $state.indicatorShowsTime)

                Text(L("settings.showTime.explanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.section.permissions")) {
                PermissionRow(
                    title: L("permission.microphone"), granted: Permissions.microphoneGranted,
                    action: Permissions.openMicrophoneSettings)
                PermissionRow(
                    title: L("permission.accessibility"), granted: Permissions.accessibilityGranted,
                    action: Permissions.openAccessibilitySettings)
                PermissionRow(
                    title: L("permission.inputMonitoring"), granted: Permissions.inputMonitoringGranted,
                    action: Permissions.openInputMonitoringSettings)
                Text(L("settings.permissions.explanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L("settings.section.model")) {
                LabeledContent(L("settings.model.label"), value: "Parakeet TDT 0.6B v3")
                Text(L("settings.model.explanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .onChange(of: state.binding) { _, _ in
            state.persistBinding()
            controller.applyBindingChange()
            rejection = nil
        }
        .onChange(of: state.pushToTalkThreshold) { _, _ in
            state.persistThreshold()
        }
        .onChange(of: state.waveformStyle) { _, _ in state.persistAppearance() }
        .onChange(of: state.indicatorShowsTime) { _, _ in state.persistAppearance() }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                if !granted {
                    Button(L("button.open"), action: action)
                }
            }
        }
    }
}
