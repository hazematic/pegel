import AppKit
import SwiftUI

/// The pill window. Must never take focus, or the synthetic ⌘V misses the target.
/// As a non-activating panel it still accepts mouse events and can be dragged.
final class IndicatorPanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var onDragEnded: ((NSPoint) -> Void)?
    /// X hit area in window coordinates, nil when not shown.
    var cancelHitRect: NSRect? {
        didSet { if cancelHitRect == nil { setCancelHovered(false) } }
    }
    var onCancel: (() -> Void)?
    var onCancelHoverChanged: ((Bool) -> Void)?

    private var grabOffset: NSPoint?
    /// A press on the X never drags; only releasing on it cancels.
    private var pressedCancel = false
    private var cancelHovered = false

    /// Mouse handling lives here, not in `mouseDown`: the hosting view swallows clicks
    /// despite `allowsHitTesting(false)`, so `mouseDown` never fired.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: pointerDown(event)
        case .leftMouseDragged: pointerDragged(event)
        case .leftMouseUp: pointerUp(event)
        case .mouseMoved:
            updateHover(event)
            super.sendEvent(event)
        default: super.sendEvent(event)
        }
    }

    private func pointerDown(_ event: NSEvent) {
        if let cancelHitRect, cancelHitRect.contains(event.locationInWindow) {
            pressedCancel = true
            return
        }
        grabOffset = event.locationInWindow
    }

    private func pointerDragged(_ event: NSEvent) {
        if pressedCancel {
            setCancelHovered(cancelHitRect?.contains(event.locationInWindow) ?? false)
            return
        }
        guard let grabOffset else { return }
        let pointer = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y))
    }

    private func pointerUp(_ event: NSEvent) {
        if pressedCancel {
            pressedCancel = false
            if cancelHitRect?.contains(event.locationInWindow) == true { onCancel?() }
            return
        }
        guard grabOffset != nil else { return }
        grabOffset = nil
        onDragEnded?(frame.origin)
    }

    // `.activeAlways`: Pegel is never the active app, so no moves arrive otherwise.

    private func updateHover(_ event: NSEvent) {
        setCancelHovered(cancelHitRect?.contains(event.locationInWindow) ?? false)
    }

    override func mouseExited(with event: NSEvent) {
        setCancelHovered(false)
    }

    func installHoverTracking() {
        guard let view = contentView else { return }
        view.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    private func setCancelHovered(_ hovered: Bool) {
        guard hovered != cancelHovered else { return }
        cancelHovered = hovered
        onCancelHoverChanged?(hovered)
    }
}

@MainActor
final class IndicatorPanelController {

    private let model = IndicatorModel()
    private let panel: IndicatorPanel
    private var traceTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?
    /// Bumped on every show, so a finishing fade-out leaves a newer pill alone.
    private var presentation = 0

