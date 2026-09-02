import AVFoundation
import Foundation
import os

/// Mikrofonaufnahme in einen Speicherpuffer.
///
/// Nimmt in der nativen Rate des Eingangsgeräts auf und liefert die Rohsamples
/// zurück; das Resampling auf 16 kHz macht der `TranscriptionService` einmal am
/// Ende, damit im Audio-Callback keine unnötige Arbeit anfällt.
final class AudioCapture {

    struct Recording {
        let samples: [Float]
        let sampleRate: Double
        var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    }

    /// Sicherheitsnetz gegen vergessene Aufnahmen.
    static let maximumDuration: TimeInterval = 10 * 60

    /// Ab hier gilt es als Stille, der Pegel ist 0.
    static let silenceFloor: Double = -60
    /// Ab hier ist der Ausschlag voll.
    ///
    /// An echten Messungen ausgerichtet statt geschätzt: normale Sprechlautstärke
    /// erreicht auf diesem Gerät Spitzen um -30 bis -37 dBFS bei Mittelwerten um
    /// -48 dBFS. Ein Vollausschlag erst bei -24 dBFS wäre nie erreicht worden.
    static let fullScaleLevel: Double = -32

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var inputSampleRate: Double = 0
    private var isRunning = false
    private let log = Logger(subsystem: "io.github.hazematic.pegel", category: "audio")

    // Nur auf dem Main-Thread benutzt.
    private var smoothedLevel: Double = 0
    private var peakDecibels: Double = -.infinity
    private var decibelSum: Double = 0
    private var decibelCount: Int = 0

    /// Mikrofonpegel 0...1, auf dem Main-Thread. Wird etwa 20 mal pro Sekunde gerufen.
    var onLevel: ((Double) -> Void)?
    /// Feuert, wenn `maximumDuration` erreicht ist.
    var onLimitReached: (() -> Void)?

    func start() throws {
        guard !isRunning else { return }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        smoothedLevel = 0
        peakDecibels = -.infinity
        decibelSum = 0
        decibelCount = 0

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        inputSampleRate = format.sampleRate
        let limit = Int(format.sampleRate * Self.maximumDuration)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer, limit: limit)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Beendet die Aufnahme und gibt das Aufgenommene zurück.
    @discardableResult
    func stop() -> Recording {
        guard isRunning else { return Recording(samples: [], sampleRate: inputSampleRate) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()

        let recording = Recording(samples: captured, sampleRate: inputSampleRate)
        // Die gemessenen Werte protokollieren, damit sich die Pegelkennlinie an der
        // echten Stimme und am echten Mikrofon nachjustieren lässt statt nach Gefühl.
        let average = decibelCount > 0 ? decibelSum / Double(decibelCount) : -.infinity
        log.info(
            "Aufnahme beendet: \(recording.duration, format: .fixed(precision: 1)) s, Spitze \(self.peakDecibels, format: .fixed(precision: 1)) dBFS, Mittel \(average, format: .fixed(precision: 1)) dBFS"
        )
        return recording
    }

    /// Beendet die Aufnahme und verwirft das Aufgenommene.
    func cancel() {
        _ = stop()
    }

    // MARK: - Audio-Thread

    private func append(_ buffer: AVAudioPCMBuffer, limit: Int) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)

        var mono = [Float](repeating: 0, count: frames)
        if channelCount == 1 {
            mono.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress?.update(from: channels[0], count: frames)
            }
        } else {
            // Mehrkanalige Eingänge (etwa manche Interfaces) auf Mono mischen.
            let scale = 1 / Float(channelCount)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channels[channel][frame] }
                mono[frame] = sum * scale
            }
        }

        var sumOfSquares: Float = 0
        for value in mono { sumOfSquares += value * value }
        let rms = (sumOfSquares / Float(frames)).squareRoot()
        let decibels = 20 * log10(max(Double(rms), 1e-7))

        lock.lock()
        samples.append(contentsOf: mono)
        let total = samples.count
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.publish(decibels: decibels)
            if total >= limit { self?.onLimitReached?() }
        }
    }

    /// Rechnet den gemessenen Schalldruck in einen Pegel von 0 bis 1 um.
    ///
    /// Über Dezibel statt linear: linear entspricht normale Sprechlautstärke nur einem
    /// kleinen Bruchteil des Vollausschlags, der Indikator bewegte sich dann kaum.
    private func publish(decibels: Double) {
        guard decibels.isFinite else { return }
        peakDecibels = max(peakDecibels, decibels)
        decibelSum += decibels
        decibelCount += 1

        let span = Self.fullScaleLevel - Self.silenceFloor
        let target = min(1, max(0, (decibels - Self.silenceFloor) / span))
        // Schnell anspringen, weich abklingen. Sonst zappelt der Pegel zwischen den
        // Silben, statt dass die Gruppe atmet.
        smoothedLevel = target > smoothedLevel ? target : smoothedLevel * 0.72 + target * 0.28
        onLevel?(smoothedLevel)
    }

    enum CaptureError: LocalizedError {
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return L("error.noInputDevice")
            }
        }
    }
}
