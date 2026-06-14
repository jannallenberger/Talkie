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

# Resolve a signing identity. A STABLE identity (Apple Development / Developer ID)
# keeps the same code-signing "designated requirement" across rebuilds, so macOS
# does NOT wipe granted permissions every time you rebuild. Ad-hoc ("-") changes
# its hash on every build and is the cause of the "permissions keep resetting" bug.
SIGN_ID="${TALKIE_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 'Apple Development' | sed -E 's/.*"(.*)".*/\1/')"
  if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="-"
    echo "⚠  No Apple Development identity found — falling back to ad-hoc."
    echo "   macOS will re-ask for permissions after every rebuild."
    echo "   Set TALKIE_SIGN_ID to a stable identity to fix that."
  fi
fi

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

# Bundled fonts (Young Serif display face) — registered at launch via the
# Info.plist `ATSApplicationFontsPath = Fonts` key.
if [[ -d "$ROOT/Resources/Fonts" ]]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp "$ROOT/Resources/Fonts/"*.otf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
fi

# App icon from the Icon Composer .icon bundle (macOS 26 Liquid Glass).
# actool emits AppIcon.icns (Finder/Dock fallback) + Assets.car (glass icon).
if [[ -d "$ROOT/Resources/AppIcon.icon" ]]; then
  echo "▶ Compiling app icon…"
  xcrun actool "$ROOT/Resources/AppIcon.icon" \
    --compile "$APP/Contents/Resources" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --output-partial-info-plist /tmp/talkie_icon_partial.plist \
    --errors --warnings >/dev/null 2>&1 || echo "  (icon compile skipped)"
fi

echo "▶ Signing (identity: $SIGN_ID)…"
SIGN_ARGS=(--force --sign "$SIGN_ID" --identifier com.coralate.talkie
           --entitlements "$ROOT/Resources/talkie.entitlements")
# Hardened Runtime + timestamp are only needed for Developer ID notarization;
# Apple Development local builds stay simple (still a stable signature → TCC sticks).
if [[ "$SIGN_ID" == *"Developer ID"* ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/   /' || true

echo "✓ Built $APP"
