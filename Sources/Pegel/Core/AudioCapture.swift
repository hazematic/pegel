import AVFoundation
import CoreAudio
import Foundation
import os

/// Records the microphone into memory at the device's native rate.
/// Resampling to 16 kHz happens once at the end, not in the audio callback.
final class AudioCapture {

    struct Recording {
        let samples: [Float]
        let sampleRate: Double
        let deviceName: String
        let peakDecibels: Double
        let averageDecibels: Double
        let wallDuration: TimeInterval

        var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

        /// Nothing usable arrived. Separates a dead input device from poor recognition.
        var isSilent: Bool { peakDecibels <= AudioCapture.silenceFloor }

        /// The device delivered no buffer at all.
        var receivedNothing: Bool { samples.isEmpty && wallDuration > 0.4 }
    }

    static let maximumDuration: TimeInterval = 10 * 60

    static let silenceFloor: Double = -60
    /// Full scale. Calibrated on real speech: peaks around -30 to -37 dBFS.
    static let fullScaleLevel: Double = -32

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var inputSampleRate: Double = 0
    private var isRunning = false
    private let log = Logger(subsystem: "io.github.hazematic.pegel", category: "audio")

    private var engineDeviceID: AudioDeviceID?
    private var tapFormat: AVAudioFormat?
    private var deviceName: String = L("audio.device.systemDefault")

    // Written on the audio thread, guarded by `lock`.
    private var peakDecibels: Double = -.infinity
    private var decibelSum: Double = 0
    private var decibelCount: Int = 0
    private var bufferCount: Int = 0

    // Main thread only.
    private var smoothedLevel: Double = 0
    private var isStarting = false
    private var preferredUID: String?
    private var startedAt = Date()
    private var stallCheck: DispatchWorkItem?

    /// First buffer normally arrives after ~90 ms.
    static let stallTimeout: TimeInterval = 0.6

    /// Level 0...1 on the main thread.
    var onLevel: ((Double) -> Void)?
    var onLimitReached: (() -> Void)?
    var onInterrupted: (() -> Void)?

