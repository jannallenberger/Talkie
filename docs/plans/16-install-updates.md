# 16 — Frictionless install & auto-update

> Engineer-ready plan to make the OSS app spread: a one-step install (Homebrew cask
> + signed/notarized DMG) and a one-step, **opt-in**, in-app auto-update (Sparkle),
> shipped by a GitHub Actions release pipeline that builds → signs → notarizes →
> publishes → bumps the cask + appcast.
>
> Ground truth: `docs/plans/_CURRENT_STATE.md` (§6 entitlements/signing, §0 build
> target) and `docs/plans/_UNIFICATION.md` (§4.1 privacy/two-build-flavors, §6
> contract **16**). Floor: macOS 26.0, Apple Silicon, Swift 6 `.v6`.
> All file:line anchors are on `main` (HEAD `5f747fb`) unless tagged **[branch]**.
> External facts verified June 2026 — see §15 sources.

---

## 1. Summary

Distribute Talkie two ways that update themselves: a **Homebrew cask** in a
first-party tap (`brew install --cask coralate/talkie/talkie`) and a signed,
notarized, stapled **DMG** attached to each GitHub Release; add **opt-in** in-app
updates via Sparkle 2 (EdDSA-signed appcast), and drive the whole thing from a
GitHub Actions workflow that, on a `v*` tag, builds → Developer-ID-signs →
notarizes → staples → makes the DMG → signs the appcast → publishes the Release →
auto-bumps the cask and appcast.

## 2. Why it matters

The strategic thesis is *one private voice brain for the Mac, $0, open source,
nothing leaves your machine*. None of that spreads if installing is "clone the
repo, install Xcode 26, run a shell script." The two incumbents win partly on
**frictionless onboarding** (Wispr Flow and Granola are a download-and-go DMG with
silent auto-update). To out-compete them on openness we must *match* them on
install friction while staying provably private.

