import SwiftUI

/// The name "Pegel" in PT Sans Bold, the brand's typeface on the site and in the film.
/// The font ships in Contents/Resources/Fonts (ATSApplicationFontsPath); 20 pt matches the
/// optical size of the system font's title2, PT Sans runs smaller.
struct Wordmark: View {
    var body: some View {
        Text("Pegel")
            .font(.custom("PTSans-Bold", size: 20, relativeTo: .title2))
    }
}
