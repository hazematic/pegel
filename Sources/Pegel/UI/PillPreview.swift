import SwiftUI

/// The real pill in settings, same `IndicatorView` with its own model and a
/// synthetic speech level, so the preview can't drift from the real thing.
struct PillPreview: View {

    @ObservedObject var state: AppState
    @StateObject private var driver = PreviewDriver()

    var body: some View {
        IndicatorView(model: driver.model)
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .onAppear {
                driver.model.style = state.waveformStyle
                driver.model.showsTime = state.indicatorShowsTime
                driver.model.palette = state.palette
                driver.start()
            }
            // Stop everything, including the view's timeline, outside the tab.
            .onDisappear { driver.stop() }
            .onChange(of: state.waveformStyle) { _, style in
                withAnimation(.snappy(duration: 0.25)) { driver.model.style = style }
            }
            .onChange(of: state.indicatorShowsTime) { _, showsTime in
                withAnimation(.snappy(duration: 0.25)) { driver.model.showsTime = showsTime }
            }
            .onChange(of: state.palette) { _, palette in driver.model.palette = palette }
            .accessibilityHidden(true)
    }
}

@MainActor
private final class PreviewDriver: ObservableObject {

    let model = IndicatorModel()
    private var timer: Timer?
    private var startedAt = Date()

    init() {
        model.session = .recording
    }

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        model.recordingStartedAt = startedAt
        model.resetTrace()
        model.isVisible = true
        let timer = Timer(timeInterval: Indicator.advanceInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        model.isVisible = false
    }

    deinit {
        timer?.invalidate()
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(startedAt)
        // Restart after a minute so the time stays short.
        if elapsed >= 60 {
            startedAt = Date()
            model.recordingStartedAt = startedAt
        }
        model.level = Self.speechLevel(at: elapsed)
        model.advanceTrace()
    }

    /// Speech-like: syllables around 3 Hz, varying emphasis, a short pause every ~3 s.
    private static func speechLevel(at time: TimeInterval) -> Double {
        let phrase = time.truncatingRemainder(dividingBy: 4.2)
        guard phrase < 3.4 else { return 0.04 }
        let syllable = pow(max(0, sin(2 * .pi * 3.1 * time)), 0.6)
        let emphasis = 0.65 + 0.35 * sin(2 * .pi * 0.45 * time + 1.3)
        return min(1, 0.12 + 0.8 * syllable * emphasis)
    }
}
