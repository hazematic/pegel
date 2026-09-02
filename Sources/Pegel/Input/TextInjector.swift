import AppKit
import Carbon.HIToolbox
import Foundation

/// Fügt Text an der Einfügemarke der gerade aktiven App ein.
///
/// Über die Zwischenablage plus synthetisches ⌘V, weil das in praktisch jeder App
/// funktioniert. Direktes Setzen über die Accessibility-API klappt nur in einem Teil
/// der Programme und ignoriert dort außerdem die Undo-Historie.
enum TextInjector {

    /// Zeit, die die Zielanwendung zum Verarbeiten des Pastes bekommt, bevor die
    /// Zwischenablage zurückgesetzt wird.
    private static let restoreDelay: TimeInterval = 0.2

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        let payload = leadingSpace(before: text) + text
        let pasteboard = NSPasteboard.general
        let backup = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        postPasteShortcut()
        rememberInsertion(of: payload)

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            restore(backup, to: pasteboard)
        }
    }

    // MARK: - Abstand zum vorherigen Satz

    /// Zeichen, nach denen kein Leerzeichen gehört, obwohl sie kein Leerraum sind.
    private static let openingCharacters: Set<Character> = [
        "(", "[", "{", "\"", "'", "„", "“", "‚", "‘", "«", "‹", "/", "-", "–", "@", "#",
    ]

    /// Zeichen, vor denen kein Leerzeichen gehört, wenn das Diktat damit anfängt.
    private static let closingCharacters: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "“", "”", "‘", "»", "›",
    ]

    /// Entscheidet, ob vor dem Diktat ein Leerzeichen gehört.
    ///
    /// Parakeet schließt jeden Satz mit einem Punkt ab. Ohne diesen Zusatz klebte
    /// das nächste Diktat direkt am vorherigen Satzende.
    private static func leadingSpace(before text: String) -> String {
        guard let first = text.first, !first.isWhitespace,
            !closingCharacters.contains(first)
        else { return "" }

        switch CaretTracker.precedingContext() {
        case .startOfText:
            return ""
        case .character(let previous):
            if previous.isWhitespace || openingCharacters.contains(previous) { return "" }
            return " "
        case .unknown:
            // Terminal und einige Java- und Electron-Apps geben ihren Text nicht
            // preis. Dann bleibt nur, sich an das eigene letzte Einfügen zu erinnern.
            return fallbackSpace()
        }
    }

    private static func fallbackSpace() -> String {
        guard let last = lastInsertion,
            last.app == NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            Date().timeIntervalSince(last.at) < 120,
            let previous = last.text.last, !previous.isWhitespace,
            !openingCharacters.contains(previous)
        else { return "" }
        return " "
    }

    private static var lastInsertion: (text: String, app: String?, at: Date)?

    private static func rememberInsertion(of text: String) {
        lastInsertion = (
            text: text,
            app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            at: Date()
        )
    }

    // MARK: - Zwischenablage sichern

    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }

    private static func restore(
        _ backup: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !backup.isEmpty else { return }
        let items = backup.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Tastendruck erzeugen

    private static func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = CGKeyCode(kVK_ANSI_V)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
