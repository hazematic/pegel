import AppKit
import Foundation
import os

/// The app's state machine: hotkey, recording, transcription, insertion, indicator.
@MainActor
final class RecordingController {

    private enum Mode {
        case idle
        /// Recording; hold or toggle not decided yet.
        case awaitingRelease(since: Date)
        /// Toggle: runs until the next press.
        case latched
    }

    private let appState: AppState
    private let capture = AudioCapture()
    private let service = TranscriptionService()
    private let indicator = IndicatorPanelController()
    private let monitor: HotkeyMonitor
    private let log = Logger(subsystem: "io.github.hazematic.pegel", category: "controller")

    private var mode: Mode = .idle
    /// The press that ends a latched recording still produces a release to ignore.
    private var ignoreNextRelease = false
    /// A press during the previous transcription; starts once that is inserted.
    private var pendingStart: (since: Date, released: Bool)?
    private var preparation: Task<Void, Never>?
    private var deviceWatcher: AudioDeviceWatcher?
    private var fileTask: Task<Void, Never>?

    var onNeedsSetup: (() -> Void)?

    init(appState: AppState) {
        self.appState = appState
        self.monitor = HotkeyMonitor(binding: appState.binding)

        monitor.onSignal = { [weak self] signal in
            guard let self else { return }
            switch signal {
            case .hotkeyDown: self.hotkeyPressed()
            case .hotkeyUp: self.hotkeyReleased()
            case .escape: self.cancel()
            }
        }

        capture.onLevel = { [weak self] level in
            self?.appState.level = level
            self?.indicator.update(level: level)
        }
        capture.onLimitReached = { [weak self] in
            self?.log.notice("Recording limit reached, stopping")
            self?.finishRecording()
        }
        // Keep what was captured before the device dropped out.
        capture.onInterrupted = { [weak self] in
            self?.finishRecording()
        }
        indicator.onCancel = { [weak self] in
            self?.cancelFileTranscription()
        }
    }

    // MARK: - Start

    func start() {
        appState.refreshInputDevices()
        observeDevices()
        observeWake()

        // Only with permissions granted; otherwise `tapCreate` prompts before onboarding.
        if Permissions.accessibilityGranted, Permissions.inputMonitoringGranted {
            appState.hotkeyActive = monitor.start()
        } else {
            appState.hotkeyActive = false
        }

        // The download needs explicit consent in the setup window.
        if TranscriptionService.isModelInstalled {
            loadModel()
        } else {
            appState.install = .waitingForConsent
            appState.session = .preparing(L("preparing.waiting"))
        }
    }

    func installModel() {
        guard !appState.install.isRunning else { return }
        loadModel()
    }

    var hasCustomIndicatorPosition: Bool { indicator.hasCustomPosition }

    func resetIndicatorPosition() {
        indicator.resetPosition()
    }

    // MARK: - Audio file

    /// Clipboard, not the caret: long files take a while, and by then focus may have moved.
    func transcribeFile() {
        guard case .ready = appState.session else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("file.panel.message")
        panel.prompt = L("file.panel.prompt")
        // Otherwise the panel opens behind the active app.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard case .ready = appState.session else { return }

        appState.session = .transcribing
        appState.fileProgress = nil
        applyAppearance()
        indicator.startFile()
        monitor.isTranscribingFile = true
        log.info("Transcribing audio file")

        fileTask = Task {
            defer {
                appState.fileProgress = nil
                monitor.isTranscribingFile = false
                fileTask = nil
            }
            do {
                let text = try await service.transcribe(fileAt: url) { value in
                    Task { @MainActor in
                        // Drop late updates so they don't show in the next dictation.
                        guard case .transcribing = self.appState.session else { return }
                        self.appState.fileProgress = value
                        self.indicator.updateFile(progress: value)
                    }
                }
                guard !Task.isCancelled else { return fileCancelled() }
                copyFileResult(text)
            } catch {
                if Task.isCancelled || error is CancellationError { return fileCancelled() }
                log.error("File transcription failed: \(error.localizedDescription)")
                report(error.localizedDescription)
            }
        }
    }

