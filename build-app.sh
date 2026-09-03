#!/bin/bash
# Baut Pegel.app aus dem SwiftPM-Paket.
#
# Xcode wird dafür nicht gebraucht, die Command Line Tools genügen. Das Skript
# erzeugt das Bundle, rendert das Iconset aus der Bildmarke im Code und signiert.
#
# Signatur: ohne eigenes Zertifikat wird ad-hoc signiert. Das funktioniert, aber
# macOS erkennt die App nach jedem Neubau als neu und fragt Mikrofon- und
# Bedienungshilfen-Recht erneut ab. Wer das nicht will, legt sich in der
# Schlüsselbundverwaltung ein selbstsigniertes Code-Signing-Zertifikat an und
# setzt CODESIGN_IDENTITY auf dessen Namen.
set -euo pipefail

# Argumente: die Konfiguration als erstes Positionsargument, danach beliebig viele
# Flags. Vorher wurde die Konfiguration blind aus $1 gelesen, ein vorangestelltes
# --install landete deshalb als Konfiguration in "swift build -c".
CONFIGURATION="release"
DO_INSTALL=false
DO_ZIP=false
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=true ;;
        --zip) DO_ZIP=true ;;
        --*) echo "Unbekanntes Argument: $arg" >&2; exit 1 ;;
        *) CONFIGURATION="$arg" ;;
    esac
done
# Signaturidentität: explizit gesetzt, sonst das lokale Zertifikat, sonst ad-hoc.
# Mit stabiler Identität behält die App ihre erteilten Rechte über Neubauten hinweg,
# weil die Designated Requirement gleich bleibt.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    if security find-certificate -c "Pegel Local" >/dev/null 2>&1; then
        IDENTITY="Pegel Local"
    else
        IDENTITY="-"
    fi
fi
BUNDLE_ID="io.github.hazematic.pegel"
VERSION="0.1.1"

cd "$(dirname "$0")"
echo "→ Baue ($CONFIGURATION)"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP="build/Pegel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/Pegel" "$APP/Contents/MacOS/Pegel"
# Ressourcen-Bundles der Abhängigkeiten (FluidAudio) mitnehmen.
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Sprachdateien als echte .lproj-Ordner ins Bundle. Nur so findet macOS sie, bietet
# die Umschaltung pro Programm in den Systemeinstellungen an und wählt selbst die
# passende Sprache.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Pegel</string>
    <key>CFBundleDisplayName</key><string>Pegel</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Pegel</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>Pegel</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Englisch als Entwicklungssprache, also als Rückfallebene: Deutsch greift nur
         bei einem echten Sprachtreffer (de, de-DE, de-AT, de-CH, de-LU), jede andere
         Systemsprache bekommt Englisch. Stünde hier "de", bekäme ein französisches
         System Deutsch. Die verfügbaren Sprachen deklarieren die .lproj-Ordner;
         CFBundleLocalizations zusätzlich zu setzen erzeugt nur doppelte Einträge. -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Menüleisten-App ohne Dock-Icon und ohne Fenster beim Start. -->
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Pegel nimmt dein Diktat auf und wandelt es lokal auf diesem Mac in Text um. Es wird nichts übertragen.</string>
</dict>
</plist>
PLIST

echo "→ Rendere Iconset aus der Bildmarke"
ICONSET="$(mktemp -d)/Pegel.iconset"
"$APP/Contents/MacOS/Pegel" --export-icons "$ICONSET" >/dev/null 2>&1 || true
if [ -d "$ICONSET" ] && [ -n "$(ls -A "$ICONSET" 2>/dev/null)" ]; then
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Pegel.icns"
else
    echo "  Warnung: Iconset konnte nicht gerendert werden, App bleibt ohne Icon."
fi

cat > "build/Pegel.entitlements" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Keine App Sandbox: der globale Event-Tap und das Einfügen in fremde Apps
         funktionieren darin nicht. -->
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENTITLEMENTS

echo "→ Signiere (Identität: $IDENTITY)"
codesign --force --options runtime \
    --entitlements "build/Pegel.entitlements" \
    --sign "$IDENTITY" "$APP"

echo "✓ $APP"
if [ "$IDENTITY" = "-" ]; then
    echo "  Ad-hoc signiert. Nach jedem Neubau müssen die Rechte neu erteilt werden."
fi

# Mit --zip entsteht das Archiv für die Weitergabe. Bewusst "ditto" und nicht "zip":
# nur ditto legt ein App-Bundle so ab, dass Symlinks und erweiterte Attribute heil
# bleiben. Ein mit "zip" gepacktes Bundle kommt beim Empfänger als "ist beschädigt"
# an, weil die Signatur die Reise nicht überlebt hat.
if [ "$DO_ZIP" = true ]; then
    ZIP="build/Pegel-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "✓ $ZIP"
    echo "  SHA256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    # Das Quarantäne-Merkmal setzt erst der Browser des Empfängers, nicht dieses
    # Archiv. Ohne Notarisierung muss es dort einmal entfernt werden:
    #   xattr -dr com.apple.quarantine /Applications/Pegel.app
fi

# Mit --install landet die App dort, wo macOS sie erwartet, und behält denselben
# Pfad: die erteilten Rechte hängen auch am Ort.
if [ "$DO_INSTALL" = true ]; then
    pkill -f "Pegel.app/Contents/MacOS/Pegel" 2>/dev/null || true
    # Ohne diese Pause kommt "open" dem beendeten Exemplar zuvor und LaunchServices
    # antwortet mit -600.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -qf "Pegel.app/Contents/MacOS/Pegel" || break
        sleep 0.3
    done
    rm -rf /Applications/Pegel.app
    cp -R "$APP" /Applications/Pegel.app
    # LaunchServices braucht nach dem Austausch des Bundles einen Moment, sonst
    # antwortet "open" mit -600.
    for _ in 1 2 3 4 5; do
        open /Applications/Pegel.app 2>/dev/null && break
        sleep 0.5
    done
    echo "✓ nach /Applications installiert und gestartet"
fi
