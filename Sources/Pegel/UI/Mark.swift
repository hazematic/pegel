import AppKit
import SwiftUI

/// Die Bildmarke: ein Pegel aus fünf senkrechten Strichen, symmetrisch um die
/// Mitte, monochrom.
///
/// Konstruiert in einem 16 × 16-Raster. Gerade Striche sind die einzige Form, die bei
/// 16 pt verlustfrei durchkommt; die vorherige Marke aus Einfügemarke und laufenden
/// Bögen ist daran gescheitert.
///
/// Das Zeichen kennt keinen Zustand. In der Menüleiste sieht es beim Aufnehmen aus wie
/// im Ruhezustand, der Zustand gehört an den Cursor, weil man dort hinsieht.
struct PegelMark: View {

    var color: Color = .primary
    /// Strichstärke in Rastereinheiten.
    var lineWidth: Double = 1.5

    private let unit: Double = 16
    private let positions: [Double] = [2.75, 5.4, 8, 10.6, 13.25]
    private let halfHeights: [Double] = [1.4, 3.5, 5.4, 3.5, 1.4]

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / unit
            var path = Path()
            for (x, half) in zip(positions, halfHeights) {
                path.move(to: CGPoint(x: x * scale, y: (8 - half) * scale))
                path.addLine(to: CGPoint(x: x * scale, y: (8 + half) * scale))
            }
            context.stroke(
                path, with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Rendering für AppKit

extension PegelMark {

    /// Rendert das Zeichen als Template-Image für die Menüleiste.
    /// Template heißt: macOS färbt selbst ein, hell wie dunkel.
    @MainActor
    static func menuBarImage(pointSize: CGFloat = 18) -> NSImage? {
        let renderer = ImageRenderer(
            content: PegelMark(color: .black, lineWidth: 1.5)
                .frame(width: pointSize, height: pointSize)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
