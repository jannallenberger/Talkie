#!/bin/bash
# Build a signed, notarized, stapled drag-to-Applications DMG of Talkie.
#
#   export TALKIE_DEVID_ID="Developer ID Application: Your Name (TEAMID)"
#   export TALKIE_NOTARY_PROFILE="talkie-notary"
#   ./scripts/make_dmg.sh            # build + sign + notarize app, then DMG
#   ./scripts/make_dmg.sh --skip-app # reuse an already notarized ./Talkie.app
#
# Output: ./Talkie-<version>.dmg and a stable-named copy ./Talkie.dmg (so the
# website can link to .../releases/latest/download/Talkie.dmg permanently).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Talkie.app"

: "${TALKIE_DEVID_ID:?Set TALKIE_DEVID_ID to your 'Developer ID Application: …' identity}"
: "${TALKIE_NOTARY_PROFILE:?Set TALKIE_NOTARY_PROFILE to your notarytool keychain profile}"

if [[ "${1:-}" != "--skip-app" ]]; then
  "$ROOT/scripts/notarize.sh"
fi
[[ -d "$APP" ]] || { echo "✗ $APP not found" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOLNAME="Talkie"
DMG="$ROOT/Talkie-$VERSION.dmg"
STAGE="$(mktemp -d -t talkie-dmg)"
trap 'rm -rf "$STAGE"' EXIT

echo "▶ Staging DMG contents…"
ditto "$APP" "$STAGE/Talkie.app"
ln -s /Applications "$STAGE/Applications"

echo "▶ Creating $DMG…"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

echo "▶ Signing DMG…"
codesign --force --timestamp --sign "$TALKIE_DEVID_ID" "$DMG"

echo "▶ Notarizing DMG (this can take a minute)…"
xcrun notarytool submit "$DMG" --keychain-profile "$TALKIE_NOTARY_PROFILE" --wait

echo "▶ Stapling + validating…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

cp -f "$DMG" "$ROOT/Talkie.dmg"
echo "✓ $DMG  (+ Talkie.dmg)"
shasum -a 256 "$DMG"
