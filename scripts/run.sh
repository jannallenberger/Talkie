#!/bin/bash
# Build the .app, (re)launch it as a menu-bar app.
#   ./scripts/run.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"

"$ROOT/scripts/build_app.sh" "$CONFIG"

echo "▶ Relaunching…"
osascript -e 'quit app "Talkie"' 2>/dev/null || true
pkill -x Talkie 2>/dev/null || true
sleep 0.5
open "$ROOT/Talkie.app"
echo "✓ Talkie is running — look for the microphone in your menu bar."
