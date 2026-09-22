import AppKit
import Combine
import Sparkle

/// Sparkle updates. Never checks unless the user asks or enables automatic checks
/// (off by default, no prompt). Fetches only `appcast.xml`; no system profile.
@MainActor
final class UpdateController: NSObject, ObservableObject {

    @Published var automaticallyChecks: Bool = false {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != automaticallyChecks
            else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }
    @Published private(set) var canCheck = false

    /// No feed URL without a bundle (e.g. `swift run`); Sparkle would show an error.
    let isAvailable: Bool

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }

    override init() {
        isAvailable = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        super.init()
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheck)
    }

    func checkForUpdates() {
        // Otherwise Sparkle's window opens behind the active app.
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {

    /// No Dock icon, so scheduled update windows would go unnoticed.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
}
