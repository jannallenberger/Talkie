#!/bin/bash
# fetch_diarization_models.sh — BUILD-TIME fetch of the speaker-diarization
# CoreML models (pyannote community-1, CoreML conversion by Fluid Inference).
#
#   ./scripts/fetch_diarization_models.sh [dest-root]
#
# dest-root defaults to Vendor/DiarizationModels (gitignored). Files land in
# <dest-root>/speaker-diarization/ — FluidAudio's cache folder name (Repo.diarizer.folderName) — and a
# `.fluidaudio-revision` marker holding the pinned revision is written last.
#
# This is the ONLY place the network is touched for diarization, and it runs on
# the developer's machine at build time. The shipped app never downloads: the
# models are copied into Talkie.app/Contents/Resources/DiarizationModels by
# scripts/build_app.sh and loaded read-only from there.
#
# Supply chain:
#   • REVISION is an immutable Hugging Face commit (the same pin FluidAudio
#     0.18.3 uses: ModelNames.Repo.diarizer.revision). Never `main`.
#   • Every file is verified against the committed SHA-256 manifest
#     scripts/diarization-models.sha256. The manifest IS the file list: nothing
#     outside it is fetched. A mismatch deletes the bad file and fails loudly.
#   • Idempotent: files already present with the right hash are not re-fetched.
#
# Bumping FluidAudio: if its diarizer revision changes, update REVISION and
# regenerate the manifest (download, `shasum -a 256`, cross-check the LFS oids
# from the HF tree API), then re-run this script. TalkieDiarization rejects a
# models folder whose marker does not match the linked FluidAudio's pin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="FluidInference/speaker-diarization-coreml"
REVISION="df2625ac79a7ac6b65ad868fee6d80f320da4232"
MANIFEST="$ROOT/scripts/diarization-models.sha256"
DEST_ROOT="${1:-$ROOT/Vendor/DiarizationModels}"
DEST="$DEST_ROOT/speaker-diarization"
MARKER="$DEST/.fluidaudio-revision"

[[ -f "$MANIFEST" ]] || { echo "✗ manifest missing: $MANIFEST" >&2; exit 1; }

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$DEST"

# Fast path: marker matches and every file verifies → nothing to do.
all_ok=1
while read -r want rel; do
  [[ -z "${want:-}" || "$want" == \#* ]] && continue
  f="$DEST/$rel"
  if [[ ! -f "$f" ]] || [[ "$(sha_of "$f")" != "$want" ]]; then all_ok=0; break; fi
done < "$MANIFEST"
if [[ $all_ok -eq 1 && -f "$MARKER" && "$(tr -d '[:space:]' < "$MARKER")" == "$REVISION" ]]; then
  echo "✓ Diarization models present and verified ($DEST)"
  exit 0
fi

echo "▶ Fetching diarization models ($REPO @ ${REVISION:0:12}) → $DEST"
# Invalidate the marker while files are in flux, so a half-fetched folder is
# never mistaken for a complete one.
rm -f "$MARKER"

fetched=0
while read -r want rel; do
  [[ -z "${want:-}" || "$want" == \#* ]] && continue
  case "$rel" in
    /*|*..*) echo "✗ unsafe path in manifest: $rel" >&2; exit 1 ;;
  esac
  f="$DEST/$rel"
  if [[ -f "$f" && "$(sha_of "$f")" == "$want" ]]; then continue; fi
  mkdir -p "$(dirname "$f")"
  tmp="$f.partial"
  rm -f "$tmp"
  curl --fail --location --silent --show-error --retry 3 \
       --proto '=https' --tlsv1.2 \
       -o "$tmp" "https://huggingface.co/$REPO/resolve/$REVISION/$rel"
  got="$(sha_of "$tmp")"
  if [[ "$got" != "$want" ]]; then
    rm -f "$tmp"
    echo "✗ SHA-256 MISMATCH for $rel" >&2
    echo "    expected $want" >&2
    echo "    got      $got" >&2
    echo "  Refusing to use these models. Check the pin/manifest before retrying." >&2
    exit 1
  fi
  mv -f "$tmp" "$f"
  fetched=$((fetched + 1))
done < "$MANIFEST"

# Final full verification pass (also catches files modified in place).
while read -r want rel; do
  [[ -z "${want:-}" || "$want" == \#* ]] && continue
  if [[ "$(sha_of "$DEST/$rel")" != "$want" ]]; then
    echo "✗ verification failed for $rel" >&2; exit 1
  fi
done < "$MANIFEST"

printf '%s\n' "$REVISION" > "$MARKER"
echo "✓ Diarization models verified ($fetched file(s) fetched) → $DEST"
