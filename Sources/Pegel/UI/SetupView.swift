import SwiftUI

/// First-run setup: confirm the model download, follow it, grant permissions.
/// Permissions and download run side by side. Accessibility only takes effect after
/// the switch is flipped, hence polling.
struct SetupView: View {

    @ObservedObject var state: AppState
    let controller: RecordingController
    let openSettings: () -> Void
    let onFinish: () -> Void
    let onReady: () -> Void

    private enum Page {
        case welcome
        case install
        case done
    }

    @State private var page: Page
    @State private var rejection: String?
    @State private var microphone = Permissions.microphoneGranted
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var inputMonitoring = Permissions.inputMonitoringGranted

    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Only the caller knows whether the model is missing or just permissions.
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
        .onChange(of: state.binding) { _, _ in
            state.persistBinding()
            controller.applyBindingChange()
            rejection = nil
        }
        .onReceive(poll) { _ in
            // Every check is an IPC call to TCC.
            if !microphone { microphone = Permissions.microphoneGranted }
            if !accessibility { accessibility = Permissions.accessibilityGranted }
            if !inputMonitoring { inputMonitoring = Permissions.inputMonitoringGranted }
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

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 16) {
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

    // MARK: - Page 2: Installation and permissions

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

            // Two buttons on purpose: the system prompt adds the app to the list, and opening
            // System Settings at the same time would hide the prompt.
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
                    // The window may close; the download continues in the background.
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
            // Partial files are kept, so a retry resumes.
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

    // MARK: - Page 3: Done

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("setup.done.title")).font(.headline)
            Text(L("setup.done.body"))

            VStack(alignment: .leading, spacing: 10) {
                Text(L("setup.done.shortcut.label"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HotkeyRecorderField(
                    binding: $state.binding,
                    onRejected: { rejection = $0 },
                    onCaptureChanged: { controller.setHotkeyCapture($0) })
                .frame(width: 220, height: 40)
                Text(L("hotkey.clickToChange"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let rejection {
                    Text(rejection)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("setup.done.shortcut.explanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            if !allGranted {
                // Without both keyboard permissions the event tap stays off; say so.
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
                Button(L("setup.done.openSettings")) { openSettings() }
                    .buttonStyle(.link)
                Spacer()
                Button(L("onboarding.start")) { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Components

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
                    // macOS shows the system prompt only once per permission.
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
