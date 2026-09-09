#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ARTWORK="$(mktemp -d)"
trap 'rm -rf "$ARTWORK"' EXIT
swift script/render_icon.swift "$ARTWORK/icon.png"
mkdir "$ARTWORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ARTWORK/icon.png" --out "$ARTWORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ARTWORK/icon.png" --out "$ARTWORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ARTWORK/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$ARTWORK/AppIcon.iconset/icon_256x256@2x.png" website/public/icon.png
