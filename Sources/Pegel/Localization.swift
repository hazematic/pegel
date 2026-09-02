import Foundation

/// Übersetzte Zeichenkette aus dem App-Bundle.
///
/// Die Sprachdateien liegen bewusst als `de.lproj` und `en.lproj` direkt im
/// App-Bundle und nicht in einem SwiftPM-Ressourcenpaket: nur so findet macOS sie,
/// bietet die Umschaltung pro Programm in den Systemeinstellungen an und wählt ohne
/// Zutun die passende Sprache. Fällt eine Sprache aus, bleibt der Schlüssel stehen,
/// was beim Testen sofort auffällt.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Bundle.main.localizedString(forKey: key, value: key, table: nil),
        arguments: arguments)
}
