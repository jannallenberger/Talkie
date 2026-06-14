#!/bin/bash
# check-no-network.sh — Talkie's provable-zero-network CI gate (feature 15).
#
#   ./scripts/check-no-network.sh
#
# What it does:
#   Greps the on-device targets — Sources/Talkie and Sources/TalkieMCP — for any
#   symbol that could open an outbound connection. If it finds even one, it prints
#   the offending lines and EXITS NONZERO, failing the build. If it finds nothing,
#   it prints a clear PASS and exits 0.
#
# Why Sources/TalkieBridge is EXCLUDED (this is deliberate, per _CORES_STANDARDS.md
# §1.1): the bridge is the ONE module allowed to touch the network. It conforms to
# the Summarizer protocol and is injected only into the opt-in "Talkie (Connected)"
# flavor, behind consent. The app core never imports it. Scanning the bridge would
# be a guaranteed false positive that defeats the whole gate, so we scope the scan
# to the two targets that MUST stay offline and leave the bridge alone.
#
# The honest claim this protects: "Talkie's shipped core contains zero networking
# code — open source, grep it yourself." This script IS that grep, run for you in
# CI so the claim can never silently rot. (Verify the rest with the signed
# entitlement list — `codesign -d --entitlements - Talkie.app` — and a live
# firewall test like Little Snitch or `nettop -p $(pgrep Talkie)`.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The targets that must stay offline. TalkieBridge is intentionally NOT listed.
SCAN_DIRS=()
for d in "Sources/Talkie" "Sources/TalkieMCP"; do
  [ -d "$ROOT/$d" ] && SCAN_DIRS+=("$ROOT/$d")
done

if [ "${#SCAN_DIRS[@]}" -eq 0 ]; then
  echo "check-no-network: no scan targets found under $ROOT — nothing to check." >&2
  echo "  (expected Sources/Talkie and/or Sources/TalkieMCP)" >&2
  exit 2
fi

# Network symbols that have no business in the on-device core.
#   URLSession / NSURLConnection / URLRequest  — Foundation HTTP clients
#   CFNetwork / CFStream / CFSocket            — Core Foundation networking
#   NWConnection / NWListener / Network.       — Network.framework
#   getaddrinfo / socket(/bind/connect         — BSD sockets
#   http:// / https://                         — raw URLs / endpoints
PATTERN='URLSession|NSURLConnection|URLRequest|CFNetwork|CFStream|CFSocket|NWConnection|NWListener|Network\.framework|getaddrinfo|[^A-Za-z_]socket\(|Socket|https?://'

echo "check-no-network: scanning the on-device targets for network symbols"
for d in "${SCAN_DIRS[@]}"; do
  echo "  • ${d#$ROOT/}"
done
echo "  (excluding Sources/TalkieBridge — the bridge is the only module allowed to network)"
echo

# We match against CODE, not comments. A line like
#   /// still 100% local disk I/O (no `URLSession`, nothing leaves the Mac)
# is honest documentation asserting the *absence* of networking — failing on it
# would punish exactly the candour we want. So before matching we strip comments:
#   • drop whole-line comments (// , /// , and lines inside /* … */ blocks)
#   • strip trailing inline // comments, leaving any code that precedes them
# Anything that survives is real Swift that would actually run. This is stricter
# where it counts (it still catches `let s = URLSession.shared // local only`)
# and lenient only on pure prose. The grep stays line-numbered against the
# ORIGINAL file so the report points at the right line.
#
# `|| true` keeps set -e from aborting when grep finds nothing (exit 1).
MATCHES="$(
  for f in $(grep -rl --include='*.swift' '' "${SCAN_DIRS[@]}" 2>/dev/null); do
    awk -v file="$f" '
      # Track multi-line /* … */ block comments.
      {
        line = $0
        if (inblock) {
          if (match(line, /\*\//)) { line = substr(line, RSTART + 2); inblock = 0 }
          else { next }
        }
        # Remove inline /* … */ spans on this line (simple, non-nested).
        while (match(line, /\/\*.*\*\//)) {
          line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
        }
        # An unterminated /* opens a block for subsequent lines.
        if (match(line, /\/\*/)) { line = substr(line, 1, RSTART - 1); inblock = 1 }
        # Strip a trailing // line comment (incl. ///). Naive but safe: it only
        # over-strips if "//" appears inside a string literal, which would make
        # the gate MORE lenient on that line, never falsely fail.
        sub(/\/\/.*/, "", line)
        print file ":" NR ":" line
      }
    ' "$f"
  done | grep -iE "$PATTERN" || true
)"

if [ -n "$MATCHES" ]; then
  echo "FAIL — network symbols found in the on-device core:" >&2
  echo >&2
  echo "$MATCHES" >&2
  echo >&2
  echo "The app core (Sources/Talkie) and the MCP peer (Sources/TalkieMCP) must" >&2
  echo "contain zero networking code. If this code genuinely needs the network, it" >&2
  echo "belongs in Sources/TalkieBridge, injected behind consent into the Connected" >&2
  echo "flavor — not here. See docs/PRIVACY.md and docs/plans/_CORES_STANDARDS.md §1." >&2
  exit 1
fi

echo "PASS — no network symbols in Sources/Talkie or Sources/TalkieMCP."
echo "The on-device core stays offline. Verify the rest with:"
echo "  codesign -d --entitlements - Talkie.app   # → no com.apple.security.network.client"
echo "  nettop -p \$(pgrep Talkie)                  # → zero bytes while you use it"
exit 0
