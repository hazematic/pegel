import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A shortcut as keycode plus modifiers. Keycodes are layout-independent positions,
/// so the label is resolved through the active layout.
struct HotkeyBinding: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// Raw `CGEventFlags`, masked to the relevant bits.
    var modifiers: UInt64

    /// Caps Lock, Fn and numpad bits are ignored so keyboard state doesn't matter.
    static let relevantFlags: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift,
    ]

    /// ⌥Space: same position on ANSI, ISO and JIS, and not a system shortcut. Alfred
    /// uses it by default. The old ⌘ + `^` (keycode 10) doesn't exist on ANSI keyboards.
    static let fallback = HotkeyBinding(
        keyCode: UInt16(kVK_Space),
        modifiers: CGEventFlags.maskAlternate.rawValue
    )

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    func matches(keyCode code: Int64, flags eventFlags: CGEventFlags) -> Bool {
        guard UInt16(truncatingIfNeeded: code) == keyCode else { return false }
        return eventFlags.intersection(Self.relevantFlags).rawValue == modifiers
    }

    // MARK: - Display

    var displayString: String {
        var result = ""
        let f = flags
        if f.contains(.maskControl) { result += "⌃" }
        if f.contains(.maskAlternate) { result += "⌥" }
        if f.contains(.maskShift) { result += "⇧" }
        if f.contains(.maskCommand) { result += "⌘" }
        return result + Self.keyLabel(for: keyCode)
    }

    /// macOS order: ⌃ ⌥ ⇧ ⌘, then the key.
    var keycapLabels: [String] {
        let f = flags
        var labels: [String] = []
        if f.contains(.maskControl) { labels.append("⌃") }
        if f.contains(.maskAlternate) { labels.append("⌥") }
        if f.contains(.maskShift) { labels.append("⇧") }
        if f.contains(.maskCommand) { labels.append("⌘") }
        labels.append(Self.keyLabel(for: keyCode))
        return labels
    }

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
            // Dead keys (e.g. `^` on German layouts) only yield their character on a second pass.
            if length == 0, deadKeyState != 0, run() != noErr { return nil }
            guard length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    // MARK: - Persistence

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

    // MARK: - Validation

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
