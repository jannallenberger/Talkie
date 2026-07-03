#!/bin/bash
# check-no-network.sh — Talkie's provable-zero-network CI gate (feature 15).
#
#   ./scripts/check-no-network.sh
#
# What it does:
#   Greps the on-device targets — Sources/Talkie and Sources/TalkieMCP (plus the
#   shared TalkieFileKit + TalkieCLI, which also ship inside the app bundle) — for
#   any symbol that could open an outbound connection. If it finds even one, it
#   prints the offending lines and EXITS NONZERO, failing the build. If it finds
#   nothing, it prints a clear PASS and exits 0.
#
# Why Sources/TalkieBridge is EXCLUDED (this is deliberate, per _CORES_STANDARDS.md
# §1.1): the bridge is a module allowed to touch the network. It conforms to
# the Summarizer protocol and is injected only into the opt-in "Talkie (Connected)"
# flavor, behind consent. The app core never imports it. Scanning the bridge would
# be a guaranteed false positive that defeats the whole gate, so we scope the scan
# to the two targets that MUST stay offline and leave the bridge alone.
#
# Sources/TalkieUpdater is EXCLUDED for the same reason: it's the in-app "update
# from GitHub" module, compiled in ONLY for the dev-tools flavor (TALKIE_DEV_TOOLS)
# and never linked into the public build. Like the bridge, the core never imports
# it, so the shipped app still contains zero update/network code.
#
# ── HARD bans vs SOFT (audited-exception) matches ───────────────────────────────
# Not every match is equal. We split the scan into two tiers:
#
#   HARD — real network-client APIs that have NO legitimate place in the on-device
#     core (URLSession, NWConnection, getaddrinfo, the bare socket() call, …). A
#     HARD hit ALWAYS fails. No comment, no marker, nothing can excuse it — if the
#     core genuinely needs one, it belongs in Sources/TalkieBridge behind consent.
#
#   SOFT — two broad substrings (`Socket`, `https?://`) that are usually network
#     smells but have narrow, honest, on-device uses: own-pid socket introspection
#     for the "we opened zero sockets" proof panel (libproc `PROC_PIDFDSOCKETINFO`,
#     which contains the substring "Socket"), and a browser-handoff / repo URL that
#     is opened in the user's browser, never fetched in-process. A SOFT hit fails
#     UNLESS the line carries an explicit, reason-tagged audit marker (below).
#
# ── The audit marker ────────────────────────────────────────────────────────────
# A SOFT match is waved through ONLY if the line ends with a marker of the form:
#
#     // talkie:no-network(<reason>)
#
# where <reason> is one of exactly two allow-listed reasons:
#
#   browser-handoff  — a URL string that is handed to the user's browser (e.g. via
#                      NSWorkspace.open) or shown as text. It is NEVER fetched by
#                      Talkie itself; no in-process request is made. This is how the
#                      repo/"grep it yourself" URL (feature 17-adjacent) can live in
#                      the core without the core making a request.
#   self-inspection  — libproc / proc_pidinfo socket-introspection code that reads
#                      THIS process's own file descriptors to PROVE no sockets are
#                      open. It inspects; it never connects. (Enables feature I5.)
#
# Any other reason string is REJECTED and fails the build — you cannot invent a new
# excuse inline; widening the allow-list is a deliberate, reviewed edit to THIS file.
# Marked lines are additionally re-checked against the HARD tier: a marker can never
# excuse a URLSession. And every honoured exception is PRINTED in the PASS report
# (see below) — the mechanism makes exceptions LOUDER, not quieter. Nothing is
# silently waved through: if you add one, it shows up in every green CI log.
#
# ── The raw-line URL match (loophole fix) ───────────────────────────────────────
# We match `Socket` against the COMMENT-STRIPPED line but `https?://` against the
# RAW, pre-strip line. That asymmetry is deliberate and closes a real hole: the
# trailing-comment strip removes everything from `//` onward, and `https://` CONTAINS
# a `//`, so a string literal like `let repo = "https://github.com/…/Talkie"` used to
# be silently gutted to `let repo = "https:` before matching and slipped through the
# gate entirely — a URL shipping INVISIBLE to the wall, which is worse than one that
# fails loudly. Matching the raw line for URLs fixes that. It is safe because the
# scanned targets currently contain ZERO `https?://` occurrences (even in comments),
# so the only cost is that a future doc-comment link will need a `browser-handoff`
# marker — loud beats invisible.
#
# The honest claim this protects: "Talkie's shipped core contains zero networking
# code — open source, grep it yourself." This script IS that grep, run for you in
# CI so the claim can never silently rot. (Verify the rest with the signed
# entitlement list — `codesign -d --entitlements - Talkie.app` — and a live
# firewall test like Little Snitch or `nettop -p $(pgrep Talkie)`.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The targets that must stay offline. TalkieBridge and TalkieUpdater (the two
# network-allowed, non-default-flavor modules) are intentionally NOT listed.
# TalkieFileKit (shared file-transcription kit) and TalkieCLI (the `talkie` CLI)
# are on-device, network-free, and ship inside the app bundle, so they are held to
# the same zero-network bar and scanned here too.
SCAN_DIRS=()
for d in "Sources/Talkie" "Sources/TalkieMCP" "Sources/TalkieFileKit" "Sources/TalkieCLI"; do
  [ -d "$ROOT/$d" ] && SCAN_DIRS+=("$ROOT/$d")
