import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// Die drei Rechte, ohne die Pegel nicht arbeiten kann.
///
/// Mikrofon ist offensichtlich. Bedienungshilfen brauchen wir für das synthetische
/// ⌘V und für die Frage, wo die Einfügemarke steht. Die Eingabeüberwachung kommt
/// getrennt dazu: seit macOS 10.15 ist sie Voraussetzung dafür, dass ein
/// `CGEventTap` überhaupt Tastaturereignisse zu sehen bekommt. Nur eines von beiden
/// zu erteilen reicht nicht, und der Unterschied ist von außen nicht zu erkennen.
enum Permissions {

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Eingabeüberwachung, in den Systemeinstellungen als eigener Punkt geführt.
    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static var allGranted: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted
    }

    /// Zeigt den Systemdialog für die Eingabeüberwachung.
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

    /// Zeigt den Systemdialog für Bedienungshilfen. Das Recht wird erst nach dem
    /// Umlegen des Schalters wirksam, deshalb muss der Aufrufer danach pollen.
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
