import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// Microphone, Accessibility (synthetic ⌘V, caret position) and Input Monitoring,
/// which a `CGEventTap` needs to see key events at all. Both keyboard ones are required.
enum Permissions {

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static var allGranted: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func requestMicrophone() async -> Bool {
        if microphoneGranted { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Takes effect only after the switch is flipped; the caller has to poll.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
