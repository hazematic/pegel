import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Ein Tastenkürzel als Keycode plus Modifier.
///
/// Keycodes sind Positionsangaben und layout-unabhängig: Keycode 10 ist auf jeder
/// ISO-Tastatur die Taste links neben der 1, auf deutschem Layout also `^ °`.
/// Für die Anzeige muss der Keycode deshalb über das aktive Layout aufgelöst werden.
struct HotkeyBinding: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// Rohwert der `CGEventFlags`, bereits auf die relevanten Bits maskiert.
    var modifiers: UInt64

    /// Nur diese Modifier werden verglichen. CapsLock, Fn und die Numpad-Bits
    /// bleiben außen vor, sonst reagiert das Kürzel je nach Tastaturzustand nicht.
    static let relevantFlags: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift,
    ]

    /// ⌥ + Leertaste.
    ///
    /// Die Leertaste sitzt auf jeder Tastatur an derselben Stelle, ANSI wie ISO wie
    /// JIS. Das frühere ⌘ plus `^ °` war Keycode 10 (`kVK_ISO_Section`) und existiert
    /// auf amerikanischen ANSI-Tastaturen physisch nicht.
    ///
    /// ⌥Leertaste ist in macOS kein Kurzbefehl: ⌘Leertaste gehört Spotlight,
    /// ⌃Leertaste und ⌃⌥Leertaste der Eingabequellen-Umschaltung, ⌘⌥Leertaste dem
    /// Finder-Suchfenster. Übrig bleibt, dass ⌥Leertaste beim Tippen ein geschütztes
    /// Leerzeichen einfügt; das fängt der Event-Tap ab. Bekannter Konflikt außerhalb
    /// des Systems: Alfred belegt ⌥Leertaste vorgegeben.
    static let fallback = HotkeyBinding(
        keyCode: UInt16(kVK_Space),
        modifiers: CGEventFlags.maskAlternate.rawValue
    )

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    func matches(keyCode code: Int64, flags eventFlags: CGEventFlags) -> Bool {
        guard UInt16(truncatingIfNeeded: code) == keyCode else { return false }
        return eventFlags.intersection(Self.relevantFlags).rawValue == modifiers
    }

    // MARK: - Anzeige

    var displayString: String {
        var result = ""
        let f = flags
        if f.contains(.maskControl) { result += "⌃" }
        if f.contains(.maskAlternate) { result += "⌥" }
        if f.contains(.maskShift) { result += "⇧" }
        if f.contains(.maskCommand) { result += "⌘" }
        return result + Self.keyLabel(for: keyCode)
    }

    /// Löst einen Keycode gegen das aktive Tastaturlayout auf.
    static func keyLabel(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        if let translated = translate(keyCode: keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return L("key.unknown", Int(keyCode))
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: L("key.space"), kVK_Return: "⏎", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func translate(keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue()
        return (layoutData as Data).withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }

            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)

            func run() -> OSStatus {
                UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &length, &chars)
            }

            guard run() == noErr else { return nil }
            // Tottasten (auf deutschem Layout etwa `^`) liefern beim ersten Durchlauf
            // nichts und geben ihr Zeichen erst mit dem gesetzten Dead-Key-State heraus.
            if length == 0, deadKeyState != 0, run() != noErr { return nil }
            guard length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    // MARK: - Persistenz

    private static let defaultsKey = "hotkeyBinding"

    static func load() -> HotkeyBinding {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(HotkeyBinding.self, from: data)
        else { return .fallback }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Validierung

    /// Kürzel, die das System oder die App unbrauchbar machen würden.
    func rejectionReason() -> String? {
        let f = flags
        let hasModifier = !f.intersection(Self.relevantFlags).isEmpty
        if !hasModifier {
            return L("hotkey.reject.noModifier")
        }
        if keyCode == UInt16(kVK_Escape) {
            return L("hotkey.reject.escape")
        }
        let blocked: [(UInt16, CGEventFlags, String)] = [
            (UInt16(kVK_ANSI_Q), .maskCommand, L("hotkey.reject.quit")),
            (UInt16(kVK_ANSI_W), .maskCommand, L("hotkey.reject.close")),
            (UInt16(kVK_Tab), .maskCommand, L("hotkey.reject.switchApp")),
            (UInt16(kVK_Space), .maskCommand, L("hotkey.reject.spotlight")),
        ]
        for (code, modifier, reason) in blocked
        where keyCode == code && f.intersection(Self.relevantFlags) == modifier {
            return reason
        }
        return nil
    }
}
