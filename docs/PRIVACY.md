# Privacy — nothing leaves your Mac

Talkie is a voice layer for your Mac that runs entirely on your machine. Your
audio, your transcripts, your meetings — none of it is sent anywhere. This page
explains exactly how that works, and, more importantly, how *you* can prove it
for yourself in about a minute. We would rather hand you the commands than ask
you to trust the copy.

The short version: Talkie holds one permission (your microphone), ships with no
network entitlement, and contains zero networking code. It is open source, so
you can grep it; it is signed, so you can dump its entitlements; and it never
opens a connection, so you can watch your firewall stay quiet.

---

## What Talkie can do — the one permission

Talkie's shipped (default) build requests exactly **one** capability in its code
signature:

| Entitlement | What it allows | Why Talkie needs it |
|---|---|---|
| `com.apple.security.device.audio-input` | Microphone capture under the Hardened Runtime | To hear you while you hold the dictation key, and to record meetings |

That is the whole list. You can confirm it against the signed binary:

```sh
codesign -d --entitlements - /Applications/Talkie.app
```

You should see `com.apple.security.device.audio-input` and **nothing else** — in
particular, **no `com.apple.security.network.client`**. If you ever see a network
entitlement on a build labelled plain "Talkie", that is a bug, and the in-app
Privacy panel (which reads the live signature, not hardcoded text) will show it
in red.

