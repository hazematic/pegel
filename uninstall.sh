#!/bin/bash
# Removes Pegel completely, including ~1.7 GB outside the bundle.
# Homebrew users: brew uninstall --zap --cask pegel does the same.
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

echo "Will remove:"
FOUND=false
for target in "${TARGETS[@]}"; do
    if [ -e "$target" ]; then
        FOUND=true
        printf '  %-6s %s\n' "$(du -sh "$target" 2>/dev/null | cut -f1)" "$target"
    fi
done
$FOUND || { echo "  nothing found, Pegel is already removed"; exit 0; }

echo
echo "Plus the entries under Privacy & Security (Microphone,"
echo "Accessibility, Input Monitoring)."
echo
read -r -p "Continue? [y/N] " answer || answer=""
case "$answer" in
    [jJyY]) ;;
    *) echo "Cancelled."; exit 0 ;;
esac

pkill -x Pegel 2>/dev/null || true
for target in "${TARGETS[@]}"; do
    [ -e "$target" ] && rm -rf "$target"
done

# Otherwise stale entries remain under Privacy & Security.
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "✓ Pegel removed."
