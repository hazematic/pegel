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

    /// Eine einzelne Pille, freigestellt.
    ///
    /// Ohne Untergrund und ohne Beschriftung: die Bilder stehen in einer Tabelle in
    /// der README, der Text daneben ist echter Text. Das spart die zweite Fassung für
    /// das dunkle Erscheinungsbild, denn ein durchsichtiger Rand passt auf jeden
    /// Untergrund, auch auf die Spielarten von GitHubs dunklem Thema. Nebenbei wird
    /// die Beschriftung damit auswählbar, vorlesbar und übersetzbar, statt in Pixel
    /// eingebrannt zu sein.
    private struct Pill: View {
        let session: SessionState
        let style: WaveformStyle
        let showsTime: Bool
        let time: TimeInterval

        var body: some View {
            let model = IndicatorModel()
            model.session = session
            model.style = style
            model.showsTime = showsTime
            model.isVisible = true
            model.level = 0.8
            model.recordingStartedAt = Date(timeIntervalSinceNow: -12)
            model.stateChangedAt = Date(timeIntervalSinceReferenceDate: time - 0.5)
            model.setTraceForPreview(Self.sample)

            // Luft für den Schatten, der unten weiter reicht als oben.
            return IndicatorView(model: model, fixedTime: time)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 18)
        }

        /// Ein Pegelverlauf, der wie gesprochene Sprache aussieht.
        private static var sample: [Double] {
            (0..<Indicator.traceCapacity).map { index in
                let t = Double(index) * 0.7 + 0.4
                return min(1, max(0.05, 0.5 + 0.35 * sin(t) + 0.2 * sin(t * 2.3)))
            }
        }
    }

    static func write(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        // Die vier Zustände, alle in der voreingestellten Wellenform.
        let states: [(String, SessionState, TimeInterval)] = [
            ("pill-recording", .recording, 0.18),
            ("pill-transcribing", .transcribing, 0.45),
            ("pill-discarded", .discarded, 0.14),
            ("pill-error", .failed("x"), 0.6),
        ]
        for (name, session, time) in states {
            try write(
                Pill(session: session, style: .levels, showsTime: false, time: time),
                named: name, to: directory)
        }

        // Beide Wellenformen, jeweils mit und ohne laufende Zeit.
        for style in WaveformStyle.allCases {
            for showsTime in [false, true] {
                try write(
                    Pill(session: .recording, style: style, showsTime: showsTime, time: 0.18),
                    named: "pill-\(style.rawValue)\(showsTime ? "-time" : "")",
                    to: directory)
            }
        }
    }

    private static func write(_ view: some View, named name: String, to directory: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        // Ohne das legt der Renderer Weiß unter das Bild und der freigestellte Rand
        // wäre dahin.
        renderer.isOpaque = false
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let trimmed = trimmed(bitmap),
            let png = trimmed.representation(using: .png, properties: [:])
        else { return }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// Schneidet den durchsichtigen Rand weg.
    ///
    /// SwiftUI gibt der Pille mehr Fläche, als sie bemalt. In einer Tabellenzelle
    /// würde dieser Leerraum die Zeilen unnötig hoch machen. Der weiche Schatten
    /// zählt als bemalt und bleibt deshalb erhalten, er hat ja Deckkraft.
    private static func trimmed(_ bitmap: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let data = bitmap.bitmapData, bitmap.samplesPerPixel == 4 else { return bitmap }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let rowBytes = bitmap.bytesPerRow
        let pixelBytes = bitmap.bitsPerPixel / 8

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                // Ein wenig Toleranz gegen Rundungsreste am Rand.
                guard data[y * rowBytes + x * pixelBytes + 3] > 2 else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY, let source = bitmap.cgImage else { return bitmap }

        let box = CGRect(
            x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = source.cropping(to: box) else { return bitmap }
        return NSBitmapImageRep(cgImage: cropped)
    }
}
