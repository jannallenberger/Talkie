# Talkie — The Unification Spine (`_UNIFICATION.md`)

> The contract every feature planner builds against. Its job is to keep 20 features
> ONE coherent product instead of 20 bolt-ons. Read `_CURRENT_STATE.md` first (the
> ground-truth map); read this second (how the pieces interlock).
>
> **Generated:** 2026-06-14 by the unification-architect pass.
> **Floor:** macOS 26.0, Apple Silicon, Swift 6 strict concurrency (`.v6`).
> **The one thesis this spine serves:** both voice surfaces (dictation + meetings)
> flow into ONE on-device personal context graph. That shared brain is the moat.
> Everything below exists to make that graph the gravitational center and to stop
> any feature from privately reinventing a piece of it.

---

## 0. The shape of the spine (one paragraph)

There is **one brain** (the Personal Context Graph, `ContextGraph`), fed by **two
mouths** (dictation, meetings), spoken through **swappable organs** (the protocols:
transcription backend, summarizer/LLM, note destination, command intent, meeting
context). The brain is always-local. The organs each have a 100%-on-device default
implementation; the *networked* organs (Claude bridge, remote connector) are
separate optional modules behind a hard sandbox/consent wall. Everything else —
recall, the daily Brief, voice commands, cross-surface actions, search, the MCP
server — is a **consumer** of the brain, never a second copy of it. If a feature
needs to know "who/what/when," it asks `ContextGraph`. If it needs to turn audio
into text, it asks a `TranscriptionBackend`. If it needs to turn text into better
text, it asks a `Summarizer`. If it needs to put a note somewhere, it asks a
`NoteDestination`. Five nouns, and the product stays one thing.

---

## 1. THE PERSONAL CONTEXT GRAPH (feature 05 — the keystone)

Everything else is a tributary to or a consumer of this. Build it first, build it
right, and the other 19 features become small.

### 1.1 What it supersedes

Today the "context graph" exists only as **fragments**, each a private island:

| Fragment (today) | File | What it really is |
|---|---|---|
| Custom vocabulary + learned replacements | `DictionaryStore.swift` | Terms (a partial Term store) |
| The daily "Brief" | `ContextSummary.swift` | A throwaway LLM render over 7 days of dictations — **no entities, no provenance** |
| Mined phrases | `AppContext.swift` (`PhraseMiner`) | Ephemeral per-session bias; thrown away after the session |
| Per-app usage | `AppUsageStore.swift` | Where words go (not who/what) |
| Meeting transcripts | `Meeting.swift` | Raw text with `participants`/`source` (branch) but no extracted entities |

The graph **absorbs** the fragments: the Brief becomes a *projection* of the graph
(not a separate LLM pass over raw history); the dictionary becomes the *user-curated
slice of the Term store*; mined phrases become *candidate entities with provenance*;
meeting participants become *Person entities*.

### 1.2 The data model

A new module `Sources/Talkie/ContextGraph/` (see §3 for layout). All types are
`Codable` + `Sendable` value types; the **store** that owns them is a
`@MainActor final class … ObservableObject` matching the existing store
convention, with an `actor`-based query layer for off-main consumers (§1.6).

```swift
// ContextGraph/Entity.swift

/// A stable identity for an extracted thing. Deterministic from kind+normalizedKey
/// so the same person/term mentioned twice merges instead of duplicating.
struct EntityID: Hashable, Codable, Sendable {
    let kind: EntityKind
    let key: String   // normalized: lowercased, trimmed, diacritics-folded
}

enum EntityKind: String, Codable, Sendable, CaseIterable {
    case person       // "Sarah Chen", "@dave"
    case project      // "Coralate", "the Q3 launch"
    case term         // vocabulary / jargon / brand words  (supersedes DictionaryStore vocab)
    case commitment   // an action item / promise ("I'll send the deck Friday")
    case organization // optional, cheap to add; "Anthropic", "Figma"
}

/// One node in the graph. Merged across all sources; carries provenance back to
/// every source it was seen in.
struct Entity: Codable, Sendable, Identifiable {
    var id: EntityID
    var kind: EntityKind { id.kind }

    /// The best human-facing form ("Sarah Chen", not "sarah chen"). Highest-confidence
    /// surface form wins; alternates kept as `aliases`.
    var displayName: String
    var aliases: [String] = []

    /// Free-form, model-or-heuristic-extracted facts ("PM on Coralate", "owes Jann the deck").
    /// Short, append-only, deduped. NOT a chat log — the recall surface, kept tight.
    var notes: [String] = []

    /// Every place this entity was seen. The provenance chain. (§1.3)
    var provenance: [Provenance] = []

    var firstSeenUnix: Double
    var lastSeenUnix: Double
    var mentionCount: Int = 1

    /// 0…1 — heuristic + model confidence this is a real, distinct entity (used to
    /// gate biasing & recall; low-confidence stays in the graph but is not surfaced).
    var confidence: Double = 0.5

    /// True if the user explicitly curated this (e.g. a dictionary term, a pinned
    /// person). Curated entities never get pruned and always bias the recognizer.
    var pinned: Bool = false
}

/// Commitments are Entities of kind `.commitment` PLUS this structured sidecar
/// (kept in a parallel dictionary keyed by EntityID so `Entity` stays uniform).
struct CommitmentDetail: Codable, Sendable {
    var text: String              // "send the design deck"
    var owner: EntityID?          // a .person entity, or nil = the user
    var counterparty: EntityID?   // who it's owed to
    var dueHint: String?          // "Friday", "by end of week" — never a fabricated date
    var status: CommitmentStatus  // open | done | dropped
    var source: Provenance
}
enum CommitmentStatus: String, Codable, Sendable { case open, done, dropped }
```

