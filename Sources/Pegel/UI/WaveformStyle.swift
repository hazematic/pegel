import Foundation

/// Welche Darstellung die Pille zeigt.
enum WaveformStyle: String, CaseIterable, Codable, Sendable {
    /// Elf Striche, deren Welle nach rechts läuft (Entwurf 9a). Voreinstellung.
    case levels
    /// Die Pegelspur der letzten zwei Sekunden, läuft nach links (Entwurf 6c).
    case trace

    var label: String {
        switch self {
        case .trace: return L("waveform.trace")
        case .levels: return L("waveform.levels")
        }
    }

    var explanation: String {
        switch self {
        case .trace:
            return L("waveform.trace.explanation")
        case .levels:
            return L("waveform.levels.explanation")
        }
    }

    private static let defaultsKey = "waveformStyle"

    static func load() -> WaveformStyle {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let value = WaveformStyle(rawValue: raw)
        else { return .levels }
        return value
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

extension UserDefaults {
    private static let showsTimeKey = "indicatorShowsTime"

    var indicatorShowsTime: Bool {
        get {
            guard object(forKey: Self.showsTimeKey) != nil else { return true }
            return bool(forKey: Self.showsTimeKey)
        }
        set { set(newValue, forKey: Self.showsTimeKey) }
    }
}
