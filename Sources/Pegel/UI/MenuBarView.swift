import SwiftUI

struct MenuBarView: View {

    @ObservedObject var state: AppState
    let controller: RecordingController
    let openSettings: () -> Void
    let openAbout: () -> Void
    let openSetup: () -> Void

    var body: some View {
        Text(statusLine)

        if case .failed(let message) = state.session {
            Text(message)
        } else if let error = state.lastError {
            Text(L("menu.status.last", error))
        }

        // Keep setup reachable; the user may have closed its window.
        if state.install != .ready {
            Button(L("menu.setup"), action: openSetup)
        }

        if !state.hotkeyActive {
            Text(L("menu.status.hotkeyInactive"))
        }

        // Fixed layout, no shortcuts. Unavailable items are disabled, not hidden.
        Divider()

        Button(L("menu.transcribeFile")) { controller.transcribeFile() }
            .disabled(state.session != .ready)
        Button(L("menu.copyLast")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(state.lastTranscript, forType: .string)
        }
        .disabled(state.lastTranscript.isEmpty)

        Divider()

        Button(L("menu.resetPosition")) { controller.resetIndicatorPosition() }
            .disabled(!controller.hasCustomIndicatorPosition)

        Divider()

        Button(L("menu.settings"), action: openSettings)

        Divider()

        Button(L("menu.about"), action: openAbout)

        Divider()

        Button(L("menu.quit")) { NSApplication.shared.terminate(nil) }
    }

    private var statusLine: String {
        if state.install == .waitingForConsent { return L("menu.status.notInstalled") }

        switch state.session {
        case .preparing(let step): return step + "…"
        case .ready: return L("status.ready")
        case .recording: return L("status.recording")
        case .transcribing:
            if let progress = state.fileProgress {
                return L("status.transcribingFile", percentText(progress))
            }
            return L("status.transcribing")
        case .finished: return L("status.finished")
        case .discarded: return L("status.discarded")
        case .failed: return L("status.failed")
        }
    }
}
