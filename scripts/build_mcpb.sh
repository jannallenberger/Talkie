#!/usr/bin/env bash
set -euo pipefail

# Builds the Talkie Desktop connector (.mcpb) — a one-click Claude Desktop install
# that bundles the standalone `talkie-mcp` server with its manifest. 100% local,
# no network. Install: Claude Desktop → Settings → Extensions → Install Extension…
# → pick the produced Talkie.mcpb.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/connector/Talkie.mcpb"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Fail fast before packaging: a .mcpb built from a drifted manifest would ship a lie
# (wrong tool list or a version that won't trigger a Desktop upgrade). The gate is
# pure text, no build, so it's cheap to run here as insurance for local builds that
# skip CI.
echo "› Checking MCP drift…"
"$ROOT/scripts/check-mcp-drift.sh"

echo "› Building talkie-mcp (release)…"
swift build -c release --product talkie-mcp --package-path "$ROOT"
BIN="$ROOT/.build/release/talkie-mcp"
[ -x "$BIN" ] || { echo "✗ talkie-mcp binary not found at $BIN"; exit 1; }

echo "› Assembling bundle…"
mkdir -p "$STAGE/server"
cp "$ROOT/connector/manifest.json" "$STAGE/manifest.json"
cp "$BIN" "$STAGE/server/talkie-mcp"
chmod +x "$STAGE/server/talkie-mcp"
# Optional on-brand icon (ignored if the master art isn't present).
if [ -f "$ROOT/icon_assets/talkie_parrot_transparent.png" ]; then
  cp "$ROOT/icon_assets/talkie_parrot_transparent.png" "$STAGE/icon.png"
fi

echo "› Zipping → $OUT"
mkdir -p "$ROOT/connector"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" . )

echo "✓ Built $OUT"
echo "  Install in Claude Desktop: Settings → Extensions → Install Extension… → $OUT"
