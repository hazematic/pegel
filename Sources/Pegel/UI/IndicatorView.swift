import AppKit
import SwiftUI

@MainActor
final class IndicatorModel: ObservableObject {

    @Published var session: SessionState = .ready
    @Published var level: Double = 0
    /// Recent levels, oldest first.
    @Published private(set) var trace: [Double] = Array(
        repeating: 0, count: Indicator.traceCapacity)
    /// Lets the view interpolate between values so the trace flows.
    @Published private(set) var lastAdvance: Date = .distantPast
    @Published var recordingStartedAt: Date = .distantPast
    /// Start of error or discard; drives the one-shot animations.
    @Published var stateChangedAt: Date = .distantPast
    @Published var style: WaveformStyle = .levels
    @Published var showsTime: Bool = true
    @Published var palette: PillPalette = .standard
    /// Stops the timeline while hidden.
    @Published var isVisible: Bool = false

    /// Audio file mode: progress, X, then a checkmark. Reset once hidden.
    @Published var isFile: Bool = false
    @Published var fileProgress: Double = 0
    @Published var cancelHovered: Bool = false

    func advanceTrace() {
        trace.removeFirst()
        trace.append(level)
        lastAdvance = Date()
    }

    func setTraceForPreview(_ values: [Double]) {
        trace = values
        lastAdvance = Date()
    }

    func resetTrace() {
        trace = Array(repeating: 0, count: Indicator.traceCapacity)
        lastAdvance = Date()
    }
}

/// Pill metrics. Widths are computed: the handoff values don't fit their own content.
enum Indicator {

    /// Opaque: vibrancy washes out on light backgrounds.
    static let capsuleColor = Color(white: 0.094)

    static let horizontalInset: CGFloat = 16
    static let itemSpacing: CGFloat = 14
    /// Fixed so the capsule doesn't jump at 0:09 → 0:10.
    static let timeWidth: CGFloat = 30

    // MARK: - Trace

    static let traceWidth: CGFloat = 104
    static let traceHeight: CGFloat = 24
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 3.5
    static let barRadius: CGFloat = 1.5
    static let slotWidth: CGFloat = barWidth + barSpacing
    static let traceCapacity = 20  // 16 visible plus spare

    /// Two seconds of history across 16 values.
    static let advanceInterval: TimeInterval = 0.074

    static let minimumBarHeight: CGFloat = 5
    static let maximumBarHeight: CGFloat = 24

    // MARK: - Levels

    static let levelBarSpacing: CGFloat = 5
    static let levelRowWidth: CGFloat = 11 * barWidth + 10 * levelBarSpacing
    static let levelMaxHeights: [CGFloat] = [15, 18, 21, 22, 22, 22, 22, 22, 21, 18, 15]
    static let levelPhases: [Double] = (0..<11).map { Double($0) * 0.05 }
    static let levelCycle: Double = 0.72
    static let levelRestingFactor: CGFloat = 0.25
    static let transcribingBarHeight: CGFloat = 7
    static let levelSweepStagger: Double = 0.06

    // MARK: - Audio file

    /// 16 + 83 + 14 + 34 + 12 + 20 + 12, independent of style and time.
    static let fileCapsuleWidth: CGFloat = 191
    static let fileTrailingInset: CGFloat = 12
    static let percentWidth: CGFloat = 34
    static let cancelSpacing: CGFloat = 12
    static let cancelSize: CGFloat = 20
    static let cancelHitSlop: CGFloat = 4

    /// In capsule coordinates, origin bottom left like the window.
    static var cancelFrameInCapsule: CGRect {
        CGRect(
            x: fileCapsuleWidth - fileTrailingInset - cancelSize,
            y: (capsuleHeight(for: .levels) - cancelSize) / 2,
            width: cancelSize, height: cancelSize)
    }

    // MARK: - Capsule

    static func capsuleHeight(for style: WaveformStyle, file: Bool = false) -> CGFloat {
        file || style == .levels ? 40 : 42
    }

    static func contentWidth(for style: WaveformStyle) -> CGFloat {
        style == .trace ? traceWidth : levelRowWidth
    }

    static func contentHeight(for style: WaveformStyle) -> CGFloat {
        traceHeight
    }

    static func capsuleWidth(
        for style: WaveformStyle, showsTime: Bool, file: Bool = false
    ) -> CGFloat {
        if file { return fileCapsuleWidth }
        var width = 2 * horizontalInset + contentWidth(for: style)
        if showsTime { width += itemSpacing + timeWidth }
        return width
    }

    /// The shadow is drawn in SwiftUI, so the window is larger than the capsule.
    static let panelPadding: CGFloat = 24

