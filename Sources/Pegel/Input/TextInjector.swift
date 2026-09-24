import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Inserts text at the caret via the clipboard and a synthetic ⌘V, which works in
/// virtually every app, unlike setting text through Accessibility.
enum TextInjector {

    /// Time for the target app to read the clipboard before it is restored.
    private static let restoreDelay: TimeInterval = 0.2

    private static let log = Logger(subsystem: "io.github.hazematic.pegel", category: "insert")

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        let payload = leadingSpace(before: text) + text
        // Logs no text. A still-held ⌥ turns ⌘V into ⌥⌘V, which many apps ignore.
        let held = CGEventSource.flagsState(.hidSystemState)
            .intersection([.maskAlternate, .maskShift, .maskControl, .maskCommand])
        log.notice(
            "Inserting \(payload.count) characters into \(CaretTracker.activeApplication?.bundleIdentifier ?? "?", privacy: .public), held modifiers: \(held.rawValue)"
        )
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

    // MARK: - Leading space

    private static let openingCharacters: Set<Character> = [
        "(", "[", "{", "\"", "'", "„", "“", "‚", "‘", "«", "‹", "/", "-", "–", "@", "#",
    ]

    private static let closingCharacters: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "“", "”", "‘", "»", "›",
    ]

    /// Parakeet ends every sentence with a period; without this the next one would stick to it.
    private static func leadingSpace(before text: String) -> String {
        guard let first = text.first, !first.isWhitespace,
            !closingCharacters.contains(first)
        else { return "" }

        // Logs only what kind of context was found, never the text itself.
        let space: String
        let found: String
        switch CaretTracker.precedingContext() {
        case .startOfText:
            (space, found) = ("", "start of text")
        case .character(let previous):
            let open = previous.isWhitespace || openingCharacters.contains(previous)
            (space, found) = (open ? "" : " ", "character")
        case .unknown:
            // Some apps hide their text; fall back to our own last insertion.
            (space, found) = (fallbackSpace(), "unknown, fallback")
        }
        log.notice("Preceding context: \(found, privacy: .public), leading space: \(!space.isEmpty)")
        return space
    }

    private static func fallbackSpace() -> String {
        guard let last = lastInsertion,
            last.app == CaretTracker.activeApplication?.bundleIdentifier,
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
            app: CaretTracker.activeApplication?.bundleIdentifier,
            at: Date()
        )
    }

    // MARK: - Clipboard backup

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

    // MARK: - Synthetic key press

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
