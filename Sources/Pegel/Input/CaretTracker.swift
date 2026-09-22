import AppKit
import ApplicationServices
import Foundation
import os

/// Reads text and position around the caret: for the leading space and for choosing
/// the pill's screen. Too unreliable to place anything at the caret itself.
enum CaretTracker {

    // MARK: - Location

    /// Runs on the main thread at recording start; a hung app must not block the pill.
    private static let locationTimeout: Float = 0.2

    /// A point on the caret's screen in Cocoa coordinates. Falls back from caret rect to
    /// focused element to focused window; VS Code has no caret rect but a field frame.
    static func caretLocation() -> NSPoint? {
        enableManualAccessibilityForFrontmostApp()
        guard AXIsProcessTrusted() else { return nil }

        if let element = focusedElement() {
            AXUIElementSetMessagingTimeout(element, locationTimeout)
            if let rect = caretBounds(in: element) ?? frame(of: element) {
                return cocoaPoint(at: rect)
            }
        }
        if let window = focusedWindow(), let rect = frame(of: window) {
            return cocoaPoint(at: rect)
        }
        return nil
    }

    private static func caretBounds(in element: AXUIElement) -> CGRect? {
        guard let range = selectedRange(in: element) else { return nil }
        // Selection first, then the character right of the caret, then left. An empty
        // selection often yields a zero rect.
        let candidates = [
            range,
            CFRange(location: range.location, length: 1),
            CFRange(location: max(range.location - 1, 0), length: 1),
        ]
        return candidates.lazy.compactMap { bounds(of: $0, in: element) }.first(where: isUsable)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        let rect = CGRect(origin: position, size: size)
        return isUsable(rect) ? rect : nil
    }

    private static func focusedWindow() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, locationTimeout)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let window = value
        else { return nil }
        return (window as! AXUIElement)
    }

    /// Some apps return a zero rect instead of an error.
    private static func isUsable(_ rect: CGRect) -> Bool {
        rect != .zero && rect.origin != .zero
    }

    /// Accessibility counts from the primary screen's top left, Cocoa from bottom left.
    private static func cocoaPoint(at rect: CGRect) -> NSPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        return NSPoint(x: rect.midX, y: primary.frame.maxY - rect.midY)
    }

    // MARK: - Text context

    enum PrecedingContext {
        case startOfText
        case character(Character)
        /// The app doesn't expose its text.
        case unknown
    }

    /// Read from the actual text rather than inferred: the user may have typed or moved since.
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

    /// Chromium/Electron apps (Obsidian, Slack, VS Code) expose no text without this.
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
