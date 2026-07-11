#!/bin/bash
# Build, install ONE canonical copy to /Applications, and launch it.
# Using a single stable location (+ the stable signature from build_app.sh) is
# what makes macOS permissions persist across rebuilds.
#   ./scripts/run.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
DEST="/Applications/Talkie.app"

echo "▶ Build provenance:"
CUR="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
ORIGIN="$(git -C "$ROOT" rev-parse origin/main 2>/dev/null || echo unknown)"
DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null)"
echo "   HEAD=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) branch=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [[ "$CUR" != "$ORIGIN" || -n "$DIRTY" ]]; then
  echo "⚠  This tree is NOT at origin/main${DIRTY:+ and has uncommitted changes}."
  echo "   You are about to install a build that does not match origin/main."
  if [[ "${TALKIE_ALLOW_STALE:-0}" != "1" ]]; then
    echo "   Refusing to install. Re-run with TALKIE_ALLOW_STALE=1 to override." >&2
    exit 1
  fi
  echo "   TALKIE_ALLOW_STALE=1 set — continuing."
fi

"$ROOT/scripts/build_app.sh" "$CONFIG"

echo "▶ Stopping any running Talkie…"
osascript -e 'quit app "Talkie"' 2>/dev/null || true
pkill -x Talkie 2>/dev/null || true

echo "▶ Installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$ROOT/Talkie.app" "$DEST"

# Register with LaunchServices so `open` doesn't fail with -600 right after the
# bundle is replaced.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$DEST" 2>/dev/null || true

echo "▶ Launching…"
sleep 0.5
open "$DEST" || { sleep 1; open "$DEST"; }
echo "✓ Talkie is running — it's a Dock app now (window opens on launch); there's"
echo "  also a 🎤 in the menu bar. First run: grant the 3 permissions, Quit & Reopen once."