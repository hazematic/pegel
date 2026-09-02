import AppKit
import SwiftUI

/// Das vorgerenderte Menüleistensymbol.
///
/// Es gibt nur eines: die Leiste zeigt in Ruhe, Aufnahme und Transkription dasselbe
/// Bild. Der Umweg über `NSImage` bleibt nötig, weil SwiftUI einen `Canvas` als
/// MenuBarExtra-Label nicht zeichnet und das Statusitem sonst leer bliebe.
@MainActor
enum MenuBarIcon {

    private static var cached: NSImage?

    /// Der Zustand wird bewusst ignoriert; der Parameter bleibt, damit die Aufrufstelle
    /// gleich aussieht, falls sich das je wieder ändert.
    static func image(for session: SessionState) -> NSImage {
        if let cached { return cached }
        let image = PegelMark.menuBarImage() ?? NSImage(size: NSSize(width: 18, height: 18))
        cached = image
        return image
    }
}
