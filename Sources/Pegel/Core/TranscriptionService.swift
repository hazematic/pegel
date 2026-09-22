import AVFoundation
import FluidAudio
import Foundation
import os

/// Parakeet TDT 0.6B v3 via FluidAudio, running locally on the Neural Engine.
actor TranscriptionService {

    /// Finer than a percentage: Core ML compilation takes minutes without visible progress.
    enum Preparation: Equatable {
        case listing
        case downloading(fraction: Double, completedFiles: Int, totalFiles: Int)
        case compiling
        case loading
        case warmingUp
        case ready
    }

    /// Derived from the files, not a stored flag, so deleting the model folder brings back setup.
    nonisolated static var isModelInstalled: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    private var manager: AsrManager?
    private let converter = AudioConverter()
    private let log = Logger(subsystem: "io.github.hazematic.pegel", category: "asr")

    /// Filters out candidates from other scripts; English terms in German stay intact.
    private let languageHint: Language = .german

    var isReady: Bool { manager != nil }

    /// Removes Core ML compilation caches of previous builds (~36 MB each, never cleaned
    /// by the system). Only when the build changed, since that recompiles anyway (~40 s).
    nonisolated private static func purgeStaleCompilationCache() {
        let key = "compiledModelBuild"
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "?"
        let built = (try? Bundle.main.executableURL?.resourceValues(
            forKeys: [.contentModificationDateKey]))??.contentModificationDate
        let stamp = "\(version)@\(built?.timeIntervalSince1970.rounded() ?? 0)"

        guard UserDefaults.standard.string(forKey: key) != stamp else { return }
        defer { UserDefaults.standard.set(stamp, forKey: key) }

        guard let identifier = Bundle.main.bundleIdentifier,
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first
        else { return }

        let cache =
            caches
            .appendingPathComponent(identifier)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache")
        guard FileManager.default.fileExists(atPath: cache.path) else { return }
        try? FileManager.default.removeItem(at: cache)
        Logger(subsystem: "io.github.hazematic.pegel", category: "asr").info(
            "Removed compiled models of the previous build")
    }

    /// The warmup moves the first-run Core ML compilation out of the first dictation.
    func prepare(progress: @escaping @Sendable (Preparation) -> Void) async throws {
        guard manager == nil else {
            progress(.ready)
            return
        }

        // Before loading, or this would hit the entry about to be created.
        Self.purgeStaleCompilationCache()

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
        log.info("Parakeet TDT v3 ready")
    }

    /// Fresh decoder state per call: each dictation is its own utterance.
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

        // Real-time factor on this machine; published benchmarks come from newer hardware.
        let audioSeconds = Double(prepared.count) / 16_000
        if elapsed > 0 {
            log.info(
                "Transcribed: \(audioSeconds, format: .fixed(precision: 1)) s of audio in \(elapsed, format: .fixed(precision: 2)) s, factor \(audioSeconds / elapsed, format: .fixed(precision: 0))x"
            )
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FluidAudio handles decoding, resampling and chunking; large files stream from disk.
    /// - Parameter progress: 0...1, only for files over 15 s.
    func transcribe(
        fileAt url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        guard let manager else { throw ServiceError.notReady }

        let duration: TimeInterval
        do {
            let file = try AVAudioFile(forReading: url)
            duration = Double(file.length) / file.processingFormat.sampleRate
        } catch {
            log.error("File unreadable: \(error.localizedDescription)")
            throw ServiceError.unreadableFile(url.lastPathComponent)
        }
        guard duration >= 0.25 else { throw ServiceError.tooShort }

        // Short files never finish a progress session, and the open stream would leak into
        // the next long dictation.
        var watcher: Task<Void, Never>?
        if duration > 15 {
            let stream = await manager.transcriptionProgressStream
            watcher = Task {
                do {
                    for try await value in stream { progress(value) }
                } catch {}
            }
        }
        defer { watcher?.cancel() }

        var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let started = Date()
        let result = try await manager.transcribe(
            url, decoderState: &decoderState, language: languageHint)
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 0 {
            log.info(
                "File transcribed: \(duration, format: .fixed(precision: 1)) s of audio in \(elapsed, format: .fixed(precision: 2)) s, factor \(duration / elapsed, format: .fixed(precision: 0))x"
            )
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ServiceError: LocalizedError {
        case notReady
        case unreadableFile(String)
        case tooShort

        var errorDescription: String? {
            switch self {
            case .notReady: return L("error.notReady")
            case .unreadableFile(let name): return L("error.unreadableFile", name)
            case .tooShort: return L("error.tooShort")
            }
        }
    }
}