    static func panelSize(
        for style: WaveformStyle, showsTime: Bool, file: Bool = false
    ) -> CGSize {
        CGSize(
            width: capsuleWidth(for: style, showsTime: showsTime, file: file) + 2 * panelPadding,
            height: capsuleHeight(for: style, file: file) + 2 * panelPadding)
    }

    static let distanceFromBottom: CGFloat = 96
}

struct IndicatorView: View {

    @ObservedObject var model: IndicatorModel
    /// Freezes motion for rendered previews.
    var fixedTime: TimeInterval?

    var body: some View {
        if let fixedTime {
            capsule(at: fixedTime)
        } else if model.isVisible {
            TimelineView(.animation) { timeline in
                capsule(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            // Otherwise the timeline keeps ticking while hidden and burns CPU.
            Color.clear
        }
    }

    private func capsule(at time: TimeInterval) -> some View {
        let panel = Indicator.panelSize(
            for: model.style, showsTime: model.showsTime, file: model.isFile)
        return HStack(spacing: Indicator.itemSpacing) {
            if model.isFile {
                fileContent(at: time)
            } else {
                content(at: time)
            }
        }
        .padding(.leading, Indicator.horizontalInset)
        .padding(
            .trailing, model.isFile ? Indicator.fileTrailingInset : Indicator.horizontalInset)
        .frame(
            width: Indicator.capsuleWidth(
                for: model.style, showsTime: model.showsTime, file: model.isFile),
            height: Indicator.capsuleHeight(for: model.style, file: model.isFile))
        .background(Indicator.capsuleColor)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.10), .clear],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
        .opacity(capsuleOpacity)
        .shadow(color: .black.opacity(0.24), radius: 10, y: 6)
        .frame(width: panel.width, height: panel.height)
        .accessibilityHidden(true)
    }

    /// Always the levels row: progress needs eleven fixed steps.
    @ViewBuilder
    private func fileContent(at time: TimeInterval) -> some View {
        switch model.session {
        case .transcribing:
            FileProgressRow(model: model, time: time)
            HStack(spacing: Indicator.cancelSpacing) {
                Text("\(Int(model.fileProgress * 100)) %")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.65))
                    .frame(width: Indicator.percentWidth, alignment: .trailing)
                CancelGlyph(hovered: model.cancelHovered)
            }

        case .finished:
            Checkmark(opacity: flashOpacity(at: time))
                .frame(maxWidth: .infinity)

        case .discarded:
            CollapsedRow(model: model, time: time)
            Spacer(minLength: 0)

        case .failed:
            ErrorGlyph(opacity: flashOpacity(at: time))
                .frame(maxWidth: .infinity)

        default:
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func content(at time: TimeInterval) -> some View {
        switch model.session {
        case .recording:
            waveform(at: time, running: true)
            if model.showsTime { TimeLabel(seconds: elapsed, opacity: 0.85) }

        case .transcribing:
            // Frozen waveform with a light sweep, distinguishable from recording without text.
            waveform(at: time, running: false)
            if model.showsTime { TimeLabel(seconds: elapsed, opacity: 0.45) }

        case .discarded:
            CollapsedRow(model: model, time: time)
            if model.showsTime { Spacer(minLength: 0).frame(width: Indicator.timeWidth) }

        case .failed:
            ErrorGlyph(opacity: flashOpacity(at: time))
                .frame(maxWidth: .infinity)

        default:
            Color.clear.frame(
                width: Indicator.contentWidth(for: model.style),
                height: Indicator.contentHeight(for: model.style))
            if model.showsTime { Spacer(minLength: 0).frame(width: Indicator.timeWidth) }
        }
    }

    @ViewBuilder
    private func waveform(at time: TimeInterval, running: Bool) -> some View {
        switch model.style {
        case .trace:
            TraceView(model: model, time: time, running: running)
        case .levels:
            LevelRow(model: model, time: time, running: running)
        }
    }

    private var elapsed: Int {
        guard model.recordingStartedAt != .distantPast else { return 0 }
        return max(0, Int(Date().timeIntervalSince(model.recordingStartedAt)))
    }

    private var capsuleOpacity: Double {
        if case .discarded = model.session { return 0.55 }
        return 1
    }

    private func flashOpacity(at time: TimeInterval) -> Double {
        let elapsed = time - model.stateChangedAt.timeIntervalSinceReferenceDate
        let stops: [(TimeInterval, Double)] = [
            (0, 1), (0.12, 0.15), (0.24, 1), (0.36, 0.15), (0.48, 1),
        ]
        guard elapsed < 0.48 else { return 1 }
        for index in 1..<stops.count where elapsed < stops[index].0 {
            let (startTime, startValue) = stops[index - 1]
            let (endTime, endValue) = stops[index]
            return startValue
                + (endValue - startValue) * (elapsed - startTime) / (endTime - startTime)
        }
        return 1
    }
}

