#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-/Applications/Talkie.app}"
PB=/usr/libexec/PlistBuddy
SHA="$($PB -c 'Print :TalkieGitSHA' "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
DIRTY="$($PB -c 'Print :TalkieGitDirty' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILD="$($PB -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
ORIGIN="$(git -C "$ROOT" rev-parse --short=12 origin/main 2>/dev/null || echo unknown)"
echo "Installed: $SHA (build $BUILD, dirty=$DIRTY)   origin/main: $ORIGIN"
[[ "$SHA" == "$ORIGIN" && "$DIRTY" == "0" ]] && echo "✓ MATCHES origin/main" || { echo "✗ STALE / dirty"; exit 1; }
