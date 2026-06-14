#!/bin/bash
# Sign with Developer ID + Hardened Runtime, notarize, and staple — the path for
# handing Talkie.app to your co-founders so it opens without Gatekeeper friction.
#
# Prereqs (one-time):
#   1. Apple Developer account (you already have one for Coralate).
#   2. A "Developer ID Application" certificate in your login keychain.
#   3. A notary credential profile stored in the keychain:
#        xcrun notarytool store-credentials talkie-notary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# Usage:
#   export TALKIE_DEVID_ID="Developer ID Application: Your Name (TEAMID)"
#   export TALKIE_NOTARY_PROFILE="talkie-notary"
#   ./scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Talkie.app"
ZIP="$ROOT/Talkie.zip"

: "${TALKIE_DEVID_ID:?Set TALKIE_DEVID_ID to your 'Developer ID Application: …' identity}"
: "${TALKIE_NOTARY_PROFILE:?Set TALKIE_NOTARY_PROFILE to your notarytool keychain profile}"

# Build + sign with the Developer ID identity (Hardened Runtime + entitlements).
TALKIE_SIGN_ID="$TALKIE_DEVID_ID" "$ROOT/scripts/build_app.sh" release

echo "▶ Re-signing with Hardened Runtime + entitlements…"
codesign --force --options runtime --timestamp \
  --entitlements "$ROOT/Resources/talkie.entitlements" \
  --sign "$TALKIE_DEVID_ID" "$APP"

echo "▶ Zipping for notarization…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▶ Submitting to Apple notary service (this can take a minute)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$TALKIE_NOTARY_PROFILE" --wait

echo "▶ Stapling ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "▶ Re-zipping the stapled app for distribution…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✓ Notarized & stapled. Share Talkie.zip — your co-founders can open it normally."
