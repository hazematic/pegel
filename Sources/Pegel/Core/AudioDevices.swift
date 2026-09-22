import CoreAudio
import Foundation
import os

struct AudioInputDevice: Identifiable, Equatable, Hashable {
    /// Runtime only: CoreAudio reassigns IDs on every restart.
    let id: AudioDeviceID
    /// Stable across restarts, so the selection is stored by UID.
    let uid: String
    let name: String
    let sampleRate: Double
    let channels: Int

    /// Below the model's 16 kHz, e.g. Bluetooth headsets on HFP (8 kHz).
    var isNarrowband: Bool { sampleRate > 0 && sampleRate < 16_000 }

    var summary: String {
        guard sampleRate > 0 else { return name }
        let kHz = (sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))
        return "\(name), \(kHz) kHz"
    }
}

/// Input devices via the CoreAudio HAL. AVFoundation doesn't expose the
/// `AudioDeviceID` the engine's input node needs.
enum AudioDevices {

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func inputs() -> [AudioInputDevice] {
        allDeviceIDs()
            .compactMap(device)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var defaultInput: AudioInputDevice? {
        guard let id = defaultInputID() else { return nil }
        return device(id)
    }

    static func input(uid: String) -> AudioInputDevice? {
        inputs().first { $0.uid == uid }
    }

    /// - Returns: nil without input channels, so speakers and displays are left out.
    static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        return AudioInputDevice(
            id: id,
            uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
            name: string(id, kAudioObjectPropertyName) ?? L("audio.device.unknown"),
            sampleRate: sampleRate(id),
            channels: channels)
    }

    // MARK: - HAL

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var query = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &query, 0, nil, &size) == noErr, size > 0
        else { return [] }

        var ids = [AudioDeviceID](
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &query, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var query = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &query, 0, nil, &size, &id) == noErr,
            id != AudioDeviceID(kAudioObjectUnknown)
        else { return nil }
        return id
    }

    private static func string(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var query = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &query, 0, nil, &size, &value) == noErr,
            let value
        else { return nil }
        // Returned +1 retained; we own it.
        return value.takeRetainedValue() as String
    }

    private static func sampleRate(_ id: AudioDeviceID) -> Double {
        var query = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &query, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var query = address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &query, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        // Variable-length struct, hence raw memory.
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &query, 0, nil, &size, buffer) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Reports devices appearing, disappearing or the default changing. An object, because
/// CoreAudio holds the listener blocks until they are removed.
final class AudioDeviceWatcher {

    private let onChange: () -> Void
    private var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        observe(kAudioHardwarePropertyDevices)
        observe(kAudioHardwarePropertyDefaultInputDevice)
    }

    deinit {
        for (stored, block) in registered {
            var query = stored
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &query, DispatchQueue.main, block)
        }
    }

    private func observe(_ selector: AudioObjectPropertySelector) {
        var query = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange() }
        guard
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &query, DispatchQueue.main, block) == noErr
        else {
            Logger(subsystem: "io.github.hazematic.pegel", category: "audio").error(
                "Could not register device listener")
            return
        }
        registered.append((query, block))
    }
}