    /// Triggered by the X in the pill and by Escape.
    func cancelFileTranscription() {
        guard let fileTask else { return }
        fileTask.cancel()
        indicator.flash(.discarded, duration: 0.25)
    }

    /// Ready only once the model has actually stopped, so a new dictation can't overlap.
    private func fileCancelled() {
        appState.session = .ready
        log.info("File transcription cancelled")
    }

    private func applyAppearance() {
        indicator.apply(
            style: appState.waveformStyle, showsTime: appState.indicatorShowsTime,
            palette: appState.palette)
    }

    private func copyFileResult(_ text: String) {
        guard !text.isEmpty else {
            report(L("error.noSpeech"))
            return
        }
        // No clipboard restore: the text stays until the user pastes it.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.lastError = nil
        appState.lastTranscript = text
        appState.session = .ready
        // Unlike dictation, confirm: the user was looking elsewhere.
        indicator.finishFile()
    }

    func applyBindingChange() {
        monitor.binding = appState.binding
    }

    /// Suspends the global tap while the recorder field captures a new shortcut.
    func setHotkeyCapture(_ capturing: Bool) {
        monitor.isSuspended = capturing
    }

    @discardableResult
    func retryHotkeyMonitor() -> Bool {
        appState.hotkeyActive = monitor.start()
        return appState.hotkeyActive
    }

    private func observeDevices() {
        deviceWatcher = AudioDeviceWatcher { [weak self] in
            Task { @MainActor in self?.inputDevicesChanged() }
        }
    }

    private func inputDevicesChanged() {
        let previous = appState.defaultInputDevice
        appState.refreshInputDevices()
        let current = appState.defaultInputDevice
        if previous?.uid != current?.uid {
            log.notice(
                "Default input now \(current?.summary ?? "none", privacy: .public)")
        }
        capture.invalidateDevice()
    }

