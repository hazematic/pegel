import AppKit
import SwiftUI

/// Fenster der Pille.
///
/// Darf unter keinen Umständen den Fokus nehmen: sonst wechselt die aktive App und
/// das synthetische ⌘V landet im Nichts statt im Zieltext. Als nicht aktivierendes
/// Panel nimmt es Mausereignisse an, ohne die Vordergrund-App zu wechseln, und lässt
/// sich deshalb ziehen.
final class IndicatorPanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Meldet den neuen Ort, sobald der Nutzer losgelassen hat.
    var onDragEnded: ((NSPoint) -> Void)?

    private var grabOffset: NSPoint?

    override func mouseDown(with event: NSEvent) {
        grabOffset = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabOffset else { return }
        let pointer = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard grabOffset != nil else { return }
        grabOffset = nil
        onDragEnded?(frame.origin)
    }
}

@MainActor
final class IndicatorPanelController {

    private let model = IndicatorModel()
    private let panel: IndicatorPanel
    private var traceTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?

    private let appearDuration: TimeInterval = 0.14
    private let disappearDuration: TimeInterval = 0.12
    /// Die Kapsel steigt beim Erscheinen ein Stück auf.
    private let appearRise: CGFloat = 8

    init() {
        panel = IndicatorPanel(
            contentRect: NSRect(
                origin: .zero, size: Indicator.panelSize(for: .levels, showsTime: true)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Der Schatten wird in SwiftUI gezeichnet, deshalb keiner vom Fenster.
        panel.hasShadow = false
        // Muss Mausereignisse annehmen, sonst ließe sich die Pille nicht ziehen.
        // Das Panel aktiviert die App dabei nicht, der Zieltext behält den Fokus.
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        // Ohne Hit-Testing landen Klicks beim Fenster statt bei SwiftUI, und das
        // Ziehen funktioniert über die ganze Fläche.
        panel.contentView = NSHostingView(
            rootView: IndicatorView(model: model).allowsHitTesting(false))
        panel.onDragEnded = { [weak self] origin in
            self?.storedOrigin = origin
        }
    }

    // MARK: - Gemerkter Ort

    private static let originKey = "indicatorOrigin"

    private var storedOrigin: NSPoint? {
        get {
            guard let values = UserDefaults.standard.array(forKey: Self.originKey) as? [Double],
                values.count == 2
            else { return nil }
            return NSPoint(x: values[0], y: values[1])
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: Self.originKey)
                return
            }
            UserDefaults.standard.set([newValue.x, newValue.y], forKey: Self.originKey)
        }
    }

    var hasCustomPosition: Bool { storedOrigin != nil }

    func resetPosition() {
        storedOrigin = nil
        reposition()
    }

    /// Der gemerkte Ort gilt nur, solange die Kapsel dort auch sichtbar wäre. Nach dem
    /// Abstecken eines Bildschirms läge sie sonst im Nichts.
    private func usableStoredOrigin() -> NSPoint? {
        guard let origin = storedOrigin else { return nil }
        let capsule = NSRect(
            x: origin.x + Indicator.panelPadding, y: origin.y + Indicator.panelPadding,
            width: Indicator.capsuleWidth(for: model.style, showsTime: model.showsTime),
            height: Indicator.capsuleHeight(for: model.style))
        guard NSScreen.screens.contains(where: { $0.frame.contains(capsule) }) else { return nil }
        return origin
    }

    // MARK: - Steuerung

    /// Darstellung übernehmen, bevor die Pille erscheint: Größe und Ort hängen daran.
    func apply(style: WaveformStyle, showsTime: Bool) {
        guard model.style != style || model.showsTime != showsTime else { return }
        model.style = style
        model.showsTime = showsTime
        panel.setContentSize(Indicator.panelSize(for: style, showsTime: showsTime))
    }

    func startRecording() {
        model.recordingStartedAt = Date()
        model.resetTrace()
        show(.recording)
        startTrace()
    }

    func show(_ session: SessionState) {
        hideWorkItem?.cancel()
        model.stateChangedAt = Date()
        model.session = session
        if case .recording = session {} else { stopTrace() }

        model.isVisible = true
        let wasVisible = panel.isVisible
        // Ein laufendes Fenster nicht umsetzen: sonst spränge die Pille beim Wechsel
        // von Aufnahme zu Transkription an einen anderen Ort zurück.
        if !wasVisible { reposition() }
        panel.orderFrontRegardless()
        guard !wasVisible else {
            panel.alphaValue = 1
            return
        }
        appear()
    }

    func update(level: Double) {
        model.level = level
    }

    /// Zeigt einen Zustand für kurze Zeit und blendet ihn dann aus.
    func flash(_ session: SessionState, duration: TimeInterval) {
        show(session)
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Blendet aus. Nach dem Einfügen gibt es bewusst keine Bestätigung mehr:
    /// das Ergebnis steht im Text.
    func dismiss() {
        hideWorkItem?.cancel()
        stopTrace()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = disappearDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.model.isVisible = false
        }
    }

    func hide() {
        hideWorkItem?.cancel()
        stopTrace()
        panel.orderOut(nil)
        model.isVisible = false
    }

    private func appear() {
        let target = panel.frame.origin
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - appearRise))
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearDuration
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(target)
        }
    }

    // MARK: - Spur

    /// Der Vorschub läuft in eigenem Takt, unabhängig davon, wie oft das Mikrofon
    /// Puffer liefert. So bleibt die Spur bei jeder Puffergröße gleich schnell.
    private func startTrace() {
        stopTrace()
        let timer = Timer(timeInterval: Indicator.advanceInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.model.advanceTrace() }
        }
        RunLoop.main.add(timer, forMode: .common)
        traceTimer = timer
    }

    private func stopTrace() {
        traceTimer?.invalidate()
        traceTimer = nil
    }

    // MARK: - Position

    /// Unten mittig auf dem Bildschirm, auf dem gerade gearbeitet wird. Kein
    /// Nachführen: die Kapsel steht, wo sie steht.
    private func reposition() {
        if let origin = usableStoredOrigin() {
            panel.setFrameOrigin(origin)
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = Indicator.panelSize(for: model.style, showsTime: model.showsTime)
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + Indicator.distanceFromBottom - Indicator.panelPadding))
    }
}
