#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
VERSION="$(python3 -c 'import json; print(json.load(open("release.json"))["version"])')"
DMG="$PWD/outputs/RedmiBudsBar-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto outputs/RedmiBudsBar.app "$STAGE/RedmiBudsBar.app"
rm -f "$DMG"
create-dmg --volname 'Redmi Buds Bar' --volicon Resources/AppIcon.icns \
  --background Resources/DMGBackground.png --window-pos 200 120 --window-size 640 440 \
  --icon-size 112 --text-size 14 --icon RedmiBudsBar.app 160 200 \
  --hide-extension RedmiBudsBar.app --app-drop-link 480 200 --filesystem APFS \
  "$DMG" "$STAGE"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
codesign --verify --strict "$DMG"
