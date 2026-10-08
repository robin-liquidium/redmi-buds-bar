#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${SIGNING_IDENTITY:--}"
APP="$PWD/outputs/RedmiBudsBar.app"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# SwiftPM's Xcode build driver otherwise records the deployment target as the SDK,
# which opts the executable into macOS's legacy appearance despite using a new SDK.
LINKER_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")
mkdir -p outputs
if [[ "${1:-}" == --universal ]]; then
  swift build -c release --arch arm64 --arch x86_64 "${LINKER_FLAGS[@]}"
  BUILD_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release "${LINKER_FLAGS[@]}"
  BUILD_DIR="$(swift build -c release --show-bin-path)"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD_DIR/RedmiBudsBar" "$APP/Contents/MacOS/"
SDK_METADATA="$(xcrun vtool -show-build "$APP/Contents/MacOS/RedmiBudsBar")"
RECORDED_SDKS="$(awk '$1 == "sdk" { print $2 }' <<< "$SDK_METADATA")"
[[ -n "$RECORDED_SDKS" ]] || { echo "Missing executable SDK metadata" >&2; exit 2; }
while IFS= read -r RECORDED_SDK; do
  [[ "$RECORDED_SDK" == "$SDK_VERSION" ]] || { echo "Unexpected executable SDK: $RECORDED_SDK (expected $SDK_VERSION)" >&2; exit 2; }
done <<< "$RECORDED_SDKS"
if [[ "${1:-}" == --universal ]]; then
  ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/RedmiBudsBar")"
  [[ "$ARCHITECTURES" == "arm64 x86_64" || "$ARCHITECTURES" == "x86_64 arm64" ]] || {
    echo "Expected a universal app, got: $ARCHITECTURES" >&2; exit 2;
  }
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
./script/build_media_bridge.sh "${1:-}"
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
 'NSBluetoothAlwaysUsageDescription':'Read battery levels, change noise control and update firmware on your paired Redmi earbuds.',
 'SUFeedURL':'https://buds.robin.build/appcast.xml',
 'SUPublicEDKey':'lqc2rvxIT5NqCBGRHfjswstRg3cepOzdWfnY40e6FyM=',
 'SUEnableAutomaticChecks':True,'SUAutomaticallyUpdate':True,
 'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,
 'NSHumanReadableCopyright':'Copyright © 2026 Robin Obermaier. GPL-3.0.'
}
with open('outputs/RedmiBudsBar.app/Contents/Info.plist','wb') as f: plistlib.dump(p,f)
PY
sign() {
  if [[ "$IDENTITY" == - ]]; then codesign --force --options 0 --sign - "$1"
  else codesign --force --timestamp --options runtime --sign "$IDENTITY" "$1"; fi
}
sign "$FRAMEWORK/Versions/B/Autoupdate"
sign "$FRAMEWORK/Versions/B/Updater.app"
sign "$FRAMEWORK"
sign "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "$APP"
