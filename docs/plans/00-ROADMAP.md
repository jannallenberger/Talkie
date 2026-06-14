# 00 — Talkie Master Roadmap

> The single sequenced build plan that turns 20 separate feature plans into ONE
> product. Read `_CURRENT_STATE.md` first (ground truth), `_UNIFICATION.md` second
> (how the pieces interlock), this third (the order to build them in).
>
> **Generated:** 2026-06-14 by the roadmap-synthesizer pass.
> **Floor:** macOS 26.0, Apple Silicon, Swift 6 strict concurrency (`.v6`).
> **Inputs:** `_UNIFICATION.md`, `_CURRENT_STATE.md`, and the 20 plans `01`–`20`.
>
> **STATUS UPDATE (2026-06-14, post-plan):** the repo moved forward during planning.
> **Far-end capture (01) is now MERGED to `main`** (`99a69ff`/`1fa7624`/`a3f95c6`) —
> so **"PR 2 — rebase+merge far-end" is DONE.** Two brand commits also landed (real
> logo + feather art; clay icons + grouped settings). A German-meeting/locale
> transcription bug was fixed (`1fa7624`). M0's revised remaining work = **the
> protocol pass (PR 1)** + **the Context Graph MVP (PR 3)**; 01's leftover scope
> (permission UX, two-analyzer load, watchdog, Phase-3 diarization) moves into a
> later 01 slice. The author works in **parallel sessions** on this same repo, so
> implementation should run in an **isolated git worktree** to avoid colliding with
> live edits (decided 2026-06-14: "plans only" until an explicit hand-off sync).

---

## 1. Executive framing (one paragraph)

Talkie already is, today, a complete Wispr-Flow-class on-device dictation tool with
zero network code and one audio entitlement; the meeting recorder is mic-only on
`main` and Me/Them-labeled on an unmerged, cleanly-rebaseable branch. The work ahead
is **not** "build two products" — both already exist or nearly do. The work is to
route **both voice surfaces into ONE on-device Personal Context Graph** (feature 05,
the keystone) and then make that shared brain do things neither Wispr Flow nor
Granola can structurally copy: voice commands that know your meetings, a local MCP
server and Claude connector over your own data, universal note export, on-device
semantic search, and a *provable* zero-network privacy wall. Every milestone below
is sequenced so that (a) the graph and its two shared protocols land first as the
spine, (b) Milestone 1 ships the honest "Wispr Flow + Granola, free, on-device, open
source" claim, and (c) each later milestone bolts on one moat layer that depends on
the graph being real. The disruption is the unification; the roadmap exists to keep
20 features ONE thing.

---

## 2. Dependency graph (what blocks what)

