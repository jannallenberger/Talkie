# Talkie — Cores Standards (`_CORES_STANDARDS.md`)

> The binding contract for the four "cores" workers (features 15, 16, 17, 18) building
> the production-hardening + networked-accelerator layer in parallel. Read
> `_UNIFICATION.md` §3 (module boundaries) and §4.1 (privacy/sandbox) first; this file
> turns those into pinned, non-negotiable rules so four people can work at once without
> colliding, forking a protocol, or punching a hole in the privacy wall.
>
> **Owned by:** the cores orchestrator. **Floor:** macOS 26.0, Apple Silicon, Swift 6
> strict concurrency (`.v6`). **Generated:** 2026-06-15.
>
> If a per-feature plan (15/16/17/18) and this file ever disagree, **this file wins**
> for the four things it governs: the network wall, target/dir naming, file ownership,
> and the consistency rules below. Everything else, defer to the plan.

---

## 0. The one sentence

Talkie ships **provably zero-network by default**; only `Sources/TalkieBridge/` may ever
touch the network, every other line you write stays on-device, and you write **only**
into the directory your feature owns — never into `Sources/Talkie/` and never into
`Package.swift`.

---

## 1. THE NETWORK WALL (the invariant that outranks everything)

This is the product's whole thesis (`_UNIFICATION.md` §4.1). It is enforced by *target
separation*, not by good intentions. The rule is mechanical:

- **`Sources/TalkieBridge/` is the ONLY place** in the entire repo allowed to construct
  a network client — `URLSession`, `NSURLConnection`, `NWConnection`, `CFStream`,
  `Network.framework`, or any raw `http://` / `https://` socket. (Feature 18 verified:
  there is **no official Anthropic Swift SDK**, so raw `URLSession` in `TalkieBridge` is
  the correct path and keeps "zero dependencies" true.)
- **The Talkie app target (`Sources/Talkie/`) and `talkie-mcp` (`Sources/TalkieMCP/`)
  must NEVER** import or reference a network client. The app target carries the audio-input
  entitlement and deliberately **omits** `com.apple.security.network.client`
  (`Resources/talkie.entitlements`). `talkie-mcp` is stdio-only, a read-mostly peer of the
  on-disk stores.
- **The app core must never `import TalkieBridge`.** The bridge conforms to the
  `Summarizer` protocol and is injected (or absent) at the composition root
  (`AppDelegate`) behind a feature flag + consent. The core depends on the *protocol*,
  never the module. (Feature 18 owns this conformance and injection design — the worker
  writing it must keep `import TalkieBridge` out of every file under `Sources/Talkie/`.)
- **`requiresNetwork` is the runtime gate.** Any `Summarizer`/`TranscriptionBackend` whose
  `requiresNetwork == true` (i.e. `ClaudeBridge`) must refuse to instantiate in the
  sandboxed default flavor. It is OFF by default, requires a deliberate enable, and
  discloses exactly what bytes leave (per-call disclosure surface).

### 1.1 Feature 15's no-network check — the exact scan scope (PIN THIS)

Feature 15's CI/proof grep is the wall's enforcement. It **MUST scan `Sources/Talkie`
and `Sources/TalkieMCP`** and **MUST EXCLUDE `Sources/TalkieBridge`** (the bridge is
*expected* to contain network code — scanning it would be a false positive that defeats
the gate). Pin the scope explicitly so the gate keeps passing once the bridge lands:

```sh
# Feature 15 zero-network gate — scans the local targets, EXCLUDES the bridge.
grep -rniE \
  "URLSession|NSURLConnection|NWConnection|CFStream|Network\.framework|http://|https://" \
  Sources/Talkie Sources/TalkieMCP
# → MUST return nothing. (Sources/TalkieBridge is intentionally NOT scanned.)
```

The "verify it yourself" claim stays honest the same way the plan states it: source grep
of the *local* targets + the signed entitlement list (`codesign -d --entitlements -`) +
a live firewall test (`nettop -p $(pgrep Talkie)` / `lsof -i -a -p $(pgrep Talkie)` show
zero bytes/sockets). Do **not** overclaim a kernel-enforced block for the non-sandboxed
default build — the absence of `network.client` is documentary there, and the honesty
invariant (`_UNIFICATION.md` §4.3) forbids inflating it.

---

## 2. TARGET & DIRECTORY NAMING (pinned exactly — do not improvise)

| Feature | SwiftPM target | Kind | Source directory (write here ONLY) |
|---|---|---|---|
| 17 benchmark | **`talkie-bench`** | executable | **`Sources/TalkieBench/`** |
| 18 Claude bridge | **`TalkieBridge`** | library | **`Sources/TalkieBridge/`** |

Reference (already in `Package.swift`, do not touch): app exec `Talkie` at
`Sources/Talkie`; MCP exec `talkie-mcp` at `Sources/TalkieMCP`.