// MARK: - Curves

enum Curves {

    /// Triangle wave with ease-in-out, 0...1 (CSS `ease-in-out` between two keyframes).
    static func pulse(time: TimeInterval, cycle: Double, delay: Double) -> Double {
        let phase = (((time - delay).truncatingRemainder(dividingBy: cycle) + cycle) / cycle)
            .truncatingRemainder(dividingBy: 1)
        let triangle = phase < 0.5 ? phase / 0.5 : (1 - phase) / 0.5
        return triangle * triangle * (3 - 2 * triangle)
    }

    /// 0.15, up to 1 at 35 %, back at 70 %, then rest.
    static func sweep(time: TimeInterval, cycle: Double, delay: Double) -> Double {
        let phase = (((time - delay).truncatingRemainder(dividingBy: cycle) + cycle) / cycle)
            .truncatingRemainder(dividingBy: 1)
        switch phase {
        case ..<0.35: return 0.15 + 0.85 * (phase / 0.35)
        case ..<0.70: return 1 - 0.85 * ((phase - 0.35) / 0.35)
        default: return 0.15
        }
    }
}

private struct LevelRow: View {

    @ObservedObject var model: IndicatorModel
    let time: TimeInterval
    let running: Bool

    private let sweepCycle: Double = 1.1

    var body: some View {
        HStack(spacing: Indicator.levelBarSpacing) {
            ForEach(0..<11, id: \.self) { index in
                RoundedRectangle(cornerRadius: Indicator.barRadius, style: .continuous)
                    .fill(model.palette.levelColor(at: index))
                    .frame(width: Indicator.barWidth, height: height(at: index))
                    .opacity(running ? 1 : opacity(at: index))
            }
        }
        .frame(
            width: Indicator.levelRowWidth, height: Indicator.contentHeight(for: .levels))
    }

    private func height(at index: Int) -> CGFloat {
        guard running else { return Indicator.transcribingBarHeight }
        let oscillation = Curves.pulse(
            time: time, cycle: Indicator.levelCycle, delay: Indicator.levelPhases[index])
        let factor =
            Indicator.levelRestingFactor
            + (1 - Indicator.levelRestingFactor) * CGFloat(model.level * oscillation)
        return Indicator.levelMaxHeights[index] * factor
    }

    private func opacity(at index: Int) -> Double {
        Curves.sweep(
            time: time, cycle: sweepCycle,
            delay: Indicator.levelSweepStagger * Double(index))
    }
}

/// Done bars glow on the left; open bars keep the sweep, running right to left.
private struct FileProgressRow: View {

    @ObservedObject var model: IndicatorModel
    let time: TimeInterval

    private let sweepCycle: Double = 1.1

    var body: some View {
        let done = Int((model.fileProgress * 11).rounded())
        HStack(spacing: Indicator.levelBarSpacing) {
            ForEach(0..<11, id: \.self) { index in
                let color = model.palette.levelColor(at: index)
                RoundedRectangle(cornerRadius: Indicator.barRadius, style: .continuous)
                    .fill(color)
                    .frame(width: Indicator.barWidth, height: Indicator.transcribingBarHeight)
                    .opacity(index < done ? 1 : sweep(at: index))
                    // CSS 6 px blur ≈ SwiftUI radius 3.
                    .shadow(color: index < done ? color.opacity(0.55) : .clear, radius: 3)
            }
        }
        .frame(width: Indicator.levelRowWidth, height: Indicator.contentHeight(for: .levels))
    }

    private func sweep(at index: Int) -> Double {
        Curves.sweep(
            time: time, cycle: sweepCycle,
            delay: Indicator.levelSweepStagger * Double(10 - index))
    }
}

private struct TraceView: View {

    @ObservedObject var model: IndicatorModel
    let time: TimeInterval
    let running: Bool

    private let sweepDuration: Double = 1.3
    private let sweepWidth: CGFloat = 40