```
                       ┌───────────────────────────────────────────────┐
   TIER 0 (the spine)  │  PROTOCOL PASS (do once, behavior-preserving)  │
   build these first   │   TranscriptionBackend  ◄── conform existing   │
                       │   Summarizer            ◄── TranscriptionEngine│
                       │   NoteDestination       ◄── + CleanupEngine    │
                       │   (CommandIntent, MeetingContextProvider:       │
                       │    define stubs now, implement in their feats)  │
                       └───────────────┬───────────────────────────────┘
                                       │
   ┌───────────────────────────────────┼────────────────────────────────────────┐
   │  05 CONTEXT GRAPH (KEYSTONE)       │  01 FAR-END → main (rebase, ~conflict-free)│
   │  model+store+extractor+query API   │  gives the graph its richest feed (Me/Them)│
   │  rewrites the Brief as projection  │                                            │
   └───────┬────────────────────────────┴───────────────┬───────────────────────┘
           │ blocks: 04 06 07 09 19 (and sharpens 08/12) │ blocks: 02 04 (dual-engine bias)
           │                                             │
   ┌───────▼─────────────────────────────────────────────▼───────────────────────┐
   │  TIER 1 — product surfaces (need only Tier 0 / each other lightly)            │
   │                                                                               │
   │   02 notes fusion ──needs Summarizer+NoteDestination, lands on rebased 01     │
   │   04 calendar ─────needs 01 merged (dual-engine bias) + writes Person nodes→05 │
   │   08 voice commands ──CommandIntent layer; ships graph-DARK, lights up w/ 05   │
   │   12 edit-by-voice ──the selection branch of 08's router (shared machinery)    │
   │   11 macros ────────simplest CommandIntent; proves the router; no hard deps    │
   │   03 auto-detect ───introduces MeetingContextProvider.detect(); 01 is better    │
   │   10 export ────────NoteDestination UX+templating; graph optional for links    │
   │   13 per-app profiles ─extends CleanupStyle resolution; filters 05 biasPhrases  │
   │   14 HUD switcher ──surfaces 13's resolved profile; shares HUD with 08         │
   │   15 ZERO-NET PROOF ─lock the wall BEFORE any networked module exists          │
   └───────┬───────────────────────────────────────────────────────────────────────┘
           │ 08 + 05 blocks 09;  15's wall gates 18/07b;  06 blocks 07a
           │
   ┌───────▼───────────────────────────────────────────────────────────────────────┐
   │  TIER 2 — capstones (the demos that sell the thesis)                           │
   │   09 cross-surface ──needs 05 + 08. THE pitch sentence. Headline demo.          │
   │   06 local MCP ─────needs 05 for commitments/entities; first SwiftPM dep        │
   │   19 semantic search ─needs 05 for entity hits; ships history+meetings first    │
   │   07 Claude connector ─07a needs 06's binary; 07b needs 15's wall (network)     │
   │   18 Claude bridge ──the ONLY networked Summarizer; behind 15's wall, OFF default│
   └───────────────────────────────────────────────────────────────────────────────┘

   CROSS-CUTTING / ANYTIME (low coupling, schedule by capacity):
     16 install & update  — cask+DMG MVP anytime; Sparkle needs 15's connected flavor
     17 benchmark         — Talkie-only MVP anytime; validates 20's backends later
     20 pluggable backend — needs the TranscriptionBackend protocol; widens OSS reach
```

**The three load-bearing edges (call these out to every builder):**

