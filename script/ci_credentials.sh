#!/usr/bin/env bash
set -euo pipefail
for name in MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD APP_STORE_CONNECT_KEY_P8_BASE64 APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID SPARKLE_PRIVATE_KEY; do
  [[ -n "${!name:-}" ]] || { echo "Missing secret: $name" >&2; exit 2; }
done
umask 077
KEYCHAIN="$RUNNER_TEMP/redmi-signing.keychain-db"
PASSWORD="$(uuidgen)"
printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 -D > "$RUNNER_TEMP/redmi-developer.p12"
printf '%s' "$APP_STORE_CONNECT_KEY_P8_BASE64" | base64 -D > "$RUNNER_TEMP/redmi-notary.p8"
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$RUNNER_TEMP/redmi-developer.p12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
echo "NOTARY_KEY_PATH=$RUNNER_TEMP/redmi-notary.p8" >> "$GITHUB_ENV"
