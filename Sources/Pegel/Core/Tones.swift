import AVFoundation
import Foundation

/// The confirmation tone sets. Each has a start and an end tone that differ in
/// direction: rising when recording starts, falling when it ends.
///
/// Ordered from least to most present, which is also the order in the settings.
enum ToneSet: String, CaseIterable, Sendable {
    case cricket
    case pebble
    case drop
    case moss
    case glass

    static let fallback: ToneSet = .cricket

    var label: String { L("tones.\(rawValue)") }
}

/// Plays the selected tone set.
///
/// Synthesised in memory rather than shipped as audio files, so pitch, length and
/// level stay adjustable in one place. Played through `AVAudioPlayer`, which uses its
/// own output and never touches the recording engine. Levels stay at 0.1 or below:
/// the microphone is already listening when the start tone plays, and it should not
/// end up in the transcript.
@MainActor
enum Tones {

    private static let sampleRate: Double = 44_100

    /// Loudness factor on top of each set's level, set in the settings.
    nonisolated static let volumeRange: ClosedRange<Double> = 0.5...3
    /// Tones are synthesised at the top of the range; the player can only attenuate.
    private static var headroom: Double { volumeRange.upperBound }
    private static var players: [String: AVAudioPlayer] = [:]
    private static var pendingPreview: DispatchWorkItem?

    static func start(_ set: ToneSet) { play(set, rising: true) }
    static func stop(_ set: ToneSet) { play(set, rising: false) }

    /// Start, then end, as in a short recording.
    static func preview(_ set: ToneSet) {
        pendingPreview?.cancel()
        start(set)
        let end = DispatchWorkItem { stop(set) }
        pendingPreview = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: end)
    }

    private static func play(_ set: ToneSet, rising: Bool) {
        let key = "\(set.rawValue).\(rising)"
        if players[key] == nil {
            let loud = samples(set, rising: rising).map { $0 * headroom }
            players[key] = try? AVAudioPlayer(data: wav(loud))
            players[key]?.prepareToPlay()
        }
        guard let player = players[key] else { return }
        player.volume = Float(UserDefaults.standard.toneVolume / headroom)
        player.currentTime = 0
        player.play()
    }

    // MARK: - Synthesis

    private static func samples(_ set: ToneSet, rising: Bool) -> [Double] {
        func ordered(_ low: Double, _ high: Double) -> (Double, Double) {
            rising ? (low, high) : (high, low)
        }
        switch set {
        case .cricket:
            let (first, second) = ordered(1046.50, 1318.51)  // C6, E6
            return tap(first, duration: 0.045, amplitude: 0.03, decay: 120)
                + tap(second, duration: 0.04, amplitude: 0.03, decay: 120)
        case .pebble:
            return tap(rising ? 1318.51 : 987.77, duration: 0.04, amplitude: 0.04, decay: 110)
        case .drop:
            return pluck(rising ? 880 : 659.25)
        case .moss:
            let (first, second) = ordered(523.25, 659.25)  // C5, E5
            return softPair(first, second)
        case .glass:
            let (first, second) = ordered(659.25, 987.77)  // E5, B5
            return tone(first) + tone(second)
        }
    }

    /// A sine with a 2 ms attack that dies away almost at once.
    private static func tap(
        _ frequency: Double, duration: Double, amplitude: Double, decay: Double
    ) -> [Double] {
        let attack = sampleRate * 0.002
        return (0..<Int(sampleRate * duration)).map { index in
            let t = Double(index) / sampleRate
            return sin(2 * .pi * frequency * t) * min(1, Double(index) / attack)
                * exp(-decay * t) * amplitude
        }
    }

    /// A plucked note: 3 ms attack, slow decay, a touch of the octave in the attack.
    private static func pluck(_ frequency: Double) -> [Double] {
        let attack = sampleRate * 0.003
        return (0..<Int(sampleRate * 0.16)).map { index in
            let t = Double(index) / sampleRate
            let value = sin(2 * .pi * frequency * t)
                + 0.15 * sin(2 * .pi * 2 * frequency * t) * exp(-40 * t)
            return value / 1.15 * min(1, Double(index) / attack) * exp(-28 * t) * 0.07
        }
    }

    /// Two 70 ms notes with a Hann envelope, overlapping by 20 ms.
    private static func softPair(_ first: Double, _ second: Double) -> [Double] {
        let frames = Int(sampleRate * 0.07)
        let step = Int(sampleRate * 0.05)
        var out = [Double](repeating: 0, count: step + frames)
        for (offset, frequency) in [(0, first), (step, second)] {
            for index in 0..<frames {
                let envelope = pow(sin(.pi * Double(index) / Double(frames)), 2)
                out[offset + index] +=
                    sin(2 * .pi * frequency * Double(index) / sampleRate) * envelope * 0.06
            }
        }
        return out
    }

    /// A 75 ms sine with 6 ms fades: without them the start and end click audibly.
    private static func tone(_ frequency: Double) -> [Double] {
        let frames = Int(sampleRate * 0.075)
        let fade = sampleRate * 0.006
        return (0..<frames).map { index in
            let envelope = min(1, Double(index) / fade, Double(frames - index) / fade)
            return sin(2 * .pi * frequency * Double(index) / sampleRate) * envelope * 0.1
        }
    }

    /// 16-bit mono WAV.
    private static func wav(_ samples: [Double]) -> Data {
        let dataSize = samples.count * 2
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append(UInt32(36 + dataSize))
        append("WAVEfmt ")
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)  // bytes per second
        append(UInt16(2))  // block align
        append(UInt16(16))  // bits per sample
        append("data")
        append(UInt32(dataSize))
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * Double(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

extension UserDefaults {
    private static let toneSetKey = "toneSet"
    private static let toneVolumeKey = "toneVolume"

    /// 1 is the level in the table; missing means 1.
    var toneVolume: Double {
        get {
            let value = double(forKey: Self.toneVolumeKey)
            guard value > 0 else { return 1 }
            return min(max(value, Tones.volumeRange.lowerBound), Tones.volumeRange.upperBound)
        }
        set { set(newValue, forKey: Self.toneVolumeKey) }
    }

    /// nil means off.
    var toneSet: ToneSet? {
        get {
            let raw = string(forKey: Self.toneSetKey)
            if raw == "off" { return nil }
            return raw.flatMap(ToneSet.init(rawValue:)) ?? .fallback
        }
        set { set(newValue?.rawValue ?? "off", forKey: Self.toneSetKey) }
    }
}
