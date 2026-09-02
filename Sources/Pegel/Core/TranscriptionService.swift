import AVFoundation
import FluidAudio
import Foundation
import os

/// Kapselt Parakeet TDT 0.6B v3 über FluidAudio.
///
/// Ein einziges Modell, keine Auswahl. Läuft lokal auf der Neural Engine; nach dem
/// ersten Download ist kein Netz mehr nötig.
actor TranscriptionService {

    /// Wo die Vorbereitung gerade steht. Feiner als nur ein Prozentwert, weil die
    /// CoreML-Kompilierung am Ende Minuten ohne sichtbaren Zuwachs kostet: ein
    /// stehender Balken ohne Erklärung sieht wie ein Hänger aus.
    enum Preparation: Equatable {
        case listing
        case downloading(fraction: Double, completedFiles: Int, totalFiles: Int)
        case compiling
        case loading
        case warmingUp
        case ready
    }

    /// Ob das Modell schon im Cache liegt.
    ///
    /// Bewusst aus dem Dateizustand abgeleitet und nicht als Flag in `UserDefaults`
    /// gemerkt: wer den Modellordner löscht, bekommt damit korrekt wieder die
    /// Einrichtung, ein Flag würde in dem Fall lügen.
    nonisolated static var isModelInstalled: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    private var manager: AsrManager?
    private let converter = AudioConverter()
    private let log = Logger(subsystem: "io.github.hazematic.pegel", category: "asr")

    /// Skript-Hinweis für v3. Filtert Kandidaten aus fremden Schriftsystemen heraus.
    /// Englische Fachbegriffe im deutschen Satz bleiben unberührt, weil beide Sprachen
    /// lateinisch schreiben.
    private let languageHint: Language = .german

    var isReady: Bool { manager != nil }

    /// Lädt das Modell und wärmt es vor.
    ///
    /// Das Warmup ist kein Luxus: Core ML kompiliert die Modelle beim ersten Lauf für
    /// die Neural Engine, und diese Sekunden würden sonst im ersten echten Diktat
    /// anfallen.
    func prepare(progress: @escaping @Sendable (Preparation) -> Void) async throws {
        guard manager == nil else {
            progress(.ready)
            return
        }

        progress(.listing)
        let models = try await AsrModels.downloadAndLoad(
            version: .v3,
            progressHandler: { update in
                switch update.phase {
                case .listing:
                    progress(.listing)
                case .downloading(let completed, let total):
                    progress(
                        .downloading(
                            fraction: update.fractionCompleted, completedFiles: completed,
                            totalFiles: total))
                case .compiling:
                    progress(.compiling)
                }
            })

        progress(.loading)
        let asr = AsrManager()
        try await asr.loadModels(models)
        manager = asr

        progress(.warmingUp)
        _ = try? await transcribe(samples: [Float](repeating: 0, count: 8_000), sampleRate: 16_000)

        progress(.ready)
        log.info("Parakeet TDT v3 bereit")
    }

    /// Transkribiert eine abgeschlossene Aufnahme.
    ///
    /// Der Decoder-Zustand wird pro Aufruf frisch angelegt: jedes Diktat ist eine
    /// eigene Äußerung und soll keinen Kontext aus dem vorherigen mitschleppen.
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard let manager else { throw ServiceError.notReady }
        guard !samples.isEmpty else { return "" }

        let prepared: [Float]
        if abs(sampleRate - 16_000) < 1 {
            prepared = samples
        } else {
            prepared = try converter.resample(samples, from: sampleRate)
        }

        var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let started = Date()
        let result = try await manager.transcribe(
            prepared, decoderState: &decoderState, language: languageHint)
        let elapsed = Date().timeIntervalSince(started)

        // Echtzeitfaktor auf dieser Maschine protokollieren. Fremde Benchmarks taugen
        // nicht als Zusage: die veröffentlichten Zahlen stammen von deutlich neuerer
        // Hardware.
        let audioSeconds = Double(prepared.count) / 16_000
        if elapsed > 0 {
            log.info(
                "Transkribiert: \(audioSeconds, format: .fixed(precision: 1)) s Audio in \(elapsed, format: .fixed(precision: 2)) s, Faktor \(audioSeconds / elapsed, format: .fixed(precision: 0))x"
            )
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ServiceError: LocalizedError {
        case notReady

        var errorDescription: String? {
            switch self {
            case .notReady: return L("error.notReady")
            }
        }
    }
}
