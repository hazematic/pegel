import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Globaler Tastaturmitschnitt für das Diktat-Kürzel und den Escape-Abbruch.
///
/// Bewusst ein `CGEventTap` statt `RegisterEventHotKey`: nur der Tap liefert
/// verlässliche Key-Up-Events (Voraussetzung für Push-to-talk) und kann Escape
/// während der Aufnahme schlucken, damit es nicht zusätzlich in der Zielanwendung
/// landet.
final class HotkeyMonitor {

    enum Signal {
        case hotkeyDown
        case hotkeyUp
        case escape
    }

    /// Wird auf dem Main-Thread aufgerufen; der Tap läuft im Main-Runloop.
    var onSignal: ((Signal) -> Void)?

    /// Aktuelles Kürzel. Kann jederzeit ersetzt werden, ohne den Tap neu zu bauen.
    var binding: HotkeyBinding {
        // Ein Wechsel mitten im Tastendruck darf kein Loslassen der alten Taste
        // hinterlassen, das nie abgefangen wird.
        didSet { swallowedKeyDown = false }
    }

    /// Nur während einer laufenden Aufnahme wird Escape abgefangen und geschluckt.
    var isRecording: Bool = false

    /// Reicht alles unverändert durch, solange gesetzt. Gedacht für das Aufnehmen
    /// eines neuen Kürzels: dort muss die Taste im Aufnahmefeld ankommen und darf
    /// nicht hier abgefangen werden.
    var isSuspended: Bool = false {
        didSet { if isSuspended { swallowedKeyDown = false } }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Ob der letzte Druck dieser Taste als Kürzel geschluckt wurde.
    ///
    /// Das Loslassen wird nur dann abgefangen, wenn auch das Drücken abgefangen war.
    /// Ohne diese Symmetrie würde bei einem Kürzel auf der Leertaste jedes normale
    /// Leerzeichen sein Key-Up verlieren, und Anwendungen, die das Halten der
    /// Leertaste auswerten (Figma, Photoshop), blieben im gehaltenen Zustand hängen.
    private var swallowedKeyDown = false
    private let log = Logger(subsystem: "io.github.hazematic.pegel", category: "hotkey")

    init(binding: HotkeyBinding) {
        self.binding = binding
    }

    /// - Returns: false, wenn der Tap nicht erzeugt werden konnte. Praktisch immer
    ///   ein fehlendes Bedienungshilfen-Recht.
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
            log.error("Event-Tap konnte nicht erzeugt werden. Es fehlt Eingabeueberwachung oder Bedienungshilfen.")
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

    /// Muss kurz bleiben: macOS schaltet Taps ab, deren Callback zu lange braucht.
    /// Deshalb hier nur Zustand auswerten und weitermelden, keine Arbeit erledigen.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.warning("Event-Tap wurde vom System abgeschaltet und wieder aktiviert")
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let pass = Unmanaged.passUnretained(event)

        guard !isSuspended else { return pass }

        switch type {
        case .keyDown:
            if isRecording, keyCode == Int64(kVK_Escape) {
                onSignal?(.escape)
                return nil
            }
            guard binding.matches(keyCode: keyCode, flags: event.flags) else { return pass }
            swallowedKeyDown = true
            // Auto-Repeat beim Halten ignorieren, sonst feuert der Start dauernd nach.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            onSignal?(.hotkeyDown)
            return nil

        case .keyUp:
            // Beim Loslassen werden die Modifier nicht mehr verglichen: wer erst
            // Option loslässt und dann die Taste, soll trotzdem sauber beenden.
            guard swallowedKeyDown, UInt16(truncatingIfNeeded: keyCode) == binding.keyCode
            else { return pass }
            swallowedKeyDown = false
            onSignal?(.hotkeyUp)
            return nil

        default:
            return pass
        }
    }
}
