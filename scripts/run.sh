#!/bin/bash
# Build, install ONE canonical copy to /Applications, and launch it.
# Using a single stable location (+ the stable signature from build_app.sh) is
# what makes macOS permissions persist across rebuilds.
#   ./scripts/run.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
DEST="/Applications/Talkie.app"

"$ROOT/scripts/build_app.sh" "$CONFIG"

echo "▶ Stopping any running Talkie…"
osascript -e 'quit app "Talkie"' 2>/dev/null || true
pkill -x Talkie 2>/dev/null || true

echo "▶ Installing to $DEST…"
rm -rf "$DEST"
cp -R "$ROOT/Talkie.app" "$DEST"

echo "▶ Launching…"
open "$DEST"
echo "✓ Talkie is running from /Applications — look for the 🎤 in your menu bar."
echo "  (First run: grant the 3 permissions in Settings, then Quit & Reopen once.)"