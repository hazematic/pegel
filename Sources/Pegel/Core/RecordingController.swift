import AppKit
import Foundation
import os

/// Der Zustandsautomat der App: verbindet Tastenkürzel, Aufnahme, Transkription,
/// Texteinfügung und Indikator.
@MainActor
final class RecordingController {

    /// Wie die laufende Aufnahme beendet werden wird.
    private enum Mode {
        /// Nichts läuft.
        case idle
        /// Aufnahme läuft, es ist noch offen, ob Halten oder Umschalten gemeint war.
        case awaitingRelease(since: Date)
        /// Kurzer Druck war es: die Aufnahme läuft weiter bis zum nächsten Druck.
        case latched
    }

    private let appState: AppState
    private let capture = AudioCapture()
    private let service = TranscriptionService()
    private let indicator = IndicatorPanelController()
    private let monitor: HotkeyMonitor
    private let log = Logger(subsystem: "io.github.hazematic.pegel", category: "controller")

    private var mode: Mode = .idle
    /// Der Tastendruck, der eine gehaltene Aufnahme beendet hat, erzeugt noch ein
    /// Loslassen. Das darf nicht als neue Entscheidung gewertet werden.
    private var ignoreNextRelease = false
    /// Läuft die Modellvorbereitung. Verhindert einen zweiten Anlauf, während der
    /// erste noch unterwegs ist.
    private var preparation: Task<Void, Never>?

    /// Wird gerufen, wenn der Nutzer etwas will, das ohne fertige Einrichtung nicht
    /// geht. Der Controller kennt keine Fenster, das Öffnen macht der AppDelegate.
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
            self?.log.notice("Aufnahmelimit erreicht, wird automatisch beendet")
            self?.finishRecording()
        }
    }

    // MARK: - Start

    func start() {
        appState.hotkeyActive = monitor.start()

        // Liegt das Modell schon im Cache, wird es kommentarlos geladen. Fehlt es,
        // passiert von selbst nichts: der Download braucht die ausdrückliche
        // Zustimmung im Einrichtungsfenster.
        if TranscriptionService.isModelInstalled {
            loadModel()
        } else {
            appState.install = .waitingForConsent
            appState.session = .preparing(L("preparing.waiting"))
        }
    }

    /// Der Nutzer hat den Download bestätigt oder will es nach einem Fehler noch
    /// einmal versuchen.
    func installModel() {
        guard !appState.install.isRunning else { return }
        loadModel()
    }

    /// Ob der Nutzer die Pille an einen eigenen Platz gezogen hat.
    var hasCustomIndicatorPosition: Bool { indicator.hasCustomPosition }

    func resetIndicatorPosition() {
        indicator.resetPosition()
    }

    func applyBindingChange() {
        monitor.binding = appState.binding
    }

    /// Nach dem Erteilen des Bedienungshilfen-Rechts, ohne Neustart.
    @discardableResult
    func retryHotkeyMonitor() -> Bool {
        appState.hotkeyActive = monitor.start()
        return appState.hotkeyActive
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
                log.error("Modell konnte nicht geladen werden: \(error.localizedDescription)")
                appState.install = .failed(reason: reason, offline: offline)
                appState.session = .failed(reason)
            }
            preparation = nil
        }
    }

    /// Fehlendes Netz von allem anderen trennen. Es ist der einzige Fehler, gegen den
    /// der Nutzer selbst etwas tun kann, und verdient deshalb eine eigene Meldung.
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

    // MARK: - Tastenlogik

    private func hotkeyPressed() {
        switch mode {
        case .latched:
            // Zweiter Druck im Umschaltbetrieb beendet die Aufnahme.
            ignoreNextRelease = true
            finishRecording()
        case .awaitingRelease:
            break
        case .idle:
            beginRecording()
        }
    }

    private func hotkeyReleased() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard case .awaitingRelease(let start) = mode else { return }

        if Date().timeIntervalSince(start) >= appState.pushToTalkThreshold {
            // Gehalten: Loslassen beendet.
            finishRecording()
        } else {
            // Kurz getippt: Aufnahme bleibt an, bis erneut gedrückt wird.
            mode = .latched
        }
    }

    // MARK: - Aufnahme

    private func beginRecording() {
        guard case .ready = appState.session else {
            // Ohne bestätigten Download hilft kein Hinweis in der Pille: das Fenster
            // muss nach vorn, dort steht der Knopf.
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
            try capture.start()
        } catch {
            report(error.localizedDescription)
            return
        }

        mode = .awaitingRelease(since: Date())
        monitor.isRecording = true
        appState.session = .recording
        indicator.apply(
            style: appState.waveformStyle, showsTime: appState.indicatorShowsTime)
        indicator.startRecording()
        log.info("Aufnahme gestartet")
    }

    private func finishRecording() {
        guard monitor.isRecording else { return }
        let recording = capture.stop()
        monitor.isRecording = false
        mode = .idle
        appState.level = 0

        guard recording.duration > 0.25 else {
            report(L("error.tooShort"))
            return
        }

        appState.session = .transcribing
        indicator.show(.transcribing)

        Task {
            do {
                let text = try await service.transcribe(
                    samples: recording.samples, sampleRate: recording.sampleRate)
                deliver(text)
            } catch {
                log.error("Transkription fehlgeschlagen: \(error.localizedDescription)")
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
        // Keine Bestätigung: das Ergebnis steht im Text, die Anzeige soll weg sein.
        indicator.dismiss()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if case .finished = appState.session { appState.session = .ready }
        }
    }

    /// Vorübergehende Fehler zeigen, aber die App bereit halten.
    ///
    /// Ein dauerhaft gesetzter Fehlerzustand hätte die App nach dem ersten Aussetzer
    /// unbrauchbar gemacht, weil `beginRecording` nur aus `.ready` heraus startet.
    private func report(_ message: String) {
        indicator.apply(
            style: appState.waveformStyle, showsTime: appState.indicatorShowsTime)
        appState.lastError = message
        appState.session = .ready
        // 1,4 s stehen lassen, danach die bestehenden 0,2 s Ausblenden. So im Design
        // festgelegt, damit das Ausrufezeichen nicht als Aufnahme missverstanden wird.
        indicator.flash(.failed(message), duration: 1.4)
    }

    /// Escape: Aufnahme verwerfen, nichts einfügen.
    private func cancel() {
        guard monitor.isRecording else { return }
        capture.cancel()
        monitor.isRecording = false
        mode = .idle
        ignoreNextRelease = false
        appState.level = 0
        appState.session = .ready
        // Kurz zeigen, dass verworfen wurde, statt kommentarlos zu verschwinden.
        indicator.flash(.discarded, duration: 0.25)
        log.info("Aufnahme per Escape verworfen")
    }
}
