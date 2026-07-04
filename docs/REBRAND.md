# Rebrand playbook — renaming the display brand (e.g. Talkie → Chirp)

**Status:** readiness reference (shipped by work package **L8**). No rename has
happened. This document exists so that when one does, it is a bounded, checklist-
driven change instead of a 900-site archaeology dig — and so nobody accidentally
renames a load-bearing identifier and breaks every existing install.

The core idea L8 established: **the user-visible DISPLAY name is one constant.**

- App target: `Brand.displayName` (`Sources/Talkie/DesignSystem.swift`) reads
  `CFBundleDisplayName` from `Bundle.main`, with a `"Talkie"` fallback for bare
  `swift test` / un-assembled runs.
- MCP binary: `BrandMirror.displayName` (`Sources/TalkieMCP/BrandMirror.swift`) —
  a hard-coded mirror, because `talkie-mcp` is a separate bare executable with no
  app Info.plist to read.
- Updater (dev flavor, compiled into the app): `AppUpdater.brandName`
  (`Sources/TalkieUpdater/AppUpdater.swift`) reads the same `CFBundleDisplayName`.

Changing the display name to "Chirp" is, for the chrome tier, a **one-line
Info.plist edit** (`CFBundleDisplayName`) plus the `BrandMirror` literal. The
`scripts/check-brand-literals.sh` guard freezes the remaining literal footprint so
new hard-coded "Talkie" copy can't creep back in.

But a REAL public rename touches much more than the display name. The rest of this
document is the two lists that matter: what must **never** change, and what a
rename must edit by hand.

---

## ⛔ FREEZE — identifiers that must stay byte-identical

Changing any of these breaks existing installs, the updater, on-disk data, or user
registrations. They are **not** derived from `Brand.displayName` on purpose. A
public rename does NOT touch them; at most it ships a *transitional updater* first
(see below) and then, far later and only with a data-migration plan, considers
changing them.

| Frozen identifier | Value | Anchor | Why it's frozen |
|---|---|---|---|
| Bundle identifier | `com.coralate.talkie` | `Resources/Info.plist` `CFBundleIdentifier`; validated in `Sources/TalkieUpdater/UpdateInstaller.swift` | TCC permission grants, the UserDefaults suite, and the updater's own validation all key on it. Change it and every user re-grants mic/accessibility/calendar and loses their settings. |
| Executable name | `Contents/MacOS/Talkie` | `Resources/Info.plist` `CFBundleExecutable`; hard-validated in `UpdateInstaller.swift` | Shipped updaters REJECT any downloaded bundle whose executable isn't exactly `Contents/MacOS/Talkie`. Renaming it bricks the in-app updater for everyone already on an old build. |
| Support directory | `~/Library/Application Support/Talkie` | `Sources/Talkie/AppPaths.swift`; mirrored in `Sources/TalkieMCP/TalkieStore.swift`; scanned by `scripts/check-no-network.sh` | All persisted stores (history, dictionary, stats, scratchpad, context graph…) live here. Renaming orphans every user's data. |
| Meetings directory | `~/Talkie Meetings` | `Sources/Talkie/AppPaths.swift`; mirrored in `TalkieStore.swift` | Users' recordings + transcripts live here in plain folders they own. Renaming orphans them. |
| `.talkiepack` UTType | `com.coralate.talkie.talkiepack`, ext `talkiepack` | `Sources/Talkie/TalkiePack.swift` (`utTypeIdentifier`, `fileExtension`); declared in `Resources/Info.plist` `UTExportedTypeDeclarations` / `CFBundleDocumentTypes` | Existing shared dictionary packs (`.talkiepack` files) stop opening if the type/extension changes. |
| Keychain service | `com.coralate.talkie.update` | `Sources/TalkieUpdater/Keychain.swift` | The updater's stored GitHub token is filed under this service name. |
| UserDefaults keys | `TalkieDevMode`, `TalkieUpdaterAutoCheck`, `TalkieMainWindow`, … | across `Sources/Talkie` + `AppUpdater.swift` (`autoKey`) | Renaming a defaults key silently resets that preference for every user. |
| SwiftPM target/dir names | `Talkie`, `talkie-mcp`, `TalkieFileKit`, `talkie-cli`, `talkie-bench`, `TalkieBridge`, `TalkieUpdater`, `TalkieTests`, … | `Package.swift`; pinned by `docs/plans/_CORES_STANDARDS.md §2` | `scripts/check-no-network.sh` scans these literal paths (`Sources/Talkie`, `Sources/TalkieMCP`, `Sources/TalkieFileKit`, `Sources/TalkieCLI`). Build scripts hard-code them. They are internal names — no user ever sees them — so renaming buys nothing and breaks the gate + scripts. |
| MCP protocol id | `"talkie"` | `Sources/TalkieMCP/MCPServer.swift` serverInfo; `connector/manifest.json` `name` | This is the server identity users have already registered via `claude mcp add talkie`. Renaming it de-registers every existing connector. |
| MCP binary | `talkie-mcp` | `Package.swift`; `scripts/build_app.sh`; `scripts/build_mcpb.sh`; connector-card fallback paths in `Sources/Talkie/SettingsView.swift`; `connector/manifest.json` `entry_point` | The bundled binary name + all the paths pointing at it. |
| Cask token | `talkie` | `Casks/talkie.rb` (`cask "talkie"`) | `brew install --cask talkie` — the public install command. Renaming breaks upgrades for everyone who installed via brew. |
| GitHub repo slug | `jannallenberger/Talkie` | `Sources/TalkieUpdater/UpdaterSupport.swift` (`owner`/`name`/`slug`) | Compiled into shipped updater binaries; they fetch releases from this slug. Renaming the repo without a transitional updater strands old builds. |
| Dictionary seed | `"talkie" → "Talkie"` | `Sources/Talkie/DictionaryStore.swift` (`defaultReplacements`) | See the migration note below — this one needs *positive* action at rename time, not freezing. |

