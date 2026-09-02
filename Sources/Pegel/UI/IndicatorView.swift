import AppKit
import SwiftUI

/// Beobachtbarer Zustand der Pille.
@MainActor
final class IndicatorModel: ObservableObject {

    @Published var session: SessionState = .ready
    /// Aktueller, bereits geglätteter Mikrofonpegel 0…1.
    @Published var level: Double = 0
    /// Die letzten Pegelwerte, ältester zuerst. Füllt die Spur.
    @Published private(set) var trace: [Double] = Array(
        repeating: 0, count: Indicator.traceCapacity)
    /// Wann der letzte Wert dazukam. Daraus rechnet die Ansicht den Zwischenschritt,
    /// damit die Spur fließt statt im Takt zu springen.
    @Published private(set) var lastAdvance: Date = .distantPast
    @Published var recordingStartedAt: Date = .distantPast
    /// Beginn von Fehler oder Verwerfen; treibt die einmaligen Animationen.
    @Published var stateChangedAt: Date = .distantPast
    @Published var style: WaveformStyle = .levels
    @Published var showsTime: Bool = true
    /// Ob die Pille gerade zu sehen ist. Steuert, ob die Zeitachse überhaupt läuft.
    @Published var isVisible: Bool = false

    func advanceTrace() {
        trace.removeFirst()
        trace.append(level)
        lastAdvance = Date()
    }

    /// Nur für die Vorschau: setzt einen Verlauf, ohne den Takt laufen zu lassen.
    func setTraceForPreview(_ values: [Double]) {
        trace = values
        lastAdvance = Date()
    }

    func resetTrace() {
        trace = Array(repeating: 0, count: Indicator.traceCapacity)
        lastAdvance = Date()
    }
}

/// Maße der Pille. Aus dem Handoff 6c, mit zwei begründeten Abweichungen:
/// die Spur ist 104 pt breit (16 Werte × 6,5 pt geht exakt auf, die 112 pt im
/// Prototyp sind der CSS-Container), und die Kapselbreite ist ausgerechnet statt
/// gesetzt, weil die angegebenen 168 pt für die Zeitanzeige nur 18 pt übrig ließen.
enum Indicator {

    /// Deckend, nicht durchscheinend: das im Entwurf vorgesehene Vibrancy-Material
    /// wird auf hellem Untergrund flau, und ein Statusanzeiger muss überall tragen.
    static let capsuleColor = Color(white: 0.094)

    static let horizontalInset: CGFloat = 16
    static let itemSpacing: CGFloat = 14
    /// Feste Breite für die Zeit, damit die Kapsel bei 0:09 → 0:10 nicht springt.
    static let timeWidth: CGFloat = 30

    // MARK: - Spur (Entwurf 6c)

    static let traceWidth: CGFloat = 104
    static let traceHeight: CGFloat = 24
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 3.5
    static let barRadius: CGFloat = 1.5
    static let slotWidth: CGFloat = barWidth + barSpacing  // 6.5
    static let traceCapacity = 20  // 16 sichtbare plus Reserve

    /// Ein neuer Wert alle 74 ms, macht zwei Sekunden Historie auf 16 Werten.
    static let advanceInterval: TimeInterval = 0.074

    static let minimumBarHeight: CGFloat = 5
    static let maximumBarHeight: CGFloat = 24

    // MARK: - Pegelreihe (Entwurf 9a)

    static let levelBarSpacing: CGFloat = 5
    /// Elf Striche à 3 pt mit 5 pt Abstand ergeben 83 pt.
    static let levelRowWidth: CGFloat = 11 * barWidth + 10 * levelBarSpacing
    /// Eigene Maximalhöhe je Strich: die Reihe verjüngt sich zu den Enden.
    static let levelMaxHeights: [CGFloat] = [15, 18, 21, 22, 22, 22, 22, 22, 21, 18, 15]
    /// Eigener Versatz je Strich, dadurch läuft die Welle nach rechts.
    static let levelPhases: [Double] = (0..<11).map { Double($0) * 0.05 }
    static let levelColors: [UInt32] = [
        0xB4_78EC, 0xAD_7BED, 0xA6_7FEF, 0x9F_82F0, 0x98_85F2, 0x92_89F3,
        0x8B_8CF4, 0x84_8FF6, 0x7D_92F7, 0x76_96F9, 0x6F_99FA,
    ]
    static let levelCycle: Double = 0.72
    /// Bei Stille bleibt die Reihe als flache Linie sichtbar.
    static let levelRestingFactor: CGFloat = 0.25
    static let transcribingBarHeight: CGFloat = 7
    static let levelSweepStagger: Double = 0.06

