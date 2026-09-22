import SwiftUI

struct GeneralSettingsView: View {

    @ObservedObject var state: AppState
    let controller: RecordingController

    @State private var rejection: String?

    var body: some View {
        Form {
            Section(L("settings.section.hotkey")) {
                LabeledContent(L("settings.hotkey.label")) {
                    VStack(spacing: 4) {
                        HotkeyRecorderField(
                            binding: $state.binding,
                            onRejected: { reason in rejection = reason },
                            onCaptureChanged: { controller.setHotkeyCapture($0) })
                        .frame(width: 220, height: 38)
                        Text(L("hotkey.clickToChange"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

            Section(L("settings.section.audio")) {
                Picker(L("settings.input.label"), selection: $state.inputDeviceUID) {
                    Text(L("settings.input.systemDefault")).tag(String?.none)
                    ForEach(state.inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }

                if let device = state.effectiveInputDevice {
                    // The only place that shows which device the system default resolves to.
                    Text(L("settings.input.current", device.summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if device.isNarrowband {
                        Text(L("settings.input.narrowband"))
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(L("settings.input.none"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if state.inputDeviceMissing {
                    Text(L("settings.input.missing"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Text(L("settings.input.explanation"))
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
        .frame(width: SettingsLayout.width, height: 640)
        .onAppear { state.refreshInputDevices() }
        .onChange(of: state.binding) { _, _ in
            state.persistBinding()
            controller.applyBindingChange()
            rejection = nil
        }
        .onChange(of: state.pushToTalkThreshold) { _, _ in
            state.persistThreshold()
        }
        .onChange(of: state.inputDeviceUID) { _, _ in state.persistInputDevice() }
    }
}

struct AppearanceSettingsView: View {

    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                PillPreview(state: state)
            }

            Section {
                Picker(L("settings.waveform"), selection: $state.waveformStyle) {
                    ForEach(WaveformStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(state.waveformStyle.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LabeledContent(L("settings.palette")) {
                    HStack(spacing: 8) {
                        ForEach(PillPalette.allCases, id: \.self) { palette in
                            PaletteSwatch(
                                palette: palette, selected: state.palette == palette
                            ) {
                                state.palette = palette
                            }
                        }
                    }
                }

                Text("\(state.palette.label): \(state.palette.note)")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(L("settings.showTime"), isOn: $state.indicatorShowsTime)

                Text(L("settings.showTime.explanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 600)
        .onChange(of: state.waveformStyle) { _, _ in state.persistAppearance() }
        .onChange(of: state.indicatorShowsTime) { _, _ in state.persistAppearance() }
        .onChange(of: state.palette) { _, _ in state.persistAppearance() }
    }
}

/// Shared width, so switching tabs only changes the height.
enum SettingsLayout {
    static let width: CGFloat = 520
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

/// On the pill's dark background, as it will look on screen.
private struct PaletteSwatch: View {
    let palette: PillPalette
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                ForEach(0..<11, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(palette.levelColor(at: index))
                        .frame(width: 2, height: 9)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Indicator.capsuleColor))
            .overlay(
                Capsule().strokeBorder(
                    selected ? Color.accentColor : .clear, lineWidth: 2)
                    .padding(-3)
            )
            .padding(3)
        }
        .buttonStyle(.plain)
        .help(palette.label)
        .accessibilityLabel(palette.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