- **`brew install --cask` is the OSS distribution standard.** It is how a
  developer audience (exactly Talkie's wedge — vibe-coders, Claude users) expects
  to install Mac tools, and it gives free discoverability, versioning, and
  uninstall (`brew uninstall`, `--zap` to remove `~/Library/Application
  Support/Talkie/`).
- **Auto-update keeps the moat fresh.** The whole plan in `_UNIFICATION.md` ships
  20 features over time; if users are stranded on v0.1 the context-graph/MCP/voice
  surfaces never reach them. One-click "Install Update" closes that gap.
- **It is the credibility test for feature 15 (provable privacy).** An update
  mechanism is the *one* place a privacy-first app most plausibly phones home.
  Doing it transparently — opt-in, you can read exactly what is fetched, the
  default build can ship with it off — is itself a demonstration of the thesis.
  Getting this wrong (silent daily callbacks in a "zero-network" app) would be the
  single most damaging contradiction in the product.

## 3. Current state in the code

Honest status: **the signing/notarization half is partly built; the cask, the
appcast/Sparkle, and the CI pipeline do not exist at all.** There is no `.github/`
directory and **no git remote configured** (`git remote -v` is empty) — a GitHub
repo is a prerequisite for everything in §4.

### 3.1 Build & packaging — already built

- `scripts/build_app.sh` (read in full) — assembles `Talkie.app` *by hand* from the
  SwiftPM product, NOT via Xcode:
  - `swift build -c release` then `--show-bin-path` to locate the `Talkie` binary
    (`:37-38`).
  - `mkdir` the bundle, copies the binary to `Contents/MacOS/Talkie`, `Info.plist`,
    `PkgInfo`, bundled `Fonts/`, `Brand/` PNGs, and compiles the `AppIcon.icon`
    with `actool` (`:45-79`).
  - Resolves a signing identity: `TALKIE_SIGN_ID` env → first `Apple Development`
    in the keychain → ad-hoc `-` (`:24-34`). Signs with
    `--identifier com.coralate.talkie --entitlements Resources/talkie.entitlements`,
    adding `--options runtime --timestamp` **only** when the identity is a
    `Developer ID` (`:81-89`). This is the hook we extend for Sparkle (must sign
    nested frameworks inside-out) — see §5.
- `scripts/notarize.sh` (read in full) — the Developer ID path:
  `TALKIE_SIGN_ID=$TALKIE_DEVID_ID build_app.sh release` → re-sign with Hardened
  Runtime + entitlements → `ditto -c -k --keepParent` to a ZIP → `xcrun notarytool
  submit --keychain-profile "$TALKIE_NOTARY_PROFILE" --wait` → `stapler staple` +
  `validate` → re-zip. Distributes a **ZIP**, not a DMG (`:33-48`).
- `scripts/run.sh` — installs ONE canonical copy to `/Applications/Talkie.app` and
  `lsregister`s it (`:19-25`). The comment explains *why* a stable signature
  matters: ad-hoc hashes change each build → macOS wipes TCC grants.
- `README.md:111-134` already documents the manual notarize flow and the
  stable-signature tip.

### 3.2 Versioning & bundle identity — already present, but static

- `Resources/Info.plist`: `CFBundleIdentifier = com.coralate.talkie`,
  `CFBundleShortVersionString = 0.1.0`, `CFBundleVersion = 1`,
  `LSMinimumSystemVersion = 26.0` (`:5-26`). These are **hand-edited** today; the CI
  pipeline (§4) must stamp them from the git tag.
- `Sources/Talkie/LaunchAtLogin.swift` already wraps `SMAppService.mainApp`
  (register/unregister + `isEnabled`) — relevant only as a sign that the app is a
  *real signed bundle* at runtime (SMAppService and Sparkle both require that, not a
  bare `swift run`).

### 3.3 Entitlements — the network question is open

- `Resources/talkie.entitlements`: **only** `com.apple.security.device.audio-input`
  (`:7-8`). There is **no App Sandbox** (`com.apple.security.app-sandbox` absent),
  and **no** `com.apple.security.network.client`. The privacy invariant
  (`_CURRENT_STATE.md` §6, verified zero `URLSession`) holds today.
- **Consequence for Sparkle:** Sparkle's appcast fetch needs outbound network. With
  *no* sandbox (today's reality), a hardened-runtime non-sandboxed app can make
  network connections **without** any entitlement — there is nothing to add to
  `talkie.entitlements` for Sparkle to work *today*. The entitlement question only
  becomes real when feature 15 turns on the App Sandbox; at that point Sparkle (or
  any networked module) needs `com.apple.security.network.client`, which is exactly
  the "connected build flavor" wall §4.1 of `_UNIFICATION.md` describes. This plan
  is designed so Sparkle is **compile-time optional** and lives behind that wall
  (§10).

### 3.4 What does NOT exist

- No `.github/workflows/*.yml`, no git remote, no tag conventions.
- No Homebrew tap repo, no `Casks/talkie.rb`.
- No Sparkle dependency in `Package.swift` (zero external deps today, `:9-17`), no
  EdDSA keys, no `appcast.xml`, no `SUFeedURL`/`SUPublicEDKey` in `Info.plist`, no
  updater UI.
- No DMG creation (notarize ships a ZIP).

## 4. Design & approach

Four sub-systems, sequenced so each works standalone (you can stop after any one
and still have shipped value):

```
(a) Homebrew cask  ──►  needs only a signed+notarized DMG on a GitHub Release
(b) Signing+notarize ─► extend the existing scripts; produce a DMG, not a ZIP
(c) Sparkle in-app  ──►  OPTIONAL compile flag; opt-in checks; EdDSA appcast
(d) CI pipeline     ──►  ties a→c together on every `v*` tag
```

### 4.a Homebrew cask (zero new app code)

A **first-party tap** is a normal GitHub repo named `homebrew-<tap>` — recommended
`github.com/coralate/homebrew-talkie` (the brand owner; bundle id is
`com.coralate.talkie`). Install becomes:

```bash
brew install --cask coralate/talkie/talkie
```

(`brew tap coralate/talkie` then `brew install --cask talkie` is the long form.)
The cask file `Casks/t/talkie.rb` (Homebrew shards casks by first letter) points at
the notarized DMG asset on the GitHub Release:

- `auto_updates true` — REQUIRED whenever the app self-updates (Sparkle).
  Verified: this tells `brew upgrade` the app updates itself, so brew won't fight
  Sparkle. Cask + Sparkle **coexist** — brew does the first install; whichever
  updater runs first wins; `brew upgrade --cask talkie` still works to force a
  brew-side bump. (Without `auto_updates true`, Homebrew's auditors flag a cask
  whose livecheck uses a Sparkle/built-in-updater strategy.)
- `livecheck { url :url; strategy :github_latest }` — auto-detects the newest
  release tag from the GitHub Releases API, so the official `brew bump-cask-pr`
  bot (and our own CI bump, §4.d) can find new versions.
- `depends_on macos: ">= :tahoe"` — encodes the macOS 26 floor (matches
  `LSMinimumSystemVersion 26.0`); `depends_on arch: :arm64` encodes Apple Silicon.
- `zap trash:` removes `~/Library/Application Support/Talkie/`, the `UserDefaults`
  plist (`~/Library/Preferences/com.coralate.talkie.plist`), Sparkle's caches, and
  the saved-state — but **never** `~/Talkie Meetings/` (user data; the cookbook
  forbids deleting user-created files).

**Tap vs. official `homebrew-cask`:** ship the first-party tap first (full control,
instant releases, fewer rules). Submitting to the official `Homebrew/homebrew-cask`
later is a stretch goal — it requires the app to be reasonably popular and to pass
stricter audits (e.g. no `allow_untrusted`, stable URL). The first-party tap has no
such gate and is the right MVP.

### 4.b Signing, notarization, DMG (extend the existing scripts)

The Developer ID flow already works (§3.1). Three deltas:

1. **Produce a DMG, not a ZIP.** A cask `app` stanza installs from a DMG (or ZIP);
   a DMG is the conventional, drag-to-Applications artifact and what users expect.
   Use the `create-dmg/create-dmg` shell tool (or `sindresorhus/create-dmg`) to make
   a styled DMG with an `/Applications` symlink, then **notarize the DMG itself**
   (notarizing the DMG staples a ticket to the container so Gatekeeper is happy even
   before the app is copied out). New `scripts/make_dmg.sh` (§5).
2. **Sign Sparkle's nested components inside-out** (only when Sparkle is compiled
   in). `Sparkle.framework` ships XPC services (`Autoupdate`, `Updater.app`,
   `Installer`/`Downloader` XPC) under `Contents/Frameworks/Sparkle.framework/`.
   Hardened-runtime + notarization require every nested Mach-O to be signed with the
   same Developer ID *before* the outer app, preserving symlinks. Extend
   `build_app.sh`'s signing block to walk `Contents/Frameworks` and sign nested
   bundles first (`codesign --deep` is discouraged by Apple; sign each explicitly).
3. **Stamp the version from the tag in CI** (not by hand-editing Info.plist). The
   workflow sets `CFBundleShortVersionString` = the tag minus `v` (e.g. `0.2.0`)
   and `CFBundleVersion` = a monotonic integer (the run number, or
   `git rev-list --count HEAD`) via `PlistBuddy` before `build_app.sh` runs (§4.d).

**CI credentials:** `notarytool` accepts either a stored keychain profile
(`--keychain-profile`, what `notarize.sh` uses locally) **or** raw
`--apple-id <id> --team-id <TEAMID> --password <app-specific-pw> --wait`. CI uses
the raw form from GitHub Secrets (no interactive keychain). The Developer ID cert is
imported into a throwaway CI keychain via `Apple-Actions/import-codesign-certs` from
a base64 `.p12` secret.

### 4.c Sparkle in-app auto-update (OPTIONAL, opt-in)

**Dependency.** Add Sparkle 2 (currently 2.9.3, **MIT-licensed**, compatible with
zero-OSS-friction) via SwiftPM:

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3")
```

Gate it behind a SwiftPM **trait/build flag** so the *default* build can omit it
entirely (the "provably zero-network" build flavor, §10). Concretely: a Swift
compilation condition `TALKIE_SPARKLE` (passed via `.define("TALKIE_SPARKLE")` in a
separate package manifest path or a `swift build -Xswiftc -DTALKIE_SPARKLE`
invocation), and the Sparkle product only linked in the "connected" flavor. All
Sparkle-touching code sits behind `#if canImport(Sparkle) && TALKIE_SPARKLE`.

**Embedding (the non-Xcode wrinkle).** Talkie assembles its bundle by hand, and
`swift build` will produce the `Talkie` binary linked against Sparkle but will NOT
copy `Sparkle.framework` (with its XPC services + symlinks) into the bundle. So
`build_app.sh` must, when Sparkle is enabled: locate the built
`Sparkle.framework` in the SwiftPM artifacts (`.build/.../artifacts/` or the
checkout), `ditto` it into `Contents/Frameworks/` preserving symlinks, then sign it
inside-out before signing the app. This is the single most fiddly part of the plan
and the one most likely to fail notarization on the first try (§12).

**Runtime wiring (programmatic — there is no MainMenu.xib).** Talkie's
`AppDelegate` (`@MainActor`, owns every store) gains an optional
`SPUStandardUpdaterController` created with `startingUpdater: false` (we do NOT auto-
start checks), plus a "Check for Updates…" item in the App menu
(`AppDelegate.swift:107-147` already builds the menus manually) and a row in
Settings → General → Behavior (`SettingsView.swift`, alongside the existing
sounds/login toggles).

**Opt-in, not default-on (the privacy reconciliation).** Sparkle's default is a
silent check every 24h. We override that:

- `Info.plist`: `SUEnableAutomaticChecks = false`, `SUEnableInstallerLauncherService
  = false` (no helper if not needed), `SUScheduledCheckInterval` unset. Set
  `SUFeedURL` and `SUPublicEDKey` only in the connected flavor's plist.
- At runtime, `updater.automaticallyChecksForUpdates` defaults to `false`. The user
  must either click "Check for Updates…" (manual, one-shot, transparent) **or** flip
  a Settings toggle "Check for updates automatically" (which sets
  `automaticallyChecksForUpdates = true` + calls `resetUpdateCycle()`). The first
  time *any* check is attempted we show Sparkle's standard "Check for updates
  automatically?" permission prompt — and our copy makes the network implication
  explicit (§8).
- A "Check for updates" is the FIRST and only network call the app ever makes, only
  after explicit user action. Honest copy states exactly that.

**Appcast + signing.** `appcast.xml` (RSS) hosted on GitHub
(Releases asset or GitHub Pages). Each `<item>` carries `sparkle:version` (=
CFBundleVersion), `sparkle:shortVersionString`, `<enclosure url=…/Talkie-X.dmg
sparkle:edSignature=… length=…>`, `sparkle:minimumSystemVersion = 26.0`, and
release notes. Generated by Sparkle's `generate_appcast` tool (auto-computes EdDSA
signatures + delta updates) using a private EdDSA key created once by
`generate_keys` (public half → `SUPublicEDKey`, private half → GitHub Secret /
local Keychain, never committed). `sign_update` can sign a single DMG if not using
`generate_appcast`.

