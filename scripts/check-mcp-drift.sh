#!/usr/bin/env bash
# check-mcp-drift.sh — lock the three hand-maintained copies of the MCP tool set
# together, plus the server/manifest version pair.
#
#   ./scripts/check-mcp-drift.sh
#
# The tool surface is spelled out in THREE places that must never disagree:
#
#   1. Sources/TalkieMCP/MCPServer.swift   — the `spec("<name>", …)` lines in
#      `toolSpecs` (the actual JSON-RPC tool list the server advertises).
#   2. connector/manifest.json            — the `tools[]` array (what Claude
#      Desktop / the registry describe to the user).
#   3. Sources/Talkie/SettingsView.swift  — the `toolChips` array (the in-app
#      "What Claude can do" disclosure strip).
#
# If someone adds a tool to one and forgets the others — or renames one — the
# connector lies about its surface. This gate greps each list, sorts it, and
# fails LOUDLY on any mismatch, printing the offending diff.
#
# It also enforces two things that had ALREADY silently drifted for the separate
# Claude Code plugin/marketplace distribution, breaking the dictionary tools for
# external users:
#
#   • Plugin skill coverage — claude-plugin/talkie/skills/talkie/SKILL.md teaches
#     Claude the tool surface; every server tool must appear in it (it was frozen
#     at "the six tools" while the server had eighteen).
#   • Version lockstep across all FIVE copies of the connector version: serverInfo
#     (MCPServer.swift), manifest (.mcpb), plugin.json, marketplace.json, and
#     Brand.mcpConnectorVersion (the in-app copy the connector card compares an
#     installed connector against to detect staleness). A bump must move all five —
#     see scripts/bump-connector-version.sh.
#
# Zero dependencies: bash + grep + awk + sort/comm, all POSIX. Runs on the cheap
# ubuntu `gates` CI job alongside check-no-network.sh. No Swift build required —
# it reads source text, so it's fast and always available.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/Sources/TalkieMCP/MCPServer.swift"
MANIFEST="$ROOT/connector/manifest.json"
SETTINGS="$ROOT/Sources/Talkie/SettingsView.swift"
# The Claude Code plugin/marketplace install path (a SEPARATE distribution from the
# .mcpb) and the in-app version constant. All three carry the connector version, and
# the plugin's SKILL.md teaches Claude the tool surface — both had silently drifted
# (skill stuck at "six tools", versions at 0.1.1) while the .mcpb moved to 0.4.0.
PLUGIN="$ROOT/claude-plugin/talkie/.claude-plugin/plugin.json"
MARKETPLACE="$ROOT/.claude-plugin/marketplace.json"
DESIGN="$ROOT/Sources/Talkie/DesignSystem.swift"
PLUGIN_SKILL="$ROOT/claude-plugin/talkie/skills/talkie/SKILL.md"

fail=0
note() { printf '%s\n' "$*"; }
die_diff() {
  # $1 = human label, $2 = file A name, $3 = file B name, $4 = A list, $5 = B list
  note "✗ MCP tool drift: $1"
  note "  only in $2:"
  comm -23 <(printf '%s\n' "$4") <(printf '%s\n' "$5") | sed 's/^/    /' || true
  note "  only in $3:"
  comm -13 <(printf '%s\n' "$4") <(printf '%s\n' "$5") | sed 's/^/    /' || true
  fail=1
}

for f in "$SERVER" "$MANIFEST" "$SETTINGS" "$PLUGIN" "$MARKETPLACE" "$DESIGN" "$PLUGIN_SKILL"; do
  [ -f "$f" ] || { note "✗ missing file: $f"; exit 1; }
done

# (1) toolSpecs: every `spec("<name>", …)` — the first quoted arg on a spec( line.
specs="$(grep -oE 'spec\("[a-z_]+"' "$SERVER" | sed -E 's/spec\("([a-z_]+)"/\1/' | sort -u)"

# (2) manifest tools[]: every `"name": "<name>"` INSIDE the tools[] array only.
# The manifest has other `"name":` keys (the top-level server name "talkie",
# author.name "Talkie") that are NOT tools, so we slice out the tools array first
# (from the `"tools": [` line to its closing `]`) with awk, then grep names from
# that slice. This keeps the check honest: only the tool entries are compared.
manifest="$(awk '/"tools":[[:space:]]*\[/{f=1} f{print} f&&/^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/{exit}' "$MANIFEST" \
  | grep -oE '"name":[[:space:]]*"[a-z_]+"' | sed -E 's/.*"([a-z_]+)"$/\1/' | sort -u)"