Alongside the microphone entitlement, Talkie asks the system (TCC) for a few
runtime permissions you grant by hand the first time: Microphone, Speech
Recognition, Input Monitoring (to notice your dictation key), and Accessibility
(to paste the transcribed text into the app you're typing in). These are
operating-system permission prompts, not network access — none of them let Talkie
reach the internet.

---

## There is zero network code — and here is how to check

Talkie's on-device targets — the app itself (`Sources/Talkie`) and the local MCP
peer (`Sources/TalkieMCP`) — contain no networking code at all. No `URLSession`,
no sockets, no `Network.framework`, no raw URLs. Because Talkie is open source,
this is not a claim you have to take on faith — it is a `grep` you can run:

```sh
grep -rniE "URLSession|NSURLConnection|URLRequest|NWConnection|getaddrinfo|https?://" \
  Sources/Talkie Sources/TalkieMCP
# → nothing
```

We run this exact check in CI on every change, via
[`scripts/check-no-network.sh`](../scripts/check-no-network.sh). If a single
network symbol ever lands in the on-device core, the build fails. Run it
yourself:

```sh
./scripts/check-no-network.sh
# PASS — no network symbols in Sources/Talkie or Sources/TalkieMCP.
```

### Watch it stay silent (the firewall test)

Source and signature tell you what Talkie *is*. A live firewall test tells you
what it *does*. Launch Talkie, then watch it from the outside while you dictate,
record a meeting, and generate a Brief:

```sh
nettop -p $(pgrep Talkie)        # live byte counters — they stay at zero
lsof -i -a -p $(pgrep Talkie)    # open sockets owned by Talkie — there are none
```

Or use the tool reviewers already trust: install
[Little Snitch](https://www.obdev.at/products/littlesnitch/index.html) (or LuLu)
in alert mode, use every feature, and watch Talkie never once ask to connect.
That silence is the proof.

> One honest asterisk. The very first time you use a new speech locale or an
> Apple Intelligence feature, **macOS itself** downloads the on-device model
> (through its own asset services — `nsurlsessiond` and friends, not Talkie). In
> a firewall watcher you'll see those *system* daemons, not Talkie, and only
> once. After that, everything runs locally and Talkie itself never opens a
> connection. We disclose this rather than hide it — auditing even the system's
> behaviour is part of the point.

---

## The wall: what actually keeps the network out

It would be easy — and wrong — to claim "the operating system makes it impossible
for Talkie to connect." That is only true for *fully App-Sandboxed* apps, and
Talkie's shipping build deliberately is **not** sandboxed (see the next section
for why). So here is the accurate description of the wall, with no overclaiming:

1. **Hardened Runtime.** Talkie's notarized builds run under the Hardened
   Runtime. This is the signed, tamper-evident envelope: the entitlement list is
   baked into the code signature, so the single-capability fact above is
   auditable and cannot be quietly changed without re-signing.

2. **No `com.apple.security.network.client` entitlement.** For a non-sandboxed
   Hardened-Runtime app, the *absence* of this entitlement is **documentary, not
   a kernel-enforced firewall** — the Hardened Runtime by itself does not block
   outbound traffic. We say this plainly because it is true, and because
   inflating it ("the kernel forbids it") would be dishonest for the default
   build. The real guarantee for the shipping build is the combination of *no
   network code* (grep it) + *no network entitlement* (codesign it) + *your own
   firewall* (watch it). That stack is stronger than a marketing sentence,
   because you can verify every layer yourself.

3. **Module separation — the structural lock.** The network wall is enforced by
   the build system, not by good intentions. The only place in the entire repo
   allowed to touch the network is a separate module, **`Sources/TalkieBridge`**,
   which is the opt-in Claude bridge. The default Talkie build **does not link or
   import it** — the app core depends on a protocol (`Summarizer`), never on the
   bridge module. Anything networked lives in `TalkieBridge`, compiles only into
   the clearly-labelled **"Talkie (Connected)"** flavor, ships **off by default**,
   and is gated behind a deliberate consent step that discloses exactly what
   bytes would leave. This is why `scripts/check-no-network.sh` scans
   `Sources/Talkie` and `Sources/TalkieMCP` but deliberately **excludes**
   `Sources/TalkieBridge`: the bridge is *expected* to contain network code, and
   the wall's job is to keep that code from ever reaching the core.

### Why not the full App Sandbox?

You might ask why Talkie doesn't just turn on the full App Sandbox with no
network entitlement, so the kernel forbids all outbound traffic. The honest
answer: it would break the product.

The App Sandbox blocks `CGEvent.post` — the synthesizing of keystrokes into other
apps — which is *exactly* how Talkie types your dictated text into whatever app
you're using. Under the sandbox, Talkie would transcribe your speech and then
fail to paste a single character. The sandbox would also block writing to your
plain `~/Talkie Meetings/` folder (forcing it into an opaque container), likely
break the Core Audio process tap used to capture meeting audio, and degrade the
Accessibility reads Talkie uses for context. So the full sandbox is the wrong
tool for the shipping build; the Hardened Runtime + absent network entitlement +
module separation is the right one.

For the curious, we keep the door open to a *kernel-enforced* demonstration: a
separate, sandboxed audit build (with the App Sandbox on and no network
entitlement) whose only job is to prove the kernel kills an attempted connection.
That artifact intentionally can't paste or write meetings — it is never shipped
to you, it just backs the "with the sandbox on, the OS itself refuses" claim and
attaches it to the right thing.

---

## Where your data lives

Everything Talkie produces stays on your disk, in plain folders you own:

- `~/Library/Application Support/Talkie/` — settings and history.
- `~/Talkie Meetings/` — your meeting recordings and transcripts, kept as a
  plain home folder (deliberately *not* `~/Documents`, to stay out of TCC) so you
  can point any local tool at it.

No copy is made anywhere else, and nothing is uploaded.

---

## Verify it yourself — the 60-second checklist

1. **Read the permissions:** `codesign -d --entitlements - /Applications/Talkie.app`
   → one entitlement, no `network.client`.
2. **Grep the source:** `./scripts/check-no-network.sh` → PASS.
3. **Watch the wire:** `nettop -p $(pgrep Talkie)` (or Little Snitch in alert
   mode) while you use every feature → zero bytes, zero alerts.

Three independent angles — what Talkie is allowed to do, what its code does, and
what it does on the wire — all pointing at the same answer. Nothing leaves your
Mac. You don't have to believe us; you can check.
