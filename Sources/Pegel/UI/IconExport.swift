import AppKit
import SwiftUI

/// Das App-Icon: dieselbe Bildmarke, nur größer.
///
/// Wird nicht als Bitmap gepflegt, sondern aus derselben `PegelMark` gerendert,
/// die auch Menüleiste und Indikator benutzen. Eine Formänderung schlägt damit
/// überall gleichzeitig durch.
struct AppIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            // macOS-Icons sitzen nicht randfüllend im Rahmen, sondern mit Luft
            // ringsum. 0.82 entspricht dem Verhältnis der Systemsymbole.
            let plate = side * 0.82
            ZStack {
                RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                    .fill(Color(white: 0.11))
                    .frame(width: plate, height: plate)
                PegelMark(color: .white, lineWidth: 1.35)
                    .frame(width: plate * 0.62, height: plate * 0.62)
            }
            .frame(width: side, height: side)
        }
    }
}

enum IconExporter {

    /// Größen, die `iconutil` für ein vollständiges Iconset erwartet.
    private static let variants: [(name: String, points: CGFloat, scale: CGFloat)] = [
        ("icon_16x16", 16, 1), ("icon_16x16@2x", 16, 2),
        ("icon_32x32", 32, 1), ("icon_32x32@2x", 32, 2),
        ("icon_128x128", 128, 1), ("icon_128x128@2x", 128, 2),
        ("icon_256x256", 256, 1), ("icon_256x256@2x", 256, 2),
        ("icon_512x512", 512, 1), ("icon_512x512@2x", 512, 2),
    ]

    @MainActor
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        for variant in variants {
            let renderer = ImageRenderer(
                content: AppIcon().frame(width: variant.points, height: variant.points))
            renderer.scale = variant.scale

            guard let image = renderer.nsImage,
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else { continue }

            try png.write(to: directory.appendingPathComponent("\(variant.name).png"))
        }

        try writeMarkPreview(to: directory)
    }

    /// Die nackte Marke in Menüleistengrößen, hell und dunkel. Dient der Prüfung,
    /// ob die Form bei 16 Punkt noch trägt.
    @MainActor
    private static func writeMarkPreview(to directory: URL) throws {
        for size in [16.0, 18.0, 32.0] as [CGFloat] {
            for (suffix, background, foreground) in
                [("hell", Color.white, Color.black), ("dunkel", Color.black, Color.white)]
            {
                let renderer = ImageRenderer(
                    content: ZStack {
                        background
                        PegelMark(color: foreground)
                            .frame(width: size, height: size)
                    }
                    .frame(width: size * 2, height: size * 2)
                )
                renderer.scale = 4

                guard let image = renderer.nsImage,
                    let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { continue }

                try png.write(
                    to: directory.appendingPathComponent("menuebar_\(Int(size))_\(suffix).png"))
            }
        }
    }
}

/// Vorschau der Pille als Bildfolge.
///
/// Dient der Abnahme des Designs: die Zustände lassen sich sonst nur durch echtes
/// Diktieren betrachten. Die Bewegung wird dafür auf feste Zeitpunkte eingefroren.
@MainActor
enum IndicatorPreview {

    /// Untergrund wie im Entwurf: die Kapsel muss über Hellem wie Dunklem tragen.
    private struct Scene: View {
        let session: SessionState
        let trace: [Double]
        let time: TimeInterval
        let dark: Bool
        let style: WaveformStyle
        let showsTime: Bool

        var body: some View {
            let model = IndicatorModel()
            model.session = session
            model.level = trace.last ?? 0
            model.recordingStartedAt = Date(timeIntervalSinceNow: -67)
            model.stateChangedAt = Date(timeIntervalSinceReferenceDate: time - 0.5)
            model.setTraceForPreview(trace)
            model.style = style
            model.showsTime = showsTime

            return ZStack {
                (dark ? Color(white: 0.13) : Color(white: 0.97))
                IndicatorView(model: model, fixedTime: time)
            }
            .frame(width: 260, height: 110)
        }
    }

    /// Ein Pegelverlauf, der wie gesprochene Sprache aussieht.
    private static func sampleTrace(seed: Double) -> [Double] {
        (0..<Indicator.traceCapacity).map { index in
            let t = Double(index) * 0.7 + seed
            let value = 0.45 + 0.4 * sin(t) + 0.22 * sin(t * 2.3) + 0.12 * sin(t * 5.1)
            return min(1, max(0.04, value))
        }
    }

    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let cases: [(String, SessionState, [Double], TimeInterval)] = [
            ("aufnahme", .recording, sampleTrace(seed: 0.3), 0.02),
            ("aufnahme_spaeter", .recording, sampleTrace(seed: 1.4), 0.05),
            ("aufnahme_stille", .recording, Array(repeating: 0.02, count: Indicator.traceCapacity), 0.02),
            ("transkription", .transcribing, sampleTrace(seed: 0.3), 0.4),
            ("transkription_spaeter", .transcribing, sampleTrace(seed: 0.3), 0.95),
            ("verworfen", .discarded, sampleTrace(seed: 0.3), 0.12),
            ("fehler", .failed("Test"), sampleTrace(seed: 0.3), 0.6),
        ]

