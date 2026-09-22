import AppKit
import CoreGraphics
import SwiftUI

/// Records the next key press as a shortcut and shows it as keycaps. Capture needs a
/// real AppKit responder; the keycaps are drawn in SwiftUI.
struct HotkeyRecorderField: View {

    @Binding var binding: HotkeyBinding
    var onRejected: (String) -> Void
    var onCaptureChanged: (Bool) -> Void = { _ in }

    @State private var capturing = false

    var body: some View {
        KeyCaptureView(
            binding: $binding, onRejected: onRejected,
            onCaptureChanged: { active in
                capturing = active
                onCaptureChanged(active)
            }
        )
        .overlay {
            Group {
                if capturing {
                    Text(L("hotkey.pressKey"))
                        .foregroundStyle(.secondary)
                } else {
                    KeycapRow(labels: binding.keycapLabels)
                }
            }
            // Clicks go to the capture view underneath.
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(capturing ? L("hotkey.pressKey") : binding.displayString)
    }
}

/// A local responder, not the global tap, so the key arrives only here.
private struct KeyCaptureView: NSViewRepresentable {

    @Binding var binding: HotkeyBinding
    var onRejected: (String) -> Void
    /// True while waiting; the caller suspends the global tap meanwhile.
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
        view.needsDisplay = true
    }

    final class RecorderView: NSView {

        var onCapture: ((HotkeyBinding) -> Void)?
        var onCaptureChanged: ((Bool) -> Void)?
        private var isRecording = false {
            didSet {
                guard isRecording != oldValue else { return }
                needsDisplay = true
                onCaptureChanged?(isRecording)
            }
        }

        private var isHovered = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        /// Re-arm the tap when the field leaves the window, or the shortcut stays dead.
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

            if event.keyCode == 53 { return }    // Escape cancels capture

            var flags: CGEventFlags = []
            if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
            if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
            if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
            if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }

            onCapture?(HotkeyBinding(keyCode: event.keyCode, modifiers: flags.rawValue))
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            let fill: NSColor
            if isRecording {
                fill = NSColor.controlAccentColor.withAlphaComponent(0.12)
            } else if isHovered {
                fill = NSColor.controlAccentColor.withAlphaComponent(0.06)
            } else {
                fill = NSColor.controlBackgroundColor
            }
            fill.setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 2 : 1
            path.stroke()
        }
    }
}

struct KeycapRow: View {
    let labels: [String]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Keycap(label: label)
            }
        }
    }
}

struct Keycap: View {
    let label: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Text(label)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: dark
                                ? [Color(white: 0.36), Color(white: 0.30)]
                                : [Color.white, Color(white: 0.94)],
                            startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        dark ? Color.white.opacity(0.10) : Color.black.opacity(0.16),
                        lineWidth: 0.5)
            )
            // Hard shadow as the bottom edge, so the key stands rather than floats.
            .shadow(color: .black.opacity(dark ? 0.55 : 0.22), radius: 0, y: 1)
    }
}
