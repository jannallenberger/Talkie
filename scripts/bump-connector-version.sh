#!/usr/bin/env bash
set -euo pipefail

# bump-connector-version.sh <x.y.z>
#
# Move ALL FIVE copies of the Talkie MCP connector version in one shot so they can
# never drift apart. Drift is not hypothetical: the marketplace plugin sat at 0.1.1
# with a "six tools" skill while the .mcpb shipped 0.4.0 with eighteen — so anyone
# installing from the marketplace got a Claude told the dictionary tools didn't exist.
#
# The five copies (all locked together by scripts/check-mcp-drift.sh):
#   1. connector/manifest.json                         — the .mcpb manifest version
#   2. claude-plugin/talkie/.claude-plugin/plugin.json — the Claude Code plugin
#   3. .claude-plugin/marketplace.json                 — the marketplace entry
#   4. Sources/TalkieMCP/MCPServer.swift               — serverInfo.version
#   5. Sources/Talkie/DesignSystem.swift               — Brand.mcpConnectorVersion
#
# After running: rebuild the .mcpb (scripts/build_mcpb.sh) and confirm lockstep
# (scripts/check-mcp-drift.sh). Uses perl -i for GNU/BSD portability (macOS + CI).

V="${1:-}"
if ! printf '%s' "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "usage: $0 <x.y.z>   (e.g. $0 0.5.0)" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/connector/manifest.json"
PLUGIN="$ROOT/claude-plugin/talkie/.claude-plugin/plugin.json"
MARKET="$ROOT/.claude-plugin/marketplace.json"
SERVER="$ROOT/Sources/TalkieMCP/MCPServer.swift"
DESIGN="$ROOT/Sources/Talkie/DesignSystem.swift"

for f in "$MANIFEST" "$PLUGIN" "$MARKET" "$SERVER" "$DESIGN"; do
  [ -f "$f" ] || { echo "✗ missing file: $f" >&2; exit 1; }
done

# JSON files: replace `"version": "x.y.z"`. This does NOT touch `"manifest_version"`
# — that key has `_` (not `"`) immediately before `version`, so the literal
# `"version":` never matches inside it.
perl -i -pe 's/("version":\s*")[0-9]+\.[0-9]+\.[0-9]+(")/${1}'"$V"'${2}/' "$MANIFEST" "$PLUGIN" "$MARKET"

# serverInfo line only (guards against any other "version": in the Swift source).
perl -i -pe 's/("version":\s*")[0-9]+\.[0-9]+\.[0-9]+(")/${1}'"$V"'${2}/ if /serverInfo/' "$SERVER"

# Brand.mcpConnectorVersion constant.
perl -i -pe 's/(mcpConnectorVersion\s*=\s*")[0-9]+\.[0-9]+\.[0-9]+(")/${1}'"$V"'${2}/' "$DESIGN"

echo "✓ set connector version to $V in all five copies."
echo "  Next: ./scripts/build_mcpb.sh && ./scripts/check-mcp-drift.sh"
