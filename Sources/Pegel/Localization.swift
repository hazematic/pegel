import Foundation

/// Localized string from the app bundle. The `.lproj` folders sit directly in the
/// bundle, not in a SwiftPM resource bundle: only then does macOS pick the language
/// and offer the per-app switch.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Bundle.main.localizedString(forKey: key, value: key, table: nil),
        arguments: arguments)
}
