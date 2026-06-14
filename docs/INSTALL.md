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

The whole app is open source. If you'd rather build from the repo:

```bash
git clone https://github.com/jannallenberger/Talkie.git
cd Talkie
./scripts/run.sh      # builds Talkie.app and launches it
```

This produces an ad-hoc local build — great on your own Mac, not for sharing.
See `README.md` for the full developer setup, and `scripts/notarize.sh` if you
have an Apple Developer account and want to sign + notarize your own copy.

---

## A note on staying private (and on auto-update)

Talkie's whole promise is that nothing leaves your Mac. An update mechanism is
the one place a "private" app most plausibly phones home, so we've drawn the line
clearly:

- **The build you install here is the default, zero-network flavor.** It contains
  **no in-app updater** and no networking code at all. You update it the way you
  installed it — `brew upgrade`, or downloading the next release — both of which
  are *you* reaching out, never the app.

- **In-app auto-update is a separate, opt-in "Connected" flavor.** We may publish
  a build that includes [Sparkle](https://sparkle-project.org) (a standard,
  open-source macOS updater) so the app can offer to update itself. Sparkle works
  by fetching a version list over the network — i.e. it *does* phone home — so it
  lives only in the Connected flavor, never the default one. Even there it is
  **off by default**: it checks only when you click "Check for Updates…", or after
  you flip a Settings toggle on. When it checks, it makes a single HTTPS request
  to read the published version list and sends nothing about you — never your
  dictation, your meetings, or your context.

If you want a build that *cannot* reach the network, install the default flavor
(the one this page sets up) and update by hand. If you'd rather the app keep
itself current, the Connected flavor exists for exactly that — and it tells you,
in plain words, every time it's about to touch the network.

Either way, the choice is yours and it's visible. That's the point.