### 1.3 Provenance (non-negotiable — it's the privacy & trust story)

Every entity and every commitment points back at exactly where it came from. This
is what lets recall say *"because you said it to Slack on Tuesday"* and what lets a
skeptic audit the graph. **No entity may exist without at least one Provenance.**

```swift
struct Provenance: Codable, Sendable, Hashable {
    enum Source: String, Codable, Sendable {
        case dictation   // a HistoryStore entry
        case meeting     // a Meeting
        case calendar    // an EventKit event (feature 04)
        case dictionary  // user-curated in the Dictionary tab
        case appContext  // mined from a focused window/field (feature 13/AppContext)
    }
    var source: Source
    var sourceID: String      // DictationEntry.id / Meeting.id / event id / "user"
    var unix: Double          // when the mention occurred
    var appName: String?      // the app it was dictated into, if any (already in DictationEntry)
    var snippet: String?      // ≤140 chars around the mention, for "jump to source"
}
```

### 1.4 Storage (format & paths — follows the existing convention exactly)

- Root: **`~/Library/Application Support/Talkie/graph/`** (new subfolder via
  `AppPaths.supportDirectory()`). Add `AppPaths.graphDirectory()` next to the
  existing helpers.
- Files (all `.atomic`, failure-tolerant decode, optional fields for back-compat —
  the house style from `_CURRENT_STATE.md` §3 & §7):
  - `entities.json` — `[Entity]` (the node table).
  - `commitments.json` — `[EntityID: CommitmentDetail]`.
  - `graph_meta.json` — `{ schemaVersion, lastExtractedUnix, watermarks }` so
    extraction is **incremental** (only process dictations/meetings newer than the
    per-source watermark).