    // MARK: - Kapsel

    static func capsuleHeight(for style: WaveformStyle) -> CGFloat {
        style == .trace ? 42 : 40
    }

    static func cornerRadius(for style: WaveformStyle) -> CGFloat {
        capsuleHeight(for: style) / 2
    }

    static func contentWidth(for style: WaveformStyle) -> CGFloat {
        style == .trace ? traceWidth : levelRowWidth
    }

    static func contentHeight(for style: WaveformStyle) -> CGFloat {
        traceHeight
    }

    /// Die Breite ist gerechnet, nicht gesetzt: die Handoffs geben Werte an, in die
    /// ihre eigenen Bestandteile nicht hineinpassen.
    static func capsuleWidth(for style: WaveformStyle, showsTime: Bool) -> CGFloat {
        var width = 2 * horizontalInset + contentWidth(for: style)
        if showsTime { width += itemSpacing + timeWidth }
        return width
    }

    /// Der Schatten wird in SwiftUI gezeichnet, deshalb ist das Fenster größer als
    /// die Kapsel und der Inhalt darin zentriert.
    static let panelPadding: CGFloat = 24

    static func panelSize(for style: WaveformStyle, showsTime: Bool) -> CGSize {
        CGSize(
            width: capsuleWidth(for: style, showsTime: showsTime) + 2 * panelPadding,
            height: capsuleHeight(for: style) + 2 * panelPadding)
    }

    /// Abstand der Kapsel zur Unterkante des nutzbaren Bildschirms.
    static let distanceFromBottom: CGFloat = 96
}

struct IndicatorView: View {

    @ObservedObject var model: IndicatorModel
    /// Nur für die Vorschau: friert die Bewegung auf einen Zeitpunkt ein.
    var fixedTime: TimeInterval?

