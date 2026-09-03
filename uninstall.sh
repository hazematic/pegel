#!/bin/bash
# Entfernt Pegel restlos.
#
# Wer über Homebrew installiert hat, braucht das nicht:
#   brew uninstall --zap --cask pegel
# erledigt dasselbe. Dieses Skript ist für alle anderen, weil macOS für
# selbst kopierte Apps keine Deinstallation kennt und das Ziehen in den
# Papierkorb rund 1,7 GB an anderer Stelle liegen lässt.
set -euo pipefail

BUNDLE_ID="io.github.hazematic.pegel"
APP="${1:-/Applications/Pegel.app}"

TARGETS=(
    "$APP"
    "$HOME/Library/Caches/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
)

echo "Entfernt wird:"
FOUND=false
for target in "${TARGETS[@]}"; do
    if [ -e "$target" ]; then
        FOUND=true
        printf '  %-6s %s\n' "$(du -sh "$target" 2>/dev/null | cut -f1)" "$target"
    fi
done
$FOUND || { echo "  nichts gefunden, Pegel ist bereits entfernt"; exit 0; }

echo
echo "Dazu die Einträge in Datenschutz und Sicherheit (Mikrofon,"
echo "Bedienungshilfen, Eingabeüberwachung)."
echo
read -r -p "Weiter? [j/N] " answer || answer=""
case "$answer" in
    [jJyY]) ;;
    *) echo "Abgebrochen."; exit 0 ;;
esac

pkill -x Pegel 2>/dev/null || true
for target in "${TARGETS[@]}"; do
    [ -e "$target" ] && rm -rf "$target"
done

# Ohne das bleiben die drei Schalter als Karteileichen in den Systemeinstellungen
# stehen und eine spätere Neuinstallation erbt einen unbrauchbaren Eintrag.
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "✓ Pegel ist entfernt."
