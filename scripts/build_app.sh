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
              | grep -m1 'Apple Development' | sed -E 's/.*"(.*)".*/\1/' || true)"
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

echo "▶ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Talkie"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle the `talkie-mcp` connector binary INSIDE the app (Contents/MacOS/talkie-mcp)
# so every installed Talkie ships a working "Connect to Claude" experience — no
# checkout, no `swift build`, no maker-specific paths. The Settings connector card
# points Claude clients at THIS path first (see MCPConnectorCard.binaryPath). It is
# the same zero-dependency stdio JSON-RPC server the .mcpb wraps; nesting it costs a
# few MB and buys one-click setup for non-maker machines.
echo "▶ Building talkie-mcp ($CONFIG)…"
swift build -c "$CONFIG" --product talkie-mcp
MCP_BIN="$(swift build -c "$CONFIG" --show-bin-path)/talkie-mcp"
if [[ ! -f "$MCP_BIN" ]]; then
  echo "✗ talkie-mcp binary not found at $MCP_BIN" >&2
  exit 1
fi
cp "$MCP_BIN" "$APP/Contents/MacOS/talkie-mcp"

# Bundle the `talkie` file-transcription CLI INSIDE the app so every install ships
# MacWhisper-Pro-style local batch transcription + `talkie last` with no checkout
# or `swift build`. Symlink it onto PATH once with:
#   ln -s /Applications/Talkie.app/Contents/Helpers/talkie /usr/local/bin/talkie
#
# IMPORTANT — it goes in Contents/Helpers/, NOT Contents/MacOS/. The app's main
# executable is Contents/MacOS/Talkie, and macOS ships on case-INSENSITIVE APFS, so
# a `talkie` next to `Talkie` in the same directory is the SAME path — copying the
# CLI there silently OVERWRITES the app binary (the bundle would then launch the CLI
# instead of the app). Contents/Helpers/ is a standard spot for a nested tool and
# sidesteps the collision while still giving the binary the exact `talkie` basename
# the user wants on their PATH. The SwiftPM product stays `talkie-cli` for the same
# case-insensitivity reason (it can't share `.build/.../Talkie`); we rename to
# `talkie` only here, at copy time. Same zero-dependency, on-device, network-free
# posture as talkie-mcp — check-no-network.sh scans Sources/TalkieCLI too.
echo "▶ Building talkie-cli ($CONFIG)…"
swift build -c "$CONFIG" --product talkie-cli
CLI_BIN="$(swift build -c "$CONFIG" --show-bin-path)/talkie-cli"
if [[ ! -f "$CLI_BIN" ]]; then
  echo "✗ talkie-cli binary not found at $CLI_BIN" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Helpers"
cp "$CLI_BIN" "$APP/Contents/Helpers/talkie"

# Also ship the one-click Claude Desktop connector (.mcpb) inside the bundle, in
# Contents/Resources/Talkie.mcpb, so the connector card can hand it straight to
# Claude Desktop (which registers as the .mcpb handler). build_mcpb.sh produces it
# from the SAME talkie-mcp target; the bundle therefore embeds a SECOND copy of the
# binary inside the zip (~a few MB) — accepted, it's the price of a self-contained,
# double-click install with no download step.
echo "▶ Building Talkie.mcpb…"
"$ROOT/scripts/build_mcpb.sh"
if [[ -f "$ROOT/connector/Talkie.mcpb" ]]; then
  cp "$ROOT/connector/Talkie.mcpb" "$APP/Contents/Resources/Talkie.mcpb"
else
  echo "⚠  connector/Talkie.mcpb not produced — connector card's Claude Desktop button will be unavailable."
fi
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Bundled fonts (Young Serif display face) — registered at launch via the
# Info.plist `ATSApplicationFontsPath = Fonts` key.
if [[ -d "$ROOT/Resources/Fonts" ]]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp "$ROOT/Resources/Fonts/"*.otf "$APP/Contents/Resources/Fonts/" 2>/dev/null || true
fi

# Brand art (the real logo + Higgsfield-generated feather/background assets),
# loaded at runtime via Brand.image(_:). Copied flat into Resources/.
if [[ -d "$ROOT/Resources/Brand" ]]; then
  cp "$ROOT/Resources/Brand/"*.png "$APP/Contents/Resources/" 2>/dev/null || true
fi

# Localizations — per-language <lang>.lproj/Localizable.strings. SwiftUI Text/
# Button literals auto-localize via LocalizedStringKey against these at runtime.
if [[ -d "$ROOT/Resources/Localizations" ]]; then
  cp -R "$ROOT/Resources/Localizations/"*.lproj "$APP/Contents/Resources/" 2>/dev/null || true
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
# Inside-out signing (NO --deep): sign every nested Mach-O executable FIRST, then
# the bundle, so each signature is sealed by the outer one. Getting this order right
# now means the future notarization package (WS-J) inherits a correctly-signed nested
# binary instead of a re-sign scramble at release time. The nested talkie-mcp is a
# plain stdio helper: it takes NO app entitlements (it must never carry the audio /
# calendar / apple-events grants), only the Hardened-Runtime/timestamp flags on the
# Developer ID branch that notarization requires.
NESTED_SIGN_ARGS=(--force --sign "$SIGN_ID" --identifier com.coralate.talkie.mcp)
if [[ "$SIGN_ID" == *"Developer ID"* ]]; then
  NESTED_SIGN_ARGS+=(--options runtime --timestamp)
fi
if [[ -f "$APP/Contents/MacOS/talkie-mcp" ]]; then
  codesign "${NESTED_SIGN_ARGS[@]}" "$APP/Contents/MacOS/talkie-mcp"
fi

# Sign the nested `talkie` CLI the same inside-out way: its own identifier, NO app
# entitlements (it's a plain on-device transcription helper — it must never carry
# the audio / calendar / apple-events grants), Hardened-Runtime/timestamp only on
# the Developer ID branch that notarization needs.
CLI_SIGN_ARGS=(--force --sign "$SIGN_ID" --identifier com.coralate.talkie.cli)
if [[ "$SIGN_ID" == *"Developer ID"* ]]; then
  CLI_SIGN_ARGS+=(--options runtime --timestamp)
fi
if [[ -f "$APP/Contents/Helpers/talkie" ]]; then
  codesign "${CLI_SIGN_ARGS[@]}" "$APP/Contents/Helpers/talkie"
fi

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
