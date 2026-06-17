#!/bin/bash
# release_dev.sh — publish a Talkie "dev channel" build for collaborators.
#
#   ./scripts/release_dev.sh
#
# This is the SOURCE side of the in-app updater (Developer ▸ App updates). It:
#   1. stamps the build number (= commit count) into CFBundleVersion,
#   2. builds the DEV-TOOLS flavor (TALKIE_DEV_TOOLS=1 → the updater is compiled
#      in, so the published build can itself update next time),
#   3. signs with a STABLE identity (so the recipient's mic/Accessibility grants
#      persist across updates — ad-hoc would re-prompt every time),
#   4. zips Talkie.app and uploads it to a GitHub Release tagged `dev-<build>`.
#
# A collaborator running a dev build then sees "Build N available" and installs
# it in-app — no rebuilding from source, no toolchain required on their Mac.
#
# Requirements: `gh` installed + authenticated (gh auth login), and ideally an
# Apple Development or Developer ID identity in your keychain (or TALKIE_SIGN_ID).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OWNER_REPO="jannallenberger/Talkie"
PLIST="Resources/Info.plist"

# --- 0. Preconditions ---------------------------------------------------------
command -v gh >/dev/null 2>&1 || {
  echo "✗ GitHub CLI (gh) not found. Install it: brew install gh && gh auth login" >&2
  exit 1
}
gh auth status >/dev/null 2>&1 || {
  echo "✗ gh is not authenticated. Run: gh auth login" >&2
  exit 1
}

BUILD="$(git rev-list --count HEAD)"
TAG="dev-${BUILD}"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
ASSET="Talkie-${TAG}.zip"

echo "▶ Talkie dev release ${TAG}  (version ${SHORT_VERSION}, build ${BUILD})"

# A STABLE signing identity keeps the recipient's TCC permissions across updates.
# Ad-hoc ("-") changes its hash every build, so they'd re-grant mic/Accessibility
# each time. Warn loudly but allow it.
if [[ -z "${TALKIE_SIGN_ID:-}" ]]; then
  DEVID="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)".*/\1/' || true)"
  APPLE_DEV="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.*)".*/\1/' || true)"
  if [[ -n "$DEVID" ]]; then
    export TALKIE_SIGN_ID="$DEVID"
  elif [[ -n "$APPLE_DEV" ]]; then
    export TALKIE_SIGN_ID="$APPLE_DEV"
  fi
fi
if [[ -n "${TALKIE_SIGN_ID:-}" ]]; then
  echo "▶ Signing identity: ${TALKIE_SIGN_ID}"
else
  echo "⚠  No stable signing identity found — this build will be ad-hoc signed."
  echo "   The recipient will have to re-grant mic + Accessibility after each update."
  echo "   Set TALKIE_SIGN_ID (Apple Development or Developer ID) to avoid that."
fi

# --- 1. Stamp the build number, build the dev-tools flavor --------------------
# build_app.sh copies Info.plist into the bundle verbatim, so stamp BEFORE building.
# Restore the committed value on exit so the working tree stays clean (it keeps
# CFBundleVersion = 1; CI / this script stamp the real number per build).
ORIG_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
restore_plist() { /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${ORIG_BUILD}" "$PLIST" >/dev/null 2>&1 || true; }
trap restore_plist EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "$PLIST"

echo "▶ Building the dev-tools flavor (in-app updater compiled in)…"
TALKIE_DEV_TOOLS=1 "$ROOT/scripts/build_app.sh" release

# --- 2. Zip the app -----------------------------------------------------------
echo "▶ Zipping ${ASSET}…"
rm -f "$ROOT/$ASSET"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$ROOT/Talkie.app" "$ROOT/$ASSET"

# Compute the zip's SHA-256 and publish it in the release notes as a
# `sha256:<hex>` line. GitHub's API exposes no per-asset digest, so this is how
# the in-app updater learns the expected hash; it enforces it fail-closed before
# de-quarantining the download (see Sources/TalkieUpdater/UpdateInstaller.swift).
SHA256="$(/usr/bin/shasum -a 256 "$ROOT/$ASSET" | awk '{print $1}')"
echo "▶ Artifact SHA-256: ${SHA256}"

# --- 3. Publish (create the release, or just re-upload the asset if it exists) -
# Embed the digest in the notes so the updater can verify the download. Keep it
# on its own line, lowercase hex — the parser (GitHubReleases.sha256(fromBody:))
# matches a line beginning `sha256:`.
COMMIT_MSG="$(git log -1 --pretty=format:'%s')"
NOTES="${COMMIT_MSG}

sha256:${SHA256}"
echo "▶ Publishing ${TAG} to ${OWNER_REPO}…"
if gh release view "$TAG" --repo "$OWNER_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ROOT/$ASSET" --repo "$OWNER_REPO" --clobber
  # Refresh the notes so the digest matches the re-uploaded asset.
  gh release edit "$TAG" --repo "$OWNER_REPO" --notes "${NOTES}"
else
  gh release create "$TAG" "$ROOT/$ASSET" \
    --repo "$OWNER_REPO" \
    --title "Talkie dev (build ${BUILD})" \
    --notes "${NOTES}" \
    --prerelease
fi

rm -f "$ROOT/$ASSET"
echo "✓ Published ${TAG} (digest sha256:${SHA256})."
echo "  Collaborators on a dev build will be offered it under Developer ▸ App updates"
echo "  (or automatically a few seconds after they next launch Talkie)."