**Acceptance for any change that touches this repo:** the built bundle must still
pass the shipped updater's validation (`UpdateInstaller.swift` checks bundle id +
`Contents/MacOS/Talkie`), and `scripts/check-no-network.sh` must still find its
four scan directories. If a change would violate either, STOP.

---

## The transitional-updater-first rule

Shipped updaters hard-validate the incoming bundle (`UpdateInstaller.swift`):

- executable must be `Contents/MacOS/Talkie`,
- `CFBundleIdentifier` must be `com.coralate.talkie`.

So you can **never** change the executable name or bundle id in a normal release —
an old client would download the new build and reject it as "not Talkie". The only
safe path to changing either is:

1. Ship a **transitional updater** release whose bundle STILL uses the old
   executable + bundle id (so current clients accept it), but whose updater code is
   relaxed to also accept the NEW identity going forward.
2. Let that transitional build propagate (everyone auto-updates to it).
3. Only then ship the renamed bundle.

Until that program is planned and executed, treat the executable name and bundle id
as immovable. The DISPLAY rename below needs none of this — it changes zero frozen
identifiers.

---

## ✅ The DISPLAY rename (the cheap, safe change)

This is the whole point of L8. To change what users SEE from "Talkie" to "Chirp":

1. `Resources/Info.plist`: set `CFBundleDisplayName` to `Chirp`. Every chrome-tier
   surface follows automatically — menu bar (About/Hide/Quit), status item title +
   tooltip + accessibility descriptions, the Settings window title, the dashboard
   wordmark, the privacy proof card, the bird-buddy labels, the Connect-to-Claude
   footer, and the updater alert. (Leave `CFBundleName` and `CFBundleExecutable`
   alone — those are frozen.)
