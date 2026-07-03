#!/bin/sh
# install.sh — take a Mac from nothing to a running, locally-built Talkie.
#
#   curl -fsSL https://raw.githubusercontent.com/jannallenberger/Talkie/main/scripts/install.sh | sh
#
# This is the honest from-source path: it clones (or updates) the repo into
# ~/Talkie and hands off to scripts/run.sh, which builds Talkie.app and installs
# ONE canonical copy to /Applications. It is the tinkerer / contributor route —
# for most people `brew install --cask talkie` (a notarized download) is simpler.
# See docs/INSTALL.md.
#
# What touches the network, and what does NOT:
#   The ONLY network call here is `git clone` / `git pull` — that is YOUR shell
#   fetching source on your behalf, exactly like `brew install` does. Talkie
#   itself stays provably zero-network (Resources/talkie.entitlements omits
#   com.apple.security.network.client; scripts/check-no-network.sh proves it).
#   Nothing about installing from source changes that.
#
# Two honest asterisks, stated up front so you don't discover them mid-build:
#   1. Building needs the Swift 6 toolchain with the macOS 26 SDK. If you don't
#      already have Xcode, that means Apple's Command Line Tools — a multi-GB
#      download. Talkie itself is small; the toolchain is the big part.
#   2. A Command-Line-Tools-only build works, but lacks the Liquid Glass app icon:
#      that icon is compiled by `xcrun actool`, which ships only with the full
#      Xcode app. build_app.sh detects this and skips the icon (the app is
#      otherwise identical). Install full Xcode if you want the pretty icon.
#
# Re-running this exact command is also the documented UPDATE path for a source
# install: it fast-forwards ~/Talkie and rebuilds.
#
# NOTE (repo visibility): the repo is PRIVATE today, so the curl one-liner above
# and an anonymous `git clone` only work once the repo is public (or for someone
# already authenticated to GitHub). Until then this is the contributor path.
#
# Deliberately no flags/options (no --prefix, no --branch): keep it simple. If you
# want a different location or branch, clone by hand and run scripts/run.sh.
set -eu

REPO_URL="https://github.com/jannallenberger/Talkie.git"
DEST="$HOME/Talkie"

echo "▶ Talkie from-source installer"

# ── 1. Preflight: this build only targets Apple Silicon on macOS 26+ ───────────
# Mirror the Homebrew cask's floor (Casks/talkie.rb: depends_on macos >= :tahoe,
# arch :arm64). The app is built for arm64 against the macOS 26 SDK; there is no
# Intel or older-macOS build to fall back to, so fail early and honestly.
echo "▶ Checking your Mac…"

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
  echo "✗ Talkie needs an Apple Silicon Mac (found: $ARCH)." >&2
  echo "  It's built for arm64 against the macOS 26 SDK — there's no Intel build." >&2
  exit 1
fi

# sw_vers -productVersion is like "26.1" — take the major (before the first dot).
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$OS_MAJOR" -lt 26 ]; then
  echo "✗ Talkie needs macOS 26 (Tahoe) or later (found: $(sw_vers -productVersion))." >&2
  echo "  It uses the macOS 26 on-device speech API, so earlier macOS can't run it." >&2
  exit 1
fi
echo "  ✓ Apple Silicon, macOS $(sw_vers -productVersion)."

# ── 2. Toolchain: need a Swift 6 compiler with the macOS 26 SDK ────────────────
# `xcode-select -p` succeeds once EITHER the full Xcode or the Command Line Tools
# are installed. If neither is present we can't compile, so kick off Apple's CLT
# installer and ask the user to re-run — we do NOT block waiting on it, because
# `xcode-select --install` pops an asynchronous GUI installer we can't see finish.
echo "▶ Checking for the Swift toolchain…"
if ! xcode-select -p >/dev/null 2>&1; then
  echo "⚠  No Xcode or Command Line Tools found — Talkie needs them to compile."
  echo "   Starting Apple's Command Line Tools installer now. Heads up: it's a"
  echo "   MULTI-GB download (the toolchain is the big part; Talkie itself is small)."
  xcode-select --install 2>/dev/null || true
  echo ""
  echo "   A macOS dialog should be installing the Command Line Tools. When it"
  echo "   finishes, RE-RUN this exact command and the install will continue:"
  echo ""
  echo "     curl -fsSL https://raw.githubusercontent.com/jannallenberger/Talkie/main/scripts/install.sh | sh"
  echo ""
  exit 1
fi

# actool (the Liquid Glass icon compiler) ships only with the full Xcode app, not
# the Command Line Tools. A CLT-only build is fine — it just lacks the fancy icon,
# because build_app.sh skips the icon step when actool is unavailable. Say so now
# rather than let it surprise anyone later.
if ! xcrun --find actool >/dev/null 2>&1; then
  echo "  ✓ Command Line Tools present (that's enough to build)."
  echo "  ℹ Note: the full Xcode app isn't installed, so the build will skip the"
  echo "    Liquid Glass app icon (its compiler, actool, ships only with Xcode)."
  echo "    Everything else builds normally; install Xcode later if you want the icon."
else
  echo "  ✓ Full Xcode toolchain present (Liquid Glass icon included)."
fi

# ── 3. Clone the repo, or fast-forward an existing checkout ────────────────────
# Never clobber a working tree that has local changes — the same parallel-session
# care we take with our own checkouts extends to yours. If ~/Talkie is dirty, we
# stop and let you decide, rather than risk losing your edits.
if [ -d "$DEST/.git" ]; then
  echo "▶ Updating your existing Talkie checkout at $DEST…"
  if [ -n "$(git -C "$DEST" status --porcelain)" ]; then
    echo "✗ $DEST has uncommitted local changes — refusing to touch it." >&2
    echo "  (We never overwrite a working tree that has changes you haven't saved.)" >&2
    echo "  Commit or stash them, then re-run:" >&2
    echo "      git -C \"$DEST\" stash   # or: git -C \"$DEST\" commit -am WIP" >&2
    exit 1
  fi
  # Fast-forward only: if your branch has diverged from origin we stop rather than
  # merge or reset — that's a decision for you to make, not the installer.
  if ! git -C "$DEST" pull --ff-only; then
    echo "✗ Couldn't fast-forward $DEST (your branch has diverged from origin)." >&2
    echo "  Reconcile it by hand, then re-run this command." >&2
    exit 1
  fi
else
  if [ -e "$DEST" ]; then
    echo "✗ $DEST already exists but isn't a git checkout — refusing to overwrite it." >&2
    echo "  Move it aside, then re-run this command." >&2
    exit 1
  fi
  echo "▶ Cloning Talkie into $DEST…"
  git clone "$REPO_URL" "$DEST"
fi

# ── 4. Build + install + launch — reuse run.sh, don't reimplement it ───────────
# run.sh builds Talkie.app, quits any running copy, installs ONE canonical bundle
# to /Applications/Talkie.app, registers it, and launches it. Using its single
# stable install location (and signature) is what keeps macOS permissions alive
# across rebuilds — so we hand off to it rather than duplicate that logic here.
echo "▶ Building and launching Talkie (this takes a few minutes the first time)…"
exec "$DEST/scripts/run.sh"
