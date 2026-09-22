#!/bin/bash
# Adds a release ZIP to appcast.xml, signed with the key in the keychain ("pegel").
#
#   ./update-appcast.sh build/Pegel-0.2.0.zip [notes.html]
#
# Notes are an optional HTML snippet, embedded so Sparkle loads no web page.
# Afterwards: upload the ZIP to release v<version>, then commit and push appcast.xml.
set -euo pipefail

ZIP="${1:?path to release ZIP missing}"
NOTES="${2:-}"
[ -f "$ZIP" ] || { echo "Not found: $ZIP" >&2; exit 1; }
[ -z "$NOTES" ] || [ -f "$NOTES" ] || { echo "Not found: $NOTES" >&2; exit 1; }

cd "$(dirname "$0")"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "sign_update missing, run swift package resolve first" >&2; exit 1; }

BASENAME="$(basename "$ZIP")"
VERSION="${BASENAME#Pegel-}"
VERSION="${VERSION%.zip}"

# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN_UPDATE" --account pegel "$ZIP")"

python3 - "$VERSION" "$SIGNATURE" "$NOTES" <<'PY'
import sys, email.utils, re
version, signature, notes = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"https://github.com/hazematic/pegel/releases/download/v{version}/Pegel-{version}.zip"
description = ""
if notes:
    description = f"\n      <description><![CDATA[{open(notes).read().strip()}]]></description>"
item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>{description}
      <enclosure url="{url}" type="application/octet-stream" {signature} />
    </item>
"""
path = "appcast.xml"
text = open(path).read()
if f"<sparkle:version>{version}</sparkle:version>" in text:
    sys.exit(f"Version {version} is already in {path}")
# Newest first.
anchor = re.search(r"    <language>.*?</language>\n", text)
text = text[:anchor.end()] + item + text[anchor.end():]
open(path, "w").write(text)
PY

echo "Added $VERSION to appcast.xml"
echo "Next: upload the ZIP to release v$VERSION, then commit and push appcast.xml."