done

if [ "${#SCAN_DIRS[@]}" -eq 0 ]; then
  echo "check-no-network: no scan targets found under $ROOT — nothing to check." >&2
  echo "  (expected Sources/Talkie and/or Sources/TalkieMCP)" >&2
  exit 2
fi

# The scan patterns (HARD / SOFT / marker) are defined as awk string literals inside
# the awk program's BEGIN block below, NOT passed via `awk -v`. That is deliberate:
# `awk -v` applies C-style backslash unescaping to the value, so a regex like
# `socket\(` would arrive as `socket(` and blow up as an "illegal primary" on BSD
# awk. To sidestep escaping entirely we (a) author the patterns inline and (b) use
# character classes `[(]` / `[.]` instead of `\(` / `\.`, which need no backslash and
# behave identically on gawk (ubuntu CI) and BSD awk (macOS). Subjects are matched
# case-insensitively via tolower() on the subject, so the patterns are written to
# match lowercased text.

echo "check-no-network: scanning the on-device targets for network symbols"
for d in "${SCAN_DIRS[@]}"; do
  echo "  • ${d#$ROOT/}"
done
echo "  (excluding Sources/TalkieBridge + Sources/TalkieUpdater — the network-allowed,"
echo "   non-default-flavor modules the public build never links)"
echo

