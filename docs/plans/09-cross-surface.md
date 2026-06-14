# 09 — Cross-surface context (dictation that knows your meetings)

> Status: PLAN. Floor: macOS 26.0, Apple Silicon, Swift 6 `.v6`. Zero-network default.
> Ground truth: `docs/plans/_CURRENT_STATE.md`. Contract: `docs/plans/_UNIFICATION.md` §6/09.
> This is a **Tier-2 capstone**: it needs 05 (Context Graph) and 08 (`CommandIntent`/`CommandRouter`).

## 1. Summary

Add a `CrossSurfaceIntent` (a `CommandIntent`) that turns a spoken request like
*"email Sarah the action items from my last meeting"* into a drafted, previewable
text block injected via the existing `TextInjector` — by pulling the meeting,
the people, and the commitments straight out of the on-device Context Graph (05),
disambiguating ("which meeting?") in the brand HUD when the reference is ambiguous,
and drafting the prose with the shared `Summarizer`. No external integration:
everything is already on the user's Mac.

## 2. Why it matters

This single sentence is the product pitch made concrete. Wispr Flow can dictate;
Granola can summarize a meeting — but neither can dictate *with knowledge of your
meetings*, because they are two separate cloud companies that never share a brain.
Talkie can, because both voice surfaces (dictation + meetings) feed **one local
graph** (the thesis in `_UNIFICATION.md` §0). The demo proves the moat in one
breath: the user is in Mail, holds the command key, says "email Sarah the action
items from my last meeting," and a clean draft appears in the compose window —
sourced, attributable ("from your 2:00 PM meeting"), and provably on-device.
It is the headline that justifies building the graph at all (sequencing in
`_UNIFICATION.md` §5, Tier 2).

## 3. Current state in the code

What exists today that this feature builds on (all on `main` unless marked **[branch]**):

- **Meeting store & data** — `Meeting.swift:5-16` (`Meeting` struct: `title`,
  `startUnix`, `durationSec`, `transcript`, `summary`, `fileName`); **[branch]**
  adds `participants: [String]` + `source: String` with back-compat decode
  (`feat/meeting-far-audio:Meeting.swift:23-39`). `MeetingStore`
  (`Meeting.swift:53-123`) keeps `@Published private(set) var meetings: [Meeting]`
  **newest-first** (`add` inserts at 0, `:67`), writes one `.md` per meeting to
  `~/Talkie Meetings/` (`writeMarkdown :88-109`) plus a `meetings.json` index.
  **The summary already contains an "Action items:" section** — `MeetingSummarizer`
  (`Meeting.swift:19-50`, **[branch]** `:41-72`) is instructed to emit a
  `**Action items:**` bullet block "naming the owner if the transcript mentions one"
  (`:26-27`). That is the action-item source the demo needs **today** even before
  the graph's structured `.commitment` entities land.
- **Text injection** — `TextInjector.insert(_:mode:)` (`TextInjector.swift:26-54`):
  pasteboard → synthesize ⌘V → restore, with secure-field + no-Accessibility
  fallback to "left on clipboard." Generation-guarded restore (`:60-94`). **This is
  the only sanctioned insertion path** (`_UNIFICATION.md` §2.4) — the intent MUST
  reuse it, never fork a paste path.
- **The frontmost app / target** — `ContextCapture.capture(...)`
  (`AppContext.swift:41-61`) → `TargetApp` (bundleID, name, `AppCategory`). The
  intent needs the target to know it's drafting into Mail vs. Slack and to log usage.
- **On-device LLM** — `CleanupEngine` (`CleanupEngine.swift`) and the near-identical
  `MeetingSummarizer`/`ContextSummaryEngine` actors all wrap `LanguageModelSession`
  (Foundation Models), greedy / low-temp, with `sanitize()` stripping "Sure, here's…"
  preambles (`CleanupEngine.swift:225-259`). 05 unifies these behind the `Summarizer`
  protocol (`_UNIFICATION.md` §2.2); this feature drafts **through** that protocol.
