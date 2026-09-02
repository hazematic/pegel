import AppKit
import ApplicationServices
import Foundation
import os

/// Liest den Text unmittelbar vor der Einfügemarke.
///
/// Dient nur noch einem Zweck: der Frage, ob vor dem Diktat ein Leerzeichen gehört.
/// Die Anzeige während der Aufnahme hängt nicht mehr daran, weil sich die Position der
/// Einfügemarke als app-abhängig und am Zeilenende unzuverlässig erwiesen hat.
enum CaretTracker {

    // MARK: - Textkontext

    /// Was unmittelbar vor der Einfügemarke steht.
    enum PrecedingContext {
        /// Die Einfügemarke steht am Anfang des Feldes.
        case startOfText
        case character(Character)
        /// Die App gibt ihren Text nicht preis.
        case unknown
    }

    /// Liest das Zeichen direkt vor der Einfügemarke.
    ///
    /// Grundlage für die Frage, ob vor dem Diktat ein Leerzeichen gehört. Bewusst
    /// aus dem echten Text gelesen statt aus dem zuletzt Eingefügten geschlossen:
    /// dazwischen kann getippt oder der Cursor bewegt worden sein.
    static func precedingContext() -> PrecedingContext {
        enableManualAccessibilityForFrontmostApp()
        guard AXIsProcessTrusted(), let element = focusedElement() else { return .unknown }

        guard let range = selectedRange(in: element) else { return .unknown }
        guard range.location > 0 else { return .startOfText }

        guard
            let text = string(
                of: CFRange(location: range.location - 1, length: 1), in: element),
            let character = text.first
        else { return .unknown }

        return .character(character)
    }

    // MARK: - Accessibility

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let element = value
        else { return nil }
        return (element as! AXUIElement)
    }

    /// Rechteck der Einfügemarke.
    ///
    /// Eine Einfügemarke ohne Auswahl ist null Zeichen lang, und viele Apps liefern
    /// dafür kein brauchbares Rechteck. Deshalb in mehreren Anläufen, beginnend mit
    /// dem Zeichen rechts der Marke: dessen linke Kante ist die Marke, und es liegt
    /// garantiert auf der richtigen Zeile.
    private static func selectedRange(in element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
            let value
        else { return nil }

        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func string(of range: CFRange, in element: AXUIElement) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }

        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }

        var boundsValue: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue, &boundsValue) == .success,
            let boundsValue
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Bittet die Vordergrund-App, ihren Accessibility-Baum aufzubauen.
    ///
    /// Chromium- und damit Electron-Apps (Obsidian, Slack, VS Code) geben ohne dieses
    /// Attribut keinen Text heraus. Einmal pro Prozess genügt.
    private static var manualAccessibilityEnabled: Set<pid_t> = []

    static func enableManualAccessibilityForFrontmostApp() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            !manualAccessibilityEnabled.contains(pid)
        else { return }

        manualAccessibilityEnabled.insert(pid)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