        for (name, session, trace, time) in cases {
            for dark in [false, true] {
                for style in WaveformStyle.allCases {
                    for showsTime in [true, false] {
                        try writeScene(
                            name: "\(name)_\(style.rawValue)\(showsTime ? "" : "_ohnezeit")",
                            session: session, trace: trace, time: time, dark: dark,
                            style: style, showsTime: showsTime, to: directory)
                    }
                }
            }
        }
    }

    private static func writeScene(
        name: String, session: SessionState, trace: [Double], time: TimeInterval, dark: Bool,
        style: WaveformStyle, showsTime: Bool, to directory: URL
    ) throws {
        let renderer = ImageRenderer(
            content: Scene(
                session: session, trace: trace, time: time, dark: dark, style: style,
                showsTime: showsTime))
        renderer.scale = 3
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try png.write(
            to: directory.appendingPathComponent("\(name)_\(dark ? "dunkel" : "hell").png"))
    }
}


/// Zustandsgrafik für die README.
///
/// Wird aus demselben Code gerendert, den die App benutzt, und kann deshalb nicht vom
/// echten Aussehen abweichen. Das ist der Vorteil gegenüber einem Export aus dem
/// Designprojekt, der bei jeder Änderung nachgezogen werden müsste.
@MainActor
enum ReadmeFigure {

    private struct Row: View {
        let title: String
        let caption: String
        let session: SessionState
        let trace: [Double]
        let time: TimeInterval
        let dark: Bool

        var body: some View {
            let model = IndicatorModel()
            model.session = session
            model.level = trace.last ?? 0
            model.style = .levels
            model.showsTime = false
            model.isVisible = true
            model.recordingStartedAt = Date(timeIntervalSinceNow: -8)
            model.stateChangedAt = Date(timeIntervalSinceReferenceDate: time - 0.5)
            model.setTraceForPreview(trace)

            return HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dark ? Color.white : Color(white: 0.1))
                    .frame(width: 120, alignment: .leading)
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(dark ? Color.white.opacity(0.55) : Color(white: 0.45))
                    .frame(width: 250, alignment: .leading)
                IndicatorView(model: model, fixedTime: time)
                Spacer(minLength: 0)
            }
            .frame(height: 58)
        }
    }

    private struct Figure: View {
        let dark: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                Row(
                    title: "Recording", caption: "height follows the microphone level",
                    session: .recording, trace: sample(seed: 0.4), time: 0.18, dark: dark)
                Row(
                    title: "Transcribing", caption: "same height, a light runs through",
                    session: .transcribing, trace: sample(seed: 0.4), time: 0.45, dark: dark)
                Row(
                    title: "Discarded", caption: "escape, nothing is inserted",
                    session: .discarded, trace: sample(seed: 0.4), time: 0.14, dark: dark)
                Row(
                    title: "Error", caption: "flashes twice, then stands",
                    session: .failed("x"), trace: sample(seed: 0.4), time: 0.6, dark: dark)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
            .frame(width: 640, alignment: .leading)
            .background(dark ? Color(white: 0.07) : Color.white)
        }

        private func sample(seed: Double) -> [Double] {
            (0..<Indicator.traceCapacity).map { index in
                let t = Double(index) * 0.7 + seed
                return min(1, max(0.05, 0.5 + 0.35 * sin(t) + 0.2 * sin(t * 2.3)))
            }
        }
    }

    /// Vierfeld: beide Wellenformen, jeweils mit und ohne laufende Zeit.
    private struct Variants: View {
        let dark: Bool

        private var label: Color { dark ? Color.white : Color(white: 0.1) }
        private var caption: Color {
            dark ? Color.white.opacity(0.55) : Color(white: 0.45)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 0) {
                    Text("").frame(width: 110, alignment: .leading)
                    Text("without time")
                        .font(.system(size: 12)).foregroundStyle(caption)
                        .frame(width: 200, alignment: .leading)
                    Text("with time")
                        .font(.system(size: 12)).foregroundStyle(caption)
                        .frame(width: 220, alignment: .leading)
                }
                row(title: "Levels", subtitle: "default", style: .levels)
                row(title: "Trail", subtitle: "last two seconds", style: .trace)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
            .frame(width: 580, alignment: .leading)
            .background(dark ? Color(white: 0.07) : Color.white)
        }

        private func row(title: String, subtitle: String, style: WaveformStyle) -> some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(label)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(caption)
                }
                .frame(width: 110, alignment: .leading)

                pill(style: style, showsTime: false).frame(width: 200, alignment: .leading)
                pill(style: style, showsTime: true).frame(width: 220, alignment: .leading)
            }
        }

        private func pill(style: WaveformStyle, showsTime: Bool) -> some View {
            let model = IndicatorModel()
            model.session = .recording
            model.style = style
            model.showsTime = showsTime
            model.isVisible = true
            model.level = 0.8
            model.recordingStartedAt = Date(timeIntervalSinceNow: -12)
            model.setTraceForPreview(
                (0..<Indicator.traceCapacity).map { index in
                    let t = Double(index) * 0.7 + 0.4
                    return min(1, max(0.05, 0.5 + 0.35 * sin(t) + 0.2 * sin(t * 2.3)))
                })
            return IndicatorView(model: model, fixedTime: 0.18)
        }
    }

    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        for dark in [false, true] {
            let renderer = ImageRenderer(content: Variants(dark: dark))
            renderer.scale = 3
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(
                    to: directory.appendingPathComponent(
                        "variants-\(dark ? "dark" : "light").png"))
            }
        }

        for dark in [false, true] {
            let renderer = ImageRenderer(content: Figure(dark: dark))
            renderer.scale = 3
            guard let image = renderer.nsImage,
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else { continue }
            try png.write(
                to: directory.appendingPathComponent("states-\(dark ? "dark" : "light").png"))
        }
    }
}
