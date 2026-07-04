# Homebrew cask for Talkie — a fast, private, on-device dictation app for macOS.
#
# Install:
#   brew tap jannallenberger/talkie https://github.com/jannallenberger/Talkie
#   brew install --cask talkie
#
# This cask installs the *default* (zero-network) Talkie build: there is no
# in-app updater and nothing phones home. You update by running `brew upgrade`,
# which is your shell reaching out on your behalf — the app process never does.
# The in-app updater (the hand-rolled, zero-dependency `TalkieUpdater` — there is
# no Sparkle) is compiled ONLY into the dev-tools flavor, never this default cask
# build, so no `auto_updates true` line belongs here.
#
# ── How release.yml fills in the placeholders ────────────────────────────────
# `version` and `sha256` below are placeholders. On a `v*` tag, the release
# workflow (.github/workflows/release.yml) builds + notarizes Talkie.zip, uploads
# it to the GitHub Release, computes the artifact's sha256, and rewrites the two
# lines marked `# RELEASE:` so this file always matches the published asset. The
# `version "0.0.0"` / `sha256 :no_check` values are what's committed between
# releases; CI replaces them with the real tag and hash. Until the first release
# lands, `brew install` from this file will not resolve a real download.
cask "talkie" do
  # RELEASE: version — set by release.yml to the git tag minus the leading "v".
  version "0.0.0"
  # RELEASE: sha256 — set by release.yml to the sha256 of the uploaded Talkie.zip.
  sha256 :no_check

  url "https://github.com/jannallenberger/Talkie/releases/download/v#{version}/Talkie-#{version}.zip"
  name "Talkie"
  desc "Fast, private, on-device dictation for macOS — your own free Wispr Flow"
  homepage "https://github.com/jannallenberger/Talkie"

  # Auto-detect the newest release tag from the GitHub Releases API so
  # `brew bump-cask-pr` and Homebrew's autobump can find new versions.
  livecheck do
    url :url
    strategy :github_latest
  end

  # macOS 26 (Tahoe) floor — matches LSMinimumSystemVersion 26.0 in Info.plist —
  # and Apple Silicon only (the app is built for arm64 against the macOS 26 SDK).
  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "Talkie.app"

  # `zap` removes Talkie's own caches/preferences on `brew uninstall --zap`, but
  # NEVER the user's meetings — "~/Talkie Meetings/" is user-created data and the
  # Cask Cookbook forbids deleting it.
  zap trash: [
    "~/Library/Application Support/Talkie",
    "~/Library/Caches/com.coralate.talkie",
    "~/Library/Preferences/com.coralate.talkie.plist",
    "~/Library/Saved Application State/com.coralate.talkie.savedState",
  ]
end