    var body: some View {
        if let fixedTime {
            capsule(at: fixedTime)
        } else if model.isVisible {
            TimelineView(.animation) { timeline in
                capsule(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            // Ohne diese Verzweigung tickt die Zeitachse auch bei ausgeblendetem
            // Fenster weiter, treibt fortwährend Core-Animation-Transaktionen und
            // kostet im Leerlauf dauerhaft CPU.
            Color.clear
        }
    }

    private func capsule(at time: TimeInterval) -> some View {
        HStack(spacing: Indicator.itemSpacing) {
            content(at: time)
        }
        .padding(.horizontal, Indicator.horizontalInset)
        .frame(
            width: Indicator.capsuleWidth(for: model.style, showsTime: model.showsTime),
            height: Indicator.capsuleHeight(for: model.style))
        .background(Indicator.capsuleColor)
        .clipShape(Capsule())
        // Innenkante oben, wie im Entwurf: eine Spur Licht auf der Oberkante.
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
        .frame(
            width: Indicator.panelSize(for: model.style, showsTime: model.showsTime).width,
            height: Indicator.panelSize(for: model.style, showsTime: model.showsTime).height)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(at time: TimeInterval) -> some View {
        switch model.session {
        case .recording:
            waveform(at: time, running: true)
            if model.showsTime { TimeLabel(seconds: elapsed, opacity: 0.85) }

        case .transcribing:
            // Die Darstellung steht still und wird zum Bild des Gesagten; darüber
            // läuft ein Lauflicht. So ist der Zustand ohne Wort von der Aufnahme zu
            // unterscheiden.
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

    /// Zweimaliges Aufblitzen beim Erscheinen, danach steht das Zeichen.
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

// MARK: - Spur


/// Die Bewegungskurven aus den Entwürfen, an einer Stelle.
enum Curves {

    /// Dreieckschwingung mit weichem Ein- und Ausschwingen, Ergebnis 0…1.
    /// Entspricht der CSS-Kurve `ease-in-out` zwischen zwei Keyframes.
    static func pulse(time: TimeInterval, cycle: Double, delay: Double) -> Double {
        let phase = (((time - delay).truncatingRemainder(dividingBy: cycle) + cycle) / cycle)
            .truncatingRemainder(dividingBy: 1)
        let triangle = phase < 0.5 ? phase / 0.5 : (1 - phase) / 0.5
        return triangle * triangle * (3 - 2 * triangle)
    }

    /// Lauflicht: 0.15, bis 35 Prozent auf 1, bis 70 Prozent zurück, dann Pause.
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

/// Die Pegelreihe aus Entwurf 9a: elf Striche, die Welle läuft nach rechts.
///
/// Jeder Strich hat eine eigene Maximalhöhe, dadurch verjüngt sich die Reihe zu den
/// Enden, und einen eigenen Versatz, dadurch wandert die Welle.
private struct LevelRow: View {

    @ObservedObject var model: IndicatorModel
    let time: TimeInterval
    /// Während der Aufnahme folgt die Höhe dem Pegel, danach läuft nur Licht durch.
    let running: Bool

    private let sweepCycle: Double = 1.1

    var body: some View {
        HStack(spacing: Indicator.levelBarSpacing) {
            ForEach(0..<11, id: \.self) { index in
                RoundedRectangle(cornerRadius: Indicator.barRadius, style: .continuous)
                    .fill(Color(hex: Indicator.levelColors[index]))
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
        // Der Pegel bestimmt die Amplitude, der Versatz lässt die Welle wandern.
        // Bei Stille bleibt die Reihe als flache Linie stehen.
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

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

private struct TraceView: View {

    @ObservedObject var model: IndicatorModel
    let time: TimeInterval
    /// Während der Aufnahme wandert die Spur, danach steht sie.
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
        // Links ausblenden, damit die Werte nicht abgeschnitten verschwinden.
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
                    .fill(TraceColors.color(atSlot: index, of: model.trace.count))
                    .frame(
                        width: Indicator.barWidth,
                        height: Indicator.minimumBarHeight
                            + (Indicator.maximumBarHeight - Indicator.minimumBarHeight) * value)
            }
        }
        .frame(
            width: Indicator.traceWidth, height: Indicator.traceHeight, alignment: .trailing)
        // Zwischen zwei Werten linear weiterschieben: der neueste Wert kommt von rechts
        // herein, statt an Ort und Stelle aufzuploppen.
        .offset(x: running ? Indicator.slotWidth * (1 - progress) : 0)
    }

    private var progress: CGFloat {
        let since = time - model.lastAdvance.timeIntervalSinceReferenceDate
        return CGFloat(min(1, max(0, since / Indicator.advanceInterval)))
    }

    /// Lichtstreifen über der stehenden Spur.
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

/// Farbe hängt am Platz, nicht am Wert: ein wandernder Strich wechselt die Farbe,
/// dadurch bleibt das Farbbild ruhig.
enum TraceColors {

    private static let stops: [(r: Double, g: Double, b: Double)] = [
        (0xB4 / 255, 0x78 / 255, 0xEC / 255),
        (0x90 / 255, 0x84 / 255, 0xF5 / 255),
        (0x6F / 255, 0x99 / 255, 0xFA / 255),
    ]

    static func color(atSlot index: Int, of count: Int) -> Color {
        guard count > 1 else { return rgb(stops[0]) }
        let position = Double(index) / Double(count - 1)
        let scaled = position * Double(stops.count - 1)
        let lower = min(Int(scaled), stops.count - 2)
        let fraction = scaled - Double(lower)
        let a = stops[lower]
        let b = stops[lower + 1]
        return rgb(
            (
                r: a.r + (b.r - a.r) * fraction,
                g: a.g + (b.g - a.g) * fraction,
                b: a.b + (b.b - a.b) * fraction
            ))
    }

    private static func rgb(_ value: (r: Double, g: Double, b: Double)) -> Color {
        Color(.sRGB, red: value.r, green: value.g, blue: value.b, opacity: 1)
    }
}

/// Escape: die Darstellung fällt auf eine Reihe Punkte zusammen und verschwindet.
private struct CollapsedRow: View {

    @ObservedObject var model: IndicatorModel
    let time: TimeInterval

    private let collapseDuration: Double = 0.18

    var body: some View {
        let elapsed = time - model.stateChangedAt.timeIntervalSinceReferenceDate
        let progress = min(1, max(0, elapsed / collapseDuration))

        let count = model.style == .trace ? 6 : 11
        let spacing =
            (Indicator.contentWidth(for: model.style) - CGFloat(count) * Indicator.barWidth)
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
            width: Indicator.contentWidth(for: model.style),
            height: Indicator.contentHeight(for: model.style), alignment: .center)
    }

    /// Ausgangshöhe: der Wert, der an dieser Stelle zuletzt stand.
    private func startHeight(_ index: Int) -> CGFloat {
        let count = model.style == .trace ? 6 : 11
        let source = model.trace.suffix(count)
        guard index < source.count else { return 3 }
        let value = Array(source)[index]
        return Indicator.minimumBarHeight
            + (Indicator.maximumBarHeight - Indicator.minimumBarHeight) * value
    }
}

// MARK: - Bausteine

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


