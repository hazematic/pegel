import SwiftUI

/// Die Einrichtung beim ersten Start: Modell-Download bestätigen, den Fortschritt
/// verfolgen, die drei Rechte erteilen.
///
/// Drei Seiten in einem Fenster. Rechte und Download laufen bewusst nebeneinander:
/// der Download dauert Minuten, in denen der Nutzer ohnehin in den Systemeinstellungen
/// unterwegs sein kann.
///
/// Das Bedienungshilfen-Recht wird erst nach dem Umlegen des Schalters wirksam,
/// deshalb wird der Zustand hier gepollt statt einmalig abgefragt.
struct SetupView: View {

    @ObservedObject var state: AppState
    let controller: RecordingController
    /// Öffnet die Einstellungen, damit das Kürzel gleich hier geändert werden kann.
    let openSettings: () -> Void
    let onFinish: () -> Void
    /// Feuert, sobald alle Rechte stehen. Zieht den Event-Tap nach.
    let onReady: () -> Void

    private enum Page {
        case welcome
        case install
        case done
    }

    @State private var page: Page
    @State private var microphone = Permissions.microphoneGranted
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var inputMonitoring = Permissions.inputMonitoringGranted

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// `startsAtWelcome` kommt von außen, weil nur der Aufrufer weiß, ob das Modell
    /// noch fehlt oder ob das Fenster bloß wegen der Rechte offen ist.
    init(
        state: AppState, controller: RecordingController, startsAtWelcome: Bool,
        openSettings: @escaping () -> Void, onFinish: @escaping () -> Void,
        onReady: @escaping () -> Void
    ) {
        self.state = state
        self.controller = controller
        self.openSettings = openSettings
        self.onFinish = onFinish
        self.onReady = onReady
        _page = State(initialValue: startsAtWelcome ? .welcome : .install)
    }

    private var allGranted: Bool { microphone && accessibility && inputMonitoring }
    private var modelReady: Bool { state.install == .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            switch page {
            case .welcome: welcomePage
            case .install: installPage
            case .done: donePage
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
        .onReceive(poll) { _ in
            // Nur nachfragen, was noch fehlt: jede Abfrage ist ein IPC-Aufruf an TCC.
            if !microphone { microphone = Permissions.microphoneGranted }
            if !accessibility { accessibility = Permissions.accessibilityGranted }
            if !inputMonitoring { inputMonitoring = Permissions.inputMonitoringGranted }
            // Sobald alles steht, den Event-Tap ohne Neustart nachziehen.
            if allGranted { onReady() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PegelMark(color: .primary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading) {
                Text("Pegel").font(.title2).bold()
                Text(L("onboarding.subtitle"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Seite 1: Willkommen

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Oben und unten Luft: der Text steht damit ruhig in der Fensterhöhe, die
            // erst die Installationsseite wirklich braucht.
            Spacer(minLength: 0)
            Text(L("setup.welcome.title")).font(.headline)
            Text(L("setup.welcome.body"))
            Text(L("setup.welcome.privacy"))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(L("setup.welcome.size"))
                    .font(.callout)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            HStack {
                Button(L("onboarding.later")) { onFinish() }
                Spacer()
                Button(L("setup.welcome.confirm")) {
                    controller.installModel()
                    page = .install
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Seite 2: Installation, parallel zu den Rechten

    private var installPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .failed(let reason, let offline) = state.install {
                failureBlock(reason: reason, offline: offline)
            } else if modelReady {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text(L("setup.install.done")).bold()
                }
            } else {
                progressBlock
            }

            Divider()

            Text(L("setup.permissions.title")).font(.headline)

            step(
                title: L("permission.microphone"), granted: microphone,
                detail: L("onboarding.microphone.detail")
            ) {
                Task { microphone = await Permissions.requestMicrophone() }
            }

            // Anfordern und Systemeinstellungen öffnen sind bewusst zwei Knöpfe. Der
            // Systemdialog ist der Aufruf, der die App überhaupt erst in die Liste
            // einträgt; öffnet man die Systemeinstellungen im selben Atemzug, schiebt
            // sich deren Fenster davor und der Dialog geht unter.
            step(
                title: L("permission.accessibility"), granted: accessibility,
                detail: L("onboarding.accessibility.detail"),
                openSettings: Permissions.openAccessibilitySettings
            ) {
                accessibility = Permissions.requestAccessibility()
            }

            step(
                title: L("permission.inputMonitoring"), granted: inputMonitoring,
                detail: L("onboarding.inputMonitoring.detail"),
                openSettings: Permissions.openInputMonitoringSettings
            ) {
                inputMonitoring = Permissions.requestInputMonitoring()
            }

            Spacer()

            HStack {
                Spacer()
                if modelReady {
                    Button(L("setup.next")) { page = .done }
                        .keyboardShortcut(.defaultAction)
                } else {
                    // Ohne fertiges Modell gibt es nichts zu bestätigen. Das Fenster
                    // darf trotzdem weg, der Download läuft im Hintergrund weiter.
                    Button(L("onboarding.later")) { onFinish() }
                }
            }
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: state.install.fraction)
                .progressViewStyle(.linear)

            HStack(spacing: 8) {
                if state.install.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(phaseLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .downloading(let fraction, _, _) = state.install {
                    Text("\(Int(fraction * 100)) %")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func failureBlock(reason: String, offline: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                Text(L("setup.install.failed")).bold()
            }
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Angefangene Dateien bleiben liegen, ein zweiter Versuch macht dort
            // weiter statt von vorn anzufangen.
            Text(offline ? L("setup.install.retry.offline") : L("setup.install.retry.hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("setup.install.retry")) { controller.installModel() }
        }
    }

    private var phaseLabel: String {
        switch state.install {
        case .waitingForConsent: return L("setup.phase.waiting")
        case .listing: return L("setup.phase.listing")
        case .downloading(_, let completed, let total):
            guard total > 0 else { return L("setup.phase.downloadingPlain") }
            return L("setup.phase.downloading", completed, total)
        case .compiling: return L("setup.phase.compiling")
        case .loading: return L("preparing.loading")
        case .warmingUp: return L("preparing.warmup")
        case .ready: return L("setup.install.done")
        case .failed(let reason, _): return reason
        }
    }

    // MARK: - Seite 3: Fertig

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("setup.done.title")).font(.headline)
            Text(L("setup.done.body"))

            VStack(alignment: .leading, spacing: 10) {
                Text(L("setup.done.shortcut.label"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(state.binding.displayString)
                    .font(.system(size: 24, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(.separator)
                    )
                Text(L("setup.done.shortcut.explanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            if !allGranted {
                // Ohne die beiden Tastatur-Rechte bleibt der Event-Tap aus, das Kürzel
                // reagiert dann nirgends. Das gehört hier gesagt, nicht verschwiegen.
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(L("setup.done.permissionsMissing"))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            HStack {
                Button(L("setup.done.changeShortcut")) { openSettings() }
                Spacer()
                Button(L("onboarding.start")) { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Bausteine

    @ViewBuilder
    private func step(
        title: String, granted: Bool, detail: String,
        openSettings: (() -> Void)? = nil, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                VStack(alignment: .trailing, spacing: 6) {
                    Button(L("button.allow"), action: action)
                    // Zweiter Weg für den Fall, dass der Systemdialog nicht mehr
                    // erscheint: macOS zeigt ihn pro Recht nur einmal.
                    if let openSettings {
                        Button(L("button.openSettings"), action: openSettings)
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
    }
}
