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
echo "✓ Talkie is running — it's a Dock app now (window opens on launch); there's"
echo "  also a 🎤 in the menu bar. First run: grant the 3 permissions, Quit & Reopen once."