# (3) SettingsView toolChips: every `.init(name: "<name>", …)` chip entry.
chips="$(grep -oE '\.init\(name:[[:space:]]*"[a-z_]+"' "$SETTINGS" | sed -E 's/.*"([a-z_]+)"$/\1/' | sort -u)"

n_specs=$(printf '%s\n' "$specs" | grep -c . || true)
n_manifest=$(printf '%s\n' "$manifest" | grep -c . || true)
n_chips=$(printf '%s\n' "$chips" | grep -c . || true)

note "MCP tool sets: toolSpecs=$n_specs  manifest=$n_manifest  chips=$n_chips"

# A sanity floor: if any extractor found nothing, the anchor moved — fail rather
# than pass a vacuously-equal empty-vs-empty comparison.
if [ "$n_specs" -eq 0 ] || [ "$n_manifest" -eq 0 ] || [ "$n_chips" -eq 0 ]; then
  note "✗ an extractor matched zero tools — a source anchor drifted (see comments in this script)."
  exit 1
fi

[ "$specs" = "$manifest" ] || die_diff "toolSpecs vs manifest.json tools[]" "toolSpecs" "manifest" "$specs" "$manifest"
[ "$specs" = "$chips" ]    || die_diff "toolSpecs vs SettingsView toolChips"  "toolSpecs" "chips"    "$specs" "$chips"

# --- Plugin skill coverage: the marketplace skill must mention every tool ----------
# The Claude Code plugin ships claude-plugin/talkie/skills/talkie/SKILL.md, which
# TEACHES Claude the tool surface. If a tool exists in the server but not the skill,
# a marketplace-installed Claude is told the tool doesn't exist — exactly how the
# skill drifted to "six tools" while the server advertised eighteen. Assert every
# toolSpecs name appears (whole-word) in the skill.
missing_in_skill=""
for t in $specs; do
  grep -qw "$t" "$PLUGIN_SKILL" || missing_in_skill="$missing_in_skill $t"
done
if [ -n "$missing_in_skill" ]; then
  note "✗ plugin SKILL.md is missing tools:$missing_in_skill"
  note "  (add them to $PLUGIN_SKILL — the marketplace install teaches Claude from this file)"
  fail=1
else
  note "✓ plugin SKILL.md covers all $n_specs tools"
fi

# --- Version lockstep: every copy of the connector version moves together ---------
# serverInfo (MCPServer.swift) == manifest (.mcpb) == plugin.json == marketplace.json
# == Brand.mcpConnectorVersion (the in-app copy the connector card trusts to judge an
# installed connector stale). Any bump must move all five — use
# scripts/bump-connector-version.sh so this never drifts silently again.
server_ver="$(grep -oE '"serverInfo":[[:space:]]*\["name":[[:space:]]*"talkie",[[:space:]]*"version":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$SERVER" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
manifest_ver="$(grep -oE '"version":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$MANIFEST" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
plugin_ver="$(grep -oE '"version":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$PLUGIN" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
market_ver="$(grep -oE '"version":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$MARKETPLACE" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
brand_ver="$(grep -oE 'mcpConnectorVersion[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$DESIGN" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

ver_fail=0
for pair in "serverInfo:$server_ver" "manifest:$manifest_ver" "plugin.json:$plugin_ver" \
            "marketplace.json:$market_ver" "Brand.mcpConnectorVersion:$brand_ver"; do
  name="${pair%%:*}"; val="${pair#*:}"
  if [ -z "$val" ]; then note "✗ could not read connector version: $name"; ver_fail=1; fi
done
canon="$manifest_ver"
if [ -n "$canon" ]; then
  for pair in "serverInfo:$server_ver" "plugin.json:$plugin_ver" \
              "marketplace.json:$market_ver" "Brand.mcpConnectorVersion:$brand_ver"; do
    name="${pair%%:*}"; val="${pair#*:}"
    if [ -n "$val" ] && [ "$val" != "$canon" ]; then
      note "✗ connector version drift: $name=$val != manifest=$canon (all five must match)"
      ver_fail=1
    fi
  done
fi
if [ "$ver_fail" -ne 0 ]; then
  fail=1
else
  note "version: $canon (serverInfo == manifest == plugin == marketplace == Brand)"
fi

if [ "$fail" -ne 0 ]; then
  note "✗ MCP drift check FAILED."
  exit 1
fi

note "✓ MCP drift check passed — $n_specs tools agree across toolSpecs, manifest, chips, and the plugin skill; connector version $canon in lockstep across all five copies."
