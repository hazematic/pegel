import AppKit
import SwiftUI

/// The mark: five vertical bars on a 16 × 16 grid, the only shape that survives 16 pt.
/// Stateless: status belongs at the cursor, where the user looks.
struct PegelMark: View {

    var color: Color = .primary
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

// MARK: - AppKit rendering

extension PegelMark {

    /// Template image, so macOS tints it for light and dark.
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