- **The dictation funnel** — `AppDelegate.beginDictation/endDictation`
  (`AppDelegate.swift:295-549`): the ordered `AsyncStream<DictationEvent>` hotkey
  funnel (`:241-267`), `sessionID` generation guard, the post-processing pipeline,
  and `TextInjector.insert(...)` at `:527`. The cross-surface command rides a
  **separate** entry gesture (08's command mode) but reuses this machinery's
  patterns (session guard, mic, finishSession → text).
- **HUD** — `HUDController` (`HUD.swift:45-185`): a non-activating floating glass
  pill, `HUDPhase` enum (`:17-25`). Today it is display-only and `ignoresMouseEvents`
  (`HUD.swift:72`). Disambiguation needs either a new interactive panel or a
  numbered-choice voice flow (see §8 — the voice flow avoids making the HUD clickable).

**Honestly missing today (hard dependencies, NOT built):**

- **05 Context Graph** — there is no `ContextGraphStore`, no `Entity`, no
  `.commitment` sidecar, no `openCommitments(...)`, no `entities(fromMeeting:)`. The
  `_UNIFICATION.md` §1.6 query API is a contract, not code yet. Until 05 lands, the
  graph-backed paths (resolve "Sarah" → a Person, structured commitments with
  owner/counterparty) cannot run.
- **08 CommandIntent / CommandRouter** — there is no `CommandIntent` protocol, no
  `CommandRouter`, no command-mode entry gesture, no `CommandContext`/`CommandResult`.
  The intent protocol this feature implements (`_UNIFICATION.md` §2.4) does not exist
  yet.
- **No meeting recall API** — nothing answers "my last meeting" or "the meeting with
  Sarah." `MeetingStore.meetings` is in memory (newest-first) but there is no
  resolver from a spoken phrase to a `Meeting`.

The MVP (§14) is designed to degrade onto **what exists** (the meeting summary's
"Action items" text + a heuristic meeting resolver) so the demo can be shown before
05's structured commitments are complete, then upgrade transparently.

## 4. Design & approach

### 4.1 The shape: it's an Intent, not a new pipeline

Per `_UNIFICATION.md` §2.4 + §6/09, cross-surface is **one `CommandIntent`** routed
by 08's `CommandRouter`. It shares entry, safety (`isMutating`/`preview`/`undoToken`),
the graph snapshot, the summarizer, and injection with every other command. We do
NOT build a parallel hotkey, parallel mic capture, or parallel paste path.

Flow (all on the main actor unless noted; heavy LLM work `await`s an `actor`):

```
command-mode gesture (08)  →  speech captured (08 reuses AudioCapture+TranscriptionEngine)
        │
        ▼  spokenCommand = "email Sarah the action items from my last meeting"
CommandRouter.route(ctx)  ── matches ──►  CrossSurfaceIntent.run(ctx)
        │
        ├─ 1. PARSE the request (heuristic first, LLM fallback) → CrossSurfaceRequest:
        │        action: .draftMessage(recipientHint:"Sarah", channel:.email)
        │        contentKind: .actionItems
        │        meetingRef: .lastMeeting        (or .withPerson("Sarah"), .onDate(...), .byTitle(...))
        │
        ├─ 2. RESOLVE the meeting via MeetingResolver(graph, meetingStore):
        │        .lastMeeting           → meetings.first
        │        .withPerson(name)      → graph.entities(fromMeeting:) filter by Person; fallback transcript scan
        │        ambiguous / >1 strong candidate → return .needsDisambiguation([Meeting])
        │
        ├─ 3. RESOLVE the recipient via graph.lookup("Sarah", kinds:[.person])
        │        (ranked: pinned + recent + high-confidence). 0 hits → keep raw "Sarah".
        │
        ├─ 4. GATHER content for the resolved meeting:
        │        .actionItems  → graph.openCommitments(involving: meeting’s entities) — structured;
        │                        FALLBACK: parse the "**Action items:**" block out of meeting.summary
        │        .summary      → meeting.summary
        │        .decisions    → the "**Decisions:**" block
        │
        ├─ 5. DRAFT via Summarizer.generate(instructions: draftInstructions(channel), input: structured payload)
        │        → channel-appropriate prose (email: greeting + body + sign-off scaffold;
        │          chat: terse). NEVER invents commitments not in the payload (same guardrail
        │          as ContextSummary / MeetingSummarizer).
        │
        └─ 6. RETURN CommandResult(replacement: draft, preview: true, undoToken: priorSelection)
                 → 08's router shows the preview/confirm, then TextInjector.insert(draft, mode:)
```

### 4.2 Request parsing (heuristic-first, LLM-assisted)

Mirror the codebase's "free deterministic pass, then LLM" pattern
(`_UNIFICATION.md` §1.5; `PhraseMiner` is the precedent). A pure `enum
CrossSurfaceParser { static func parse(...) -> CrossSurfaceRequest? }`:

- **Channel** from leading verb: `email|mail` → `.email`; `message|slack|dm|tell|send` →
  `.chat`; `note|jot|write` → `.note`. Default `.draftInPlace` (just draft, no recipient).
- **Content kind**: `action items|to-?dos|next steps` → `.actionItems`;
  `summary|recap|notes` → `.summary`; `decisions` → `.decisions`.
- **Recipient hint**: the token(s) after the channel verb, before "the/about/from" —
  e.g. `email **Sarah** the…`. Passed to `graph.lookup`.
- **Meeting reference**: `last|latest|recent|just had` → `.lastMeeting`;
  `with X` / `X's meeting` → `.withPerson(X)`; `today|yesterday|monday` → `.onDate`;
  `about X` / `the X meeting` → `.byTitle(X)`.
- If the heuristic can't classify (low confidence), fall back to **one constrained
  LLM parse**: ask the on-device model to emit the four fields as a tiny labeled
  block (not free chat), parsed back. Reuse `Summarizer.generate` with a strict
  instruction + `sanitize`. This keeps the common phrasings instant and offline-cheap
  while handling odd phrasings.

### 4.3 Meeting resolution & disambiguation

`MeetingResolver` (a pure helper over an injected snapshot — see §5) ranks candidate
`Meeting`s:

- `.lastMeeting` → `meetings.first` (store is newest-first). High confidence if there
  is exactly one in the last N hours; otherwise still return it but mark `ambiguous`
  if a second meeting is within a tight window (e.g. two meetings today).
- `.withPerson(name)` → meetings whose graph `entities(fromMeeting:)` include a Person
  matching `name` (alias-aware). Fallback when 05 absent: case-insensitive transcript
  / participants scan. Multiple matches → disambiguation.
- `.onDate` / `.byTitle` → filter `meetings` by `Calendar.isDate(...)` / fuzzy title.

When >1 strong candidate, the intent returns `.needsDisambiguation([Meeting])`. 08's
router presents the choice (§8). Resolving the choice re-enters `run(...)` with a
pinned `meetingRef: .byID(uuid)` so the second pass is deterministic.

### 4.4 Graceful degradation onto today's code (so the demo works before 05/08 fully land)

- **No structured commitments yet** → parse the `**Action items:**` block from
  `meeting.summary` (the model already produces it; `MeetingSummarizer` §3). The
  intent treats graph commitments and parsed-summary bullets through one
  `ActionItemSource` so the upgrade is a one-line swap.
- **No graph person resolution** → keep the raw recipient hint string; the draft still
  addresses "Sarah" correctly, it just doesn't dedupe/alias.
- **No 08 router yet (earliest MVP)** → a temporary entry: a menu-bar item "Run a
  voice command…" and/or a debug hotkey that captures one phrase and calls
  `CrossSurfaceIntent.run` directly, showing the draft in a confirm sheet. This is
  explicitly a scaffold to be deleted once 08's `CommandRouter` exists.

### 4.5 Concurrency

- `CrossSurfaceIntent` is a `Sendable` value (`struct`), per the `CommandIntent`
  protocol. Its `run(_:) async` does the LLM `await`s off the main actor (the
  `Summarizer` is an `actor`/`Sendable`).
- It reads the **immutable** `ContextGraphSnapshot` carried in `CommandContext`
  (`_UNIFICATION.md` §2.4) — never the `@MainActor` store directly — so it can run
  off-main without touching main-actor state.
- It honors model exclusivity (`_UNIFICATION.md` §4.4): command parsing/drafting must
  not run while a dictation or meeting recording is live; 08's router gates entry on
  the same `isDictating`/`isRecording` probes `AppDelegate` already holds
  (`AppDelegate.swift:296-313`, `MeetingRecorder.isRecording`).
- Injection is `@MainActor` (`TextInjector` is a `@MainActor enum`), so the final
  `CommandResult` is delivered back to the main actor by the router before insertion.

## 5. New & changed files/types

New folder per `_UNIFICATION.md` §3: `Sources/Talkie/Commands/`.

```swift
// Commands/CrossSurfaceIntent.swift  (NEW)

/// "email Sarah the action items from my last meeting" — drafts from the graph
/// + meeting store and returns a previewable, undoable injection.
struct CrossSurfaceIntent: CommandIntent {                  // CommandIntent from 08
    let id = "cross-surface"
    let needsSelection = false       // it pulls from the graph, not the current selection
    let isMutating = true            // always preview before inserting

    let meetings: MeetingSnapshot    // an injected read model (see below)

    func run(_ ctx: CommandContext) async -> CommandResult? {
        guard let req = CrossSurfaceParser.parse(ctx.spokenCommand, summarizer: ctx.summarizer)
        else { return nil }
        let resolution = MeetingResolver.resolve(req.meetingRef, graph: ctx.graph, meetings: meetings)
        switch resolution {
        case .none:
            return CommandResult(replacement: "", preview: true,
                                 undoToken: nil, note: "I couldn’t find that meeting.")
        case .ambiguous(let candidates):
            return CommandResult.disambiguation(candidates.map(\.asChoice))   // §8
        case .one(let meeting):
            let content = ActionItemSource.gather(req.contentKind, meeting: meeting, graph: ctx.graph)
            guard let draft = await Drafter.draft(req, content: content, target: ctx.target,
                                                  summarizer: ctx.summarizer) else { return nil }
            return CommandResult(replacement: draft, preview: true, undoToken: ctx.selection)
        }
    }
}

// Commands/CrossSurfaceRequest.swift  (NEW) — pure, Sendable
struct CrossSurfaceRequest: Sendable {
    enum Channel: Sendable { case email, chat, note, draftInPlace }
    enum ContentKind: Sendable { case actionItems, summary, decisions, full }
    enum MeetingRef: Sendable {
        case lastMeeting
        case withPerson(String)
        case onDate(DateComponents)
        case byTitle(String)
        case byID(UUID)
    }
    var channel: Channel
    var contentKind: ContentKind
    var recipientHint: String?
    var meetingRef: MeetingRef
}

enum CrossSurfaceParser {
    /// Heuristic-first; falls back to one constrained LLM parse for odd phrasings.
    static func parse(_ spoken: String, summarizer: any Summarizer) async -> CrossSurfaceRequest?
}

// Commands/MeetingResolver.swift  (NEW) — pure, Sendable
enum MeetingResolver {
    enum Resolution: Sendable { case none, one(Meeting), ambiguous([Meeting]) }
    static func resolve(_ ref: CrossSurfaceRequest.MeetingRef,
                        graph: ContextGraphSnapshot,
                        meetings: MeetingSnapshot) -> Resolution
}

// Commands/ActionItemSource.swift  (NEW) — pure, Sendable
enum ActionItemSource {
    /// Graph commitments when available; else parse the "**Action items:**" /
    /// "**Decisions:**" block out of meeting.summary. One seam → graceful upgrade.
    static func gather(_ kind: CrossSurfaceRequest.ContentKind,
                       meeting: Meeting, graph: ContextGraphSnapshot) -> DraftPayload
}
struct DraftPayload: Sendable {
    var meetingTitle: String
    var meetingDate: Date
    var items: [String]          // already plain bullets
    var attribution: String      // "from your 2:00 PM meeting on Tue"
}

// Commands/Drafter.swift  (NEW)
enum Drafter {
    /// Channel-appropriate prose through the Summarizer; never invents items.
    static func draft(_ req: CrossSurfaceRequest, content: DraftPayload,
                      target: TargetApp, summarizer: any Summarizer) async -> String?
}
```

A **read model for meetings** so the intent stays off-main and Sendable (mirrors
`ContextGraphSnapshot` / `ProjectIndexSnapshot`):

```swift
// Meeting.swift  (CHANGED — add a snapshot accessor on MeetingStore)
struct MeetingSnapshot: Sendable {
    let meetings: [Meeting]      // newest first, copied at snapshot time
    var last: Meeting? { meetings.first }
    func onDate(_ comps: DateComponents) -> [Meeting]
    func matchingTitle(_ q: String) -> [Meeting]
    func byID(_ id: UUID) -> Meeting?
}
extension MeetingStore { func snapshot() -> MeetingSnapshot { MeetingSnapshot(meetings: meetings) } }
```

Changes to other files:
- **08's `CommandRouter`** registers `CrossSurfaceIntent(meetings: meetingStore.snapshot())`
  alongside the other intents (router refreshes the snapshot per invocation).
- **`CommandResult`** (defined by 08) gains a `note: String?` and a
  `disambiguation(_:)` constructor (a choice list). If 08's shape is already frozen,
  cross-surface returns the choice list via a thin wrapper the router understands.
- **`AppDelegate`** injects `meetingStore` (already owned, `:15`) and `contextGraph`
  (from 05) into the router at the composition root (where 08 wires the router).

## 6. Data model & persistence

**This feature stores almost nothing new.** It is a *consumer* (`_UNIFICATION.md`
§6/09 — "Consumes," not "Exposes" persistence). It reads:

- `MeetingStore.meetings` (in-memory) + the durable `.md` in `~/Talkie Meetings/`
  (`AppPaths.meetingsDirectory()`), index `meetings.json` in
  `~/Library/Application Support/Talkie/` (`Meeting.swift:60`).
- 05's graph (`entities.json`, `commitments.json`) via the injected
  `ContextGraphSnapshot` — **never the JSON directly** (`_UNIFICATION.md` §1.6).

Optional, additive persistence (Phase 2, off the critical path):
- **Command history** — if we want "redo last command" / an audit trail, append to a
  new `commands.json` in the support dir (same `.atomic`, failure-tolerant,
  optional-fields convention, `_CURRENT_STATE.md` §3/§7). Not required for the demo;
  recommend deferring.

**Back-compat:** meetings saved before **[branch]** lack `participants`/`source`;
the branch's `decodeIfPresent` (`feat/meeting-far-audio:Meeting.swift:34-35`) already
handles that, and the resolver tolerates `participants == ["Me"]`. The summary-block
parser must tolerate older summaries that may not have an "Action items" heading
(returns empty → the draft says "no action items were recorded for that meeting").

## 7. Unification contract

Per `_UNIFICATION.md` §6 block **09**:

**EXPOSES**
- `CrossSurfaceIntent: CommandIntent` (`id == "cross-surface"`) — registered with 08's
  `CommandRouter`. This is the only public surface; everything else (parser, resolver,
  drafter) is internal to `Commands/`.
- `MeetingSnapshot` + `MeetingStore.snapshot()` — a small Sendable read model other
  off-main consumers (e.g. 19 search, 06 MCP `get_meeting`) may reuse instead of
  touching the `@MainActor` store. (Net-new but in the spirit of the §3 "`XxxSnapshot`"
  convention; offer it for reuse.)

**CONSUMES**
- **Context Graph (05)** — the keystone. Specifically the `_UNIFICATION.md` §1.6 query
  surface, all via the immutable `ContextGraphSnapshot` in `CommandContext`:
  - `lookup(_:kinds:)` → resolve the recipient ("Sarah" → Person) and meeting-by-person.
  - `openCommitments(involving:since:)` → structured action items (preferred over
    summary parsing).
  - `entities(fromMeeting:)` → which people a meeting involves (meeting-by-person
    resolution) + provenance for attribution.
- **08 `CommandIntent` / `CommandRouter` / `CommandContext` / `CommandResult`** — the
  entry gesture, routing, the `isMutating`/`preview`/`undoToken` safety contract, and
  the `TextInjector` insertion. Cross-surface adds NO new selection or paste path
  (`_UNIFICATION.md` §2.4 "do NOT fork a second selection/inject path").
- **`Summarizer` (05/02)** — `generate(instructions:input:)` for the optional LLM parse
  and the draft prose. On-device default (`OnDeviceLLM`); transparently benefits from
  18's opt-in `ClaudeBridge` for heavier drafting **without this feature importing the
  bridge** (it only sees the protocol).
- **`TargetApp`** (`AppContext.swift:6-12`) via `CommandContext.target` — to tune the
  draft (email vs. chat) and (optionally) log usage.

**Honors the contract note:** "THE demo that sells the thesis… it exists *because*
both surfaces feed one graph — make it concrete and reliable." Reliability work lives
in §12 (every step degrades to a useful, honest result rather than failing).

## 8. UI / UX

Three touchpoints, all on-brand (`DesignSystem.swift` is the source of truth for
*values*; `BRAND.md` for philosophy — warm, honest, calm, one accent, second person):

1. **Invocation** — owned by 08 (command-mode gesture). Cross-surface adds nothing
   here except being a registered intent. The reused **glass HUD** pill
   (`HUD.swift`, `.glassEffect`, `:209`) shows command-mode capture exactly like
   dictation (red dot + `Waveform`, `HUD.swift:225-230`).

2. **Disambiguation ("which meeting?")** — preferred design avoids making the HUD
   clickable (it is `ignoresMouseEvents`, `HUD.swift:72`, and non-activating by design):
   - **Voice-first:** the HUD/banner lists up to 3 candidates as numbered chips
     ("1 · 2:00 PM with Sarah · 2 · 11:00 AM standup") and the user says "one" / "the
     Sarah one." A tiny follow-up capture re-enters `run` with `.byID`. This keeps the
     interaction hands-free and matches the voice-copilot story.
   - **Fallback pointer UI:** a small confirm sheet (a new `NSPanel` that DOES accept
     mouse, separate from the display-only HUD) listing candidates as
     `.talkieCard()` rows (`MeetingsView.swift:200` pattern) with the meeting title,
     relative time, and participant chips (`FlowLayout`, `DesignSystem.swift`).
   - Copy is honest and second person: "You had two meetings today — which one?"
     (`BRAND.md` §voice; never invent which one they meant).

3. **Draft preview / confirm** — required because `isMutating == true`
   (`_UNIFICATION.md` §2.4). Before injecting, show the draft in a confirm panel:
   - Header `Eyebrow` "Draft · from your 2:00 PM meeting" (attribution always cites the
     source — the provenance / honesty rule, `BRAND.md` "honest about limits";
     `_UNIFICATION.md` §4.3 "cite provenance, never assert facts the graph can't back").
   - Body = the draft in `MarkdownText` (reuse `MarkdownText.swift`).
   - Actions: **Insert** (coral/blue accent `Theme.coral`, one accent per view) and
     **Cancel**. Optional **Edit** drops it onto the clipboard so the user can paste +
     tweak (reuses the `TextInjector` "left on clipboard" affordance semantics).
   - On Insert → `TextInjector.insert(draft, mode: settings.insertionMode)`; on the
     `.leftOnClipboard` outcome, surface the same honest reason string TextInjector
     returns (`TextInjector.swift:33,40`).
   - Spring transitions (`response 0.28, damping 0.8`, `HUD.swift:200`,
     `BRAND.md` §motion).

No new tab is required for the MVP. (Optionally, a later "Commands" affordance could
live near the Meetings tab, but that is out of scope here.)

## 9. Permissions / entitlements / Info.plist

**Nothing new.** This feature uses only capabilities the app already has:
- Microphone (capture the spoken command) — already granted for dictation.
- Input Monitoring (the command gesture, owned by 08).
- Accessibility (the ⌘V injection via `TextInjector`) — already required.
- Reading `~/Talkie Meetings/` and the support dir — already done, no new TCC.

No new entitlement, no plist key, no sandbox change. The `talkie.entitlements` stays
single-entitlement (`com.apple.security.device.audio-input`), preserving the verified
privacy invariant (`_CURRENT_STATE.md` §6).

## 10. Privacy posture

**Zero-network preserved.** Every step is on-device: parsing (heuristics +
Foundation Models), meeting/graph reads (local files via injected snapshots),
drafting (`OnDeviceLLM`), injection (synthetic ⌘V). No `URLSession`, no new
entitlement (§9). The default build still makes zero network connections
(`_CURRENT_STATE.md` §0; `_UNIFICATION.md` §4.1).

The only path to the network is the *opt-in* `Summarizer` swap (18's `ClaudeBridge`,
`requiresNetwork == true`), which is OFF by default, lives in the separate
`TalkieBridge` module, is gated by 15's consent wall, and is never imported by this
feature (it sees only the protocol). If the user has explicitly enabled the bridge,
drafting through it would send *only* the constructed `DraftPayload` (meeting title,
date, the action-item bullets) + the draft instruction — and 18 must disclose that at
consent time. The provenance attribution in the preview (§8) is precisely the
"here's exactly what would be sent" honesty surface (`_UNIFICATION.md` §4.1, §15).

## 11. Open-source genericity

- **No hardcoded personal stack.** "Email" / "message" are *channels* that resolve to
  **drafting into whatever app is frontmost** + the existing `TextInjector` — not to
  Gmail, not to a specific mail client, not to Obsidian. The zero-config default: hold
  the command key in Mail.app (or any compose field), say the command, get a draft in
  place. No third-party app, no account, no integration.
- **Recipient resolution** is graph-generic (any Person entity from any source); it
  does not assume a contacts provider. If 04 (EventKit) is present, attendee Person
  entities improve resolution for free, but its absence only degrades, never breaks.
- **Output is plain Markdown/text.** If 10's `NoteDestination` is configured, a "note"
  channel could route the draft through it (Obsidian/Logseq/plain folder) — but the
  default needs none of that.
- **Community extension points:** the parser's verb/keyword maps and the `Drafter`
  channel instructions are pure, table-driven helpers — adding a new channel or a new
  content kind is a localized edit, no core surgery. New `MeetingRef` strategies plug
  into `MeetingResolver`. New languages: the parser keywords are the only
  English-specific part and should be factored into a small localizable table.

## 12. Risks, edge cases, failure modes

| Case | Behavior (graceful degradation) |
|---|---|
| 05 graph not built yet | Use summary-block parsing for action items + raw recipient string. Demo still works. |
| 08 router not built yet | Temporary menu-bar/debug entry (§4.4) calls `run` directly; deleted when 08 lands. |
| No meetings at all | `MeetingResolver` → `.none`; preview note: "You don’t have any meetings recorded yet." |
| "my last meeting" but 2+ today | `.ambiguous` → disambiguation (§8). Never silently guess. |
| Recipient "Sarah" matches 2 people | Draft to the higher-ranked (pinned/recent), and the preview attribution names which Sarah, so the user can cancel. Optionally a recipient disambiguation. |
| Summary has no "Action items" block | `items == []`; draft says "No action items were recorded for that meeting" — honest, not fabricated (`BRAND.md`). |
| Foundation Models unavailable (AI off) | Parser uses heuristics only; `Drafter` falls back to a deterministic template ("Hi {recipient},\n\nAction items from {attribution}:\n- …") so a draft still appears. |
| Long meeting summary truncated (8000-char cap, `Meeting.swift:36`) | Action items live near the top of the summary, so they survive truncation; note the known cap. Map-reduce (02/`Summarizer` helper) fixes it later. |
| Injection blocked (secure field / no Accessibility) | `TextInjector` returns `.leftOnClipboard`; preview shows the honest reason and the draft stays on the clipboard (`TextInjector.swift:31-41`). |
| Model exclusivity (dictation/recording live) | 08's router refuses entry (probes `isDictating`/`isRecording`); HUD nudges busy (`HUD.nudgeBusy`, `HUD.swift:156`). |
| Mis-parse / nonsense command | Parser returns nil → router says "I didn’t catch a command I can run." No injection. |
| Re-entrancy (a second command mid-draft) | Generation-token guard (the `sessionID` pattern, `AppDelegate.swift:325-326`) in the router; only the latest command's draft can inject. |
| Privacy: never auto-send | The intent only **drafts and inserts a draft** into a compose field. It NEVER sends an email or posts a message. The human reviews and sends. State this in copy and docs. |

## 13. Testing & verification

No test target exists today (`_CURRENT_STATE.md` §8). Add a SwiftPM test target for
the **pure** pieces (they're designed to be Sendable + dependency-light precisely so
they're testable):

- **Unit (pure, no model needed):**
  - `CrossSurfaceParser` — table of spoken strings → expected `CrossSurfaceRequest`
    (channels, content kinds, recipient hints, meeting refs; including odd casing and
    "with Sarah" vs "Sarah the action items").
  - `MeetingResolver` — fixture `MeetingSnapshot` + fixture `ContextGraphSnapshot`:
    last-meeting, by-person (alias-aware), two-today → `.ambiguous`, none → `.none`.
  - `ActionItemSource` — parse `**Action items:**` / `**Decisions:**` blocks out of
    representative `meeting.summary` strings (with/without the heading; bullets with
    owners). The graph-backed path with a fixture snapshot.
  - `Drafter` deterministic-fallback template (model-off path) — exact string output.
- **Integration (model present, manual or gated):** run `Drafter.draft` through
  `OnDeviceLLM` and assert it (a) contains every input item, (b) invents no new
  proper noun absent from the payload (a "no hallucination" check over the bullets).
- **Manual / `/run` path (the headline demo):**
  1. Record a short meeting (mic-only is fine) that contains an action item naming
     Sarah; stop → confirm the `.md` in `~/Talkie Meetings/` has an "Action items"
     bullet.
  2. Focus a Mail/TextEdit compose field. Trigger command mode (08, or the temporary
     entry). Say "email Sarah the action items from my last meeting."
  3. Verify: the resolver picks the meeting; the preview shows the draft with
     attribution; Insert pastes the draft into the field; nothing is sent.
  4. Disambiguation: record a second meeting same day, repeat, verify the "which
     meeting?" flow and that choosing re-runs deterministically.
  5. Toggle Apple Intelligence off → verify the template fallback still drafts.
- **Privacy regression:** `grep -rniE "URLSession|http://|https://" Sources/Talkie/`
  still returns nothing after this feature lands (the standing invariant check).

## 14. Effort & phasing

**MVP slice (the demo) — M.** Depends on 08's router existing (or the temporary entry):
- `CrossSurfaceRequest` + `CrossSurfaceParser` (heuristic only) — **S**
- `MeetingSnapshot` + `MeetingResolver` (`.lastMeeting` + `.withPerson` via
  transcript/participants scan; disambiguation) — **S/M**
- `ActionItemSource` (summary-block parsing path) — **S**
- `Drafter` (Summarizer + template fallback) — **S/M**
- `CrossSurfaceIntent` + router registration + draft preview panel — **M**
- Disambiguation voice flow (or fallback sheet) — **M**

**Full feature — adds L overall:**
- Swap `ActionItemSource` + recipient resolution onto **05's structured
  `openCommitments`/`lookup`** once 05 lands — **S** (the seam is pre-built).
- LLM-assisted parse fallback for odd phrasings — **S**.
- `.onDate` / `.byTitle` meeting refs + recipient disambiguation — **M**.
- Optional `NoteDestination` "note" channel (10) + command history (`commands.json`) —
  **M**, deferrable.
- Test target + the no-hallucination integration check — **M**.

Sequencing within the program: build the MVP **after** 05's model + query API and
08's router exist (per `_UNIFICATION.md` §5 Tier 2). If the schedule wants the demo
earlier, the §4.4 degradation path lets the MVP run on today's meeting summaries with
a temporary entry, then upgrade transparently.

## 15. Dependencies & interactions

- **Needs (hard):** **05 Context Graph** (`lookup`, `openCommitments`,
  `entities(fromMeeting:)`, `ContextGraphSnapshot`); **08 voice commands**
  (`CommandIntent`/`CommandRouter`/`CommandContext`/`CommandResult`, entry gesture,
  preview/undo safety, `TextInjector` insertion).
- **Needs (soft, improves it):** **01 far-end** (richer Me/Them transcripts → better
  meeting entities & action-item ownership); **04 calendar** (attendee Person entities
  → better recipient & meeting-by-person resolution, real meeting titles); **02 notes
  fusion** (better structured action items as `.commitment` entities).
- **Enables / is the payoff for:** the whole thesis — it is the capstone the graph
  exists to make possible (`_UNIFICATION.md` §5 "the demo that sells the thesis").
- **Overlaps with / shares machinery:** **12 edit-by-voice** and **11 macros** (same
  `CommandIntent`/`CommandRouter`/`TextInjector` spine — do not fork it); **19 search**
  (could reuse `MeetingSnapshot`; conversely the resolver could later lean on 19's
  semantic search for "the meeting about X"); **18 Claude bridge** (drafting
  transparently upgrades through the `Summarizer` protocol when opted in, no import).
- **Touches at the composition root:** `AppDelegate` (injects `meetingStore` +
  `contextGraph` into 08's router). No other existing file needs behavioral change;
  `MeetingStore` gains only a `snapshot()` accessor.
```
