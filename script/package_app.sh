#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGNING_IDENTITY:--}"
APP="$PWD/outputs/RedmiBudsBar.app"
mkdir -p outputs
if [[ "${1:-}" == --universal ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release
  BUILD_DIR="$(swift build -c release --show-bin-path)"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD_DIR/RedmiBudsBar" "$APP/Contents/MacOS/"
if [[ "${1:-}" == --universal ]]; then
  ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/RedmiBudsBar")"
  [[ "$ARCHITECTURES" == "arm64 x86_64" || "$ARCHITECTURES" == "x86_64 arm64" ]] || {
    echo "Expected a universal app, got: $ARCHITECTURES" >&2; exit 2;
  }
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
ditto "$BUILD_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# The app is not sandboxed; Sparkle documents these XPC services as optional.
rm -rf "$FRAMEWORK/Versions/B/XPCServices"
python3 - <<'PY'
import plistlib,json
r=json.load(open('release.json'))
p={
 'CFBundleExecutable':'RedmiBudsBar','CFBundleIdentifier':'build.robin.RedmiBudsBar',
 'CFBundleName':'Redmi Buds Bar','CFBundlePackageType':'APPL','CFBundleIconFile':'AppIcon',
 'CFBundleShortVersionString':r['version'],'CFBundleVersion':str(r['build']),
 'LSMinimumSystemVersion':'14.0','LSUIElement':True,'NSPrincipalClass':'NSApplication',
 'NSBluetoothAlwaysUsageDescription':'Read battery levels and change noise control on your paired Redmi earbuds.',
 'SUFeedURL':'https://buds.robin.build/appcast.xml',
 'SUPublicEDKey':'lqc2rvxIT5NqCBGRHfjswstRg3cepOzdWfnY40e6FyM=',
 'SUEnableAutomaticChecks':True,'SUAutomaticallyUpdate':True,
 'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,
 'NSHumanReadableCopyright':'Copyright © 2026 Robin Obermaier. GPL-3.0.'
}
with open('outputs/RedmiBudsBar.app/Contents/Info.plist','wb') as f: plistlib.dump(p,f)
PY
sign() {
  if [[ "$IDENTITY" == - ]]; then codesign --force --options runtime --sign - "$1"
  else codesign --force --timestamp --options runtime --sign "$IDENTITY" "$1"; fi
}
sign "$FRAMEWORK/Versions/B/Autoupdate"
sign "$FRAMEWORK/Versions/B/Updater.app"
sign "$FRAMEWORK"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "$APP"