    /// After wake, devices may have reconnected and the default moved.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        }
    }

    private func systemDidWake() {
        appState.refreshInputDevices()
        capture.invalidateDevice()
        log.info(
            "Woke up, input is \(self.appState.effectiveInputDevice?.summary ?? "no device", privacy: .public)"
        )
    }

    private func loadModel() {
        preparation?.cancel()
        appState.install = .listing
        appState.session = .preparing(L("preparing.listing"))
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.prepare { [weak self] step in
                    Task { @MainActor in self?.applyPreparation(step) }
                }
                appState.install = .ready
                appState.session = .ready
            } catch {
                let offline = Self.isOffline(error)
                let reason = offline ? L("install.error.offline") : error.localizedDescription
                log.error("Model failed to load: \(error.localizedDescription)")
                appState.install = .failed(reason: reason, offline: offline)
                appState.session = .failed(reason)
            }
            preparation = nil
        }
    }

    /// Offline is the one failure the user can fix, so it gets its own message.
    private static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
            .networkConnectionLost, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func applyPreparation(_ step: TranscriptionService.Preparation) {
        switch step {
        case .listing:
            appState.install = .listing
            appState.session = .preparing(L("preparing.listing"))
        case .downloading(let fraction, let completed, let total):
            appState.install = .downloading(
                fraction: fraction, completedFiles: completed, totalFiles: total)
            appState.session = .preparing(L("preparing.downloading", Int(fraction * 100)))
        case .compiling:
            appState.install = .compiling
            appState.session = .preparing(L("preparing.compiling"))
        case .loading:
            appState.install = .loading
            appState.session = .preparing(L("preparing.loading"))
        case .warmingUp:
            appState.install = .warmingUp
            appState.session = .preparing(L("preparing.warmup"))
        case .ready:
            appState.install = .ready
            appState.session = .ready
        }
    }

    // MARK: - Hotkey

    private func hotkeyPressed() {
        switch mode {
        case .latched:
            ignoreNextRelease = true
            finishRecording()
        case .awaitingRelease:
            break
        case .idle:
            // Never drop a press silently when dictating in quick succession.
            if case .transcribing = appState.session, fileTask == nil {
                pendingStart = (since: Date(), released: false)
                log.notice("Press during transcription, recording queued")
                return
            }
            beginRecording()
        }
    }

    private func startPendingRecording() {
        guard let pending = pendingStart else { return }
        pendingStart = nil
        beginRecording()
        guard monitor.isRecording else { return }
        // Still held: count from the real press. Already released: toggle.
        mode = pending.released ? .latched : .awaitingRelease(since: pending.since)
    }

    private func hotkeyReleased() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        if pendingStart != nil {
            pendingStart?.released = true
            return
        }
        guard case .awaitingRelease(let start) = mode else { return }

        if Date().timeIntervalSince(start) >= appState.pushToTalkThreshold {
            finishRecording()
        } else {
            mode = .latched
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        // `.finished` only drives the menu bar icon for 0.6 s; treat it as ready.
        let ready: Bool
        switch appState.session {
        case .ready, .finished: ready = true
        default: ready = false
        }
        guard ready else {
            log.notice("Press ignored, state \(String(describing: self.appState.session), privacy: .public)")
            // Without the model, bring up the setup window instead of flashing the pill.
            switch appState.install {
            case .waitingForConsent, .failed:
                onNeedsSetup?()
            default:
                if case .preparing = appState.session {
                    indicator.flash(.failed(L("error.modelLoading")), duration: 1.4)
                }
            }
            return
        }

        guard Permissions.microphoneGranted else {
            Task {
                if await Permissions.requestMicrophone() { return }
                report(L("error.microphone"))
            }
            return
        }

        do {
            try capture.start(preferring: appState.inputDeviceUID)
        } catch {
            report(error.localizedDescription)
            return
        }

        if let toneSet = appState.toneSet { Tones.start(toneSet) }
        mode = .awaitingRelease(since: Date())
        monitor.isRecording = true
        appState.session = .recording
        applyAppearance()
        indicator.startRecording()
        log.info("Recording started")
    }

    private func finishRecording() {
        guard monitor.isRecording else { return }
        if let toneSet = appState.toneSet { Tones.stop(toneSet) }
        let recording = capture.stop()
        monitor.isRecording = false
        mode = .idle
        appState.level = 0

        // Check before "too short": no buffers means zero duration.
        guard !recording.receivedNothing else {
            log.error(
                "No data from \(recording.deviceName, privacy: .public) after \(recording.wallDuration, format: .fixed(precision: 1)) s"
            )
            report(L("error.noAudioData", recording.deviceName))
            return
        }

        guard recording.duration > 0.25 else {
            report(L("error.tooShort"))
            return
        }

        // Otherwise a dead device looks like "nothing recognised".
        guard !recording.isSilent else {
            log.error(
                "No signal from \(recording.deviceName, privacy: .public): peak \(recording.peakDecibels, format: .fixed(precision: 1)) dBFS"
            )
            report(L("error.silentInput", recording.deviceName))
            return
        }

        appState.session = .transcribing
        appState.fileProgress = nil
        indicator.show(.transcribing)

        Task {
            do {
                let text = try await service.transcribe(
                    samples: recording.samples, sampleRate: recording.sampleRate)
                deliver(text)
            } catch {
                log.error("Transcription failed: \(error.localizedDescription)")
                report(error.localizedDescription)
            }
        }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            report(L("error.noSpeech"))
            return
        }

        appState.lastError = nil
        appState.lastTranscript = text
        TextInjector.insert(text)
        appState.session = .finished
        // No confirmation: the text is already there.
        indicator.dismiss()
        startPendingRecording()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if case .finished = appState.session { appState.session = .ready }
        }
    }

    /// Shows an error but stays ready; recording only starts from `.ready`.
    private func report(_ message: String) {
        applyAppearance()
        appState.lastError = message
        appState.session = .ready
        indicator.flash(.failed(message), duration: 1.4)
        startPendingRecording()
    }

    private func cancel() {
        if fileTask != nil {
            cancelFileTranscription()
            return
        }
        guard monitor.isRecording else { return }
        capture.cancel()
        monitor.isRecording = false
        mode = .idle
        ignoreNextRelease = false
        appState.level = 0
        appState.session = .ready
        indicator.flash(.discarded, duration: 0.25)
        log.info("Recording discarded with Escape")
    }
}
