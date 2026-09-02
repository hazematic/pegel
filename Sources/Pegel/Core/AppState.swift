import Foundation
import SwiftUI

/// Was die App gerade tut. Treibt Indikator, Menüleistensymbol und Menütexte.
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

/// Wo die einmalige Einrichtung des Modells steht.
///
/// Getrennt von `SessionState`, weil beide unterschiedliche Fragen beantworten:
/// `SessionState` treibt Pille und Menüleistensymbol und braucht dort nur eine kurze
/// Zeile, das Einrichtungsfenster braucht Bruchteil, Phase und Fehlergrund.
enum ModelInstall: Equatable {
    /// Modell fehlt, der Nutzer hat den Download noch nicht bestätigt.
    case waitingForConsent
    case listing
    case downloading(fraction: Double, completedFiles: Int, totalFiles: Int)
    case compiling
    case loading
    case warmingUp
    case ready
    /// `offline` unterscheidet fehlendes Netz vom Serverfehler: der Nutzer muss in
    /// den beiden Fällen etwas anderes tun.
    case failed(reason: String, offline: Bool)

    /// Ob gerade etwas läuft, das man nicht zweimal anstoßen darf.
    var isRunning: Bool {
        switch self {
        case .waitingForConsent, .ready, .failed: return false
        default: return true
        }
    }

    /// Bruchteil für den Balken. Nach dem Download bleibt er voll stehen, die
    /// Beschriftung erklärt derweil, woran noch gearbeitet wird.
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
    /// Stand der einmaligen Modell-Installation.
    @Published var install: ModelInstall = .waitingForConsent
    /// Mikrofonpegel 0...1, nur während der Aufnahme aktuell.
    @Published var level: Double = 0
    @Published var binding: HotkeyBinding = HotkeyBinding.load()
    @Published var lastTranscript: String = ""
    /// Letzter vorübergehender Fehler, nur zur Anzeige im Menü.
    @Published var lastError: String?
    /// Ob der globale Event-Tap steht. Ohne Bedienungshilfen-Recht bleibt er aus.
    @Published var hotkeyActive: Bool = false
    /// Ab wie vielen Sekunden Halten als Push-to-talk statt als Umschalten gilt.
    @Published var pushToTalkThreshold: Double = UserDefaults.standard.pttThreshold
    @Published var waveformStyle: WaveformStyle = .load()
    @Published var indicatorShowsTime: Bool = UserDefaults.standard.indicatorShowsTime

    func persistBinding() {
        binding.save()
    }

    func persistThreshold() {
        UserDefaults.standard.pttThreshold = pushToTalkThreshold
    }

    func persistAppearance() {
        waveformStyle.save()
        UserDefaults.standard.indicatorShowsTime = indicatorShowsTime
    }

}

extension UserDefaults {
    private static let pttKey = "pushToTalkThresholdSeconds"

    var pttThreshold: Double {
        get {
            let stored = double(forKey: Self.pttKey)
            return stored > 0 ? stored : 0.35
        }
        set { set(newValue, forKey: Self.pttKey) }
    }
}
