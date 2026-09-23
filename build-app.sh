#!/bin/bash
# Builds Pegel.app from the SwiftPM package; the Command Line Tools suffice.
#
# Without a certificate the app is signed ad hoc, and macOS asks for permissions
# again after every rebuild. Set CODESIGN_IDENTITY or create a self-signed
# code-signing certificate named "Pegel Local".
set -euo pipefail

# Usage: build-app.sh [configuration] [--zip] [--dmg] [--install]
CONFIGURATION="release"
DO_INSTALL=false
DO_ZIP=false
DO_DMG=false
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=true ;;
        --zip) DO_ZIP=true ;;
        --dmg) DO_DMG=true ;;
        --*) echo "Unknown argument: $arg" >&2; exit 1 ;;
        *) CONFIGURATION="$arg" ;;
    esac
done
# A stable identity keeps granted permissions across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    if security find-certificate -c "Pegel Local" >/dev/null 2>&1; then
        IDENTITY="Pegel Local"
    else
        IDENTITY="-"
    fi
fi
BUNDLE_ID="io.github.hazematic.pegel"
VERSION="1.1.0"

cd "$(dirname "$0")"
echo "→ Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP="build/Pegel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/Pegel" "$APP/Contents/MacOS/Pegel"

# SwiftPM only adds @loader_path (Contents/MacOS) as rpath; the framework belongs in
# Contents/Frameworks. Must precede the icon export, which launches the binary.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_PATH/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Pegel"
for bundle in "$BIN_PATH"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# .lproj folders directly in the bundle, so macOS picks the language.
# FluidAudio and its dependencies are linked statically; their licences ship too.
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE NOTICE "$APP/Contents/Resources/Licenses/"
cp -R licenses/. "$APP/Contents/Resources/Licenses/"

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
    <!-- English as fallback: German only for a real match, not for e.g. French. -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <!-- Sparkle: no automatic checks, no prompt, no system profile. -->
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/hazematic/pegel/main/appcast.xml</string>
    <key>SUPublicEDKey</key><string>M5CY+6kw4VpY9xdB2ZpNO+2OjZ1KmI3rf7W9C+6t/CE=</string>
    <key>SUEnableAutomaticChecks</key><false/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUAutomaticallyUpdate</key><false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Pegel records your dictation and turns it into text locally on this Mac. Nothing is transmitted.</string>
</dict>
</plist>
PLIST

echo "→ Rendering icon set"
ICONSET="$(mktemp -d)/Pegel.iconset"
"$APP/Contents/MacOS/Pegel" --export-icons "$ICONSET" >/dev/null 2>&1 || true
DMG_ART="$ICONSET/dmg"
if [ -d "$ICONSET" ] && [ -n "$(ls -A "$ICONSET" 2>/dev/null)" ]; then
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Pegel.icns"
else
    echo "  Warning: icon set could not be rendered, app has no icon."
fi

cat > "build/Pegel.entitlements" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- No sandbox: the global event tap and pasting into other apps need it off. -->
    <key>com.apple.security.device.audio-input</key><true/>
    <!-- Load Sparkle.framework: a self-signed certificate has no Team ID, so library
         validation would reject it. -->
    <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
ENTITLEMENTS

echo "→ Signing (identity: $IDENTITY)"
# Inside out, same identity as the app: Sparkle requires matching signatures.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
codesign --force --options runtime --preserve-metadata=entitlements --sign "$IDENTITY" \
    "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE/Autoupdate"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE/Updater.app"
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime \
    --entitlements "build/Pegel.entitlements" \
    --sign "$IDENTITY" "$APP"

echo "✓ $APP"
if [ "$IDENTITY" = "-" ]; then
    echo "  Signed ad hoc. Permissions must be granted again after every rebuild."
fi

# ditto, not zip: zip breaks symlinks and the signature ("is damaged").
if [ "$DO_ZIP" = true ]; then
    ZIP="build/Pegel-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "✓ $ZIP"
    echo "  SHA256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    # Recipients clear the browser's quarantine flag once:
    #   xattr -dr com.apple.quarantine /Applications/Pegel.app
fi

# DMG for manual downloads: drag to Applications. The ZIP stays for Sparkle and
# Homebrew. Finder layout via AppleScript, which may ask to control Finder once.
if [ "$DO_DMG" = true ]; then
    DMG="build/Pegel-$VERSION.dmg"
    STAGE="$(mktemp -d)/Pegel"
    mkdir -p "$STAGE/.background"
    ditto "$APP" "$STAGE/Pegel.app"
    ln -s /Applications "$STAGE/Applications"
    tiffutil -cathidpicheck "$DMG_ART/background.png" "$DMG_ART/background@2x.png" \
        -out "$STAGE/.background/background.tiff" >/dev/null

    RW="$(mktemp -d)/Pegel-rw.dmg"
    hdiutil create -quiet -srcfolder "$STAGE" -volname Pegel -fs HFS+ -format UDRW "$RW"
    MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"
    DISK="$(basename "$MOUNT")"

    # Window 660 × 400 plus title bar; icon centers match DMGBackground.
    osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 548}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Pegel.app" of container window to {165, 180}
        set position of item "Applications" of container window to {495, 180}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

    sync
    hdiutil detach -quiet "$MOUNT"
    rm -f "$DMG"
    hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
    rm -f "$RW"
    echo "✓ $DMG"
fi

# Same path every time: granted permissions are tied to it.
if [ "$DO_INSTALL" = true ]; then
    pkill -f "Pegel.app/Contents/MacOS/Pegel" 2>/dev/null || true
    # Wait, or "open" races the old instance and LaunchServices returns -600.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -qf "Pegel.app/Contents/MacOS/Pegel" || break
        sleep 0.3
    done
    rm -rf /Applications/Pegel.app
    cp -R "$APP" /Applications/Pegel.app
    for _ in 1 2 3 4 5; do
        open /Applications/Pegel.app 2>/dev/null && break
        sleep 0.5
    done
    echo "✓ installed to /Applications and launched"
fi
