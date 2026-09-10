#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$PWD/outputs/RedmiBudsBar.app/Contents/Frameworks/MediaRemoteAdapter.framework"
SOURCE="$PWD/Vendor/MediaRemoteAdapter"
ARCH_FLAGS=(-arch "$(uname -m)")
if [[ "${1:-}" == --universal ]]; then ARCH_FLAGS=(-arch arm64 -arch x86_64); fi
mkdir -p "$DEST/Versions/A/Resources"
xcrun clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=14.0 \
  "${ARCH_FLAGS[@]}" -I "$SOURCE/include" -I "$SOURCE/src" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  "$SOURCE"/src/adapter/*.m "$SOURCE"/src/private/*.m "$SOURCE"/src/utility/*.m \
  -o "$DEST/Versions/A/MediaRemoteAdapter"
ln -s A "$DEST/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$DEST/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$DEST/Resources"
python3 - "$DEST/Resources/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'build.robin.RedmiBudsBar.MediaRemoteAdapter',
                  'CFBundleName':'MediaRemoteAdapter','CFBundleExecutable':'MediaRemoteAdapter',
                  'CFBundlePackageType':'FMWK','CFBundleVersion':'1',
                  'CFBundleShortVersionString':'0.1.0','LSMinimumSystemVersion':'14.0'},f)
PY
cp "$SOURCE/bin/mediaremote-adapter.pl" outputs/RedmiBudsBar.app/Contents/Resources/
cp "$SOURCE/LICENSE" outputs/RedmiBudsBar.app/Contents/Resources/MediaRemoteAdapter-LICENSE.txt