    private var configurationObserver: NSObjectProtocol?

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] notification in
            let source = notification.object as AnyObject?
            MainActor.assumeIsolated { self?.configurationChanged(from: source) }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// - Parameter uid: nil means system default.
    func start(preferring uid: String?) throws {
        guard !isRunning else { return }
        preferredUID = uid

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        peakDecibels = -.infinity
        decibelSum = 0
        decibelCount = 0
        bufferCount = 0
        lock.unlock()

        smoothedLevel = 0
        startedAt = Date()
        try startEngine(forceRebuild: false)
        scheduleStallCheck(retry: true)
    }

    /// Works on a local engine reference throughout: a configuration change during
    /// start used to swap `self.engine`, leaving the tap on a dead engine.
    private func startEngine(forceRebuild: Bool) throws {
        isStarting = true
        defer { isStarting = false }

        // Only set an explicitly chosen device. Setting it, even to the default,
        // triggers a delayed configuration change that stops the engine ~30 ms after start.
        let explicit = preferredUID.flatMap { AudioDevices.input(uid: $0) }
        if preferredUID != nil, explicit == nil {
            log.notice("Selected microphone missing, using system default")
        }
        let device = explicit ?? AudioDevices.defaultInput
        // An engine sticks to the device it was built with.
        if forceRebuild || engineDeviceID != device?.id { rebuildEngine() }
        let engine = self.engine

        let input = engine.inputNode
        if let explicit { try point(input, at: explicit) }

        // `inputFormat`, not `outputFormat`: only the input side follows the device.
        // A tap on a mismatched rate stays silent without any error.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        inputSampleRate = format.sampleRate
        deviceName = device?.name ?? L("audio.device.systemDefault")
        let limit = Int(format.sampleRate * Self.maximumDuration)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer, limit: limit)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            log.error("Engine failed to start: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        isRunning = true
        engineDeviceID = device?.id
        tapFormat = format

        log.notice(
            "Recording starts on \(self.deviceName, privacy: .public): \(format.sampleRate, format: .fixed(precision: 0)) Hz, \(format.channelCount) ch"
        )
    }

    /// Safety net for a stalled tap: rebuild once, then give up.
    private func scheduleStallCheck(retry: Bool) {
        stallCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkForStall(retry: retry) }
        }
        stallCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallTimeout, execute: work)
    }

    private func checkForStall(retry: Bool) {
        guard isRunning else { return }
        lock.lock()
        let received = bufferCount
        lock.unlock()
        guard received == 0 else { return }

        log.error(
            "No buffer after \(Self.stallTimeout, format: .fixed(precision: 1)) s from \(self.deviceName, privacy: .public)\(retry ? ", rebuilding engine" : ", giving up", privacy: .public)"
        )
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        tapFormat = nil

        guard retry else {
            onInterrupted?()
            return
        }
        do {
            try startEngine(forceRebuild: true)
            scheduleStallCheck(retry: false)
        } catch {
            onInterrupted?()
        }
    }

    @discardableResult
    func stop() -> Recording {
        stallCheck?.cancel()
        stallCheck = nil
        guard isRunning else { return empty() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        tapFormat = nil

        lock.lock()
        let captured = samples
        let peak = peakDecibels
        let average = decibelCount > 0 ? decibelSum / Double(decibelCount) : -.infinity
        samples.removeAll(keepingCapacity: false)
        lock.unlock()

        let recording = Recording(
            samples: captured, sampleRate: inputSampleRate, deviceName: deviceName,
            peakDecibels: peak, averageDecibels: average,
            wallDuration: Date().timeIntervalSince(startedAt))
        // Logged to calibrate the level curve and to spot a dead device.
        log.notice(
            "Recording ended on \(self.deviceName, privacy: .public): \(recording.duration, format: .fixed(precision: 1)) s, peak \(peak, format: .fixed(precision: 1)) dBFS, mean \(average, format: .fixed(precision: 1)) dBFS"
        )
        return recording
    }

    func cancel() {
        _ = stop()
    }

    /// Rebuilds on next start, e.g. after wake or a device change. No-op while recording.
    func invalidateDevice() {
        guard !isRunning else { return }
        rebuildEngine()
    }

    // MARK: - Device

    private func point(_ node: AVAudioInputNode, at device: AudioInputDevice) throws {
        guard let unit = node.audioUnit else { throw CaptureError.noInputDevice }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            log.error("Could not set device \(device.name, privacy: .public): \(status)")
            throw CaptureError.deviceUnavailable(device.name)
        }
    }

    private func rebuildEngine() {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        engine = AVAudioEngine()
        engineDeviceID = nil
    }

    /// While recording, keep what was captured so far instead of discarding it.
    private func configurationChanged(from source: AnyObject?) {
        if let source, source !== engine { return }
        // Setting the device during start posts this notification itself.
        guard !isStarting else { return }
        guard isRunning else {
            log.notice("Audio configuration changed, engine rebuilt on next dictation")
            rebuildEngine()
            return
        }

        // The engine stops itself before posting; check that, not device or format.
        guard !engine.isRunning else { return }

        let current = engine.inputNode.inputFormat(forBus: 0)
        let sameFormat =
            current.sampleRate == tapFormat?.sampleRate
            && current.channelCount == tapFormat?.channelCount
        lock.lock()
        let received = bufferCount
        lock.unlock()

        if sameFormat {
            // The tap survives stop/start, so the recording continues.
            do {
                try engine.start()
                log.notice("Engine had stopped itself, restarted")
                return
            } catch {
                log.error("Engine failed to restart: \(error.localizedDescription, privacy: .public)")
            }
        } else if received == 0 {
            engine.inputNode.removeTap(onBus: 0)
            isRunning = false
            tapFormat = nil
            do {
                try startEngine(forceRebuild: false)
                log.notice("Engine restarted after format change")
                return
            } catch {
                log.error("Engine failed to start after format change: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Samples at different rates cannot be joined.
        log.notice(
            "Audio configuration changed mid-recording: now \(current.sampleRate, format: .fixed(precision: 0)) Hz, \(current.channelCount) ch"
        )
        onInterrupted?()
    }

    private func empty() -> Recording {
        Recording(
            samples: [], sampleRate: inputSampleRate, deviceName: deviceName,
            peakDecibels: -.infinity, averageDecibels: -.infinity,
            wallDuration: Date().timeIntervalSince(startedAt))
    }

    // MARK: - Audio thread

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
        bufferCount += 1
        let total = samples.count
        // Measured here: going through the main thread loses the last buffers.
        if decibels.isFinite {
            peakDecibels = max(peakDecibels, decibels)
            decibelSum += decibels
            decibelCount += 1
        }
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.publish(decibels: decibels)
            if total >= limit { self?.onLimitReached?() }
        }
    }

    /// Decibels, not linear: linear speech levels barely move the indicator.
    private func publish(decibels: Double) {
        guard decibels.isFinite else { return }

        let span = Self.fullScaleLevel - Self.silenceFloor
        let target = min(1, max(0, (decibels - Self.silenceFloor) / span))
        // Fast attack, slow release.
        smoothedLevel = target > smoothedLevel ? target : smoothedLevel * 0.72 + target * 0.28
        onLevel?(smoothedLevel)
    }

    enum CaptureError: LocalizedError {
        case noInputDevice
        case deviceUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return L("error.noInputDevice")
            case .deviceUnavailable(let name): return L("error.deviceUnavailable", name)
            }
        }
    }
}