### 4.d CI release pipeline (`.github/workflows/release.yml`)

Trigger: push of a tag matching `v*.*.*`. Runner: `macos-15` (or newest available;
must have Xcode 26 / the macOS 26 SDK selectable via `xcode-select` — confirm SDK
availability before relying on it, §12). Steps:

```
1. checkout (fetch tags)
2. select Xcode 26 SDK (sudo xcode-select -s /Applications/Xcode_26.app)
3. import Developer ID cert      (Apple-Actions/import-codesign-certs, .p12 secret)
4. stamp version into Info.plist (PlistBuddy: ShortVersion=${tag#v}, Version=run#)
5. build + sign  (TALKIE_SIGN_ID=$DEVID; TALKIE_SPARKLE flag for the connected DMG)
       → build_app.sh release   (signs nested Sparkle, then the app)
6. make DMG      (scripts/make_dmg.sh → Talkie-${ver}.dmg)
7. notarize DMG  (notarytool submit --apple-id/--team-id/--password --wait)
8. staple DMG    (xcrun stapler staple; validate)
9. sign appcast  (Sparkle sign_update on the DMG → edSignature; update appcast.xml)
10. create GitHub Release, upload Talkie-${ver}.dmg + appcast.xml
11. bump tap     (checkout coralate/homebrew-talkie via a PAT; update version+sha256
                  in Casks/t/talkie.rb; commit/push) — OR rely on Homebrew's autobump
12. publish appcast (commit appcast.xml to gh-pages / Releases)
```