1. **05 (Context Graph) is the gate.** It blocks 04, 06, 07, 09, 19 and reshapes the
   Brief. Build its model + query API (`ContextGraphStore`/`ContextGraphSnapshot`)
   before any consumer writes a line against it. Consumers that *can* ship graph-dark
   (08, 12, 10, 09's fallback path) must, so they're not stuck behind it.
2. **The protocol pass is cheap now, expensive later.** Conform `TranscriptionEngine`
   → `AppleSpeechBackend`, the four Foundation-Models actors → `OnDeviceLLM`, and
   `writeMarkdown` → `TalkieFolderDestination` *while the impls are still the existing
   on-device code*. This is a behavior-preserving refactor that stops 01/02/18/20 from
   forking parallel engines. Define `CommandIntent` and `MeetingContextProvider`
   types now too (even if implemented later) so 03/04/08/12 share one file, never a
   fork.
3. **Merge far-end (01) early and lock the sandbox (15) early.** Far-end is a
   conflict-free rebase that gives the graph its best data (Me/Them turns). 15's
   *structural* network wall must exist before the first networked module (18/07b) can
   possibly leak across it — the wall is built-in, not bolted-on.

---

## 3. Milestones (grouped, in build order)

Sizes use the plans' own scale: **S** ≈ <1 day, **M** ≈ 1–3 days, **L** ≈ 3–6 days,
per sub-step. Milestone size is the rough sum of its must-ship slices (MVP slices,
not full features — the "full feature" rows are deferred unless noted).

### Milestone 0 — The Spine (foundation; nothing user-visible ships alone)

**Features:** the Tier-0 protocol pass (from 01/02/18/20), plus **05** MVP and the
**01** rebase-merge.

**What ships:**
- `TranscriptionBackend`, `Summarizer`, `NoteDestination` protocols defined; the
  existing actors conformed with **zero behavior change**; `CommandIntent` +
  `MeetingContextProvider` types defined (impls later).
- **01 merged to main** as-is (Me/Them speaker-labeled meetings become real).
- **05 MVP:** heuristic Context Graph (Entity/Provenance/EntityID + JSON store +
  Stage-1 heuristic extractor + `biasPhrases` rewiring `AppDelegate`'s ad-hoc union)
  and **the Brief rewritten as a graph projection**. No new tab, no model required.

**Headline outcome (internal):** one brain exists and already improves recognition +
the Brief; meetings are speaker-labeled; every later feature has its seams.

**Rough size:** **L** (05 model+Stage-1 ≈ M+M, Brief+bias rewire ≈ S+S, protocol
pass ≈ M, 01 rebase ≈ S, two-analyzer load check ≈ S–M).

---

### Milestone 1 — "Wispr Flow + Granola, free, on-device, OSS" (the launch core)

**Features:** **02** (notes fusion), **04** (calendar), **08** (voice commands MVP),
**12** (edit-by-voice), **11** (macros), **15** (zero-net proof MVP+wall), **16**
(install MVP), **17** (benchmark MVP), **10** (export default + protocol).

**What ships (user-visible):**
- **Granola magic:** type sparse notes live during a meeting; at stop they fuse with
  the Me/Them transcript into a 3-section Markdown note (Notes + Summary + Transcript)
  — feature 02. Meetings get **real titles + attendee names** from the calendar and
  pre-biased recognition — feature 04.
- **Voice copilot:** say "make this a list / fix this / translate this" over a
  selection and it rewrites on-device with preview + undo — features 08 + 12. Plus
  curated **voice macros** ("insert my address") — feature 11.
- **Provable privacy:** an in-app Privacy panel listing actual entitlements + the
  structural network wall (`requiresNetwork` gate, connected build flavor stubbed) —
  feature 15. The honest selling surface.
- **Frictionless install:** `brew install --cask` of a notarized DMG — feature 16 MVP.
- **Honest benchmark:** a defensible "WER X% / N× real-time on test-clean, M-series"
  number to replace the README's borrowed claim — feature 17 MVP.
- **Export that isn't Obsidian-locked:** the `~/Talkie Meetings/` folder generalized
  behind `NoteDestination` with optional YAML/wikilinks/tags off by default —
  feature 10.

**Headline outcome:** Talkie genuinely *is* "Wispr Flow + Granola, $0, on-device,
open source — nothing leaves your machine, provably." This is the public-launch cut.

**Rough size:** **XL** (the biggest milestone: ~8 features at MVP slice each, mostly
M with a couple of S). The command layer (08+12+11) and notes fusion (02) are the
heaviest; 04/10/14-class items are light.

> **Sequencing inside M1:** land 15's wall + 10's `NoteDestination` early (they're
> infra the others lean on), then 02/04 (meeting side), then 08→12→11 (command side,
> in that order so 12/11 adopt 08's router). 16/17 MVPs can land anytime in parallel.

---

### Milestone 2 — Polish & visible intelligence

**Features:** **13** (per-app profiles), **14** (HUD switcher), **05** full (Memory/
recall tab + Stage-2 LLM extraction), **03** (meeting auto-detect & consent banner).

**What ships:**
- **Per-app profiles** (13): full per-bundle-id profiles (vocab subset, cleanup
  style/level, insertion mode, active macros), extending today's per-category styles.
- **HUD switcher** (14): see/cycle the resolved cleanup style from the pill without a
  Settings trip — visible intelligence.
- **05 full:** the Memory tab (entity chips, search, provenance, commitment status)
  and Stage-2 LLM extraction (alias merge, structured commitments, entity notes).
- **Auto-detect** (03): "Meeting detected — record?" consent banner via a Core Audio
  process scan + allowlist; never silently records.

**Headline outcome:** the graph becomes *visible and browsable*; the app adapts per
app and shows its thinking; meetings start themselves (with consent).

**Rough size:** **L** (13 ≈ M, 14 ≈ S/M, 05-full ≈ M + M/L for the tab, 03 ≈ M).

---

### Milestone 3 — The moat capstones (local agents + the pitch demo)

**Features:** **06** (local MCP), **19** (semantic search), **09** (cross-surface),
**07a** (`.mcpb` Claude Desktop connector).

**What ships:**
- **Local MCP server** (06): a separate `talkie-mcp` stdio executable exposing
  `list_meetings`/`get_meeting`/`get_brief`/`list_commitments`/`lookup_entity`/
  `search`/`add_dictionary_term` over the on-disk graph+meetings — read-mostly, no
  network, runs while the app is closed. First SwiftPM dependency (MCP SDK, **only**
  in this target — the app stays zero-dep).
- **Semantic + keyword search** (19): a Search tab + command palette over history +
  meetings + graph entities (RRF-blended, on-device embeddings, jump-to-source).
- **Cross-surface** (09): *"email Sarah the action items from my last meeting"* —
  the single sentence that is the product pitch, built as a `CrossSurfaceIntent`.
- **07a:** one-click Claude Desktop `.mcpb`/DXT bundle wrapping the 06 server
  (privacy-safe, stays on-device).

**Headline outcome:** the shared brain is now *addressable by local agents* and the
flagship "dictation that knows your meetings" demo is real. This is the milestone
that demonstrates the moat.

**Rough size:** **L–XL** (06 ≈ M+M+M, 19 MVP ≈ M×4, 09 MVP ≈ M, 07a ≈ M).

---

### Milestone 4 — The opt-in network layer (the wall's first crossing)

**Features:** **18** (Claude bridge, behind 15's wall), **07b** (remote Claude.ai
connector), **16 Sparkle** (opt-in auto-update), **20** (pluggable backend — widen
OSS reach beyond macOS-26/AS).

**What ships:**
- **Claude bridge** (18): `ClaudeBridge: Summarizer` in the separate `TalkieBridge`
  module — heavy lifts (long-meeting map-reduce, rich graph Q&A, agentic follow-ups),
  **OFF by default**, opt-in, Keychain key, per-call consent, refuses to load in the
  sandboxed-default flavor. *Note: the on-device `MapReduceSummarizer` (fixes the
  8000-char truncation TODO) is a fully-local win and should ship in M1/M2 — only the
  networked path waits for here.*
- **07b:** the remote Claude.ai connector (OAuth/DCR), behind 15's connected flavor +
  consent.
- **Sparkle** (16): opt-in EdDSA-signed auto-update in the connected flavor.
- **20:** additional `TranscriptionBackend` impls (WhisperKit first, MIT-clean) +
  cleanup degradation, so Talkie installs and dictates on macOS 14+ Apple Silicon
  without Apple Intelligence — the OSS audience-widening lever.

**Headline outcome:** power-user cloud accuracy + agentic features for those who opt
in, and a dramatically wider installable base — all without compromising the
zero-network default.

**Rough size:** **L** (18 MVP ≈ M, 07b ≈ M–L, Sparkle ≈ L, 20 MVP ≈ M+L).

---

## 4. Conflicts & overlaps found (and resolutions)

1. **Voice commands (08) vs edit-by-voice (12) vs macros (11) vs cross-surface (09)
   — four "do something with text by voice" features.**
   *Resolution (already encoded in the spine §2.4):* all four are `CommandIntent`s
   behind ONE `CommandRouter`, sharing entry, the `isMutating`/`preview`/`undoToken`
   safety contract, the `SelectionReader`, and `TextInjector`. 08 owns the router; 12
   is its selection branch; 11 is the simplest (non-mutating) intent; 09 is a
   graph-aware intent. **Build order 11/08 → 12 → 09** so later ones adopt the router
   rather than forking. No feature gets its own selection/inject path.

2. **The command-mode entry gesture (08 vs 12 vs 11 vs 14 all want a gesture).**
   *Conflict:* only three usable modifier keys exist (Fn is reserved), one is already
   dictation. *Resolution:* 08 picks **(B) parsed leading imperative** as the default
   (no new key — "make this a list" is detected by a verb list + a selection
   requirement), with **(C) a hold-chord** as the explicit power path and **(A) an
   optional dedicated key** as a setting. 11 uses **whole-utterance-only** matching
   (zero false positives, no new gesture). 14 uses an **in-HUD affordance**, not a
   global key. One gesture vocabulary, centrally owned in `HotKeyMonitor`, so meanings
   don't accumulate conflicts.

3. **Local MCP (06) vs Claude connector (07) vs Claude bridge (18) — three "talk to
   Claude" features that could each invent network code.**
   *Resolution:* they are three distinct layers, not duplicates. **06** is local
   stdio, zero network (a peer *reader* of the on-disk stores). **07a** wraps 06's
   binary in a Desktop `.mcpb` — still on-device. **07b** (remote connector) and **18**
   (cloud Summarizer) are the *only* network code, both confined to `TalkieBridge`/
   the connected build flavor, both gated by 15's wall, both off by default. Core
   `Talkie` never imports any of them — they're injected at `AppDelegate` behind a
   flag + consent. Build 06 → 07a → (15 wall) → 18/07b.

4. **Context Graph (05) vs the existing Brief / Dictionary / PhraseMiner / mined
   phrases — four private "context" islands.**
   *Resolution (spine §1.1):* the graph **absorbs** them. The Brief becomes a
   *projection* of the graph (not a second LLM pass over raw history); the dictionary
   becomes the user-curated `.term` slice (pinned nodes); mined phrases become
   candidate entities with provenance; `AppDelegate`'s ad-hoc bias union becomes
   `graph.biasPhrases(near:)`. This consolidation is the single most important one in
   the whole plan — do it *with* 05, not after.

5. **Two concurrent `SpeechAnalyzer` instances (01's mic + far-end).**
   *Conflict/risk:* Apple gives no documented guarantee two live analyzers are
   allowed; CPU/ANE/memory load is unmeasured. *Resolution:* 01 measures it; the
   `TranscriptionBackend` protocol makes the fallback (one backend, mic-only) a clean
   swap, and the branch already degrades cleanly. Resolve by measurement in M0, not by
   blocking the merge.

6. **`MeetingContextProvider` is needed by both 03 (detect) and 04 (calendar).**
   *Resolution:* define the protocol file **once** in the Tier-0 pass; 04 implements
   `eventContext(at:)`, 03 implements `detectActiveMeeting()`. Whichever lands first
   adds the file; the other fills its method. (04 is in M1, 03 in M2 — 04 adds the
   file.)

7. **Per-app profiles (13) vs HUD switcher (14) vs existing `CleanupStyle` resolution.**
   *Resolution:* 13 owns the single profile *resolver* (extending today's per-category
   `appCleanupStyles` inheritance to per-bundle-id); 14's write-back goes *through*
   13's resolver — 14 must not reimplement resolution. 14 ships a category-level shim
   if 13 isn't done yet (not hard-blocked).

8. **Sandbox model: the brief assumed full App Sandbox; 15 corrects it.**
   *Conflict:* the full App Sandbox **blocks `CGEventPost`** (the paste path), likely
   blocks the Core Audio process tap, and degrades Accessibility reads — it would
   break the core product. *Resolution (15's load-bearing correction):* the real wall
   is **Hardened Runtime + an *absent* `network.client` entitlement + structural
   module separation**, not the App Sandbox. A separate sandboxed *audit* target can
   be used purely to *demonstrate* the kernel network block in CI/screencast. Every
   planner must use 15's definition of "the wall," not "App Sandbox."

9. **MCP SDK breaks "zero external dependencies."**
   *Resolution:* the dependency lives **only** in the `TalkieMCP`/`TalkieBridge`
   targets; the app target imports nothing new and stays zero-dep. Pin the SDK
   exactly. (Optional later hardening: vendor a ~600-line stdio JSON-RPC core to
   restore zero-dep across the board — a fast-follow, not MVP.)

---

## 5. The open-source launch cut (what disrupts the industry on day one)

**Ship in the first public release (= Milestone 0 + Milestone 1):**

- The mature dictation pipeline (already done) **+ the Personal Context Graph
  improving recognition and the Brief** (05 MVP) — the differentiator framing, even
  in its heuristic form.
- **Me/Them speaker-labeled meetings** (01 merged) **+ the Granola notes-fusion
  magic** (02) **+ calendar-named meetings** (04).
- **On-device voice commands + edit-by-voice + macros** (08/12/11 MVP) — "beat Wispr
  on its own turf, on-device and free."
- **Provable zero-network privacy** (15 MVP + structural wall) — the honest,
  auditable claim that is the whole positioning.
- **One-command install** (16 cask+DMG MVP) and **a defensible benchmark number**
  (17 MVP) — so the README claim is true and trying it is frictionless.
- **Pluggable export** (10) with a zero-config default — so it's not Obsidian-locked
  on day one (open-source genericity invariant).

**Explicitly wait (post-launch milestones):**

- The **local MCP server + Claude connector + cross-surface demo + semantic search**
  (06/07/09/19, Milestone 3) — these are the *moat* and the best demos, but they need
  the graph to be mature; ship them as the headline post-launch wave once 05-full and
  the command layer have proven out.
- **Anything networked** (18 Claude bridge, 07b remote connector, Sparkle) —
  Milestone 4, behind 15's wall, off by default. The launch must be provably
  zero-network; the network layer is a deliberate, disclosed, opt-in fast-follow.
- **Wider-hardware backends** (20) — strategic for OSS reach but a large lift; land
  once the macOS-26/AS core is stable so the protocol seam is battle-tested first.
- **05's Memory tab + Stage-2 LLM extraction, per-app profiles, HUD switcher,
  auto-detect** (Milestone 2) — polish that makes the graph visible and the app
  adaptive; valuable but not required to make the launch claim true.

**Rationale:** the launch cut is precisely the minimum that makes every word of the
positioning literally true ("dictation and meetings, one private brain, $0, open
source, nothing leaves your machine, provably") while holding back the features that
either need a mature graph or cross the network wall. The moat features land *after*,
as the post-launch story — which is also the right order for credibility.

---

## 6. Risk register

| # | Risk | Type | Severity | Mitigation |
|---|------|------|----------|------------|
| R1 | **Two concurrent `SpeechAnalyzer` instances** may be disallowed or too heavy (01). | Technical | High | Measure CPU/ANE/mem in M0; `TranscriptionBackend` makes mic-only fallback a clean swap; branch already degrades. Don't block the merge on it. |
| R2 | **History pruned (7-day) before extraction** → graph data loss (05). | Technical/data | Med | Run extraction at launch *before* prune side-effects; watermark per source; document the residual >7-day-offline gap. |
| R3 | **Full App Sandbox would break the product** (blocks `CGEventPost`, likely the audio tap, degrades AX). | Technical | High | Use 15's corrected wall: Hardened Runtime + absent `network.client` + module separation. Separate sandboxed *audit* target only to *prove* the network block. |
| R4 | **Foundation Models / SpeechAnalyzer unavailable** (AI off, or wider hardware) breaks cleanup/extraction. | Technical/reach | Med | Heuristic-only graph path (05 §1.5); cleanup degradation (20); every feature degrades, not breaks. |
| R5 | **Meeting consent / two-party recording laws** — recording the far end may require consent in some jurisdictions (01/03). | Legal/consent | High | 03's banner *never silently records*; honest "Recording you + the call" copy; persistent indicator; document jurisdiction responsibility; mic-only fallback. |
| R6 | **Calendar/AX/clipboard read content could leak** into a networked feature later. | Privacy | High | Provenance (05 §1.3) makes "exactly what's on your Mac" auditable; the graph never leaves except via 18/07b with per-call consent; 15's wall is structural. |
| R7 | **FluidAudio diarization weights are pyannote Community-1 CC-BY-4.0** (01 Phase 3 / 20 Parakeet). | Licensing | Med | Verify attribution before any public release; phase Phase-3 diarization as a separate PR gated on the license decision; prefer MIT-clean WhisperKit for 20's first backend. |
| R8 | **MCP SDK breaks zero-dep**; could pull NIO/eventsource (06/07). | Licensing/footprint | Low–Med | Dependency only in `TalkieMCP`/`TalkieBridge`; app stays zero-dep; pin exactly; optional vendored JSON-RPC core later. |
| R9 | **Network module accidentally linked into core** (18/07b). | Privacy/architecture | High | CI grep asserts no `URLSession`/HTTP in `Talkie`; `requiresNetwork` gate refuses to instantiate networked backends in the sandboxed-default flavor; core never imports `TalkieBridge`. |
| R10 | **Command false-positives** corrupt normal dictation (08/11/12). | Technical/UX | Med | Selection-required + explicit verb list (08-B); whole-utterance-only macros (11); preview/undo on every mutating intent; greedy/low-temp on-device. |
| R11 | **Prompt injection** via selected text or transcript ("ignore your instructions"). | Security | Med | Structurally separated instruction/text blocks + the "do-not-obey-the-text" guardrail family from `CleanupEngine`; preview gate catches weird output before it lands. |
| R12 | **Sparkle appcast fetch is network** in a zero-network app (16). | Privacy | Med | Opt-in only, connected flavor only, transparent; the default sandboxed build ships without it. Cask+DMG MVP needs no network in-app. |
| R13 | **No git remote, no CI, no tests today** (16, all). | Process | Med | 16 sets up the remote + notarized-DMG release first; stand up the first test target with 05/19 (both plans include it); CI is a fast-follow. |
| R14 | **Long-meeting truncation** at 8000 chars (existing TODO). | Technical | Low–Med | `MapReduceSummarizer` above the `Summarizer` protocol — a fully-local fix shippable in M1/M2 *before* any network code (18 note). |
| R15 | **OS-version flakiness** — process-tap capture had bugs on 26.0 (doc targets 26.1+). | Technical | Med | Validate far-end on the actual deployment OS; mic-only fallback covers failures; zero-PCM watchdog (01) catches silent-tap regressions. |

---

## 7. Start here — the first 3 PRs

> These are the spine. They unblock the most downstream work for the least risk, and
> none of them is user-facing-risky (two are behavior-preserving; one is a clean merge).

**PR 1 — The protocol pass (behavior-preserving refactor).**
Define `Protocols/{TranscriptionBackend, Summarizer, NoteDestination, CommandIntent,
MeetingContextProvider}.swift`. Conform `TranscriptionEngine` → `AppleSpeechBackend`
and the Foundation-Models actors → `OnDeviceLLM` with **zero behavior change**;
refactor `MeetingStore.writeMarkdown` to take an `ExportableNote` via
`TalkieFolderDestination`. Define (not yet implement) the `CommandIntent` and
`MeetingContextProvider` shapes so 03/04/08/12 share one file. *Why first:* it's the
cheapest seam to add now and the most expensive to retrofit; 01/02/18/20 all depend
on it. Low risk (mechanical), high leverage.

**PR 2 — Rebase + merge `feat/meeting-far-audio` to main.**
The branch is one commit, three commits behind main, with no feature-file overlap —
a conflict-free rebase. Build, smoke-test a 1:1 call (Me/Them labels), confirm
mic-only fallback. *Why second:* it makes "meetings" genuinely real and gives the
Context Graph its richest feed before 05 is built. Pair with the two-analyzer load
measurement (R1) but don't block the merge on it. (Have AppleSpeechBackend from PR 1
ready so the recorder can hold `any TranscriptionBackend`.)

**PR 3 — Context Graph MVP + Brief-as-projection.**
The keystone: `ContextGraph/{Entity, Provenance, ContextGraphStore,
ContextGraphExtractor, ContextGraphSnapshot}.swift` — Stage-1 heuristic extraction
(reuse `PhraseMiner`, commitment regex, meeting participants → Person nodes, dict
terms → pinned `.term` nodes), JSON persistence with watermarks, incremental +
off-main + never-during-a-live-session. Rewire `AppDelegate`'s ad-hoc bias union to
`graph.biasPhrases(near:)`, and **rewrite `ContextSummaryStore` to render the Brief
from `graph.snapshot()`** instead of re-summarizing raw history. No model required,
no new tab. *Why third:* it's the gate for 04/06/07/09/19 and the single
highest-leverage piece; shipping the heuristic MVP early lets every consumer start
coding against a stable query surface.

---

## 8. At-a-glance milestone sequence

| Milestone | Features (MVP slices) | User-visible headline | Size |
|---|---|---|---|
| **M0 — Spine** | protocol pass, 05 MVP, 01 merge | (internal) one brain + speaker-labeled meetings + seams | L |
| **M1 — Launch core** | 02, 04, 08, 12, 11, 15, 16, 17, 10 | "Wispr Flow + Granola, free, on-device, OSS — provably" | XL |
| **M2 — Polish & visible intelligence** | 13, 14, 05-full, 03 | graph you can browse; per-app adaptation; auto-start meetings | L |
| **M3 — Moat capstones** | 06, 19, 09, 07a | local agents over your data; "email Sarah my action items" | L–XL |
| **M4 — Opt-in network layer** | 18, 07b, 16-Sparkle, 20 | cloud accuracy & agentic, opt-in; far wider install base | L |

**Public launch = M0 + M1.** Everything after is the post-launch moat story, in the
order that keeps the privacy claim true and the demos credible.
