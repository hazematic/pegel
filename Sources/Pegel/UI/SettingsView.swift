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

            Section(L("settings.section.tones")) {
                LabeledContent(L("settings.tones.label")) {
                    HStack(spacing: 8) {
                        Picker(L("settings.tones.label"), selection: $state.toneSet) {
                            Text(L("tones.off")).tag(ToneSet?.none)
                            Divider()
                            ForEach(ToneSet.allCases, id: \.self) { set in
                                Text(set.label).tag(ToneSet?.some(set))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()

                        Button {
                            if let toneSet = state.toneSet { Tones.preview(toneSet) }
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .help(L("settings.tones.play"))
                        .accessibilityLabel(L("settings.tones.play"))
                        .disabled(state.toneSet == nil)
                    }
                }

                Text(L("settings.tones.explanation"))
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
        .frame(width: SettingsLayout.width, height: 740)
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
        .onChange(of: state.toneSet) { _, toneSet in
            state.persistToneSet()
            // Hear the choice right away.
            if let toneSet { Tones.preview(toneSet) }
        }
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

                VStack(alignment: .leading, spacing: 10) {
                    Text(L("settings.palette"))
                    HStack(spacing: 0) {
                        ForEach(PillPalette.allCases, id: \.self) { palette in
                            PaletteSwatch(
                                palette: palette, selected: state.palette == palette
                            ) {
                                state.palette = palette
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                Toggle(L("settings.showTime"), isOn: $state.indicatorShowsTime)

                Text(L("settings.showTime.explanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 620)
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

/// A round dot with the palette's gradient and its name below, as on the product page.
private struct PaletteSwatch: View {
    let palette: PillPalette
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                // Like the tag dots in Finder: small, flat, edged in a darker shade
                // of their own colour. Black at low opacity gives that shade in light
                // and dark mode alike; a white or grey rim read as blur.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: palette.traceStops.map { Color(hex: $0) },
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 1))
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 18, height: 18)
                Text(palette.label)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
