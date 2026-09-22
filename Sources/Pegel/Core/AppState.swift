import Foundation
import SwiftUI

enum SessionState: Equatable {
    case preparing(String)
    case ready
    case recording
    case transcribing
    case finished
    case discarded
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .recording, .transcribing: return true
        default: return false
        }
    }
}

/// Separate from `SessionState`: setup needs fraction, phase and failure reason.
enum ModelInstall: Equatable {
    case waitingForConsent
    case listing
    case downloading(fraction: Double, completedFiles: Int, totalFiles: Int)
    case compiling
    case loading
    case warmingUp
    case ready
    /// `offline` needs a different action from the user than a server error.
    case failed(reason: String, offline: Bool)

    var isRunning: Bool {
        switch self {
        case .waitingForConsent, .ready, .failed: return false
        default: return true
        }
    }

    /// Stays full after the download while the label explains what is still running.
    var fraction: Double {
        switch self {
        case .waitingForConsent, .listing: return 0
        case .downloading(let fraction, _, _): return fraction
        case .failed: return 0
        default: return 1
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var session: SessionState = .preparing(L("preparing.loading"))
    @Published var install: ModelInstall = .waitingForConsent
    @Published var level: Double = 0
    @Published var binding: HotkeyBinding = HotkeyBinding.load()
    @Published var lastTranscript: String = ""
    /// nil when idle or the file is too short for FluidAudio to report progress.
    @Published var fileProgress: Double?
    @Published var lastError: String?
    @Published var hotkeyActive: Bool = false
    /// Hold duration in seconds that counts as push-to-talk.
    @Published var pushToTalkThreshold: Double = UserDefaults.standard.pttThreshold
    @Published var waveformStyle: WaveformStyle = .load()
    @Published var indicatorShowsTime: Bool = UserDefaults.standard.indicatorShowsTime
    @Published var palette: PillPalette = .load()
    /// nil means system default.
    @Published var inputDeviceUID: String? = UserDefaults.standard.inputDeviceUID
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var defaultInputDevice: AudioInputDevice?

    var effectiveInputDevice: AudioInputDevice? {
        if let uid = inputDeviceUID,
            let chosen = inputDevices.first(where: { $0.uid == uid })
        {
            return chosen
        }
        return defaultInputDevice
    }

    var inputDeviceMissing: Bool {
        guard let uid = inputDeviceUID else { return false }
        return !inputDevices.contains { $0.uid == uid }
    }

    /// Stored in state so HAL calls don't run on every view update.
    func refreshInputDevices() {
        inputDevices = AudioDevices.inputs()
        defaultInputDevice = AudioDevices.defaultInput
    }

    func persistBinding() {
        binding.save()
    }

    func persistThreshold() {
        UserDefaults.standard.pttThreshold = pushToTalkThreshold
    }

    func persistInputDevice() {
        UserDefaults.standard.inputDeviceUID = inputDeviceUID
    }

    func persistAppearance() {
        waveformStyle.save()
        palette.save()
        UserDefaults.standard.indicatorShowsTime = indicatorShowsTime
    }

}

extension UserDefaults {
    private static let pttKey = "pushToTalkThresholdSeconds"
    private static let inputDeviceKey = "inputDeviceUID"

    /// The UID, not the `AudioDeviceID`, which changes on every restart.
    var inputDeviceUID: String? {
        get { string(forKey: Self.inputDeviceKey) }
        set { set(newValue, forKey: Self.inputDeviceKey) }
    }

    var pttThreshold: Double {
        get {
            let stored = double(forKey: Self.pttKey)
            return stored > 0 ? stored : 0.35
        }
        set { set(newValue, forKey: Self.pttKey) }
    }
}