**The hard rule: workers write source files ONLY into their own `Sources/...` directory
and must NOT edit `Package.swift`.** The orchestrator adds the two new targets to
`Package.swift` *after* the worker source lands, using the exact `name`/`path` pinned
above (so the executable product name `talkie-bench` and the module name `TalkieBridge`
are stable for downstream callers, CI, and `import` statements). If your target needs an
external dependency (e.g. 18 has none — raw `URLSession`; 17 may gate WhisperKit behind a
trait/flag), describe it in your plan/README for the orchestrator to wire; do not add it
yourself.

---

## 3. FILE OWNERSHIP (disjoint — no two workers touch the same path)

Each worker owns a set of directories. The sets do not overlap. **No worker edits any
existing file under `Sources/Talkie/`** (the app core is off-limits to all four —
including the `Summarizer`/`TranscriptionBackend` protocol files, which are Tier-0 work
owned elsewhere; you *consume* them, you do not author them here).

| Feature | Owns (writes here) |
|---|---|
| **15** zero-network proof | `scripts/` (CI gate + verify scripts), `Resources/` (entitlements/Info.plist proof inputs, sandboxed audit-build flavor), `docs/` (the proof writeup) |
| **16** install & update | `Casks/` (Homebrew cask), `.github/workflows/` (release pipeline), `scripts/` (notarize/DMG/appcast tooling), `docs/` (install docs) |
| **17** benchmark | `Sources/TalkieBench/` (the harness + Python scorer + chart) |
| **18** Claude bridge | `Sources/TalkieBridge/` (the `ClaudeBridge` impl, Keychain, consent/disclosure types) |

**Shared-directory rule (15 ↔ 16 both touch `scripts/` and `docs/`):** namespace your
files so they never collide. 15 owns `scripts/privacy-*` / `scripts/no-network-*` and
`docs/PRIVACY*.md`; 16 owns `scripts/notarize*` / `scripts/dmg*` / `scripts/appcast*` /
`scripts/release*` and `docs/INSTALL*.md`. Do **not** edit a file the other owns; if you
need a change in the other's file, leave a note for the orchestrator. Neither edits the
existing `scripts/build_app.sh` / `scripts/notarize.sh` / `scripts/run.sh` in place
without flagging it — 16 extends the signing path for Sparkle and 15 reads the
entitlements; coordinate through the orchestrator, don't both rewrite the same script.

---

## 4. CONSISTENCY (voice, licensing, off-by-default)

- **Brand voice in every doc/UI string:** warm, honest, calm, second-person; one accent
  per view; match `DesignSystem.swift` for values and `BRAND.md` for philosophy. **Never
  invent metrics, percentiles, or facts** — cite provenance ("because you said…",
  "measured on this machine"). This is load-bearing for 15 (the proof must be true, not
  marketed) and 17 (the benchmark replaces a borrowed/mis-attributed "~55% faster" line
  with a number *we* generated, clearly stating what was and wasn't measured).
- **Licensing must be called out explicitly:**
  - **17 (dataset & tools):** LibriSpeech `test-clean` is **CC BY 4.0** (attribute it);
    the SpeechAnalyzer CLI template is **MIT**; `jiwer` is **MIT**; baseline is labeled
    **"Whisper Large V3" (full), not Turbo**. Document the corpus license + WhisperKit
    license in the harness README.
  - **18 (API / model ids):** use the accurate current Claude model id **`claude-opus-4-8`**
    as the documented default and the real pricing from the **claude-api skill — do not
    guess; re-verify at build time**. Key handling is Keychain-only; no key in source,
    logs, or disclosure payloads.
- **Everything networked is OFF by default.** 18 (`ClaudeBridge`) ships disabled with a
  deliberate consent gate; 16 (Sparkle appcast) is **opt-in** and transparent, and must
  be reconcilable with — or absent from — the sandboxed default build, never a silent
  daily callback in a "zero-network" app. 15 defines and the others respect the two build
  flavors: **`Talkie`** (default, no network entitlement) vs. **`Talkie (Connected)`**.

---

## Summary

Four workers build Talkie's hardening + cloud-accelerator layer in parallel under one
rule above all: the network wall — `Sources/TalkieBridge/` is the sole place network code
may live, the app and `talkie-mcp` targets never touch it, and feature 15's no-network
gate scans `Sources/Talkie` + `Sources/TalkieMCP` while deliberately excluding the
bridge. Targets and directories are pinned exactly (`talkie-bench` → `Sources/TalkieBench/`,
`TalkieBridge` → `Sources/TalkieBridge/`); workers write source only into their own
directory and never edit `Package.swift` — the orchestrator adds the targets afterward.
File ownership is disjoint (15: scripts/Resources/docs; 16: Casks/.github/scripts/docs;
17: TalkieBench; 18: TalkieBridge), no worker touches any existing `Sources/Talkie/` file,
and shared `scripts/`/`docs/` are namespaced to avoid collisions. Consistency is enforced
through honest second-person brand voice with no invented metrics, explicit licensing
notes (17's CC BY 4.0 corpus, 18's `claude-opus-4-8` model id + Keychain key handling),
and every networked piece shipping off by default behind the `Talkie` vs.
`Talkie (Connected)` flavor split.
