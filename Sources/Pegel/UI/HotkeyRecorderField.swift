import AppKit
import CoreGraphics
import SwiftUI

/// Feld, das den nächsten Tastendruck als Kürzel aufnimmt.
///
/// Bewusst über einen lokalen Responder und nicht über den globalen Event-Tap:
/// beim Aufnehmen soll die Taste ausschließlich hier ankommen.
struct HotkeyRecorderField: NSViewRepresentable {

    @Binding var binding: HotkeyBinding
    var onRejected: (String) -> Void
    /// Meldet an, solange das Feld auf eine Taste wartet. Der Aufrufer legt damit
    /// den globalen Tap still, sonst fängt der das bisherige Kürzel ab und startet
    /// eine Aufnahme, statt dass die Taste hier ankommt.
    var onCaptureChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { candidate in
            if let reason = candidate.rejectionReason() {
                onRejected(reason)
            } else {
                binding = candidate
            }
        }
        view.onCaptureChanged = onCaptureChanged
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.display = binding.displayString
        view.needsDisplay = true
    }

    final class RecorderView: NSView {

        var onCapture: ((HotkeyBinding) -> Void)?
        var onCaptureChanged: ((Bool) -> Void)?
        var display: String = "" { didSet { needsDisplay = true } }
        private var isRecording = false {
            didSet {
                guard isRecording != oldValue else { return }
                needsDisplay = true
                onCaptureChanged?(isRecording)
            }
        }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        /// Auch wenn das Feld aus dem Fenster verschwindet, muss der Tap wieder
        /// scharf werden. Sonst bliebe das Kürzel nach dem Schließen tot.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { isRecording = false }
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            isRecording = false
            window?.makeFirstResponder(nil)

            if event.keyCode == 53 { return }  // Escape bricht das Aufnehmen ab

            var flags: CGEventFlags = []
            if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
            if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
            if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
            if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }

            onCapture?(HotkeyBinding(keyCode: event.keyCode, modifiers: flags.rawValue))
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 2 : 1
            path.stroke()

            let text = isRecording ? L("hotkey.pressKey") : display
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: attributes)
        }
    }
}