Notes verified in §15: step 11 needs a **separate PAT** with write access to the tap
repo (the default `GITHUB_TOKEN` can't push to another repo); GoReleaser's
`homebrew_casks` or a small `sed`/Ruby step both work for the bump.
**Optionally drop the manual bump** and let Homebrew's livecheck/autobump pick up the
release (slower, but zero-maintenance for a personal tap).

## 5. New & changed files/types

### New files

```
.github/workflows/release.yml          # the v* tag pipeline (§4.d)
.github/workflows/build.yml            # PR/push CI: swift build + (debug) app assemble
scripts/make_dmg.sh                    # build_app.sh → notarizable DMG
scripts/sign_sparkle.sh               # sign nested Sparkle XPC/framework inside-out
scripts/generate_appcast.sh           # wrap Sparkle generate_appcast / sign_update
appcast.xml                           # the EdDSA-signed feed (connected flavor)
docs/RELEASING.md                     # the human runbook (cert, keys, secrets, tagging)
Casks/t/talkie.rb                     # lives in the SEPARATE homebrew-talkie tap repo
Sources/Talkie/Updater.swift          # the Sparkle wrapper (compile-gated)
```

### `Sources/Talkie/Updater.swift` (sketch)

A thin `@MainActor` façade so the rest of the app never imports Sparkle directly,
and so the whole file compiles to a no-op when Sparkle is absent (default flavor).

```swift
import Foundation
#if canImport(Sparkle) && TALKIE_SPARKLE
import Sparkle
#endif

/// The app's update surface. In the default (zero-network) build flavor this is a
/// no-op shell: `isSupported == false`, every method does nothing, no network code
/// is linked. In the "Connected" flavor it wraps Sparkle's SPUStandardUpdaterController.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// True only in a build that compiled Sparkle in. Drives whether the UI shows
    /// the update controls at all.
    static var isSupported: Bool {
        #if canImport(Sparkle) && TALKIE_SPARKLE
        return true
        #else
        return false
        #endif
    }

    /// Mirrors the user's choice. Persisted to AppSettings (UserDefaults), default false.
    @Published var automaticChecksEnabled: Bool = false

    #if canImport(Sparkle) && TALKIE_SPARKLE
    private let controller: SPUStandardUpdaterController

    override init() {
        // startingUpdater:false → no background check until the user opts in.
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
        controller.updater.automaticallyChecksForUpdates = false
    }

    /// Begin the updater lifecycle WITHOUT scheduling any check. Safe to call at launch.
    func startIdle() { try? controller.startUpdater() }

    /// User clicked "Check for Updates…". The only network call, on explicit action.
    @objc func checkForUpdates(_ sender: Any?) { controller.checkForUpdates(sender) }

    /// Settings toggle. Persists + (re)schedules or cancels the 24h cycle.
    func setAutomaticChecks(_ on: Bool) {
        automaticChecksEnabled = on
        controller.updater.automaticallyChecksForUpdates = on
        controller.updater.resetUpdateCycle()
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }
    #else
    func startIdle() {}
    @objc func checkForUpdates(_ sender: Any?) {}
    func setAutomaticChecks(_ on: Bool) { automaticChecksEnabled = on }
    var canCheck: Bool { false }
    #endif
}
```

### `AppDelegate.swift` changes

- Own `let updater = Updater()` alongside the other stores; call
  `updater.startIdle()` in `applicationDidFinishLaunching` **only if**
  `Updater.isSupported` (no-op otherwise).
- In `setupMainMenu` (`:107-147`), add a "Check for Updates…" `NSMenuItem` to the
  App menu, `target: updater, action: #selector(Updater.checkForUpdates(_:))`,
  shown only when `Updater.isSupported`.

### `SettingsView.swift` / `AppSettings.swift` changes

- `AppSettings`: add `automaticUpdateChecks: Bool` (UserDefaults, **default false**),
  posting no engine notification (it doesn't touch the hotkey/locale).
- Settings → General → **Behavior** sub-page (where `playSounds`/`launchAtLogin`
  live, `_CURRENT_STATE.md` §4.4): add a `Toggle("Check for updates automatically")`
  bound through `updater.setAutomaticChecks`, and a "Check now" button → only
  rendered `if Updater.isSupported`. Below them, one honest sentence (§8).

### `scripts/build_app.sh` change (signing block, ~`:81-89`)

Before signing the outer app, when `Contents/Frameworks/Sparkle.framework` exists:
sign each nested XPC service + the framework with the SAME identity + `--options
runtime --timestamp`, deepest-first, preserving symlinks (a `sign_sparkle.sh`
helper). Then sign the app. (`codesign --deep` is explicitly *not* recommended by
Apple for notarization; sign components individually.)

### `Resources/Info.plist` changes (connected flavor only)

Add (templated/CI-injected so the default build omits them):
`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks=false`. The version keys
(`CFBundleShortVersionString`, `CFBundleVersion`) become CI-stamped (§4.d step 4).

## 6. Data model & persistence

Almost none — this feature is build/release plumbing, not app data.

- **Setting:** `automaticUpdateChecks: Bool` in `UserDefaults`
  (`com.coralate.talkie` domain), default `false`. Sparkle also persists its own
  keys under the same domain (`SUEnableAutomaticChecks`, `SULastCheckTime`,
  `SUSkippedVersion`, `SUHasLaunchedBefore`) — those are managed by Sparkle, written
  only after the user opts in. **Back-compat:** a missing key reads as `false`
  (opt-in stays the default for existing installs); the `zap` stanza clears them on
  uninstall.
- **Version source of truth:** the **git tag** (`vMAJOR.MINOR.PATCH`).
  `CFBundleShortVersionString` mirrors the tag; `CFBundleVersion` is a monotonic
  build integer (CI run number). The appcast's `sparkle:version` MUST equal
  `CFBundleVersion` and `sparkle:shortVersionString` the marketing version — Sparkle
  compares `CFBundleVersion` to decide "is there a newer build."
- **EdDSA private key:** stored in the macOS Keychain locally (created by
  `generate_keys`) and as a GitHub Actions Secret for CI. **Never committed.** The
  public key is baked into `Info.plist` (`SUPublicEDKey`) and is safe to publish.
- **Cask file** (`Casks/t/talkie.rb`): `version` + `sha256` of the DMG, updated each
  release (CI or autobump). Lives in the tap repo, not this repo.
- **Migration:** none for users on the current ad-hoc/manual builds — they install
  the cask fresh (or download the first notarized DMG). The first signed build
  changes the code-signing "designated requirement" once; macOS re-asks for the 3
  TCC grants one final time, then they stick forever (the stable-signature win from
  `build_app.sh`'s own comments). Document this one-time reprompt in release notes.

## 7. Unification contract

Per `_UNIFICATION.md` §6 contract **16** and §4.1 (the network wall):

**EXPOSES (what other features/users consume):**
- A Homebrew cask + a signed/notarized/stapled DMG on each GitHub Release — the
  install path the whole project (and the README) points at.
- An **opt-in** Sparkle appcast feed (the connected flavor only) + the EdDSA signing
  ritual.
- A reusable **CI release pipeline** (build → sign → notarize → publish → bump) that
  every future feature's binaries ride on for free.
- The **two build flavors** in practice: this feature is the first concrete consumer
  of feature 15's `Talkie` (sandboxed/zero-network, no Sparkle) vs.
  `Talkie (Connected)` (network entitlement + Sparkle) split. We *implement* the
  compile flag (`TALKIE_SPARKLE`) and the inside-out signing; feature 15 *owns* the
  sandbox entitlement and the `requiresNetwork` enforcement.

**CONSUMES:**
- `scripts/build_app.sh` + `scripts/notarize.sh` (extended, not replaced).
- Feature 15's network-wall model: Sparkle is `requiresNetwork`-equivalent and MUST
  be **absent from the default sandboxed build**. We honor that by making Sparkle a
  compile-time-optional module behind `TALKIE_SPARKLE` and shipping the cask's
  primary DMG as whichever flavor the project decides is "default" (recommendation
  in §10).
- Nothing from the **personal context graph** (feature 05) — this feature neither
  reads nor writes the graph. The graph **never** travels through the update
  channel; Sparkle fetches only the appcast + the DMG, never any user data (§10).
  This is the clean separation the contract wants: the one networked thing the
  default app might do (check for an update) touches zero personal data.

**The one coherence note:** the appcast URL and the cask's `livecheck` both read
from the SAME GitHub Releases as their version source of truth, so brew and Sparkle
can never disagree about "what is the latest version."

## 8. UI / UX

Minimal, on-brand, and only present in the connected flavor.

- **App menu → "Check for Updates…"** (standard macOS placement, after the About
  item). Sparkle's own update window (progress, release notes via `MarkdownText`-
  style rendering is Sparkle's, not ours) appears only after the click.
- **Settings → General → Behavior** (the `SubPage` that already holds sounds + login,
  `_CURRENT_STATE.md` §4.4): one `Toggle` "Check for updates automatically" + a
  "Check now" button. Match the existing `Form`/`Toggle` rows — no new component.
- **Honest copy (BRAND.md voice — warm, second person, no invented claims):**
  > "Talkie checks for updates only when you ask, or — if you turn this on — once a
  > day. A check contacts GitHub to read the version list; it sends nothing about
  > you and never touches your dictation, meetings, or context graph."
  This is the *only* place in the app that admits a network connection, so the copy
  is deliberately explicit (mirrors the feature-15 privacy panel tone).
- **Brand tokens** (`DesignSystem.swift`, per `_CURRENT_STATE.md` §5): the toggle row
  uses the existing `Theme.coral` (now blue) accent; no second accent; the
  explanatory sentence uses the muted secondary text style; squircle controls; calm.
  No feather colors here (those are data-only).
- **Default flavor:** none of the above renders (`Updater.isSupported == false`), so
  the zero-network build has no update UI at all — visibly honest.

## 9. Permissions / entitlements / Info.plist

- **No new TCC prompts.** Update checks need no microphone/AX/input-monitoring.
- **No new entitlement *today*** (the app is non-sandboxed; hardened-runtime
  non-sandboxed apps may use the network with no entitlement). **When feature 15
  enables the App Sandbox**, the *connected* flavor must add
  `com.apple.security.network.client`, and (if Sparkle's XPC installer is used in a
  sandbox) the Sparkle sandboxing guide's XPC services + temporary-exception
  entitlements — the default sandboxed flavor adds neither and cannot instantiate
  Sparkle (it isn't compiled in).
- **Info.plist (connected flavor):** `SUFeedURL`, `SUPublicEDKey`,
  `SUEnableAutomaticChecks=false` (§5). Version keys become CI-stamped.
- **Hardened Runtime / notarization:** unchanged in mechanism, but the nested
  Sparkle XPC services must each carry the runtime + a secure-timestamped Developer
  ID signature or notarization rejects the bundle (§12). The `--options runtime
  --timestamp` already applied for Developer ID in `build_app.sh:86-88` must now also
  reach the nested components.
- **`com.apple.security.cs.disable-library-validation`:** NOT needed if Sparkle is
  signed with the same Developer ID team as the app (library validation passes).
  Avoid adding it (it weakens the hardened runtime and would be a bad look for a
  privacy app).

## 10. Privacy posture

This is the feature most in tension with the zero-network invariant; the design
resolves it structurally, not with a promise.

- **Default = provably zero-network preserved.** The default build flavor does NOT
  compile Sparkle (`TALKIE_SPARKLE` undefined) → no Sparkle symbols, no `URLSession`,
  no network code linked; `grep -rniE "URLSession|http"` over the *default* build
  stays empty (the verified invariant). It can ship under the App Sandbox with **no**
  network entitlement (feature 15). Such users update via `brew upgrade` /
  re-downloading the DMG — entirely user-initiated, the app itself never reaches the
  network.
- **Connected flavor = opt-in, off by default, transparent.** Sparkle is present but
  `automaticallyChecksForUpdates = false`; the first check happens only on an
  explicit "Check for Updates…" click or after the user flips the Settings toggle.
  Exactly what leaves the device: an **HTTPS GET to the appcast URL** (the GitHub-
  hosted `appcast.xml`) and, if the user chooses to install, a GET of the DMG. The
  request carries Sparkle's default `User-Agent` + the app version (so the feed can
  offer the right delta) — and *nothing else*: no telemetry, no device id, no
  personal data, never the context graph/meetings/dictionary. We can further disable
  Sparkle's anonymous system-profiling (`SUEnableSystemProfiling = false`) so even
  the OS/hardware profile is not sent.
- **When it happens:** never at launch, never silently in the default build; in the
  connected build only on user action or the opted-in 24h cycle.
- **Documented tradeoff (per contract 16's "or document the tradeoff"):**
  `docs/RELEASING.md` + the in-app copy state plainly that auto-update is a network
  feature, that it is opt-in, that the default build omits it, and exactly what the
  request contains. This is the honest reconciliation feature 15 asks for.
- **Cask note:** `brew`'s own `livecheck`/`brew upgrade` runs on the *user's* shell
  on demand — it is not the app phoning home. So even cask users' update checks are
  user-initiated and outside the app process.

## 11. Open-source genericity

- **No hardcoded personal stack.** The cask, scripts, and CI reference only the
  app's own identity (`com.coralate.talkie`) and a GitHub repo — no Obsidian, no
  Claude Code, no personal folder. Meetings/data paths are untouched.
- **Zero-config default for end users:** `brew install --cask` (one command) or
  download-and-drag the DMG. No Xcode, no clone, no script.
- **Forks/community:** every secret is parameterized — a fork sets its own
  `TALKIE_DEVID_ID`, `TALKIE_NOTARY_*`/Apple-ID secrets, EdDSA keys, tap repo, and
  bundle id, and the same pipeline produces their signed cask + appcast. The Sparkle
  feed URL and public key live in (CI-injected) Info.plist, not source, so a fork
  swaps them without code changes. `docs/RELEASING.md` is the generic recipe.
- **A fork that wants zero Apple Developer account** can still ship the default
  (unsigned/ad-hoc) build for local use and skip notarization — the scripts already
  fall back to ad-hoc (`build_app.sh:28-33`); only *distribution* needs the cert.
- **License compatibility:** Sparkle is MIT (verified), compatible with shipping in
  an OSS app; attribute it in `docs/` / acknowledgements.

## 12. Risks, edge cases, failure modes

- **Manual-bundle + Sparkle embedding is the top risk.** Because Talkie isn't an
  Xcode app, nothing auto-copies/signs `Sparkle.framework` + its XPC services with
  preserved symlinks. Mis-sign or break a symlink → notarization rejects, or the
  updater silently fails to relaunch. *Mitigation:* a dedicated `sign_sparkle.sh`
  that signs deepest-first, `codesign --verify --deep --strict` + a notarization dry-
  run in CI before publishing; keep Sparkle behind the flag so a broken embed never
  blocks the default build.
- **macOS 26 SDK on GitHub-hosted runners may lag.** If `macos-15`/`macos-26`
  runners don't yet have Xcode 26 / the macOS 26 SDK, the `.macOS("26.0")` target
  won't build in CI. *Mitigation:* gate the workflow on SDK availability; fall back
  to a **self-hosted runner** on the author's Apple-Silicon Mac (the build already
  works there) until hosted runners catch up. RESEARCH/verify runner SDK before first
  release (do not assume).
- **Notarization flakiness / latency.** `notarytool --wait` can take minutes or
  return `Invalid` with a log. *Mitigation:* fetch `notarytool log <id>` on failure
  and surface it in the Action; retry once.
- **App-specific password / cert expiry.** Developer ID certs expire (~5 yr);
  app-specific passwords can be revoked. *Mitigation:* document renewal in
  RELEASING.md; the pipeline fails loudly (it never ships an unsigned build).
- **EdDSA key loss = users can't auto-update.** Losing the private key means no
  future appcast can be signed with the key in shipped `Info.plist`. *Mitigation:*
  back up the key (Keychain export + offline copy); rotating it requires shipping a
  new public key in a *brew-delivered* update first (chicken-and-egg) — so guard it.
- **Cask sha256 mismatch / race.** If the cask is bumped before the DMG asset is
  fully uploaded, `sha256` won't match. *Mitigation:* compute sha256 from the exact
  artifact the workflow uploaded, in the same job, after upload completes.
- **Brew vs Sparkle double-update churn.** Both could update the app. *Mitigation:*
  `auto_updates true` tells brew to defer; harmless if both run (idempotent —
  same version). Document that `brew upgrade --cask` is the brew-side path.
- **Gatekeeper on first launch from DMG.** Even notarized, a DMG-mounted app on
  first launch may show the "downloaded from the internet" dialog once. Expected;
  document it. (Cask installs typically suppress quarantine.)
- **Tap PAT scope.** A too-broad PAT is a security risk; a too-narrow one can't push.
  *Mitigation:* fine-grained PAT scoped to the single `homebrew-talkie` repo,
  contents:write only.
- **Graceful degradation overall:** if Sparkle is absent/broken, the app runs
  identically and updates via brew/DMG; if CI/notarization fails, no release ships
  (fail-closed) and existing users are unaffected.

## 13. Testing & verification

- **CI smoke (`build.yml`):** on every PR/push, `swift build -c release` (both
  flavors: default and `-DTALKIE_SPARKLE`) so neither breaks. Assemble the debug app
  to catch packaging regressions.
- **Sign/notarize verification (in the release job, before publishing):**
  `codesign --verify --deep --strict --verbose=2 Talkie.app`,
  `codesign -dvvv` shows the Developer ID + nested Sparkle signatures,
  `spctl -a -vvv -t install Talkie.app` → "accepted, source=Notarized Developer ID",
  `xcrun stapler validate Talkie.dmg`.
- **Manual update round-trip (the real proof):** publish `v0.2.0`, install via cask;
  publish `v0.2.1`; in the running v0.2.0 connected build, click "Check for
  Updates…" → it should find 0.2.1, verify the EdDSA signature, download, relaunch
  into 0.2.1. Repeat with the Settings auto-check toggle on (wait out / force the
  cycle via `resetUpdateCycle`).
- **Opt-in/default proof (privacy):** on the **default** build,
  `nm -u Talkie | grep -i sparkle` returns nothing and `grep -rniE "URLSession|http"`
  over the linked symbols/source stays empty; the update UI is absent. On the
  connected build, confirm NO network traffic at launch / idle (e.g. `nettop`/Little
  Snitch shows zero connections until the user clicks Check).
- **Cask lint:** `brew audit --cask --new talkie` and `brew style` against
  `Casks/t/talkie.rb`; `brew install --cask ./talkie.rb` from a local checkout;
  `brew uninstall --cask --zap talkie` leaves `~/Talkie Meetings/` intact.
- **`/run` + `/verify` path:** `/run` builds and launches via `scripts/run.sh` to
  confirm the app still starts after the AppDelegate/menu/Settings changes; `/verify`
  drives the "Check for Updates…" menu item and the Settings toggle on a connected
  build to confirm the opt-in flow and that nothing fires before the click.
- There is **no test target** today (`_CURRENT_STATE.md` §8); this feature adds CI
  scripts rather than XCTest. The shell scripts are the testable units (run them in
  `build.yml` against a dummy bundle).

## 14. Effort & phasing

| Sub-step | Size | Notes |
|---|---|---|
| **MVP — cask + signed DMG + manual release** | **M** | Set up GitHub remote; extend `notarize.sh`/`make_dmg.sh` to emit a notarized DMG; hand-write `Casks/t/talkie.rb` in a `homebrew-talkie` tap; first manual `vX` Release. Ships real one-command install with NO app code change and NO Sparkle. |
| CI pipeline (build→sign→notarize→publish→bump) | M | `release.yml` + secrets + cert import + PAT bump. Removes the manual ritual. Depends on runner SDK (§12). |
| Sparkle integration (opt-in, connected flavor) | L | SwiftPM dep + `Updater.swift` + menu/Settings UI + `Info.plist` keys + **the inside-out embed/sign** (the hard part) + EdDSA keys + `appcast.xml` generation. |
| Two-flavor build separation (with feature 15) | M | The `TALKIE_SPARKLE` flag + sandbox/network-entitlement split; co-owned with 15. |
| Submit to official `homebrew-cask` | S–M | Stretch; needs popularity + stricter audit. |

**MVP slice:** the first row alone — `brew install --cask coralate/talkie/talkie`
pulling a notarized DMG — is shippable on its own and delivers the headline value
("one-step install") with zero privacy risk and zero new app code. Sparkle is the
second wave.

## 15. Dependencies & interactions

- **Requires:** a GitHub repo + Apple Developer ID cert + notary credentials (the
  scripts assume these; `notarize.sh` documents the one-time setup). A first-party
  Homebrew tap repo.
- **Tightly coupled to feature 15 (provable zero-network privacy):** 15 defines the
  two build flavors and the network wall; 16 is the first feature to *exercise* them
  (Sparkle is the canonical "networked, behind the wall, opt-in" module). Build 15's
  flavor split alongside 16's Sparkle work, or at least agree the `TALKIE_SPARKLE`
  flag + entitlement story before shipping the connected DMG. **Sequencing
  (`_UNIFICATION.md` §5): lock 15 early** so the wall is structural, not retrofitted.
- **Enables every other feature's distribution:** 01 (far-end), 02, 05, 06, 08, …
  all ship to users *through* this pipeline. The MCP server (06) and Claude bridge
  (18) are separate targets (`TalkieMCP`, `TalkieBridge`) — the CI pipeline should be
  written to also package/notarize those when they exist (the `.mcpb` bundle for 07a
  rides the same Release).
- **Overlaps with feature 18 (Claude bridge):** both are "networked, opt-in, behind
  feature 15's wall." Reuse the SAME consent/disclosure tone and the SAME flavor
  flag; the bridge's network entitlement and Sparkle's can be the one
  `network.client` the connected flavor adds.
- **No interaction with the personal context graph (05).** Deliberately: the update
  channel must never carry user data (§7, §10).
- **Touches `docs/RELEASING.md` + `README.md`:** the README's "Sharing with your
  co-founders" section (`:111-134`) gets superseded by "Install with Homebrew" + a
  link to RELEASING.md.

## External sources (verified June 2026)

- Sparkle — repo, latest 2.9.3, MIT, tools (`generate_keys`/`generate_appcast`/
  `sign_update`): https://github.com/sparkle-project/Sparkle ;
  docs https://sparkle-project.org/documentation/ ; programmatic SwiftUI/AppKit
  setup (`SPUStandardUpdaterController`, `automaticallyChecksForUpdates`,
  `resetUpdateCycle`, framework embedding in `Contents/Frameworks/` with preserved
  symlinks): https://sparkle-project.org/documentation/programmatic-setup/
- Homebrew Cask Cookbook — `auto_updates`, `livecheck`/`:github_latest`,
  `depends_on macos`, `zap`, tap rules:
  https://docs.brew.sh/Cask-Cookbook ;
  Sparkle-livecheck-needs-`auto_updates` audit:
  https://github.com/Homebrew/homebrew-cask/issues/170994
- GitHub Actions signing/notarization — cert import:
  https://github.com/Apple-Actions/import-codesign-certs ;
  end-to-end pattern: https://federicoterzi.com/blog/automatic-code-signing-and-notarization-for-macos-apps-using-github-actions/ ;
  publishing a cask to another tap needs a separate write-scoped token:
  https://goreleaser.com/customization/homebrew_casks/
- DMG creation: https://github.com/create-dmg/create-dmg and
  https://github.com/sindresorhus/create-dmg (`--notarize`)
- `notarytool` raw-credential vs keychain-profile in CI (`--apple-id/--team-id/
  --password --wait`): https://keith.github.io/xcode-man-pages/notarytool.1.html
