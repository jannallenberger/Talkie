#!/usr/bin/env bash
# check-brand-literals.sh — the rebrand-readiness guard (work package L8).
#
# WHAT IT DOES
#   Counts, per Swift file, the number of STRING LITERALS that contain the brand
#   name "Talkie" across the on-device + updater targets, and compares each count
#   against a frozen budget in scripts/brand-literal-allowlist.txt. A file whose
#   count GREW (or a file that appears with Talkie literals but is absent from the
#   allowlist) FAILS the build. This freezes the brand-literal footprint: L8
#   converted the user-visible chrome tier to the single `Brand.displayName`
#   constant (+ its two mirrors), and this guard stops the long tail from growing
#   back. See docs/REBRAND.md for the migration story.
#
# WHY A COUNT, NOT ZERO
#   A full 0-literal sweep is explicitly out of scope for L8 (it would touch ~130
#   sites and fight every concurrent package). The remaining literals are frozen at
#   today's number; the allowlist doubles as the documented burn-down ledger —
#   lower a file's number when you convert one of its literals, and the guard holds
#   you to the new floor.
#
# WHAT COUNTS
#   Only string literals: the regex requires surrounding double quotes
#   ("[^"]*Talkie[^"]*"), so bare identifiers/type names (TalkieStore, talkie-mcp,
#   talkieDebugLog) never match. Comments are stripped BEFORE counting (the same
#   comment-stripping check-no-network.sh uses), so a `// … "Talkie" …` note or a
#   MIRROR header does not inflate the count. Localizable.strings and docs are not
#   scanned — this is a Swift-source guard.
#
# SCOPE
#   Sources/{Talkie, TalkieMCP, TalkieFileKit, TalkieCLI, TalkieUpdater}.
#   (TalkieBridge is intentionally excluded — like check-no-network.sh's scope, it
#   is a non-default-flavor module; add it here only if it ever gains brand copy.)
#
# PORTABILITY
#   Plain bash + POSIX awk (match/substr/sub/gsub/RSTART/RLENGTH). No GNU/BSD-only
#   idioms, so it runs identically on the ubuntu CI gates job and on macOS.
#
# USAGE
#   bash scripts/check-brand-literals.sh            # verify against the allowlist
#   bash scripts/check-brand-literals.sh --print    # print current counts (to
#                                                   # regenerate/lower the allowlist)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALLOWLIST="$SCRIPT_DIR/brand-literal-allowlist.txt"

PRINT_ONLY=0
[ "${1:-}" = "--print" ] && PRINT_ONLY=1

SCAN_DIRS=()
for d in "Sources/Talkie" "Sources/TalkieMCP" "Sources/TalkieFileKit" "Sources/TalkieCLI" "Sources/TalkieUpdater"; do
  [ -d "$ROOT/$d" ] && SCAN_DIRS+=("$ROOT/$d")
done
if [ "${#SCAN_DIRS[@]}" -eq 0 ]; then
  echo "check-brand-literals: no scan targets found under $ROOT — nothing to check." >&2
  exit 2
fi

# Count brand string-literals per file, comment-stripped. Emits "<count> <relpath>"
# for every file with count > 0, sorted by path. Paths are repo-relative.
current_counts() {
  # `|| true` so an empty match set doesn't trip set -e.
  for f in $(grep -rl --include='*.swift' '' "${SCAN_DIRS[@]}" 2>/dev/null || true); do
    rel="${f#"$ROOT"/}"
    awk -v rel="$rel" '
      BEGIN { in_block = 0; n = 0 }
      {
        line = $0
        # ── strip comments so quoted "Talkie" inside prose does not count ──
        # 1) inside a /* … */ block: drop until the closing */ (same-line or later)
        if (in_block) {
          idx = index(line, "*/")
          if (idx == 0) { next }              # whole line still in block
          line = substr(line, idx + 2)        # keep only code after */
          in_block = 0
        }
        # 2) a /* … */ that opens on this line
        while ((s = index(line, "/*")) > 0) {
          rest = substr(line, s + 2)
          e = index(rest, "*/")
          if (e == 0) {                       # opens, does not close on this line
            line = substr(line, 1, s - 1)
            in_block = 1
            break
          } else {                            # opens and closes inline — excise it
            line = substr(line, 1, s - 1) substr(rest, e + 2)
          }
        }
        # 3) a // line/inline comment: drop from // to EOL.
        #    (Swift string literals do not contain a bare // that matters here for a
        #    brand-name count; check-no-network.sh makes the same pragmatic call.)
        c = index(line, "//")
        if (c > 0) { line = substr(line, 1, c - 1) }

        # ── count "…Talkie…" string literals on the surviving code ──
        # Repeatedly match the shortest quoted run containing Talkie.
        while (match(line, /"[^"]*Talkie[^"]*"/)) {
          n++
          line = substr(line, RSTART + RLENGTH)
        }
      }
      END { if (n > 0) printf "%d %s\n", n, rel }
    ' "$f"
  done | sort -k2
}

CURRENT="$(current_counts)"

if [ "$PRINT_ONLY" -eq 1 ]; then
  printf '%s\n' "$CURRENT"
  exit 0
fi

if [ ! -f "$ALLOWLIST" ]; then
  echo "check-brand-literals: allowlist missing at $ALLOWLIST" >&2
  echo "  regenerate with: bash scripts/check-brand-literals.sh --print > scripts/brand-literal-allowlist.txt" >&2
  exit 2
fi

# Load the allowlist into a lookup: path -> budget. Skip blank lines + # comments.
# Build a temp file of "path budget" pairs.
ALLOW_PAIRS="$(grep -vE '^\s*(#|$)' "$ALLOWLIST" | awk '{ print $2, $1 }' | sort)"

fail=0
report=""

# Check every CURRENT file against its budget.
while IFS= read -r cline; do
  [ -z "$cline" ] && continue
  ccount="${cline%% *}"
  cpath="${cline#* }"
  budget="$(printf '%s\n' "$ALLOW_PAIRS" | awk -v p="$cpath" '$1==p { print $2; exit }')"
  if [ -z "$budget" ]; then
    report="${report}  NEW   $cpath has $ccount brand literal(s) but is not on the allowlist\n"
    fail=1
  elif [ "$ccount" -gt "$budget" ]; then
    report="${report}  GREW  $cpath: $ccount brand literal(s), budget $budget\n"
    fail=1
  fi
done <<< "$CURRENT"

if [ "$fail" -eq 1 ]; then
  echo "check-brand-literals: FAIL — the brand-literal footprint grew." >&2
  printf "%b" "$report" >&2
  echo "" >&2
  echo "New user-visible \"Talkie\" text must route through Brand.displayName (app)," >&2
  echo "BrandMirror.displayName (TalkieMCP), or the updater's brandName (TalkieUpdater)" >&2
  echo "— see docs/REBRAND.md. If a literal is legitimately unavoidable, raise the file's" >&2
  echo "budget in scripts/brand-literal-allowlist.txt with a note. Converting a literal?" >&2
  echo "LOWER the budget (the allowlist is the burn-down ledger)." >&2
  exit 1
fi

total="$(printf '%s\n' "$CURRENT" | awk '{ s += $1 } END { print s+0 }')"
files="$(printf '%s\n' "$CURRENT" | grep -c . || true)"
echo "check-brand-literals: PASS — $total brand string-literal(s) across $files file(s), all within budget."
