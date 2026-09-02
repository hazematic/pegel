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
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Icon-Export für das Build-Skript: rendert das Iconset aus derselben
        // Bildmarke, die die App benutzt, und beendet sich wieder.
        if let index = CommandLine.arguments.firstIndex(of: "--export-icons"),
            index + 1 < CommandLine.arguments.count
        {
            let target = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try? IconExporter.writeIconset(to: target)
            try? IndicatorPreview.write(to: target.appendingPathComponent("indikator"))
            try? ReadmeFigure.write(to: target.appendingPathComponent("readme"))
            NSApp.terminate(nil)
            return
        }

        // Kein Dock-Icon, kein Fenster beim Start: Pegel lebt in der Menüleiste.
        NSApp.setActivationPolicy(.accessory)

        // Rechtestatus protokollieren: die drei Dienste sind von außen nicht
        // unterscheidbar, im Log sieht man sofort, welcher fehlt.
        Logger(subsystem: "io.github.hazematic.pegel", category: "l10n").info(
            "Sprache: \(Bundle.main.preferredLocalizations.joined(separator: ","), privacy: .public), Systemwunsch: \(Locale.preferredLanguages.joined(separator: ","), privacy: .public)"
        )

        Logger(subsystem: "io.github.hazematic.pegel", category: "permissions").info(
            "Rechte beim Start: Mikrofon=\(Permissions.microphoneGranted, privacy: .public) Bedienungshilfen=\(Permissions.accessibilityGranted, privacy: .public) Eingabeueberwachung=\(Permissions.inputMonitoringGranted, privacy: .public)")

        // Vor dem Start merken, ob das Modell noch fehlt: `controller.start()` setzt
        // den Zustand danach schon auf `.listing`, wenn der Cache gefüllt ist.
        let needsModel = !TranscriptionService.isModelInstalled
        controller.onNeedsSetup = { [weak self] in self?.showSetup() }
        controller.start()

        if needsModel || !Permissions.allGranted {
            showSetup()
        }
    }

    /// Pegel lebt in der Menüleiste. Das Schließen des Onboarding-Fensters darf
    /// die App nicht mitnehmen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Einstellungen öffnen oder ein bereits offenes Fenster nach vorn holen.
    ///
    /// Bewusst ein eigenes `NSWindow` statt der SwiftUI-`Settings`-Szene: die holt in
    /// einer Menüleisten-App ohne Dock-Icon ein offenes Fenster nicht nach vorn und
    /// lässt sich in der Größe nicht steuern.
    func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = L("window.settings")
        window.contentView = NSHostingView(
            rootView: SettingsView(state: appState, controller: controller))
        window.contentMinSize = NSSize(width: 460, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PegelSettings")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    /// Das Einrichtungsfenster: Modell-Download bestätigen und verfolgen, Rechte
    /// erteilen. Auch nachträglich über das Menü erreichbar.
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
        // Beim Schließen vergessen, damit ein späteres Öffnen wieder auf der Seite
        // beginnt, die zum aktuellen Stand passt.
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupWindow = window
    }

    /// Schließt das Fenster, wenn der Nutzer es über den roten Knopf loswird.
    func windowWillClose(_ notification: Notification) {
        if (notification.object as AnyObject?) === setupWindow { setupWindow = nil }
    }
}

/// Das Menüleistensymbol spiegelt denselben Zustand wie der Indikator, damit der
/// Status auch dann sichtbar ist, wenn der Indikator auf einem anderen Bildschirm sitzt.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: state.session))
    }
}