# We match against CODE, not comments. A line like
#   /// still 100% local disk I/O (no `URLSession`, nothing leaves the Mac)
# is honest documentation asserting the *absence* of networking — failing on it
# would punish exactly the candour we want. So before matching we strip comments:
#   • drop whole-line comments (// , /// , and lines inside /* … */ blocks)
#   • strip trailing inline // comments, leaving any code that precedes them
# Anything that survives is real Swift that would actually run. This is stricter
# where it counts (it still catches `let s = URLSession.shared // local only`)
# and lenient only on pure prose. The awk stays line-numbered against the ORIGINAL
# file so the report points at the right line.
#
# All tiers are evaluated inside one awk pass so it can see the RAW line, the
# comment-stripped line, and any audit marker at once (the URL-vs-Socket asymmetry
# and the marker routing all need the raw text alongside the stripped text). awk
# emits tagged records on stdout:
#   VIOLATION:<file>:<line>:<why>:<text>
#   EXCEPTION:<file>:<line>:<reason>:<text>
# and the bash below turns those into the FAIL block or the loud PASS report.
#
# Portable: plain POSIX awk (match/substr/sub/tolower/RSTART/RLENGTH) + grep -rl.
# No GNU/BSD-only idioms, so it behaves identically on the ubuntu CI runner.
#
# `|| true` keeps set -e from aborting when grep -rl finds no files.
SCAN_OUT="$(
  for f in $(grep -rl --include='*.swift' '' "${SCAN_DIRS[@]}" 2>/dev/null); do
    awk -v file="$f" '
      # Case-insensitive regex test: lowercase the subject, match a lowercase pattern.
      function imatch(subject, re) { return (tolower(subject) ~ re) }
      BEGIN {
        # HARD — real network-client symbols that can NEVER be excused:
        #   URLSession / NSURLConnection / URLRequest  — Foundation HTTP clients
        #   CFNetwork / CFStream / CFSocket            — Core Foundation networking
        #   NWConnection / NWListener / Network.framework — Network.framework
        #   getaddrinfo / socket(                       — BSD sockets (bare socket() call)
        # (lowercase; [(] and [.] avoid backslash-escaping portability traps)
        HARD  = "urlsession|nsurlconnection|urlrequest|cfnetwork|cfstream|cfsocket|nwconnection|nwlistener|network[.]framework|getaddrinfo|[^a-z_]socket[(]"
        # SOFT — broad substrings with narrow honest on-device uses; excusable ONLY
        # via a valid audit marker (see header). `Socket` is matched against the
        # comment-stripped code; `https?://` against the RAW line (the loophole fix).
        SOFT_SOCKET = "socket"
        SOFT_URL    = "https?://"
        # The audit marker and its allow-listed reasons. Any other reason fails.
        MARKER = "// talkie:no-network[(][a-z-]+[)]"
      }
      {
        raw = $0          # untouched original — used for the URL match + marker
        line = $0         # becomes the comment-stripped code below

        # ── Detect an audit marker on the RAW line BEFORE stripping comments ──
        # (the marker itself lives in a // comment, so it must be read here).
        reason = ""
        has_marker = 0
        bad_reason = ""
        if (match(raw, MARKER)) {
          has_marker = 1
          # Extract the (…) reason from the matched marker span.
          m = substr(raw, RSTART, RLENGTH)
          sub(/^\/\/ talkie:no-network\(/, "", m)
          sub(/\)$/, "", m)
          reason = m
          if (reason != "browser-handoff" && reason != "self-inspection") {
            bad_reason = reason
          }
        }

        # ── Comment-strip `line` (same logic the gate has always used) ──
        # Track multi-line /* … */ block comments.
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
        # over-strips if "//" appears inside a string literal, which for the HARD
        # and Socket tiers only makes the gate MORE lenient, never falsely fail.
        # (URLs are matched on the RAW line precisely so this strip cannot hide
        # an https:// literal — see the header.)
        sub(/\/\/.*/, "", line)

        # ── Tier 1: HARD — always fatal, marker or not. ──
        if (imatch(line, HARD)) {
          print "VIOLATION:" file ":" NR ":hard-network-api:" raw
          next
        }

        # ── An invalid reason tag is itself a failure (before we let any
        #    marker excuse a SOFT hit). You cannot smuggle in a new excuse. ──
        if (has_marker && bad_reason != "") {
          print "VIOLATION:" file ":" NR ":bad-marker-reason(" bad_reason "):" raw
          next
        }

        # ── Tier 2: SOFT — Socket (stripped) or https?:// (RAW line). ──
        soft_hit = ""
        if (imatch(line, SOFT_SOCKET)) soft_hit = "Socket"
        if (imatch(raw,  SOFT_URL))    soft_hit = (soft_hit == "" ? "url" : soft_hit "+url")

        if (soft_hit != "") {
          if (has_marker) {
            # Valid marker (bad reasons already rejected above): audited exception.
            print "EXCEPTION:" file ":" NR ":" reason ":" raw
          } else {
            print "VIOLATION:" file ":" NR ":soft-network-smell(" soft_hit "):" raw
          }
          next
        }

        # A marker on a line with NO network smell at all is pointless but harmless;
        # we do not fail it (keeps the marker from becoming a footgun on refactors).
      }
    ' "$f"
  done || true
)"

