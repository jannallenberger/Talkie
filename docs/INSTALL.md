# Installing Talkie

Talkie is a fast, private, on-device dictation app for macOS. Everything here
gets you a real, signed copy of Talkie running on your Mac — your voice never
leaves your machine, and nothing about how you install changes that.

**You need:** macOS 26 (Tahoe) or later, on an Apple Silicon Mac.

---

## The easy way — Homebrew

If you have [Homebrew](https://brew.sh):

```bash
brew tap jannallenberger/talkie https://github.com/jannallenberger/Talkie
brew install --cask talkie
```

That downloads the notarized Talkie.app from the latest GitHub Release and drops
it in `/Applications`. Open it, grant the three permissions it asks for once, and
you're dictating.

To update later:

```bash
brew upgrade --cask talkie
```

That's *your shell* fetching the new version when you ask it to — the Talkie app
itself never reaches out. To remove Talkie and its settings (but keep your
meetings):

```bash
brew uninstall --cask --zap talkie
```

`--zap` clears Talkie's caches and preferences. It deliberately leaves
`~/Talkie Meetings/` alone — that's your data, and we don't delete it.

---

## The manual way — download the DMG/zip

Prefer not to use Homebrew? Every release has a notarized download attached.

1. Open the [latest release](https://github.com/jannallenberger/Talkie/releases/latest).
2. Download `Talkie-<version>.zip`.
3. Unzip it and drag **Talkie.app** into `/Applications`.
4. Open it. Because it's notarized by Apple, it opens without the scary
   "unidentified developer" wall. The first launch may still show a one-time
   "downloaded from the internet" confirmation — that's normal; click **Open**.

The first time you run a freshly signed build, macOS re-asks for the three
permissions (microphone, speech recognition, input monitoring) one last time.
After that they stick.

---

## Building it yourself

The whole app is open source. This is the tinkerer / contributor path — for most
people the Homebrew cask above is simpler, since it's a ready-made notarized
download and needs no toolchain. But if you'd rather build from the repo, one
command takes a fresh Mac all the way to a running, locally-built Talkie:

```bash
curl -fsSL https://raw.githubusercontent.com/jannallenberger/Talkie/main/scripts/install.sh | sh
```

Two honest asterisks, up front rather than discovered:

- **It may trigger a multi-GB download.** Building needs Apple's Swift 6 toolchain
  with the macOS 26 SDK. If you don't already have Xcode, the script kicks off
  Apple's Command Line Tools installer — *a multi-GB download*. Talkie itself is
  small; the toolchain is the big part. When it finishes, re-run the same command.
- **A Command-Line-Tools-only build skips the Liquid Glass app icon.** That icon
  is compiled by `xcrun actool`, which ships only with the full Xcode app, so a
  CLT-only build works but wears a plain icon. Install full Xcode if you want it.

Prefer to read before you pipe a script into your shell? Good instinct — it's
about 60 lines: [scripts/install.sh](../scripts/install.sh). All it does is check
your Mac (Apple Silicon, macOS 26+), make sure the toolchain is present, clone (or
fast-forward) the repo into `~/Talkie`, and hand off to `scripts/run.sh`. The only
thing that touches the network is `git clone` — *your* shell fetching source on
your behalf, exactly like `brew` does; the Talkie app never reaches out. Re-running
the same command later is also how you **update** a source install.

> **Note:** the repo is private for now, so this one-liner (and an anonymous
> `git clone`) only work once the repo is public, or for someone already signed in
> to GitHub. Until then it's the contributor path.

Rather do it by hand? The equivalent, step by step:

```bash
git clone https://github.com/jannallenberger/Talkie.git
cd Talkie
./scripts/run.sh      # builds Talkie.app and launches it
```

Either way you get an ad-hoc local build — great on your own Mac, not for sharing.
See `README.md` for the full developer setup, and `scripts/notarize.sh` if you
have an Apple Developer account and want to sign + notarize your own copy.

---

## Staying current on a dev build (collaborators)

While Talkie isn't notarized yet, collaborators run a **dev build** and update it
in place — no rebuilding from source, no toolchain needed on their Mac.

**The publisher** cuts a build whenever there's something to share:

```bash
./scripts/release_dev.sh
```

That builds the **dev-tools flavor** (the in-app updater is compiled in), signs it
with a stable identity so permissions persist across updates, and uploads it to a
GitHub Release tagged `dev-<build>`.

**The collaborator** updates from inside the app: **Developer ▸ App updates ▸
Update**. Talkie downloads the new build, swaps itself in place, and relaunches.
With "Check for updates when Talkie launches" on (the default), it also offers the
newest build a few seconds after each launch. Because the repo is private, the
first time you'll either sign in with the GitHub CLI (`gh auth login`) or paste a
read-only access token — stored in your Keychain, never in the app.

This updater is **only ever in the dev flavor**. It is a separate module that the
public build does not link at all (see the note below), so the released app stays
exactly as offline as it claims to be.

---

## A note on staying private (and on auto-update)

Talkie's whole promise is that nothing leaves your Mac. An update mechanism is
the one place a "private" app most plausibly phones home, so we've drawn the line
clearly. There are exactly three build flavors, and only one of them is what you
install here:

- **default** — the **zero-network flavor**, and the only one CI ever releases.
  It links **no updater** and contains no networking code at all. You update it
  the way you installed it — `brew upgrade`, or downloading the next release —
  both of which are *you* reaching out, never the app. This is the build this
  page sets up.

- **dev-tools** (`TALKIE_DEV_TOOLS=1`) — a build for collaborators, with the
  in-app updater (`TalkieUpdater`) compiled in. It follows the **dev-`N` channel
  only** (it can never offer a public release) and is **consent-gated**: the first
  time it would contact GitHub, it asks once, in Developer ▸ App updates. Until
  you say yes, it makes **zero** outbound connections — no launch-time check, not
  even a `gh auth status` probe. See "Staying current on a dev build" above.

- **Connected** — reserved for the opt-in Claude bridge (`TalkieBridge`), the only
  module allowed to summarize over the network. **Not shipped today.** When it
  exists it will be its own clearly-labelled flavor, off by default and gated
  behind a consent step that discloses exactly what bytes would leave.

**On the updater specifically: there is no Sparkle.** Talkie's updater is
`TalkieUpdater` — a hand-rolled, **zero-dependency** module that reads the private
repo's `dev-*` releases through your own `gh` login or token. Adding Sparkle would
be Talkie's *first* external dependency, and it is rejected under the
zero-dependency policy. `TalkieUpdater` is the only updater there is, and it never
ships in the default build — `Package.swift` links it solely when
`TALKIE_DEV_TOOLS=1`, so the released app carries no update or network code to
begin with.

If you want a build that *cannot* reach the network, install the default flavor
(the one this page sets up) and update by hand. If you're a collaborator who'd
rather stay on the newest dev build, the dev-tools flavor exists for exactly that
— and it asks, in plain words, before its first contact and tells you every time
it's about to check.

Either way, the choice is yours and it's visible. That's the point.
