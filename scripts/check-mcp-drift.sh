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
# fails LOUDLY on any mismatch, printing the offending diff. It also checks that
# the server's advertised version (serverInfo in MCPServer.swift) matches the
# manifest version, because L10's version bump must move both in lockstep.
#
# Zero dependencies: bash + grep + awk + sort/comm, all POSIX. Runs on the cheap
# ubuntu `gates` CI job alongside check-no-network.sh. No Swift build required —
# it reads source text, so it's fast and always available.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/Sources/TalkieMCP/MCPServer.swift"
MANIFEST="$ROOT/connector/manifest.json"
SETTINGS="$ROOT/Sources/Talkie/SettingsView.swift"

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

for f in "$SERVER" "$MANIFEST" "$SETTINGS"; do
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

# --- Version lockstep: serverInfo (MCPServer.swift) == manifest version ----------
server_ver="$(grep -oE '"serverInfo":[[:space:]]*\["name":[[:space:]]*"talkie",[[:space:]]*"version":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$SERVER" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
manifest_ver="$(grep -oE '"version":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$MANIFEST" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

if [ -z "$server_ver" ]; then note "✗ could not read serverInfo version from $SERVER"; fail=1; fi
if [ -z "$manifest_ver" ]; then note "✗ could not read version from $MANIFEST"; fail=1; fi
if [ -n "$server_ver" ] && [ -n "$manifest_ver" ]; then
  if [ "$server_ver" != "$manifest_ver" ]; then
    note "✗ version drift: serverInfo=$server_ver  manifest=$manifest_ver (must move in lockstep)"
    fail=1
  else
    note "version: $server_ver (serverInfo == manifest)"
  fi
fi

if [ "$fail" -ne 0 ]; then
  note "✗ MCP drift check FAILED."
  exit 1
fi

note "✓ MCP drift check passed — $n_specs tools agree across toolSpecs, manifest, and chips; version $server_ver in lockstep."