    var body: some View {
        ZStack(alignment: .leading) {
            bars
            if !running { sweep }
        }
        .frame(width: Indicator.traceWidth, height: Indicator.traceHeight)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
        )
        .opacity(running ? 1 : 0.30)
    }

    private var bars: some View {
        HStack(spacing: Indicator.barSpacing) {
            ForEach(Array(model.trace.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: Indicator.barRadius, style: .continuous)
                    .fill(model.palette.traceColor(atSlot: index, of: model.trace.count))
                    .frame(
                        width: Indicator.barWidth,
                        height: Indicator.minimumBarHeight
                            + (Indicator.maximumBarHeight - Indicator.minimumBarHeight) * value)
            }
        }
        .frame(
            width: Indicator.traceWidth, height: Indicator.traceHeight, alignment: .trailing)
        // Slide between values so the newest enters from the right instead of popping in.
        .offset(x: running ? Indicator.slotWidth * (1 - progress) : 0)
    }

    private var progress: CGFloat {
        let since = time - model.lastAdvance.timeIntervalSinceReferenceDate
        return CGFloat(min(1, max(0, since / Indicator.advanceInterval)))
    }

    private var sweep: some View {
        let phase = (time.truncatingRemainder(dividingBy: sweepDuration)) / sweepDuration
        let travel = Indicator.traceWidth + sweepWidth
        return LinearGradient(
            colors: [.clear, .white.opacity(0.55), .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: sweepWidth, height: Indicator.traceHeight)
        .offset(x: -sweepWidth + travel * phase)
        .blendMode(.plusLighter)
    }
}

/// Discard: the bars collapse into a row of dots.
private struct CollapsedRow: View {

    @ObservedObject var model: IndicatorModel
    let time: TimeInterval

    private let collapseDuration: Double = 0.18

    var body: some View {
        let elapsed = time - model.stateChangedAt.timeIntervalSinceReferenceDate
        let progress = min(1, max(0, elapsed / collapseDuration))

        let style = displayedStyle
        let count = style == .trace ? 6 : 11
        let spacing =
            (Indicator.contentWidth(for: style) - CGFloat(count) * Indicator.barWidth)
            / CGFloat(count - 1)

        return HStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { index in
                let start = startHeight(index)
                RoundedRectangle(cornerRadius: Indicator.barRadius, style: .continuous)
                    .fill(Color.white.opacity(0.5))
                    .frame(width: Indicator.barWidth, height: start + (3 - start) * progress)
            }
        }
        .frame(
            width: Indicator.contentWidth(for: style),
            height: Indicator.contentHeight(for: style), alignment: .center)
    }

    private var displayedStyle: WaveformStyle { model.isFile ? .levels : model.style }

    private func startHeight(_ index: Int) -> CGFloat {
        if model.isFile { return Indicator.transcribingBarHeight }
        let count = model.style == .trace ? 6 : 11
        let source = model.trace.suffix(count)
        guard index < source.count else { return 3 }
        let value = Array(source)[index]
        return Indicator.minimumBarHeight
            + (Indicator.maximumBarHeight - Indicator.minimumBarHeight) * value
    }
}

// MARK: - Glyphs

private struct TimeLabel: View {
    let seconds: Int
    let opacity: Double

    var body: some View {
        Text("\(seconds / 60):\(String(format: "%02d", seconds % 60))")
            .font(.system(size: 12.5).monospacedDigit())
            .foregroundStyle(Color.white.opacity(opacity))
            .frame(width: Indicator.timeWidth, alignment: .trailing)
    }
}

private struct ErrorGlyph: View {
    let opacity: Double

    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(.sRGB, red: 1, green: 0x45 / 255, blue: 0x3A / 255))
                .frame(width: 3, height: 13)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(.sRGB, red: 1, green: 0x45 / 255, blue: 0x3A / 255))
                .frame(width: 3, height: 3)
        }
        .opacity(opacity)
    }
}

/// Hit-tested by the panel, not here: the SwiftUI view ignores mouse events.
private struct CancelGlyph: View {
    let hovered: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(hovered ? 0.10 : 0))
            ForEach([45.0, -45.0], id: \.self) { angle in
                RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                    .frame(width: 11, height: 1.5)
                    .rotationEffect(.degrees(angle))
            }
            .foregroundStyle(Color.white.opacity(hovered ? 0.95 : 0.55))
        }
        .frame(width: Indicator.cancelSize, height: Indicator.cancelSize)
    }
}

private struct Checkmark: View {
    let opacity: Double

    private let color = Color(.sRGB, red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)

    var body: some View {
        // L shape, arms 7 and 13 pt, rotated −45°.
        Path { path in
            path.move(to: CGPoint(x: 1.5, y: 1.5))
            path.addLine(to: CGPoint(x: 1.5, y: 8.5))
            path.addLine(to: CGPoint(x: 14.5, y: 8.5))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        .frame(width: 16, height: 10)
        .rotationEffect(.degrees(-45))
        .offset(y: -1)
        .frame(width: 20, height: 16)
        .opacity(opacity)
    }
}