- **Why JSON, not SQLite/Core Data:** matches every other store, keeps "zero
  dependencies" true, stays trivially inspectable (the privacy thesis — feature 15
  — wants the user able to read their own brain). Re-evaluate only if the node count
  blows past ~50k; until then JSON + in-memory index is right. (Embeddings for
  feature 19 are the one thing that may want a separate compact binary sidecar —
  see that feature's contract.)
- **Caps & pruning:** entities are kept indefinitely if `pinned`; otherwise low-
  confidence, low-mention entities older than a horizon (default 90 days, a setting)
  are pruned — mirroring `HistoryStore`'s retention philosophy but far gentler
  (the graph is the long memory; raw history is the short one).

### 1.5 The extraction pipeline

A new `actor ContextGraphExtractor` (mirrors `ContextSummaryEngine`/`CleanupEngine`):
on-device LLM + heuristics, **incremental**, runs off-main at idle.

```
new dictations / meetings  ──►  ContextGraphExtractor.extract(since: watermark)
        │
        ├─ heuristics first (free, deterministic, no model):
        │    • PhraseMiner-style proper-noun / identifier extraction (reuse AppContext.PhraseMiner)
        │    • dictionary terms → Term entities (pinned, confidence 1.0)
        │    • meeting participants (branch: ["Me","Them"] / calendar names) → Person entities
        │    • simple commitment cues: /\b(I'll|I will|I need to|let me|by (Monday|...|Friday|EOD))\b/
        │
        └─ LLM pass (Foundation Models, when available) over batched new text:
             • resolve/merge aliases ("Sarah" == "Sarah Chen" in this context)
             • extract structured commitments (owner / counterparty / dueHint)
             • write one-line entity notes
             • NEVER invent: same guardrail as ContextSummary ("do not invent
               anything not in the source"). Output is constrained/parsed, not free chat.
```

- **Trigger points (where extraction is kicked):** (a) after `endDictation()` logs a
  `HistoryStore` entry — enqueue the new entry id; (b) after `MeetingRecorder.stop()`
  adds a `Meeting`; (c) when the Dictionary changes (term entities). Extraction is
  **debounced** (e.g. coalesce for 30–60s, run at `.utility`) so it never competes
  with a live dictation for the model. The shared `TranscriptionEngine`/model
  exclusivity rule extends here: **do not run extraction while a dictation or
  recording session is live** (probe the same `isDictating`/`isRecording` flags).
- **Degradation:** if `CleanupEngine.isAvailable == false` (Apple Intelligence off),
  the graph still builds from **heuristics alone** — fewer notes, no alias merging,
  but Person/Project/Term/Commitment nodes still appear. This keeps feature 05 alive
  on the widened-hardware path (feature 20).

### 1.6 The in-process query API (what features 04/06/07/09/19 call)

Other subsystems must NOT read the JSON files directly. They go through one
injected object. UI consumers use the `@MainActor` store; off-main consumers
(extraction, MCP, search) use the `actor` snapshot.

```swift
@MainActor
final class ContextGraphStore: ObservableObject {
    @Published private(set) var entities: [Entity]          // newest-touched first
    @Published private(set) var commitments: [EntityID: CommitmentDetail]

    // --- The query surface every consumer relies on (keep this stable) ---

    /// Recall: "who is X / what is Y". Fuzzy over displayName + aliases.
    func lookup(_ query: String, kinds: Set<EntityKind> = Set(EntityKind.allCases)) -> [Entity]

    /// The recognizer bias set, ranked: pinned + high-confidence + recent.
    /// Replaces the ad-hoc "custom vocab ∪ on-screen names ∪ filenames" union in
    /// AppDelegate.beginDictation. Capped (default 180, the current cap).
    func biasPhrases(limit: Int = 180, near app: TargetApp? = nil) -> [String]

    /// Open commitments, optionally for a person or since a date — powers the Brief,
    /// cross-surface actions (09), and the MCP "what did I commit to" tool.
    func openCommitments(involving: EntityID? = nil, since: Date? = nil) -> [CommitmentDetail]

    /// Entities tied to a source, for "jump to source" and meeting↔graph linking.
    func entities(fromMeeting id: UUID) -> [Entity]

    /// An immutable snapshot for off-main consumers (MCP, search, extraction).
    func snapshot() -> ContextGraphSnapshot
}

/// Sendable, immutable. The off-main read model (mirrors ProjectIndexSnapshot).
struct ContextGraphSnapshot: Sendable {
    let entities: [Entity]
    let commitments: [EntityID: CommitmentDetail]
    func lookup(_ q: String, kinds: Set<EntityKind>) -> [Entity]
    func biasPhrases(limit: Int) -> [String]
    func openCommitments(involving: EntityID?, since: Date?) -> [CommitmentDetail]
}
```

**Ownership/DI:** `ContextGraphStore` is created in `AppDelegate` alongside the
other stores (`let contextGraph = ContextGraphStore()`) and injected everywhere
the way `dictionary`/`history` already are. The `ContextSummaryStore` (the Brief)
is **rewritten to render from `contextGraph.snapshot()`** instead of re-summarizing
raw history.

### 1.7 The Brief, redefined

`ContextSummary.swift` stops being a raw-history summarizer and becomes a
**projection of the graph**: "3 open commitments, 2 due this week; you talked about
Coralate (8×) and the Q3 launch; new person: Sarah Chen (PM)." It may still use the
LLM to phrase it nicely, but it reads *structured* graph data, so it's consistent
with recall, search, and the MCP server (they all see the same nouns). This is the
single most important consolidation in the whole plan.

---

## 2. SHARED PROTOCOLS (the anti-divergence layer)

Five protocols. Each has a 100%-on-device default impl that ships in core; the
networked impls live in optional modules (§3). Define them in
`Sources/Talkie/Protocols/`. **A feature planner who needs one of these MUST adopt
the protocol, never fork it.**

### 2.1 `TranscriptionBackend` — used by 01, 18, 20

The seam that lets the mic engine, the far-end engine, the wider-hardware fallback,
and the opt-in cloud accuracy mode all be interchangeable. It is a *generalization*
of today's `TranscriptionEngine`; the existing actor becomes
`AppleSpeechBackend: TranscriptionBackend` with essentially no behavior change.

```swift
protocol TranscriptionBackend: Sendable {
    static var isAvailable: Bool { get }
    var requiresNetwork: Bool { get }                 // false for on-device; true gates the sandbox/consent wall
    var supportsContextualStrings: Bool { get }       // Apple: yes; whisper.cpp: no (degrade gracefully)

    func setLocaleIdentifier(_ id: String) async
    func setContextualStrings(_ phrases: [String]) async

    /// Live streaming session. Returns the format to feed + the input continuation,
    /// exactly like TranscriptionEngine.beginSession today, so AudioCapture &
    /// SystemAudioCapture plug in unchanged.
    func beginSession(
        onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void,
        onSegment: (@Sendable (String) -> Void)?
    ) async throws -> (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation)

    func finishSession() async -> String
    func cancelSession() async
}
```

- Default (core): `AppleSpeechBackend` (today's `TranscriptionEngine`).
- Feature 20 adds `WhisperCppBackend` (or Parakeet-CoreML) for older macOS / wider
  hardware; it sets `supportsContextualStrings = false` (callers must tolerate no
  biasing). Model-download UX + binary-size handling are 20's problem, behind this
  protocol.
- Feature 01's far-end engine and feature 18's optional cloud `Diarizer`/streaming
  client both express themselves as backends (or as a `MeetingTranscriptionBackend`
  superset that also emits speaker labels — see 01's contract). **Two concurrent
  Apple backends** (mic + far-end) is the load question 01 must measure; the
  protocol doesn't change that, it just makes the fallback (one backend, mic-only)
  a clean swap.
- **`requiresNetwork` is the load-bearing flag for feature 15:** the sandbox/consent
  layer refuses to instantiate any backend whose `requiresNetwork == true` unless
  the user has flipped the explicit opt-in.

### 2.2 `Summarizer` (LLM) — used by 02, 05, 18 (and 09's drafting)

Unifies the four near-identical Foundation-Models actors that exist today
(`CleanupEngine`, `MeetingSummarizer`, `ContextSummaryEngine`, and 05's extractor)
behind one swappable LLM seam, so the opt-in Claude bridge (18) is a drop-in.

```swift
protocol Summarizer: Sendable {
    static var isAvailable: Bool { get }
    var requiresNetwork: Bool { get }   // false = on-device; gates the sandbox/consent wall

    /// One constrained generation. `instructions` is the system prompt; `input` the
    /// user text; the impl pins determinism (greedy/low-temp) like CleanupEngine.
    func generate(instructions: String, input: String) async -> String?
}
```

- Default (core): `OnDeviceLLM: Summarizer` wrapping `LanguageModelSession`
  (Foundation Models) — the existing greedy/low-temp pattern. `CleanupEngine`,
  `MeetingSummarizer`, `ContextSummaryEngine`, and the graph extractor all call
  *through* it (keeping their own prompt strings; the protocol only owns the
  generation call).
- Feature 18 adds `ClaudeBridge: Summarizer` (`requiresNetwork = true`) in the
  optional networked module, used only for heavy lifts (long-meeting map-reduce,
  agentic follow-ups, rich graph Q&A) and only when opted in.
- **Map-reduce** (the long-meeting `8000`-char truncation TODO) lives ABOVE this
  protocol as a helper that chains `generate` calls, so it works with either backend.

### 2.3 `NoteDestination` — used by 02, 10 (and optionally dictation export)

The pluggable export layer. Meetings already write Markdown; this generalizes
*where* and *how* without hardcoding any third-party app (the OSS genericity
invariant). The default impl is the current `~/Talkie Meetings/` plain-folder
writer — zero config, no third-party app.

```swift
protocol NoteDestination: Sendable {
    var id: String { get }            // "talkie-folder", "obsidian", "logseq", …
    var displayName: String { get }
    var isConfigured: Bool { get }    // e.g. folder picked & accessible

    func write(_ note: ExportableNote) async throws -> URL
}

/// The neutral note shape every producer fills in (meetings AND, optionally,
/// dictations). Templating/front-matter/wikilinks are applied by the destination,
/// not baked into the producer.
struct ExportableNote: Sendable {
    var kind: NoteKind                  // .meeting | .dictation | .brief
    var title: String
    var date: Date
    var bodyMarkdown: String            // Summary / Notes / Transcript sections already composed
    var frontMatter: [String: String]   // duration, participants, source, app, …
    var tags: [String]
    var links: [String]                 // entity displayNames → optional [[wikilinks]] by destination
    var suggestedFileName: String
}
enum NoteKind: String, Sendable { case meeting, dictation, brief }
```

- Default (core): `TalkieFolderDestination` = today's `MeetingStore.writeMarkdown`,
  refactored to take an `ExportableNote`. Plain folder, optional YAML, no app needed.
- Optional flags the destination honors (off by default, per the invariant):
  `[[wikilinks]]`, YAML front-matter, tags. Feature 10 builds the settings UX +
  templating engine + the protocol; community ships Obsidian/Logseq/Notion impls
  WITHOUT touching core.
- **Crucial reuse:** feature 02 (notes×transcript fusion) produces the
  `bodyMarkdown` (Notes + Summary + Transcript sections) and hands it to the SAME
  `NoteDestination`, so the Granola-magic note and the plain note travel the same
  pipe. `links` is populated from the meeting's graph entities (§1.6) so any
  wikilink-aware destination can cross-link people/projects for free.

### 2.4 `CommandIntent` — used by 08, 12 (and 09, 11)

The voice-copilot intent layer. Turns a spoken command + the current selection
into a safe, previewable, undoable text transform. 08 (general commands), 12
(edit/re-dictate a selection), 11 (macros), and 09 (cross-surface) are all
**intents**, so they share entry, safety, and injection.

```swift
protocol CommandIntent: Sendable {
    var id: String { get }                  // "rewrite", "translate", "replace-verbatim", "insert-macro", "cross-surface"
    var needsSelection: Bool { get }        // true → read AX selection first
    var isMutating: Bool { get }            // true → must produce a preview/undo

    /// Produce the replacement text (or nil = no-op). `ctx` carries the selection,
    /// the target app, the graph snapshot, and the spoken command text.
    func run(_ ctx: CommandContext) async -> CommandResult?
}

struct CommandContext: Sendable {
    var spokenCommand: String               // "translate to German" / "reply thanking them"
    var selection: String?                  // current AX selection (feature 12)
    var target: TargetApp
    var graph: ContextGraphSnapshot         // so commands can pull people/commitments (09)
    var summarizer: any Summarizer
}

struct CommandResult: Sendable {
    var replacement: String                 // what to inject
    var preview: Bool                       // true → show preview/confirm before injecting (safety)
    var undoToken: String?                  // restore the prior selection on undo
}
```

- **Entry & routing** (08 decides the exact gesture: distinct modifier vs. parsed
  leading imperative) feeds a `CommandRouter` that picks the matching `CommandIntent`.
- **Safety is in the protocol, not each feature:** `isMutating`/`preview`/`undoToken`
  force every rewrite to be reversible. Injection is always via the shared
  `TextInjector` (never a new paste path). Replacing a selection feeds the diff back
  into `LearningEngine` (12) and, where it edits a name/term, into the graph.

### 2.5 `MeetingContextProvider` — used by 03, 04 (and consumed by 01/02/05)

Supplies the *surrounding facts* of a meeting — is one happening, what's it called,
who's in it — decoupled from how the meeting is captured.

```swift
protocol MeetingContextProvider: Sendable {
    /// Auto-detect: is a meeting likely in progress right now? (feature 03)
    func detectActiveMeeting() async -> MeetingSignal?

    /// Naming/attendees from the calendar for a given time window. (feature 04)
    func eventContext(at date: Date) async -> MeetingEventContext?
}

struct MeetingSignal: Sendable {
    var confidence: Double          // mic-hot-by-other-process (low) → +allowlisted app (high)
    var appBundleID: String?        // us.zoom.xos, com.microsoft.teams2, …
    var startedAtUnix: Double
}

struct MeetingEventContext: Sendable {
    var title: String?              // → meeting note title
    var attendeeNames: [String]     // → Person entities (05) AND recognizer bias (04)
    var eventID: String?            // → Provenance(.calendar)
}
```

- Feature 03 implements `detectActiveMeeting()` (Core Audio process-list scan +
  allowlist + debounce) and the consent banner; never silently records.
- Feature 04 implements `eventContext(at:)` (EventKit, read-only) and feeds
  `attendeeNames` into BOTH transcription backends' `setContextualStrings` (mic +
  far-end) AND into the graph as Person entities with `Provenance(.calendar)`.
- `MeetingRecorder` consumes a `MeetingContextProvider` to title the note and
  pre-bias names — instead of `makeTitle(start:)`'s timestamp-only title.

---

## 3. NAMING, FILE LAYOUT & MODULE BOUNDARIES

Today everything is flat in `Sources/Talkie/` (one executable target, zero deps).
We keep ONE app target but introduce **folders** for legibility and a hard
**networked/local split** for the privacy thesis. Folders are organizational; the
network wall is enforced by *target separation* + the sandbox (feature 15).

```
Sources/
  Talkie/                         ← the always-local app (the only target with the
                                     audio-input entitlement & NO network entitlement)
    (existing flat files stay)
    Protocols/
      TranscriptionBackend.swift
      Summarizer.swift
      NoteDestination.swift
      CommandIntent.swift
      MeetingContextProvider.swift
    ContextGraph/
      Entity.swift  Provenance.swift  ContextGraphStore.swift
      ContextGraphExtractor.swift  ContextGraphSnapshot.swift
    Backends/
      AppleSpeechBackend.swift      ← today's TranscriptionEngine, conformed
      OnDeviceLLM.swift             ← today's FoundationModels call, conformed
      (feature 20) WhisperCppBackend.swift
    Export/
      TalkieFolderDestination.swift ← today's writeMarkdown, conformed
    Commands/
      CommandRouter.swift  RewriteIntent.swift  ReplaceSelectionIntent.swift
      MacroIntent.swift  CrossSurfaceIntent.swift
    Meetings/  (03/04 detectors + banner live here, consuming MeetingContextProvider)
    Search/    (feature 19: embeddings index + search UI)

  TalkieMCP/                        ← SEPARATE SwiftPM executable target (feature 06)
                                      stdio only, read-mostly over the same on-disk
                                      stores. NO network. Ships the .mcpb bundle (07a).

  TalkieBridge/                     ← SEPARATE target/module (feature 18 + 07b)
                                      THE ONLY code allowed to import a network client.
                                      ClaudeBridge: Summarizer. Compiled into the app
                                      ONLY in a distinct build flavor (see §4.1).
```

**Rules of the boundary:**
- `Talkie` (core) **must never** `import` anything from `TalkieBridge`. It depends
  only on the *protocols*. The bridge is injected (or absent) at the composition
  root (`AppDelegate`), behind a feature flag + consent.
- `TalkieMCP` reads the same JSON/Markdown on disk **read-mostly**, uses file
  coordination / a lightweight file-watch, and takes no locks the app holds. It is
  a *peer reader*, not a writer, of the graph/meetings/dictionary (the one
  exception — "add to dictionary" — writes through an atomic append the app also
  tolerates). It is launched out-of-process; the app is not required to be running.
- The networked targets are **opt-in and separately distributable** so the default
  download is provably zero-network (feature 15 can ship a build with the network
  entitlement absent entirely).

**Naming conventions to keep:** stores are `XxxStore: ObservableObject`; engines/
extractors are `actor`; Sendable read models are `XxxSnapshot`; pure helpers are
`enum Xxx { static func … }`; protocols are nouns (`TranscriptionBackend`), impls
are `<Vendor><Role>` (`AppleSpeechBackend`, `OnDeviceLLM`, `ClaudeBridge`).

---

## 4. CROSS-CUTTING INVARIANTS (every planner honors these)

### 4.1 Privacy / sandbox model
- **Local is the default and the floor.** The shipped default experience makes
  **zero** network connections. The verified fact (no `URLSession` anywhere, single
  audio-input entitlement) must remain true for the default build.
- **Network is opt-in, disclosed, and architecturally separated.** Any feature that
  touches the network (07b remote connector, 16 Sparkle appcast, 18 Claude bridge)
  must: (a) be OFF by default; (b) require a deliberate user action to enable;
  (c) disclose exactly what is sent and when; (d) live in a separate module
  (`TalkieBridge`/`TalkieMCP`) — never in core.
- **Two build flavors** (feature 15 defines them, everyone respects them):
  `Talkie` (sandboxed, **no** `com.apple.security.network.client`) and a clearly-
  labeled `Talkie (Connected)` build that adds the network entitlement only when a
  networked module is compiled in. A networked `Summarizer`/`TranscriptionBackend`
  (`requiresNetwork == true`) must refuse to instantiate in the sandboxed flavor.
- **The graph never leaves the machine** except through an explicit user action via
  the bridge/connector with per-call consent. Provenance (§1.3) exists partly so the
  user can see precisely what any networked feature would expose.

### 4.2 Open-source genericity
- **No hardcoded personal stack.** Obsidian, a specific vault, a particular editor,
  Claude Code itself — all optional/pluggable via `NoteDestination` / MCP, each with
  a useful **zero-config, no-third-party-app default** (the plain `~/Talkie Meetings/`
  folder; the bundled on-device backend; the local stdio MCP server).
- **macOS 26 + Apple Silicon is the floor today**, which limits the OSS audience.
  Feature 20's `TranscriptionBackend` + the heuristic-only graph path (§1.5) are the
  two designated widening levers; every other feature should degrade, not break,
  when Foundation Models / SpeechAnalyzer are unavailable.

### 4.3 Brand / UX
- Warm, honest, calm. Match `DesignSystem.swift` (the v2 white/blue tokens are the
  source of truth for *values*; `BRAND.md` for *philosophy*). One accent
  (`Theme.coral`, now blue) per view; feather palette for **data only**; Young Serif
  for titles/hero numbers; squircle + hairline + whisper shadow; calm springs.
- **Honest second-person copy. Never invent metrics or percentiles.** Recall and the
  Brief must cite provenance ("because you said…"), never assert facts the graph
  can't back. New surfaces (search results, the consent banner, the command preview,
  the privacy panel) all follow this.
- Reuse the existing `glassEffect` HUD, `MarkdownText` renderer, `FlowLayout` chips,
  and the `NavigationSplitView` sidebar/tab pattern rather than inventing UI.

### 4.4 Swift 6 strict concurrency
- State-owning engines/extractors are `actor`s; stores/UI are
  `@MainActor final class … ObservableObject`; cross-thread value types are
  `@unchecked Sendable` + `NSLock` (`lock.withLock {}`). Off-main read models are
  immutable `Sendable` snapshots.
- Real-time audio blocks capture converters/handlers **by value**; never read a
  main-mutable property from a render thread. Async setup uses **generation tokens**
  re-checked after every `await`. Ordered events go through a single `AsyncStream`
  consumed by one task. Heavy work is `Task.detached(.utility)`. Persistence is
  `.atomic` + failure-tolerant decode + optional fields for back-compat.
- **Model exclusivity extends to the graph:** the shared transcription model and
  Foundation Models must not be driven by extraction/commands while a live
  dictation or recording is in flight (reuse the existing `isDictating`/
  `isRecording` probes).

---

## 5. DEPENDENCY / SEQUENCING

```
        ┌─────────────────────── FOUNDATION (build first) ───────────────────────┐
        │ 05 Context Graph      ──►  everything recall/brief/command/search/MCP    │
        │ TranscriptionBackend  ──►  01 far-end, 18 cloud, 20 wider hardware       │
        │ Summarizer protocol   ──►  02 fusion, 18 bridge, 05 extraction           │
        └────────────────────────────────────────────────────────────────────────┘
                                     │
   ┌─────────────────────────────────┼──────────────────────────────────────────┐
   │  PRODUCTION-HARDENING          │  PRODUCT SURFACES (depend on foundation)     │
   │  01 far-end → main (rebase)    │  02 notes fusion   04 calendar               │
   │  15 sandbox/zero-net proof     │  08 voice commands 12 edit-by-voice          │
   │  16 install/update             │  03 auto-detect    11 macros                 │
   │                                │  10 export  13 per-app  14 HUD               │
   └────────────────────────────────┼──────────────────────────────────────────┘
                                     │
          ┌──────────────────────────┼──────────────────────────┐
          │  CAPSTONES (depend on the graph + several surfaces)   │
          │  06 MCP  07 connector  09 cross-surface  19 search    │
          │  18 Claude bridge (separate networked module)         │
          └──────────────────────────────────────────────────────┘
```

**Tier 0 — must land first (nothing good happens without these):**
1. **05 ContextGraph** (model + store + extractor + query API). The keystone; the
   single highest-leverage piece. Also rewrites the Brief as a graph projection.
2. **`TranscriptionBackend` + `Summarizer` protocols** with the existing actors
   conformed (a low-risk refactor, no behavior change). Do this *alongside* 05 so
   01/18/20 and 02 have their seam from day one.
3. **01 far-end → main** (rebase the `feat/meeting-far-audio` branch; it's clean and
   3 commits behind). This makes "meetings" real and gives the graph its richest
   feed (Me/Them transcripts). Its production gaps (watchdog, two-analyzer load,
   TCC UX) are hardening, not blockers for the merge.

**Tier 1 — the moat-makers that need only Tier 0:**
- **04 calendar** (feeds names → graph + bias; tiny, high payoff).
- **02 notes fusion** (the Granola magic; needs `Summarizer` + `NoteDestination`).
- **08 voice commands** + **12 edit-by-voice** (the `CommandIntent` layer; the
  copilot story).
- **15 sandbox/zero-net proof** (lock the privacy thesis BEFORE any networked
  feature exists, so the boundary is enforced by construction, not retrofitted).

**Tier 2 — capstones (the demos that sell the thesis):**
- **09 cross-surface** ("email Sarah the action items from my last meeting") — needs
  05 + 08. This single sentence is the product pitch; sequence it as the headline demo.
- **06 MCP** + **07 connector** (expose the graph to local agents; 06 before 07).
- **19 search** (semantic + keyword over graph + history + meetings).
- **18 Claude bridge** (the only networked org; build last, behind 15's wall).

**Top 3 sequencing decisions (call these out to all planners):**
1. **Context Graph (05) is the gate.** It blocks 04/06/07/09/19 and reshapes the
   Brief. Build its model + query API before any consumer writes code against it.
2. **Conform the two protocols (`TranscriptionBackend`, `Summarizer`) up front** —
   while the impls are still the existing on-device actors — so 01/18/20 and 02
   never fork a parallel engine. This is a cheap refactor now and an expensive
   untangle later.
3. **Merge far-end (01) early and lock the sandbox (15) early.** Far-end gives the
   graph its best data; the sandbox makes the privacy wall structural before the
   first networked module (18/07b) can possibly leak across it.

---

## 6. PER-FEATURE CONTRACTS

Each block: **Exposes** (what others may consume) / **Consumes** (what it depends
on) / **Note** (the one thing that keeps it coherent). "Graph" = `ContextGraphStore`/
`Snapshot` (§1.6).

### 01 — Far-end capture, diarization & speaker-labeled transcript
- **Exposes:** the merged, speaker-labeled meeting transcript + `participants`/
  `source` metadata (already on branch); per-segment turns feeding the graph's
  meeting extraction; a `MeetingTranscriptionBackend` shape (a `TranscriptionBackend`
  that also emits speaker labels) so cloud (18) and diarization (Phase 3) slot in.
- **Consumes:** `TranscriptionBackend` (mic + far-end as two backends);
  `MeetingContextProvider` (04) for names → bias on BOTH backends.
- **Note:** keep the "two streams = free diarization" spine; 3+ speaker splitting
  only splits "Them". Rebase to main first (clean). Verify two concurrent Apple
  backends' CPU/ANE/memory; if disallowed, fall back to mic-only via the protocol.

### 02 — Notes × transcript fusion (the Granola magic)
- **Exposes:** the fused note as an `ExportableNote` (Notes + Summary + Transcript
  sections); live action-item suggestions → candidate `.commitment` entities.
- **Consumes:** `Summarizer` (fusion prompt; never invent facts); `NoteDestination`
  (write the fused note); the live notes pane persists alongside the transcript.
- **Note:** notes and transcript both become graph provenance. Fusion runs *through*
  the `Summarizer` protocol so a long meeting can map-reduce or (opt-in) use 18.

### 03 — Meeting auto-detect & consent banner
- **Exposes:** `MeetingContextProvider.detectActiveMeeting()` → `MeetingSignal`.
- **Consumes:** Core Audio process-list scan + allowlist; debounce; the brand HUD/
  banner pattern.
- **Note:** NEVER silently record — always the consent banner. Music/video can't
  trigger (output, not input). Confidence = mic-hot + allowlisted app.

### 04 — Calendar awareness (EventKit, read-only)
- **Exposes:** `MeetingContextProvider.eventContext(at:)` → title + attendee names;
  attendees as Person entities with `Provenance(.calendar)`.
- **Consumes:** the Graph (write Person entities); both transcription backends
  (`setContextualStrings(attendeeNames)`); `MeetingRecorder` (title the note).
- **Note:** on-device, read-only. No event → graceful fallback to timestamp title.

### 05 — Personal context graph (KEYSTONE)
- **Exposes:** `ContextGraphStore` + `ContextGraphSnapshot` (lookup, biasPhrases,
  openCommitments, entities-from-source); the redefined Brief as a projection.
- **Consumes:** `HistoryStore`, meetings, `DictionaryStore`, `AppContext`/PhraseMiner,
  calendar (04); `Summarizer` for the LLM extraction pass.
- **Note:** every entity has provenance; extraction is incremental, off-main, never
  during a live session; heuristic-only path when Foundation Models is unavailable.
  Replaces the ad-hoc bias union in `AppDelegate.beginDictation` with
  `graph.biasPhrases(near:)`.

### 06 — Local MCP server (stdio)
- **Exposes:** MCP tools/resources: `list_meetings`, `get_meeting`, `search`,
  `get_brief`, `list_commitments`, `lookup_entity`, `add_dictionary_term`.
- **Consumes:** the on-disk graph/meetings/dictionary **read-mostly**; the Graph
  query surface (§1.6) replicated against the file snapshot; feature 19 for `search`.
- **Note:** separate `TalkieMCP` executable target; stdio only; no network; no lock
  contention with the app; runnable while the app is closed.

### 07 — Custom Claude connector (.mcpb + Claude.ai directory)
- **Exposes:** (a) a one-click Desktop `.mcpb`/DXT bundle wrapping the 06 server
  (recommend FIRST, stays on-device); (b) a remote-connector design.
- **Consumes:** 06 (the local server); for 07b, the `TalkieBridge` network module +
  15's consent/sandbox model.
- **Note:** 07a is privacy-safe and primary. 07b breaks zero-network unless designed
  as a user-run local endpoint + explicit opt-in + per-call consent; phase it last,
  RESEARCH current DXT/.mcpb + directory + remote-MCP/OAuth facts (don't trust memory).

### 08 — Voice commands / intent layer
- **Exposes:** `CommandIntent` implementations + the `CommandRouter`; command-mode
  entry gesture.
- **Consumes:** AX selection (read), the Graph snapshot (people/commitments for
  context), `Summarizer` (the rewrite), `TextInjector` (inject), preview/undo safety.
- **Note:** safety lives in the protocol (`isMutating`/`preview`/`undoToken`). Beat
  Wispr by doing it on-device + OSS.

### 09 — Cross-surface context
- **Exposes:** a `CrossSurfaceIntent` ("email Sarah the action items from my last
  meeting").
- **Consumes:** the Graph (recent meetings, entities, open commitments + provenance),
  08's `CommandIntent` pipeline, `Summarizer` (draft), `TextInjector` (insert),
  disambiguation UX ("which meeting?").
- **Note:** THE demo that sells the thesis. It exists *because* both surfaces feed
  one graph — make it concrete and reliable.

### 10 — Universal note export (pluggable, not Obsidian-locked)
- **Exposes:** `NoteDestination` protocol + settings UX + templating engine;
  optional wikilinks/front-matter/tags (off by default).
- **Consumes:** `ExportableNote` from meetings (02) and optionally dictations; the
  Graph for `links` (entity cross-linking).
- **Note:** default `TalkieFolderDestination` must be useful with zero config and no
  third-party app. Community ships Obsidian/Logseq/Notion impls without touching core.

### 11 — Voice macros / snippets
- **Exposes:** a `MacroIntent` (`CommandIntent`); a macro store (trigger → expansion
  with `{today}` tokens).
- **Consumes:** explicit-invocation matching (no fuzzy false positives),
  `TextInjector`, `DictionaryStore` patterns for storage/UI.
- **Note:** on-device only; a Dictionary-tab sibling UI. Triggers are entities-
  adjacent but distinct (curated, not extracted).

### 12 — Edit-by-voice / re-dictate a selection
- **Exposes:** a `ReplaceSelectionIntent` (`CommandIntent`); distinguishes
  "replace verbatim with what I said" vs "apply this instruction to the selection".
- **Consumes:** AX selection, `Summarizer` (for the instruction path),
  `TextInjector`, undo safety; feeds the diff back to `LearningEngine` and (for
  name/term edits) the Graph.
- **Note:** shares the entire `CommandIntent` machinery with 08 — do NOT fork a
  second selection/inject path.

### 13 — Per-app profiles
- **Exposes:** a resolved profile (dictionary subset, cleanup level/style, insertion
  mode, capitalization, active macros) keyed by bundle id.
- **Consumes:** `AppContext` (active app), `AppSettings` (global default → per-app
  override resolution), `DictionaryStore`, `CleanupEngine`/`CleanupStyle`.
- **Note:** extends today's per-`AppCategory` `appCleanupStyles` to per-bundle-id
  full profiles, same inheritance shape. Profile selection of bias terms should
  filter the Graph's `biasPhrases` for that app.

### 14 — HUD style switcher + visible intelligence
- **Exposes:** an in-HUD affordance to view/cycle the active cleanup style/level.
- **Consumes:** the existing `glassEffect` HUD, `CleanupEngine` levels/styles,
  `AppSettings`; ties to 13 (shows the resolved per-app profile).
- **Note:** on-brand (warm, calm, one accent). Surfaces intelligence without opening
  Settings; the switch writes through the same settings/profile path (13).

### 15 — Provable zero-network privacy
- **Exposes:** the two build flavors (sandboxed default vs. connected) + the
  `requiresNetwork` enforcement point; an in-app privacy/proof panel listing actual
  entitlements; the structural network wall every networked feature respects.
- **Consumes:** nothing it doesn't already verify; must validate each on-device API
  (Speech/SpeechAnalyzer, FoundationModels, EventKit, the Core Audio tap,
  Accessibility, `~/Talkie Meetings/` access) works UNDER the App Sandbox without a
  network entitlement. RESEARCH sandbox-vs-framework specifics.
- **Note:** lock this BEFORE 18/07b exist so the wall is built-in, not bolted-on.
  The graph's provenance (§1.3) is the honest "here's exactly what's on your Mac"
  data behind the proof panel.

### 16 — Frictionless install & auto-update
- **Exposes:** Homebrew cask + signed/notarized DMG + (opt-in) Sparkle appcast + CI
  release pipeline.
- **Consumes:** `scripts/notarize.sh`/`build_app.sh`; respects 15 (Sparkle's appcast
  fetch is network → the update check must be opt-in/transparent, or documented as a
  tradeoff, and absent from the sandboxed-default if it can't be reconciled).
- **Note:** RESEARCH current Sparkle + cask + GitHub-Actions notarization practice.

### 17 — Reproducible benchmark harness
- **Exposes:** a benchmark target/script (WER + RTF/latency for Talkie's pipeline vs.
  Whisper Large V3 on the same Apple Silicon) + an on-brand results chart.
- **Consumes:** the `TranscriptionBackend` protocol (run the same corpus through any
  backend — also validates 20); a licensed corpus (e.g. LibriSpeech test subset).
- **Note:** keep it honest (cold vs warm model, on-device, documented method).
  Doubles as the regression harness for 20's backends. RESEARCH datasets + WER tools.

### 18 — Optional opt-in Claude bridge
- **Exposes:** `ClaudeBridge: Summarizer` (`requiresNetwork == true`) in the
  `TalkieBridge` module; consent + data-disclosure UX; Keychain API-key handling.
- **Consumes:** the `Summarizer` protocol (drop-in for heavy lifts: long-meeting
  map-reduce, agentic follow-ups, rich graph Q&A); 15's network wall (must require a
  deliberate enable; refuses to load in the sandboxed-default flavor).
- **Note:** OFF by default; discloses exactly what is sent and when. Use accurate
  current Claude model ids/pricing (consult the claude-api skill — don't guess).
  Aligns with 01's cloud `Diarizer`/`Transcriber` idea and 20's backend protocol.

### 19 — Local semantic + keyword search
- **Exposes:** a search API (semantic + keyword, blended ranking, snippets +
  jump-to-source) over history + meetings + graph entities; consumed by 06's `search`
  tool and a new search tab/command palette.
- **Consumes:** on-device embeddings (Apple `NLEmbedding`/`NLContextualEmbedding` or
  a small bundled/MLX model — RESEARCH); the Graph (entities as first-class hits +
  provenance for jump-to-source); `HistoryStore`, meetings.
- **Note:** stays on-device. Embeddings index may be the one component that warrants
  a compact binary sidecar next to the graph JSON (§1.4). Ranking blends semantic +
  keyword; results cite provenance (no invented relevance claims).

### 20 — Pluggable transcription backend (widen OSS reach)
- **Exposes:** additional `TranscriptionBackend` impls (`WhisperCppBackend` /
  Parakeet-CoreML) + graceful LLM-cleanup degradation when Foundation Models is
  absent (skip cleanup or use a small local model).
- **Consumes:** the `TranscriptionBackend` protocol (the SAME one mic + far-end
  adopt); model-download UX; binary-size/licensing handling.
- **Note:** STRATEGIC for OSS adoption — it's the lever that lifts the macOS-26/
  Apple-Silicon floor. Backends that set `supportsContextualStrings = false` mean
  callers must tolerate no biasing; the heuristic-only graph path (§1.5) is the
  matching degrade. RESEARCH whisper.cpp / Parakeet CoreML integration. Validate via 17.
```
