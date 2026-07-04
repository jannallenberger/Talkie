# Releasing Talkie

This is the runbook for cutting a signed, notarized Talkie release — the thing that
lets a stranger's Mac open Talkie with no Gatekeeper wall. It covers both paths:

- **The local path** — build, sign, notarize and staple on Jann's Mac by hand
  (the first release, and the fallback whenever CI can't).
- **The CI path** — push a `vMAJOR.MINOR.PATCH` tag and let the release workflow do
  the same thing unattended.

Both paths run the *same two scripts* — `scripts/build_app.sh` and
`scripts/notarize.sh` — so anything documented here for the local path is exactly
what CI does too. Neither script is modified for release; the only difference is
where the signing identity and notary credentials come from.

> **Status (2026-07-04):** RELEASING.md is drafted, but no release has been cut.
> The Developer ID certificate does not exist yet — issuing it is a human step
> gated behind Apple Developer 2FA (see [Prerequisites](#prerequisites)). The CI
> release workflow is also not yet activated (it still lives at `ci/release.yml`
> and moves to `.github/workflows/release.yml` in a later step); until then, use
> the local path.

---

## Prerequisites

You need three things in place before the first release. Two of them are one-time
human steps that require signing in to Apple with two-factor authentication —
**a build agent cannot do these; they are Jann's to do.**

1. **Xcode 26 (or its Command Line Tools) with the macOS 26 SDK.**
   `swift build` targets `.macOS("26.0")`, so an older toolchain cannot build
   Talkie at all. Notarization additionally needs the full Xcode for
   `xcrun notarytool` / `xcrun stapler` / `xcrun actool` (the Liquid Glass icon).

2. **A "Developer ID Application" certificate in the login keychain.** *(HUMAN —
   Apple Developer 2FA.)* Jann already holds an active Apple Developer Program
   membership, so this is a same-day cert *issuance*, not an enrollment with a
   review wait:

   - Sign in at [developer.apple.com](https://developer.apple.com) (or Xcode ▸
     Settings ▸ Accounts).
   - Certificates, Identifiers & Profiles ▸ Certificates ▸ **+** ▸ **Developer ID
     Application**.
   - Download it and double-click to install it in the **login** keychain.
   - Note the **Team ID** (the 10-character code in parentheses in the identity
     name) — you'll need it for the notary profile and the CI secrets.

   The identity string looks like:

   ```
   Developer ID Application: Your Name (TEAMID)
   ```

   Confirm it's installed:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

3. **A notary keychain profile.** *(HUMAN — Apple Developer 2FA; needs an
   app-specific password.)* `scripts/notarize.sh` authenticates to Apple's notary
   service through a stored keychain profile so it never sees a raw password.
   Create the profile once:

   - Generate an **app-specific password** at
     [appleid.apple.com](https://appleid.apple.com) ▸ Sign-In and Security ▸
     App-Specific Passwords.
   - Store the credentials under a profile named `talkie-notary`:

     ```bash
     xcrun notarytool store-credentials talkie-notary \
       --apple-id you@example.com \
       --team-id TEAMID \
       --password <app-specific-password>
     ```

   (This same command is documented in the header of `scripts/notarize.sh`.)

> **Never commit certificate material.** The `.p12`, its password, the Team ID,
> and the app-specific password are secrets. They live in your keychain and — for
> CI — in GitHub Actions secrets. This runbook documents *how*; it never contains
> the values themselves.

---

## Cutting a release locally

Once the prerequisites exist, one script does the whole build → sign → notarize →
staple → re-zip dance. **The first notarization run is a HUMAN dry-run** (it
submits to Apple and waits on their notary service; treat the first pass as a
rehearsal you watch to completion).

```bash
export TALKIE_DEVID_ID="Developer ID Application: Your Name (TEAMID)"
export TALKIE_NOTARY_PROFILE="talkie-notary"
./scripts/notarize.sh
```

What that does, all through the existing scripts (no changes at release time):

1. `scripts/notarize.sh` calls `scripts/build_app.sh release` with
   `TALKIE_SIGN_ID` set to your Developer ID identity. `build_app.sh` assembles
   `Talkie.app`, signs each **nested** helper inside-out first (`talkie-mcp`,
   `talkie` CLI — no app entitlements, their own identifiers), then signs the
   outer bundle. On a Developer ID identity it adds `--options runtime`
   (Hardened Runtime) and `--timestamp`, both of which notarization requires.
2. `notarize.sh` re-signs the bundle with Hardened Runtime + the entitlements
   file, zips it, submits with `xcrun notarytool submit --wait`, staples the
   ticket, validates, and re-zips the stapled app as `Talkie.zip` for
   distribution.

The output is `Talkie.zip` at the repo root — a notarized, stapled app a stranger
can open normally.

---

## Verifying the artifact

Run these after the notarize script finishes. All four must pass before the
release is real. The `spctl` / `stapler` checks are the ones that prove Gatekeeper
will let a stranger open it.

```bash
# 1. The staple actually attached.
xcrun stapler validate Talkie.app

# 2. Gatekeeper accepts it as a notarized Developer ID app.
spctl -a -t exec -vv Talkie.app
#    → must print: accepted
#    → and:        source=Notarized Developer ID

# 3. Entitlement audit — the privacy claim, restated on the shipped bundle.
codesign -d --entitlements - Talkie.app
```

### Entitlement audit — the privacy invariant

The `codesign -d --entitlements -` output must show **exactly these three**
entitlements and **no network entitlement** — Talkie's zero-network promise is not
just asserted in a doc, it's provable on the signed bundle:

| Entitlement | Why it's there |
|---|---|
| `com.apple.security.device.audio-input` | Microphone capture (dictation). |
| `com.apple.security.personal-information.calendars` | Read-only Calendar for the opt-in meeting-context feature. |
| `com.apple.security.automation.apple-events` | Pause/resume Music & Spotify while dictating (per-app Automation prompt still gates it). |

Crucially, the output must **NOT** contain:

```
com.apple.security.network.client
```

If a network client entitlement ever appears in that output, **stop** — do not
ship. The default Talkie build contains no networking code, and its signed bundle
must carry no network entitlement. (Paste the actual audit output into this file
once the first real release is cut, so every future release has a known-good
reference to diff against.)

Finally, a real end-to-end confidence check: unzip `Talkie.zip` on a **second Mac**
(or a fresh user account), double-click `Talkie.app`, and confirm it opens with at
most the one-time "downloaded from the internet" confirmation — no "unidentified
developer" wall.

---

## Cutting a release through CI

> **Not yet active.** The release workflow currently lives at `ci/release.yml`
> (and a duplicate at the repo root). Activating it — moving it under
> `.github/workflows/`, hardening the runner check, adding the gate + entitlement-
> audit steps — is a separate step (WS-J J4). Once that lands, this is the path.

### The tag convention

Releases are cut by pushing an **annotated version tag** in the form:

```
vMAJOR.MINOR.PATCH        e.g. v0.1.0, v0.2.0, v1.0.0
```

The release workflow triggers on `push` of any `v*.*.*` tag. It derives the
version by stripping the leading `v` (so `v0.1.0` → `0.1.0`), stamps it into
`Resources/Info.plist`, builds and notarizes via the same two scripts above, then:

- creates a GitHub Release for the tag,
- uploads the notarized asset as `Talkie-<version>.zip`,
- computes its `sha256`, and
- rewrites the two `# RELEASE:` lines in `Casks/talkie.rb` so the Homebrew cask
  resolves the just-published download.

**Tag a settled `main` commit only** — one that has been through CI. Never tag a
dirty tree or a commit from a parallel-session WIP branch. The cask-bump commit
lands directly on `main` mid-release, so other worktrees should `git pull --rebase`
afterward.

### Required repository secrets

The workflow builds a throwaway signing keychain from these secrets and creates
the `talkie-notary` profile from them, so `notarize.sh` runs unchanged. Set them
under **Settings ▸ Secrets and variables ▸ Actions**:

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12` | Base64 of the "Developer ID Application" `.p12` (see below). |
| `DEVELOPER_ID_CERT_PASSWORD` | The password protecting that `.p12`. |
| `TALKIE_DEVID_ID` | The identity string, e.g. `Developer ID Application: Your Name (TEAMID)`. |
| `APPLE_ID` | The Apple ID email used for notarization. |
| `APPLE_TEAM_ID` | The 10-character Team ID. |
| `APPLE_APP_PASSWORD` | The app-specific password for that Apple ID. |
| `KEYCHAIN_PASSWORD` | Any throwaway string — the password for the temp CI keychain. |

### Exporting and base64-encoding the `.p12`

`DEVELOPER_ID_CERT_P12` is your Developer ID certificate **and its private key**,
exported as a password-protected `.p12` and then base64-encoded so it survives as a
GitHub secret.

1. Open **Keychain Access**, find your **Developer ID Application** identity in the
   **login** keychain, and expand it so both the certificate *and* its private key
   are selected.
2. Right-click ▸ **Export 2 items…** ▸ save as `talkie-devid.p12`. Set an export
   password when prompted — that password is what goes into
   `DEVELOPER_ID_CERT_PASSWORD`.
3. Base64-encode the `.p12` into a single line and copy it to the clipboard:

   ```bash
   base64 -i talkie-devid.p12 | pbcopy
   ```

   Paste that as the value of the `DEVELOPER_ID_CERT_P12` secret. (CI decodes it
   with `base64 --decode` back into a `.p12` inside a temporary keychain, then
   deletes it — see the "Set up signing + notary credentials" step in the
   workflow.)
4. **Delete `talkie-devid.p12` from disk** once it's in the secret. It never
   belongs in the repo or in a synced folder.

---

## When notarization is rejected

If `notarytool submit --wait` returns `Invalid`, fetch the log to see why:

```bash
xcrun notarytool log <submission-id> --keychain-profile talkie-notary
```

The usual culprits are a nested binary that wasn't signed with Hardened Runtime +
timestamp, or a missing secure timestamp. `build_app.sh` already signs the nested
`talkie-mcp` and `talkie` CLI inside-out with the runtime + timestamp flags on the
Developer ID branch, so a clean tree should not hit this — but if it does, the log
names the exact file. Fix, rebuild, resubmit. (Notarization submissions are free,
so re-running is cheap.)

---

## Reference

- **`scripts/build_app.sh`** — assembles `Talkie.app` from the SwiftPM build and
  code-signs it (nested helpers inside-out, then the outer bundle). Adds Hardened
  Runtime + `--timestamp` automatically when the identity contains `Developer ID`.
  *Unchanged for release.*
- **`scripts/notarize.sh`** — the full Developer-ID sign → notarize → staple →
  re-zip flow. Reads `TALKIE_DEVID_ID` and `TALKIE_NOTARY_PROFILE`.
  *Unchanged for release.*
- **`Resources/talkie.entitlements`** — the three non-network entitlements audited
  above.
- **`Casks/talkie.rb`** — the Homebrew cask CI bumps on each release.
- **`docs/INSTALL.md`** — the install-side story (Homebrew, direct download,
  build-from-source) that these releases make true.
