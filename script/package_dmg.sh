#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
VERSION="$(python3 -c 'import json; print(json.load(open("release.json"))["version"])')"
DMG="$PWD/outputs/RedmiBudsBar-$VERSION.dmg"
STAGE="$(mktemp -d)"
ARTWORK="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$ARTWORK"' EXIT
# Render the vector source at each display scale; never upscale raster text.
python3 - "$ARTWORK" <<'PYCODE'
import sys, xml.etree.ElementTree as ET
from pathlib import Path
for scale in (1, 2):
    svg = ET.parse('Resources/DMGBackground.svg')
    svg.getroot().set('width', str(640 * scale))
    svg.getroot().set('height', str(400 * scale))
    svg.write(Path(sys.argv[1]) / f'background@{scale}x.svg')
PYCODE
for scale in 1 2; do
  sips -s format png "$ARTWORK/background@${scale}x.svg" --out "$ARTWORK/background@${scale}x.png" >/dev/null
  sips -s dpiWidth "$((72 * scale))" -s dpiHeight "$((72 * scale))" "$ARTWORK/background@${scale}x.png" >/dev/null
done
tiffutil -cathidpicheck "$ARTWORK/background@1x.png" "$ARTWORK/background@2x.png" -out "$ARTWORK/background.tiff"
ditto outputs/RedmiBudsBar.app "$STAGE/RedmiBudsBar.app"
rm -f "$DMG"
create-dmg --volname 'Redmi Buds Bar' --volicon Resources/AppIcon.icns \
  --background "$ARTWORK/background.tiff" --window-pos 200 120 --window-size 640 440 \
  --icon-size 112 --text-size 14 --icon RedmiBudsBar.app 160 200 \
  --hide-extension RedmiBudsBar.app --app-drop-link 480 200 --filesystem APFS \
  "$DMG" "$STAGE"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
codesign --verify --strict "$DMG"