VIOLATIONS="$(printf '%s\n' "$SCAN_OUT" | grep '^VIOLATION:' || true)"
EXCEPTIONS="$(printf '%s\n' "$SCAN_OUT" | grep '^EXCEPTION:' || true)"

if [ -n "$VIOLATIONS" ]; then
  echo "FAIL — network symbols found in the on-device core:" >&2
  echo >&2
  # Reformat VIOLATION:<file>:<line>:<why>:<text> → "<file>:<line>: [<why>] <text>"
  printf '%s\n' "$VIOLATIONS" | sed 's/^VIOLATION://' | while IFS= read -r rec; do
    f="${rec%%:*}"; rest="${rec#*:}"
    ln="${rest%%:*}"; rest="${rest#*:}"
    why="${rest%%:*}"; txt="${rest#*:}"
    printf '  %s:%s  [%s]%s\n' "${f#$ROOT/}" "$ln" "$why" "$txt" >&2
  done
  echo >&2
  echo "The app core (Sources/Talkie) and the MCP peer (Sources/TalkieMCP) must" >&2
  echo "contain zero networking code. Real network-client APIs (URLSession, NWConnection," >&2
  echo "getaddrinfo, socket(), …) can never be excused. The broad smells 'Socket' and" >&2
  echo "'https?://' may carry a reviewed audit marker" >&2
  echo "    // talkie:no-network(browser-handoff)   — a URL opened in the user's browser, never fetched" >&2
  echo "    // talkie:no-network(self-inspection)    — libproc own-pid socket introspection (proves zero sockets)" >&2
  echo "but any other reason tag is rejected here. If this code genuinely needs the" >&2
  echo "network, it belongs in Sources/TalkieBridge, injected behind consent into the" >&2
  echo "Connected flavor — not here. See docs/PRIVACY.md and docs/plans/_CORES_STANDARDS.md §1." >&2
  exit 1
fi

echo "PASS — no unaudited network symbols in the on-device targets"
echo "  (Sources/Talkie, Sources/TalkieMCP, Sources/TalkieFileKit, Sources/TalkieCLI)."

if [ -n "$EXCEPTIONS" ]; then
  # The non-negotiable part: every honoured exception is surfaced, verbatim, in the
  # green log. An exception you cannot see is an exception nobody audits.
  COUNT="$(printf '%s\n' "$EXCEPTIONS" | grep -c '^EXCEPTION:')"
  echo
  echo "$COUNT audited exception(s) — read them:"
  printf '%s\n' "$EXCEPTIONS" | sed 's/^EXCEPTION://' | while IFS= read -r rec; do
    f="${rec%%:*}"; rest="${rec#*:}"
    ln="${rest%%:*}"; rest="${rest#*:}"
    reason="${rest%%:*}"; txt="${rest#*:}"
    printf '  %s:%s  (%s)%s\n' "${f#$ROOT/}" "$ln" "$reason" "$txt"
  done
  echo
  echo "Each is waved through ONLY because of its // talkie:no-network(reason) marker."
  echo "'browser-handoff' = a URL opened in the user's browser, never fetched in-process."
  echo "'self-inspection' = libproc own-pid socket introspection that proves zero sockets."
fi

echo
echo "The on-device core stays offline. Verify the rest with:"
echo "  codesign -d --entitlements - Talkie.app   # → no com.apple.security.network.client"
echo "  nettop -p \$(pgrep Talkie)                  # → zero bytes while you use it"
exit 0
