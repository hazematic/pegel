import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Global keyboard tap for the dictation shortcut and Escape. A `CGEventTap` rather
/// than `RegisterEventHotKey`: only the tap delivers reliable key-up events and can
/// swallow Escape.
final class HotkeyMonitor {

    enum Signal {
        case hotkeyDown
        case hotkeyUp
        case escape
    }

    var onSignal: ((Signal) -> Void)?

    var binding: HotkeyBinding {
        // Switching mid-press must not leave a release of the old key unhandled.
        didSet { swallowedKeyDown = false }
    }

    /// Escape is only swallowed while recording or transcribing a file.
    var isRecording: Bool = false
    var isTranscribingFile: Bool = false

    /// Passes everything through while the recorder field captures a new shortcut.
    var isSuspended: Bool = false {
        didSet { if isSuspended { swallowedKeyDown = false } }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// A release is only swallowed if its press was. Otherwise a shortcut on Space would
    /// eat key-ups of normal spaces, and apps that track a held Space would get stuck.
    private var swallowedKeyDown = false
    private let log = Logger(subsystem: "io.github.hazematic.pegel", category: "hotkey")

    init(binding: HotkeyBinding) {
        self.binding = binding
    }

    /// - Returns: false if the tap couldn't be created, usually missing Accessibility.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard
            let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.error("Could not create event tap: Input Monitoring or Accessibility missing")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        tap = newTap
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    // MARK: - Callback

    /// Keep this short: macOS disables taps whose callback is slow.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.warning("Event tap disabled by the system, re-enabled")
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let pass = Unmanaged.passUnretained(event)

        guard !isSuspended else { return pass }

        switch type {
        case .keyDown:
            if isRecording || isTranscribingFile, keyCode == Int64(kVK_Escape) {
                signal(.escape)
                return nil
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Letting go of ⌘ a moment before the key leaves repeats without the modifier.
            // Passed through, such a repeat reaches the app as a bare `^`, a dead key that
            // then swallows the ⌘V of the insertion. Only repeats: after a missed release,
            // a fresh press must still be judged by its modifiers.
            if isRepeat, swallowedKeyDown,
                UInt16(truncatingIfNeeded: keyCode) == binding.keyCode
            {
                return nil
            }
            guard binding.matches(keyCode: keyCode, flags: event.flags) else { return pass }
            swallowedKeyDown = true
            if isRepeat { return nil }
            signal(.hotkeyDown)
            return nil

        case .keyUp:
            // Ignore modifiers on release, so letting go of Option first still ends cleanly.
            guard swallowedKeyDown, UInt16(truncatingIfNeeded: keyCode) == binding.keyCode
            else { return pass }
            swallowedKeyDown = false
            signal(.hotkeyUp)
            return nil

        default:
            return pass
        }
    }

    /// Starting a recording builds the audio engine, which can take long enough after a
    /// wake for macOS to disable the tap and hand the key to the app. So the callback
    /// only decides and returns; the work runs right after, in order.
    private func signal(_ signal: Signal) {
        DispatchQueue.main.async { [weak self] in self?.onSignal?(signal) }
    }
}