    private let appearDuration: TimeInterval = 0.14
    private let disappearDuration: TimeInterval = 0.12
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
        panel.hasShadow = false
        // Needed for dragging; the panel still doesn't activate the app.
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.contentView = NSHostingView(
            rootView: IndicatorView(model: model).allowsHitTesting(false))
        panel.onDragEnded = { [weak self] origin in
            guard let self else { return }
            self.store(origin: self.normalOrigin(forPanelOrigin: origin))
        }
        panel.onCancel = { [weak self] in self?.onCancel?() }
        panel.onCancelHoverChanged = { [weak self] hovered in
            self?.model.cancelHovered = hovered
        }
        panel.installHoverTracking()
        migrateLegacyOrigin()
    }

    var onCancel: (() -> Void)?

    // MARK: - Stored position

    /// Per screen, relative to its bottom-left corner so rearranging screens keeps it.
    private static let originsKey = "indicatorOrigins"
    /// Single absolute origin used up to 0.1.1.
    private static let legacyOriginKey = "indicatorOrigin"

    private var storedOffsets: [String: NSPoint] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: Self.originsKey) ?? [:]
            return raw.compactMapValues { value in
                guard let values = value as? [Double], values.count == 2 else { return nil }
                return NSPoint(x: values[0], y: values[1])
            }
        }
        set {
            guard !newValue.isEmpty else {
                UserDefaults.standard.removeObject(forKey: Self.originsKey)
                return
            }
            UserDefaults.standard.set(
                newValue.mapValues { [$0.x, $0.y] }, forKey: Self.originsKey)
        }
    }

    var hasCustomPosition: Bool { !storedOffsets.isEmpty }

    /// Clears all screens, including disconnected ones.
    func resetPosition() {
        storedOffsets = [:]
        if panel.isVisible { reposition() }
    }

    private func store(origin: NSPoint) {
        let capsule = capsuleFrame(at: origin)
        let center = NSPoint(x: capsule.midX, y: capsule.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
            let key = screen.displayKey
        else { return }
        var offsets = storedOffsets
        offsets[key] = NSPoint(
            x: origin.x - screen.frame.minX, y: origin.y - screen.frame.minY)
        storedOffsets = offsets
    }

    /// Only while the capsule fits entirely on its screen, e.g. not after a resolution change.
    private func usableStoredOrigin(on screen: NSScreen) -> NSPoint? {
        guard let key = screen.displayKey, let offset = storedOffsets[key] else { return nil }
        let origin = NSPoint(x: screen.frame.minX + offset.x, y: screen.frame.minY + offset.y)
        guard screen.frame.contains(capsuleFrame(at: origin)) else { return nil }
        return origin
    }

    private func capsuleFrame(at origin: NSPoint) -> NSRect {
        NSRect(
            x: origin.x + Indicator.panelPadding, y: origin.y + Indicator.panelPadding,
            width: Indicator.capsuleWidth(for: model.style, showsTime: model.showsTime),
            height: Indicator.capsuleHeight(for: model.style))
    }

    private func migrateLegacyOrigin() {
        let defaults = UserDefaults.standard
        guard let values = defaults.array(forKey: Self.legacyOriginKey) as? [Double] else {
            return
        }
        defaults.removeObject(forKey: Self.legacyOriginKey)
        guard values.count == 2, storedOffsets.isEmpty else { return }
        store(origin: NSPoint(x: values[0], y: values[1]))
    }

    // MARK: - Control

    /// Apply before showing: size and position depend on it.
    func apply(style: WaveformStyle, showsTime: Bool, palette: PillPalette) {
        model.palette = palette
        guard model.style != style || model.showsTime != showsTime else { return }
        model.style = style
        model.showsTime = showsTime
        resizePanel()
    }

    /// Keeps the center while visible so the capsule doesn't jump sideways.
    private func resizePanel() {
        let size = currentPanelSize
        guard panel.frame.size != size else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setContentSize(size)
        if panel.isVisible {
            panel.setFrameOrigin(
                NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        }
    }

    private var currentPanelSize: CGSize {
        Indicator.panelSize(for: model.style, showsTime: model.showsTime, file: model.isFile)
    }

    private var normalPanelSize: CGSize {
        Indicator.panelSize(for: model.style, showsTime: model.showsTime)
    }

    /// Stored origins refer to the normal size; a wider capsule shares the center.
    private func panelOrigin(forNormalOrigin origin: NSPoint) -> NSPoint {
        let current = currentPanelSize
        let normal = normalPanelSize
        return NSPoint(
            x: origin.x - (current.width - normal.width) / 2,
            y: origin.y - (current.height - normal.height) / 2)
    }

    private func normalOrigin(forPanelOrigin origin: NSPoint) -> NSPoint {
        let current = currentPanelSize
        let normal = normalPanelSize
        return NSPoint(
            x: origin.x + (current.width - normal.width) / 2,
            y: origin.y + (current.height - normal.height) / 2)
    }

    // MARK: - Audio file

    func startFile() {
        hideWorkItem?.cancel()
        stopTrace()
        model.isFile = true
        model.fileProgress = 0
        resizePanel()
        panel.cancelHitRect = cancelHitRect
        show(.transcribing)
    }

    /// Monotonic, so the row never jumps back.
    func updateFile(progress: Double) {
        guard model.isFile else { return }
        model.fileProgress = max(model.fileProgress, min(1, progress))
    }

    func finishFile() {
        panel.cancelHitRect = nil
        model.fileProgress = 1
        flash(.finished, duration: 0.93)
    }

    private var cancelHitRect: NSRect {
        let capsule = NSRect(
            x: Indicator.panelPadding, y: Indicator.panelPadding,
            width: Indicator.fileCapsuleWidth, height: Indicator.capsuleHeight(for: .levels))
        let glyph = Indicator.cancelFrameInCapsule.offsetBy(
            dx: Indicator.panelPadding, dy: Indicator.panelPadding)
        return glyph.insetBy(dx: -Indicator.cancelHitSlop, dy: -Indicator.cancelHitSlop)
            .intersection(capsule)
    }

    private func leaveFileMode() {
        guard model.isFile else { return }
        panel.cancelHitRect = nil
        model.isFile = false
        model.fileProgress = 0
        model.cancelHovered = false
        resizePanel()
    }

    func startRecording() {
        leaveFileMode()
        model.recordingStartedAt = Date()
        model.resetTrace()
        show(.recording)
        startTrace()
    }

    func show(_ session: SessionState) {
        hideWorkItem?.cancel()
        presentation += 1
        model.stateChangedAt = Date()
        model.session = session
        if case .recording = session {} else { stopTrace() }
        // Only the running state has an X.
        if case .transcribing = session {} else { panel.cancelHitRect = nil }

        model.isVisible = true
        let wasVisible = panel.isVisible
        // Don't move a visible pill between recording and transcribing.
        if !wasVisible { reposition() }
        panel.orderFrontRegardless()
        guard !wasVisible else {
            // Via the animator, so a running fade-out is replaced rather than finishing at zero.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.05
                panel.animator().alphaValue = 1
            }
            return
        }
        appear()
    }

    func update(level: Double) {
        model.level = level
    }

    func flash(_ session: SessionState, duration: TimeInterval) {
        show(session)
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        hideWorkItem?.cancel()
        stopTrace()
        guard panel.isVisible else { return }
        let dismissed = presentation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = disappearDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new dictation showed the pill during the fade; keep it.
                guard let self, self.presentation == dismissed else { return }
                self.panel.orderOut(nil)
                self.model.isVisible = false
                self.leaveFileMode()
            }
        }
    }

    func hide() {
        hideWorkItem?.cancel()
        stopTrace()
        panel.orderOut(nil)
        model.isVisible = false
        leaveFileMode()
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

    // MARK: - Trace

    /// Own clock, independent of the audio buffer size.
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

    /// On the caret's screen: its stored spot, otherwise bottom center. No tracking.
    private func reposition() {
        guard let screen = Self.dictationScreen() else { return }
        if let origin = usableStoredOrigin(on: screen) {
            panel.setFrameOrigin(panelOrigin(forNormalOrigin: origin))
            return
        }
        let visible = screen.visibleFrame
        let size = currentPanelSize
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + Indicator.distanceFromBottom - Indicator.panelPadding))
    }

    /// Falls back to the mouse pointer when the app hides its caret. `NSScreen.main` is
    /// unreliable for a menu bar app without a key window.
    private static func dictationScreen() -> NSScreen? {
        if let caret = CaretTracker.caretLocation(), let screen = screen(containing: caret) {
            return screen
        }
        return screen(containing: NSEvent.mouseLocation)
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        // `NSMouseInRect`, not `contains`: top and right edges belong to no screen otherwise.
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

extension NSScreen {
    /// The display ID can change on reconnect; the UUID doesn't.
    fileprivate var displayKey: String? {
        guard
            let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?
                .takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
