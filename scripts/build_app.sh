#!/bin/bash
# Assemble Talkie.app from the SwiftPM build and code-sign it.
#
#   ./scripts/build_app.sh [debug|release]
#
# Signing identity:
#   - Default: ad-hoc ("-").  Works on THIS Mac. Note: the ad-hoc signature's
#     hash changes every rebuild, so macOS may re-ask for permissions after a
#     rebuild.
#   - To avoid re-prompts during development, export your Apple Development cert:
#       export TALKIE_SIGN_ID="Apple Development: Your Name (TEAMID)"
#   - To SHARE with co-founders, sign + notarize with a Developer ID cert — see
#     scripts/notarize.sh and the README.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/Talkie.app"
SIGN_ID="${TALKIE_SIGN_ID:--}"

echo "▶ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Talkie"

if [[ ! -f "$BIN" ]]; then
  echo "✗ Binary not found at $BIN" >&2
  exit 1
fi

echo "▶ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Talkie"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▶ Signing (identity: $SIGN_ID)…"
codesign --force --sign "$SIGN_ID" --identifier com.coralate.talkie "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/   /' || true

echo "✓ Built $APP"