2. `Sources/TalkieMCP/BrandMirror.swift`: change the `displayName` literal to
   `"Chirp"` (the MCP binary can't read the app plist). Keep the `MIRROR:` header.
3. The `check-no-network.sh` and `check-brand-literals.sh` gates keep passing —
   nothing else needs to change for the DISPLAY tier.

**Dry-run before shipping:** temporarily set `CFBundleDisplayName` to a test value,
`./scripts/build_app.sh`, launch, and confirm the menu bar / About / Quit / window
title / wordmark / proof card / bird-buddy / connector / updater alert all show the
new name. Then revert. (L8 performed exactly this dry-run with "Chirp".)

---

## The full public rename: sed-target list (edit these by hand)

Beyond the display constant, a real public rename edits these DIRECTLY — most are
Info.plist strings and config files that **cannot** read a Swift constant, plus the
long-tail Swift literals the `brand-literal-allowlist.txt` budget still permits.

Property lists and config (no constant can reach these):

- `Resources/Info.plist` — the eight TCC usage strings (`NSMicrophoneUsageDescription`
  and friends), the two Services menu titles ("Transcribe with Talkie" /
  "Clean up with Talkie") and their `NSPortName`, and the "Talkie dictionary"
  document-type descriptions. (Do NOT touch the UTType identifier
  `com.coralate.talkie.talkiepack` — frozen.)
- `connector/manifest.json` — `display_name`, `description`, `long_description`,
  `author.name` (the display-facing fields). Leave `name` (`"talkie"`) and
  `entry_point` (`server/talkie-mcp`) — frozen.
- `Casks/talkie.rb` — the human-readable `name`/`desc`/comments. Leave the cask
  TOKEN (`cask "talkie"`) — frozen (renaming the token is a separate, brew-side
  migration).
- Build + release scripts: `scripts/build_app.sh`, `scripts/build_mcpb.sh`,
  `scripts/run.sh`, `scripts/release_dev.sh`, `ci/release.yml` — any human-readable
  "Talkie" in echo/log lines. Leave the frozen paths (`Contents/MacOS/Talkie`,
  `Application Support/Talkie`, `talkie-mcp`).
- `README` / `docs/*` — prose.

Swift long-tail literals (allowed to remain by the guard until converted):

- Run `bash scripts/check-brand-literals.sh --print` for the current per-file list.
- These are functional messages, `Privacy/DoctorReport.swift` transparency
  receipts, onboarding copy, MCP tool descriptions, and frozen path strings. Convert
  the *display* ones to `Brand.displayName` / `BrandMirror.displayName` and LOWER
  the file's budget in `scripts/brand-literal-allowlist.txt` in the same commit.
  Leave the frozen path/identifier strings (e.g. `"Application Support/Talkie"`,
  `"Contents/MacOS/Talkie"`, the bundle-id fragments) as literals — those are
  deliberately "Talkie" forever.

---

## Dictionary seed migration (`"talkie" → "Talkie"`)

`Sources/Talkie/DictionaryStore.swift` seeds every install with a replacement rule
`"talkie" → "Talkie"` so recognition of the app's own name is corrected. After a
rename this rule would keep "correcting" speech to the OLD brand. A rename must:

1. Change the seed to `"chirp" → "Chirp"` for NEW installs, AND
2. Ship a one-time migration for EXISTING installs that rewrites (or removes) the
   old `"talkie" → "Talkie"` rule — but only if the user hasn't customized it. Do
   NOT blindly delete user-authored dictionary rules. Model this on the existing
   store-migration patterns (optional-decode + versioned payload) already used by
   `StatsStore`.

---

## The APFS case-collision trap

`Package.swift` names the CLI target `talkie-cli`, **not** `talkie`, with a comment
explaining why: the app binary is `Talkie` and APFS is case-insensitive, so a
`talkie` product and a `Talkie` product would collide on disk. `build_app.sh`
copies the CLI to `Contents/MacOS/talkie` at bundle time.

Any new name with a case-only-different CLI hits the same wall. If you rename to
"Chirp", the CLI target must be `chirp-cli` (not `chirp`) for the identical reason —
the app binary would be `Chirp`. Do not "simplify" the target name to the bare
brand; it will fail to build or clobber the app binary.

---

## l10n key regeneration

The `Resources/Localizations/*.lproj/Localizable.strings` keys ARE the English
source text (see each file's header + `Sources/Talkie/Localization.swift`). So any
brand-bearing string whose ENGLISH text changes rewrites its KEY, and all 10
catalogs must be updated in the SAME commit or the other nine languages silently
fall back to English.

L8 already converted the chrome tier to positional `%@` format keys (`"About %@"`,
`"%@ is listening."`, the Connect-to-Claude footer, …) precisely so a DISPLAY
rename does NOT rewrite those keys — the placeholder absorbs the name change with
zero l10n churn. When a full rename touches a still-literal brand string, regenerate
all 10 catalogs together and keep the placeholder-format pattern where the name
appears inline.

---

## Chirp — action items before any public rename string ships

These are business/legal, not code, and BLOCK shipping any public "Chirp" copy:

- [ ] Reserve `trychirp.app` (and sensible variants) before announcing.
- [ ] Trademark clearance for "Chirp" in the relevant classes/jurisdictions — the
      name is common; confirm it's usable for a dictation app before committing.
- [ ] Only after the above: flip `CFBundleDisplayName` + `BrandMirror.displayName`
      and run the dry-run above.
