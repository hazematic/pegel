import AppKit
import SwiftUI

/// Pre-rendered menu bar icon, the same in every state. SwiftUI doesn't draw a
/// `Canvas` as a MenuBarExtra label, hence `NSImage`.
@MainActor
enum MenuBarIcon {

    private static var cached: NSImage?

    /// State is ignored on purpose; the parameter keeps call sites stable.
    static func image(for session: SessionState) -> NSImage {
        if let cached { return cached }
        let image = PegelMark.menuBarImage() ?? NSImage(size: NSSize(width: 18, height: 18))
        cached = image
        return image
    }
}
