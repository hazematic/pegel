import SwiftUI

struct MenuBarView: View {

    @ObservedObject var state: AppState
    let controller: RecordingController
    let openSettings: () -> Void
    let openSetup: () -> Void

    var body: some View {
        Text(statusLine)

        if case .failed(let message) = state.session {
            Text(message)
        } else if let error = state.lastError {
            Text(L("menu.status.last", error))
        }

        // Solange die Einrichtung nicht durch ist, muss das Fenster von hier aus
        // erreichbar sein: der Nutzer kann es jederzeit weggeklickt haben.
        if state.install != .ready {
            Button(L("menu.setup"), action: openSetup)
        }

        if !state.hotkeyActive {
            Text(L("menu.status.hotkeyInactive"))
        }

        if controller.hasCustomIndicatorPosition {
            Divider()
            Button(L("menu.resetPosition")) { controller.resetIndicatorPosition() }
        }

        if !state.lastTranscript.isEmpty {
            Divider()
            Button(L("menu.copyLast")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.lastTranscript, forType: .string)
            }
        }

        Divider()

        Button(L("menu.settings"), action: openSettings)
            .keyboardShortcut(",", modifiers: .command)

        Button(L("menu.quit")) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private var statusLine: String {
        // Vor der Zustimmung wartet nichts und lädt nichts, das gehört auch so gesagt.
        if state.install == .waitingForConsent { return L("menu.status.notInstalled") }

        switch state.session {
        case .preparing(let step): return step + "…"
        case .ready: return L("status.ready")
        case .recording: return L("status.recording")
        case .transcribing: return L("status.transcribing")
        case .finished: return L("status.finished")
        case .discarded: return L("status.discarded")
        case .failed: return L("status.failed")
        }
    }
}
