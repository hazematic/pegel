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
        guard let pid = activeApplication?.processIdentifier else {
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
        let justEnabled = enableManualAccessibilityForFrontmostApp()
        guard AXIsProcessTrusted() else { return .unknown }
        // Chromium builds its tree only after the first request; ask once more.
        if justEnabled, selectedRange(in: focusedElement()) == nil {
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard let element = focusedElement() else { return .unknown }

        guard let range = selectedRange(in: element) else { return .unknown }
        guard range.location > 0, !showsOnlyGeneratedText(element) else { return .startOfText }

        guard
            let text = string(
                of: CFRange(location: range.location - 1, length: 1), in: element),
            let character = text.first
        else { return .unknown }

        return .character(character)
    }

    // MARK: - Accessibility

    /// System-wide first, then the frontmost app: Electron apps such as VS Code answer
    /// the system-wide query with kAXErrorCannotComplete but report focus to their own element.
    private static func focusedElement() -> AXUIElement? {
        if let element = focusedElement(of: AXUIElementCreateSystemWide()) { return element }
        guard let pid = activeApplication?.processIdentifier else {
            return nil
        }
        return focusedElement(of: AXUIElementCreateApplication(pid))
    }

    private static func focusedElement(of owner: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                owner, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let element = value
        else { return nil }
        return (element as! AXUIElement)
    }

    /// Chromium reports a CSS placeholder as field content, with the caret behind it.
    /// Generated text has a negative ChromeAXNodeId, typed text a positive one.
    private static func showsOnlyGeneratedText(_ field: AXUIElement) -> Bool {
        guard nodeId(of: field) != nil else { return false }
        var generated = false
        var budget = 64
        func visit(_ element: AXUIElement, depth: Int) -> Bool {
            guard depth < 4, budget > 0 else { return true }
            for child in children(of: element) {
                budget -= 1
                if role(of: child) == kAXStaticTextRole {
                    guard let id = nodeId(of: child), id < 0 else { return false }
                    generated = true
                }
                guard visit(child, depth: depth + 1) else { return false }
            }
            return true
        }
        return visit(field, depth: 0) && generated
    }

    private static func nodeId(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "ChromeAXNodeId" as CFString, &value) == .success
        else { return nil }
        return (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) }
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func selectedRange(in element: AXUIElement?) -> CFRange? {
        guard let element else { return nil }
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

    /// The app that receives keystrokes. After unlocking the screen, macOS can keep
    /// reporting loginwindow as frontmost until another app is activated; the menu bar
    /// owner is right in that state.
    static var activeApplication: NSRunningApplication? {
        NSWorkspace.shared.menuBarOwningApplication ?? NSWorkspace.shared.frontmostApplication
    }

    /// Chromium/Electron apps (Obsidian, Slack, VS Code) expose no text without this.
    private static var manualAccessibilityEnabled: Set<pid_t> = []

    /// True when this call switched it on, i.e. the app's tree may not exist yet.
    @discardableResult
    static func enableManualAccessibilityForFrontmostApp() -> Bool {
        guard let pid = activeApplication?.processIdentifier,
            !manualAccessibilityEnabled.contains(pid)
        else { return false }

        manualAccessibilityEnabled.insert(pid)
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return true
    }
}
