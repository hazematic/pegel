import AppKit
import SwiftUI
import os

@main
struct PegelApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                state: delegate.appState, controller: delegate.controller,
                openSettings: { delegate.showSettings() },
                openAbout: { delegate.showAbout() },
                openSetup: { delegate.showSetup() })
        } label: {
            MenuBarLabel(state: delegate.appState)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {

    let appState = AppState()
    private(set) lazy var controller = RecordingController(appState: appState)
    /// Lazy, so the build script's icon export doesn't create it.
    private(set) lazy var updates = UpdateController()
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsTabs: NSTabViewController?
    private var aboutWindow: NSWindow?
    private var licencesWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Icon export for the build script.
        if let index = CommandLine.arguments.firstIndex(of: "--export-icons"),
            index + 1 < CommandLine.arguments.count
        {
            let target = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try? IconExporter.writeIconset(to: target)
            try? IndicatorPreview.write(to: target.appendingPathComponent("indikator"))
            try? ReadmeFigure.write(to: target.appendingPathComponent("readme"))
            try? DMGBackground.write(to: target.appendingPathComponent("dmg"))
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        // The three services look alike from outside; the log shows which one is missing.
        Logger(subsystem: "io.github.hazematic.pegel", category: "l10n").info(
            "Language: \(Bundle.main.preferredLocalizations.joined(separator: ","), privacy: .public), system preference: \(Locale.preferredLanguages.joined(separator: ","), privacy: .public)"
        )

        Logger(subsystem: "io.github.hazematic.pegel", category: "permissions").info(
            "Permissions at launch: microphone=\(Permissions.microphoneGranted, privacy: .public) accessibility=\(Permissions.accessibilityGranted, privacy: .public) inputMonitoring=\(Permissions.inputMonitoringGranted, privacy: .public)")

        // Check before `start()`, which moves the state on when the cache is filled.
        let needsModel = !TranscriptionService.isModelInstalled
        // Early, so enabled automatic checks get their schedule. Nothing goes out otherwise.
        _ = updates
        controller.onNeedsSetup = { [weak self] in self?.showSetup() }
        controller.start()

        if needsModel || !Permissions.allGranted {
            showSetup()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    enum SettingsTab: Int {
        case general, appearance
    }

    /// Own window instead of the SwiftUI `Settings` scene, which doesn't bring an open
    /// window to the front in a menu bar app without a Dock icon.
    func showSettings(tab: SettingsTab? = nil) {
        if settingsWindow == nil { buildSettingsWindow() }
        if let tab { settingsTabs?.selectedTabViewItemIndex = tab.rawValue }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildSettingsWindow() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false
        tabs.addTabViewItem(
            Self.settingsTab(
                GeneralSettingsView(state: appState, controller: controller),
                label: L("settings.tab.general"), symbol: "gearshape"))
        tabs.addTabViewItem(
            Self.settingsTab(
                AppearanceSettingsView(state: appState),
                label: L("settings.tab.appearance"), symbol: "paintpalette"))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = L("window.settings")
        // Centers the title above the tabs; without it the title sits off-center.
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        // Forget on close so the preview's timers stop too.
        window.delegate = self
        window.center()
        settingsWindow = window
        settingsTabs = tabs
    }

    private static func settingsTab(
        _ view: some View, label: String, symbol: String
    ) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    func showAbout() {
        if aboutWindow == nil {
            let host = NSHostingController(
                rootView: AboutView(
                    updates: updates, showLicences: { [weak self] in self?.showLicences() }))
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = L("window.about")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showLicences() {
        if licencesWindow == nil {
            let host = NSHostingController(rootView: AcknowledgementsView())
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = L("window.licences")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            licencesWindow = window
        }
        licencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSetup() {
        if let window = setupWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SetupView(
            state: appState, controller: controller,
            startsAtWelcome: appState.install == .waitingForConsent,
            openSettings: { [weak self] in self?.showSettings() },
            onFinish: { [weak self] in
                self?.controller.retryHotkeyMonitor()
                self?.setupWindow?.close()
                self?.setupWindow = nil
            },
            onReady: { [weak self] in
                self?.controller.retryHotkeyMonitor()
            })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("window.onboarding")
        window.contentView = NSHostingView(rootView: view)
        // Forget on close so reopening starts on the page matching the current state.
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as AnyObject?) === setupWindow { setupWindow = nil }
        if (notification.object as AnyObject?) === aboutWindow { aboutWindow = nil }
        if (notification.object as AnyObject?) === licencesWindow { licencesWindow = nil }
        if (notification.object as AnyObject?) === settingsWindow {
            settingsWindow = nil
            settingsTabs = nil
        }
    }
}

/// Mirrors the indicator, visible even when the pill is on another screen.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: state.session))
    }
}
