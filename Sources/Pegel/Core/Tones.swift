import AVFoundation
import Foundation

/// The two confirmation tones: a rising pair when recording starts, a falling pair
/// when it ends.
///
/// Synthesised in memory rather than shipped as audio files, so pitch, length and
/// level stay adjustable in one place. Played through `AVAudioPlayer`, which uses its
/// own output and never touches the recording engine.
@MainActor
enum Tones {

    /// E5 and B5, a fifth apart: audible on laptop speakers without being a chime.
    private static let low: Double = 659.25
    private static let high: Double = 987.77
    private static let noteDuration: TimeInterval = 0.075
    /// Quiet on purpose. The microphone is already listening when the start tone
    /// plays, and it should not end up in the transcript.
    private static let amplitude: Double = 0.1
    private static let sampleRate: Double = 44_100

    private static let startPlayer = player(for: [low, high])
    private static let stopPlayer = player(for: [high, low])

    static func start() { play(startPlayer) }
    static func stop() { play(stopPlayer) }

    private static func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private static func player(for notes: [Double]) -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(data: wave(notes)) else { return nil }
        player.prepareToPlay()
        return player
    }

    /// Two notes back to back with short fades, as 16-bit mono WAV.
    private static func wave(_ notes: [Double]) -> Data {
        let frames = Int(sampleRate * noteDuration)
        // 6 ms in and out: without them the start and end of a sine click audibly.
        let fade = Int(sampleRate * 0.006)
        var samples: [Int16] = []
        samples.reserveCapacity(frames * notes.count)

        for frequency in notes {
            for index in 0..<frames {
                let envelope = min(
                    1, min(Double(index) / Double(fade), Double(frames - index) / Double(fade)))
                let value = sin(2 * .pi * frequency * Double(index) / sampleRate)
                samples.append(Int16(value * envelope * amplitude * Double(Int16.max)))
            }
        }
        return wav(samples)
    }

    private static func wav(_ samples: [Int16]) -> Data {
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
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
