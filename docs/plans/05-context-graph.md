# 05 — Personal Context Graph (the keystone spine)

> The single on-device brain both voice surfaces feed. Build it first, build it
> right, and features 04/06/07/09/19 become small. This plan is the concrete
> realization of `_UNIFICATION.md` §1 + the §6 contract for **05**.
>
> Floor: macOS 26.0, Apple Silicon, Swift 6 strict concurrency (`.v6`), zero deps,
> zero network. All paths absolute. Anchors point at `main` (HEAD `5f747fb`); files
> on the unmerged `feat/meeting-far-audio` branch are marked **[branch]**.

---

## 1. Summary

A local, on-device **personal context graph** — typed entities (people, projects,
terms, commitments, organizations) extracted incrementally from every dictation and
every meeting, each carrying provenance back to its source — owned by a new
`ContextGraphStore`, fed by an `actor ContextGraphExtractor` (heuristics + on-device
Foundation Models), and read through one stable query API (`lookup`, `biasPhrases`,
`openCommitments`, `entities(fromSource:)`). It supersedes today's scattered
fragments (`DictionaryStore` vocab, the `ContextSummary` Brief, ephemeral
`PhraseMiner` phrases) and becomes the brain that recall, the Brief, recognizer
biasing, the MCP server, and semantic search all consume.

## 2. Why it matters

- **User value:** Talkie stops being a stateless typewriter and starts *remembering
  the people, projects, vocabulary, and promises you actually talk about*. You get
  recall ("who is Sarah?" → "PM on Coralate, you owe her the deck, mentioned in
  Tuesday's standup and last week's call"), a Brief that is a faithful projection of
  structured facts (not a fresh hallucination-prone LLM render each time), and a
  recognizer that spells *your* world right because the bias set is the graph, not a
  per-session guess thrown away seconds later.
- **Strategic thesis:** this is THE moat. Wispr Flow and Granola are *separate cloud
  companies*; neither can build a shared brain that fuses dictation + meetings,
  because neither owns both surfaces and neither runs on-device. The graph is what
  unlocks every downstream differentiator — voice commands that know your people
  (08/09), a local MCP server exposing your brain to agents (06/07), provable
  privacy because the brain never leaves the machine and every fact cites its source
  (15), and semantic search over everything you've ever said (19). It is the
  gravitational center that keeps 20 features ONE product.
- **Disruption:** "email Sarah the action items from my last meeting" (feature 09)
  is the one-sentence pitch — and it is *only possible* because both mouths feed one
  graph. 05 is the precondition for that sentence existing.

## 3. Current state in the code — fragments, no graph

Today the "context graph" exists only as five private islands. Honest inventory:

| Fragment | File:line | What it is | Gap vs. a graph |
|---|---|---|---|
| Custom vocab + learned replacements | `DictionaryStore.swift:23-118` | `@Published vocabulary: [String]` + `[Replacement]`; `contextualPhrasesSnapshot()` (`:107-113`) is the only typed term surface | No entity kind, no provenance, no merge, no recall. Vocab is a flat string list. |
| The daily "Brief" | `ContextSummary.swift:7-107` | `actor ContextSummaryEngine.summarize` does a **throwaway LLM render** over ≤6000 chars of app-tagged history (`:21-55`); `ContextSummaryStore` persists the string to `context_summary.json` | **No entities, no provenance, no incrementality** — it re-summarizes raw history every refresh. Exactly what §1.7 says to replace. |
| Mined phrases | `AppContext.swift:99-151` | `PhraseMiner.mine` extracts proper nouns / identifiers / filenames, cap 40 (`:100`) | **Ephemeral** — used as per-session recognizer bias then discarded. Never persisted, never merged, no kind. |
| Per-app usage | `AppUsageStore.swift` | word/dictation counts keyed by bundleID | "where words go", not who/what. Not entities. |
| Meeting transcripts | `Meeting.swift` + **[branch]** `participants`/`source` | raw Markdown + `participants: [String]` **[branch]** | Raw text; **no extracted entities**. "Them"/"Me" labels exist (branch) but aren't People nodes. |

Other relevant facts grounded in code:

- **The ad-hoc bias union** 05 must replace lives in `AppDelegate.beginDictation`
  (`AppDelegate.swift:336-339`): `dictionary.contextualPhrasesSnapshot()` ∪
  `captured.phrases` ∪ `currentVibeSnapshot.biasPhrases`, deduped, `.prefix(180)`.
- **The history feed** is `HistoryStore` (`HistoryStore.swift:24-99`):
  `DictationEntry` has `id/timestampUnix/text/wordCount/durationSec/appName/appCategory`
  (`:4-21`). **7-day retention, cap 2000** (`:29-30`, pruned on load+add). This is the
  short memory; the graph is the long one — so the graph must extract entities *before*
  an entry is pruned, or it loses them forever.
- **The meeting feed** is `Meeting.swift` (`MeetingStore`, one `.md` per meeting +
  `meetings.json` index). **[branch]** adds `participants`/`source` + a `TurnLog`
  (`MeetingTranscript.swift:14-44`) of timestamped `Me`/`Them` turns and
  `MeetingTranscriptRenderer` (`:47-93`).
- **The LLM seam** is `actor CleanupEngine` over `LanguageModelSession`
  (`CleanupEngine.swift`); `CleanupEngine.isAvailable` is the Apple-Intelligence gate
  reused by `ContextSummaryEngine.isAvailable` (`ContextSummary.swift:8`). Greedy,
  low-temp generation is the house pattern (`CleanupEngine` `.greedy` temp 0.1;
  summarizers temp 0.3).
- **Store wiring** is in `AppDelegate` (`AppDelegate.swift:6-15`): every store is a
  plain `let` created at init and injected into views (`:568` injects
  `contextSummary`). The Brief refresh is **manual only** today — triggered from
  `DashboardView.swift:196,236` (`Task { await summary.refresh(from: history) }`),
  never automatically.
- **Storage root** is `AppPaths.supportDirectory()` →
  `~/Library/Application Support/Talkie/` (`AppPaths.swift:7-13`); meetings live in
  `~/Talkie Meetings/` (`:17-22`). No `graphDirectory()` yet.

**Net: nothing of the graph exists.** The pieces it *absorbs* exist and are mature.
This feature is greenfield code that re-roots those pieces.

## 4. Design & approach

### 4.1 Shape (mirrors `_UNIFICATION.md` §1)

One **store** (`@MainActor ContextGraphStore: ObservableObject`) owns the node table
and commitments and persists them. One **extractor** (`actor ContextGraphExtractor`)
turns new dictations/meetings into entities incrementally, off-main, never during a
live session. One immutable **snapshot** (`ContextGraphSnapshot: Sendable`) is the
off-main read model (mirrors `ProjectIndexSnapshot` in `VibeCoding.swift`). The
**Brief** (`ContextSummary.swift`) is rewritten to render from the snapshot.

### 4.2 Entity identity & merge (the core algorithm)

`EntityID = (kind, normalizedKey)`. `normalizedKey` = lowercased, whitespace-trimmed,
diacritics-folded (`folding(options: .diacriticInsensitive, locale: nil)`),
punctuation-stripped. This makes identity **deterministic**: "Sarah Chen" dictated on
Tuesday and "sarah chen" said in Friday's meeting hash to the same `EntityID` and
**merge** instead of duplicating. Merge rules:

- `displayName` = the highest-confidence surface form seen (a properly-capitalized
  multi-word form beats a lowercased single token); losers go to `aliases`.
- `provenance` is appended (deduped on `(source, sourceID)`), `mentionCount += 1`,
  `lastSeenUnix = max`, `firstSeenUnix = min`, `confidence = max(existing, new)`.
- `notes` are append-only, deduped, capped (≤8 short lines) — the recall surface, not
  a chat log.
- `pinned` is sticky: once curated (a dictionary term, a pinned person) it never
  un-pins and never prunes.

### 4.3 The extraction pipeline (incremental, two-stage)

```
new dictations / meetings (since watermark)  ──►  ContextGraphExtractor.extract()
   │
   ├─ STAGE 1 — heuristics (free, deterministic, no model; ALWAYS runs):
   │    • reuse AppContext.PhraseMiner.mine() on each entry's text →
   │        candidate .term / .project nodes (CamelCase/snake_case/filenames → term;
   │        capitalized proper nouns → person-or-org candidates, confidence ~0.45)
   │    • DictionaryStore terms → .term entities, pinned, confidence 1.0
   │    • meeting participants [branch] (["Me","Them"]) + calendar names (04) → .person
   │    • commitment cue regex over sentences:
   │        \b(I'?ll|I will|I need to|I'?ve got to|let me|I should|by
   │          (Mon|Tues|...|Fri|EOD|end of (day|week)))\b
   │      → candidate .commitment (text = the clause), confidence ~0.4
   │
   └─ STAGE 2 — LLM pass (Foundation Models via Summarizer; ONLY if available):
        batched new text (≤ ~4000 chars/call, chained for more) →
          constrained extraction prompt that returns LINE-DELIMITED records:
            PERSON|Sarah Chen|PM on Coralate
            PROJECT|Coralate|
            COMMITMENT|send the design deck|owner=me|to=Sarah Chen|due=Friday
          • resolve/merge aliases ("Sarah" == "Sarah Chen" in THIS batch's context)
          • promote/demote heuristic candidates' confidence
          • write ONE-LINE entity notes
          • HARD guardrail (same as ContextSummary): "Do NOT invent anything not in
            the text. Output ONLY the records." Parsed, not free chat.
```

- **Parsing the LLM output** uses a strict line grammar (`KIND|name|fields`),
  not JSON — Foundation Models guided generation is available but the pipe grammar is
  cheaper to parse defensively and degrades to "skip the malformed line" instead of
  failing the batch. Unparseable lines are dropped silently.
- **Degradation:** if `CleanupEngine.isAvailable == false` (Apple Intelligence off,
  or feature 20's wider-hardware path), Stage 2 is skipped entirely — the graph still
  builds Person/Project/Term/Commitment nodes from Stage 1 heuristics. Fewer notes,
  no alias merging, but the spine is alive. This is the §1.5 / feature-20 degrade.

### 4.4 Trigger & scheduling (the model-exclusivity rule)

Three enqueue points, all debounced into ONE coalesced run:

1. After `endDictation()` logs a `HistoryStore` entry (`AppDelegate.swift:~490`) —
   enqueue that entry id.
2. After `MeetingRecorder.stop()` adds a `Meeting` — enqueue that meeting id.
3. After `DictionaryStore` changes — enqueue a "terms changed" marker.

The store holds a **debounce token**: each enqueue (re)starts a `Task` that sleeps
~45s at `.utility`, then — **only if no dictation and no meeting is live** (probe the
existing `isDictating` flag and `meetingRecorder.isRecording`, the same exclusivity
gate `AppDelegate.swift:299` and `MeetingRecorder.swift:39` already use) — runs the
extractor against everything newer than the per-source watermark. If a session *is*
live, it reschedules. This honors `_UNIFICATION.md` §4.4: **the shared model must not
be driven by extraction while a live session is in flight.** A pull-on-launch pass
(`extractBacklog()` at `applicationDidFinishLaunching`) catches anything logged while
the app was closed and, critically, drains history *before* `HistoryStore.prune()`
can delete 8-day-old entries the graph never saw (run extraction-before-prune ordering
on launch).

### 4.5 Recognizer biasing (replacing the ad-hoc union)

`graph.biasPhrases(limit: 180, near: target)` returns a ranked phrase list:
`pinned` first, then by `confidence × recency × mentionCount`, filtered to entity
kinds worth spelling (person/project/term/org), capped. `AppDelegate.beginDictation`
(`:336-339`) drops its three-way `Set` union and calls this instead — but **keeps**
the live, app-specific `captured.phrases` (this-second on-screen names) and the vibe
filename snapshot *appended* on top, since those are point-in-time signals the graph
shouldn't permanently absorb. So: `graph.biasPhrases(near: target)` ∪ `captured.phrases`
∪ `vibeSnapshot.biasPhrases`, deduped, `.prefix(180)`. The mined `captured.phrases`
*also* flow into the graph as low-confidence `.term`/`.person` candidates with
`Provenance(.appContext)` so repeated on-screen names eventually graduate to real
nodes (this is how the ephemeral becomes persistent, per §1.1).

### 4.6 The Brief, redefined (the single most important consolidation)

`ContextSummaryStore.refresh` stops calling `ContextSummaryEngine.summarize(entries:)`
over raw history. Instead it reads `graph.snapshot()` and composes the Brief from
**structured facts**: open commitments (count + due-this-week), most-mentioned
projects with counts, new people this period (name + the one-line note). The LLM is
optional polish — it phrases the structured digest nicely but receives the *already-true*
structured input, so it can't invent. When the model is unavailable the Brief renders
a plain templated version from the same structured data (so the Brief survives on the
heuristic-only path). The persisted `context_summary.json` shape stays valid (the
`{summary, generatedAtUnix?}` payload at `ContextSummary.swift:90-93`), so the
Dashboard `BriefBanner`/`BriefDetailView` (`DashboardView.swift:109-237`) keep working
unchanged.

## 5. New & changed files/types

New module folder `Sources/Talkie/ContextGraph/` (organizational; single target
preserved — no `Package.swift` change). Sketches:

```swift
// ContextGraph/Entity.swift
struct EntityID: Hashable, Codable, Sendable {
    let kind: EntityKind
    let key: String                              // normalized
    static func make(_ kind: EntityKind, _ surface: String) -> EntityID
}
enum EntityKind: String, Codable, Sendable, CaseIterable {
    case person, project, term, commitment, organization
}
struct Entity: Codable, Sendable, Identifiable {
    var id: EntityID
    var kind: EntityKind { id.kind }
    var displayName: String
    var aliases: [String] = []
    var notes: [String] = []
    var provenance: [Provenance] = []
    var firstSeenUnix: Double
    var lastSeenUnix: Double
    var mentionCount: Int = 1
    var confidence: Double = 0.5
    var pinned: Bool = false
    mutating func merge(_ other: Entity)          // §4.2 rules
}
struct CommitmentDetail: Codable, Sendable {
    var text: String
    var owner: EntityID?                           // nil = the user
    var counterparty: EntityID?
    var dueHint: String?                           // never a fabricated date
    var status: CommitmentStatus
    var source: Provenance
}
enum CommitmentStatus: String, Codable, Sendable { case open, done, dropped }

// ContextGraph/Provenance.swift
struct Provenance: Codable, Sendable, Hashable {
    enum Source: String, Codable, Sendable {
        case dictation, meeting, calendar, dictionary, appContext
    }
    var source: Source
    var sourceID: String                           // DictationEntry.id / Meeting.id / "user"
    var unix: Double
    var appName: String?
    var snippet: String?                           // ≤140 chars
}

// ContextGraph/ContextGraphSnapshot.swift  (Sendable, immutable; off-main read model)
struct ContextGraphSnapshot: Sendable {
    let entities: [Entity]
    let commitments: [EntityID: CommitmentDetail]
    func lookup(_ q: String, kinds: Set<EntityKind>) -> [Entity]
    func biasPhrases(limit: Int) -> [String]
    func openCommitments(involving: EntityID?, since: Date?) -> [CommitmentDetail]
    func entities(forSource source: Provenance.Source, id: String) -> [Entity]
}

// ContextGraph/ContextGraphStore.swift
@MainActor
final class ContextGraphStore: ObservableObject {
    @Published private(set) var entities: [Entity]            // newest-touched first
    @Published private(set) var commitments: [EntityID: CommitmentDetail]

    func lookup(_ query: String, kinds: Set<EntityKind> = Set(EntityKind.allCases)) -> [Entity]
    func biasPhrases(limit: Int = 180, near app: TargetApp? = nil) -> [String]
    func openCommitments(involving: EntityID? = nil, since: Date? = nil) -> [CommitmentDetail]
    func entities(fromMeeting id: UUID) -> [Entity]
    func entities(fromDictation id: UUID) -> [Entity]
    func snapshot() -> ContextGraphSnapshot

    // mutation surface used by the extractor + dictionary sync (apply merged results atomically)
    func apply(_ result: ExtractionResult)                    // merge + persist + bump watermark
    func syncDictionaryTerms(_ terms: [String])               // pinned .term nodes
    func setCommitmentStatus(_ id: EntityID, _ s: CommitmentStatus)
    func pin(_ id: EntityID, _ pinned: Bool)

    // scheduling
    func enqueueDictation(_ id: UUID)
    func enqueueMeeting(_ id: UUID)
    func enqueueDictionaryChanged()
    func extractBacklog(history: HistoryStore, meetings: MeetingStore) async   // launch pass
}

// ContextGraph/ContextGraphExtractor.swift
actor ContextGraphExtractor {
    struct Input: Sendable { var sourceID: String; var source: Provenance.Source
                             var text: String; var unix: Double; var appName: String?
                             var participants: [String] }
    func extract(_ inputs: [Input], using llm: (any Summarizer)?,
                 known: ContextGraphSnapshot) async -> ExtractionResult
}
struct ExtractionResult: Sendable {
    var upserts: [Entity]
    var commitments: [(EntityID, CommitmentDetail)]
    var watermarks: [Provenance.Source: Double]
}
```

**Changed files:**
- `AppPaths.swift` — add `static func graphDirectory()` →
  `supportDirectory()/graph/` (one helper, mirrors the existing two).
- `AppDelegate.swift` — `let contextGraph = ContextGraphStore()` (`:6-15` block);
  inject everywhere `dictionary`/`history` are injected; replace the bias union
  (`:336-339`) with `contextGraph.biasPhrases(near:)` ∪ live phrases; add
  `contextGraph.enqueueDictation(entry.id)` after the `history.add` (`:~490`); add
  `contextGraph.extractBacklog(...)` in `applicationDidFinishLaunching` (before any
  prune side-effects fire) and **before** the manual Brief path; wire
  `meetingRecorder` stop → `enqueueMeeting`.
- `ContextSummary.swift` — `ContextSummaryStore.refresh(from:)` becomes
  `refresh(graph:)` rendering a graph projection (§4.6); `ContextSummaryEngine`
  keeps its prompt but takes structured digest text. DashboardView call sites
  (`:196,236`) updated to pass `contextGraph`.
- `DictionaryStore.swift` — on mutation, call `contextGraph.enqueueDictionaryChanged()`
  / `syncDictionaryTerms(vocabulary)` so curated terms become pinned `.term` nodes.
- `MeetingRecorder.swift` — after `store.add` in `stop()`, `enqueueMeeting(meeting.id)`.

## 6. Data model & persistence

- **Root:** `~/Library/Application Support/Talkie/graph/` via new
  `AppPaths.graphDirectory()` (next to `supportDirectory()`/`meetingsDirectory()`).
- **Files** (all `.atomic`, failure-tolerant `try?`/`decodeIfPresent`, optional
  fields for back-compat — the house style in `_CURRENT_STATE.md` §3/§7):
  - `entities.json` — `[Entity]` (the node table).
  - `commitments.json` — encoded as `[CommitmentRecord]` where
    `CommitmentRecord = { id: EntityID, detail: CommitmentDetail }` (a JSON object
    can't key on a struct, so persist as an array and rebuild the dictionary on load).
  - `graph_meta.json` — `{ schemaVersion: Int, lastExtractedUnix: Double,
    watermarks: [String: Double] }` keyed by `Provenance.Source.rawValue`, so
    extraction is **incremental** (process only sources newer than each watermark).
- **Why JSON, not SQLite/Core Data:** matches every existing store, keeps the
  "zero external dependencies" invariant true, and stays trivially inspectable — the
  privacy thesis (feature 15) wants the user able to *read their own brain*.
  Re-evaluate only past ~50k nodes; until then JSON + an in-memory `[EntityID: Entity]`
  index is right. (Feature 19's embeddings are the one component that may warrant a
  compact binary sidecar — out of scope here.)
- **Caps & pruning** (gentler than `HistoryStore`, because the graph is the *long*
  memory): `pinned` entities are kept forever; otherwise entities with
  `confidence < 0.5` AND `mentionCount < 2` AND `lastSeenUnix` older than a horizon
  (default 90 days, exposed as a setting) are pruned. `notes` capped at 8/entity,
  `aliases` at 12, total entities soft-capped (~10k) by dropping the lowest-ranked
  unpinned tail. Pruning runs on load + after each extraction.
- **Migration / back-compat:** brand-new files (no migration from any prior shape).
  `schemaVersion = 1`. The **Brief migration** is the only back-compat concern: the
  existing `context_summary.json` payload shape is preserved, so old briefs still
  load. First launch with the graph runs `extractBacklog` over the retained 7-day
  history + all meetings to seed the graph from existing data.

## 7. Unification contract (honoring `_UNIFICATION.md` §6 / 05)

**EXPOSES (the stable query surface every consumer relies on — do not let any
feature fork a second copy):**
- `ContextGraphStore` (`@MainActor`, UI consumers) + `ContextGraphSnapshot`
  (`Sendable`, off-main consumers: MCP 06, search 19, the extractor itself).
- `lookup(_:kinds:)` → recall ("who is X / what is Y"), used by 06/09/19.
- `biasPhrases(limit:near:)` → **replaces** the ad-hoc union in
  `AppDelegate.beginDictation` (`:336-339`); used by 01 (both backends'
  `setContextualStrings`), 04 (attendee names), 13 (per-app filtered bias).
- `openCommitments(involving:since:)` → powers the Brief, cross-surface 09, MCP 06's
  `list_commitments`.
- `entities(fromMeeting:)`/`entities(fromDictation:)` → "jump to source", meeting↔graph
  linking, and `NoteDestination.links` (10) for `[[wikilinks]]`.
- The **redefined Brief** as a graph projection (replaces the raw-history summarizer).

**CONSUMES:**
- `HistoryStore` (`HistoryStore.swift`) — dictation feed (+ its `appName` →
  `Provenance.appName`).
- `MeetingStore`/`Meeting` (+ **[branch]** `participants`) — meeting feed; participants
  → Person entities.
- `DictionaryStore` (`DictionaryStore.swift`) — curated terms → pinned `.term` nodes;
  the dictionary becomes "the user-curated slice of the Term store" (§1.1).
- `AppContext.PhraseMiner` (`AppContext.swift:99-151`) — reused verbatim for Stage-1
  heuristic extraction (no fork).
- Calendar (feature 04, when built) — attendee names via `MeetingContextProvider`,
  `Provenance(.calendar)`.
- **`Summarizer` protocol** (the LLM seam, `_UNIFICATION.md` §2.2) — the extractor's
  Stage 2 calls `summarizer.generate(instructions:input:)`, NOT `CleanupEngine`
  directly. If the `Summarizer` protocol refactor lands alongside 05 (recommended,
  Tier-0), the extractor takes `any Summarizer`; if not, it temporarily wraps
  `CleanupEngine`-style `LanguageModelSession` directly and is swapped later. Either
  way it never forks a new prompt-generation path.

**The contract's non-negotiables, restated:** every entity has ≥1 provenance;
extraction is incremental + off-main + never during a live session; heuristic-only
path when Foundation Models is unavailable; `biasPhrases(near:)` replaces the ad-hoc
union. All four are designed in above (§4.2–4.5).

## 8. UI / UX

05 is mostly an invisible spine, but it needs three on-brand surfaces. Reuse existing
patterns rather than inventing UI (`_UNIFICATION.md` §4.3).

1. **The Brief becomes truthful (no new view).** `DashboardView`'s existing
   `BriefBanner` (`:109-175`) → `BriefDetailView` (`:178-237`) keep their exact shape;
   only the *content source* changes (graph projection). Honest second-person copy is
   preserved ("3 open commitments, 2 due this week. You talked about Coralate (8×)…").
   This alone is the headline UX win and costs no new view.
2. **A "Memory" / recall tab (M, the full feature).** A new `SettingsTab` entry
   between `meetings` and `dictionary` with its own feather tint (the per-item
   `.listItemTint` pattern, `SettingsView.swift:4-46`). Layout: a `FlowLayout`
   (`DesignSystem.swift`) of entity chips grouped by kind (People / Projects / Terms /
   Commitments), a search field driving `lookup`, and a tapped-entity detail showing
   `notes` + a provenance list ("seen in Slack on Tue · last call · 8 mentions") with
   jump-to-source. Open commitments get a checkbox to mark done (`setCommitmentStatus`).
   On-brand: `.talkieCard()` surfaces, squircle `Radius.chip` chips, one accent
   (`Theme.coral`, now blue) per view, Young Serif for the entity name header,
   feather palette **for the kind dots only** (data, per BRAND.md §3.4), whisper
   shadow, no outline.
3. **Provenance is the trust UI (feature 15 leans on this).** Every fact in recall
   and the Brief shows *why* ("because you said it to Slack on Tuesday") — never an
   asserted fact the graph can't back. This is the honest-copy invariant (BRAND.md
   "never invent metrics"; `_UNIFICATION.md` §4.3) made concrete.

The Memory tab is the *full* feature; the truthful Brief is the MVP surface (§14).

## 9. Permissions / entitlements / Info.plist

**None.** 05 reads data Talkie already has (history, meetings, dictionary, mined
phrases) and writes JSON under the existing Application Support root. No new TCC
prompt, no new entitlement, no Info.plist key, no sandbox change. It runs entirely
inside the current `com.apple.security.device.audio-input`-only profile. (Calendar
attendee names arrive *through* feature 04's EventKit permission — not 05's.)

## 10. Privacy posture

**Zero-network preserved — and 05 is the data behind the privacy *proof*.** The
graph is built only from on-device Foundation Models + pure-Swift heuristics, stored
as local JSON, and never transmitted. No `URLSession`, no new entitlement (§9). The
graph is exactly what feature 15's "here's what's on your Mac" proof panel reads, and
**provenance (§1.3) exists partly so a skeptic can audit every fact and see precisely
what any *future* opt-in networked feature (18 Claude bridge / 07b connector) would
expose** — per `_UNIFICATION.md` §4.1, the graph leaves the machine only through an
explicit user action with per-call consent, never by default. 05 itself adds no
network surface; it makes the existing zero-network story *legible*.

## 11. Open-source genericity

- **No hardcoded personal stack.** Entity extraction is generic NLP (proper nouns,
  identifiers, commitment cues) — no Obsidian, no specific vault, no editor, no
  Claude Code assumption. The graph's `links` output (entity displayNames) is handed
  to whatever `NoteDestination` the user picked (feature 10); the default
  `TalkieFolderDestination` (plain `~/Talkie Meetings/`) needs no third-party app.
- **Zero-config default:** the graph builds automatically from dictation + meetings
  with no setup; the Memory tab works out of the box. Pinning/commitment-status are
  optional curation, not required.
- **Widened-hardware path:** the Stage-1 heuristic-only extraction (§4.3) keeps the
  graph alive when Foundation Models is unavailable — the designated widening lever
  alongside feature 20's `TranscriptionBackend`. Community can extend extraction by
  adding heuristic rules or (later) a different `Summarizer` impl without touching the
  store/snapshot API.

## 12. Risks, edge cases, failure modes

- **Entity over-merge / under-merge.** "Mike" the person vs. "mic" the term collide
  on normalization across kinds? No — `EntityID` includes `kind`, so cross-kind
  collisions can't happen; *within* a kind, aggressive normalization can wrongly merge
  two different Sarahs. Mitigation: keep distinct surface forms as `aliases`, gate
  surfacing on `confidence`, and let the user split/pin in the Memory tab. **Degrade:
  a wrong merge is annoying, never destructive** (provenance preserves both sources).
- **LLM hallucination.** The hard "do not invent" guardrail (mirrors
  `ContextSummary.swift:14-18` and `Meeting.swift` summarizer) + line-grammar parsing
  + dropping unparseable lines bounds this. Commitments never get fabricated dates
  (`dueHint` is a verbatim phrase or nil).
- **History pruned before extraction (data loss).** `HistoryStore` prunes at 7 days
  (`HistoryStore.swift:82-85`) on load. If the app is closed >7 days, entries vanish
  before the graph sees them. Mitigation: `extractBacklog` runs on launch *and* the
  launch sequence extracts before prune side-effects (§4.4). Residual risk: a >7-day
  closure still loses the un-extracted tail — acceptable (the graph captures the
  durable summary going forward; meetings, the richer feed, are never pruned).
- **Model contention.** Extraction must never steal the model mid-dictation. The
  `isDictating`/`isRecording` probe + 45s debounce + reschedule (§4.4) enforces this;
  worst case extraction is merely *delayed*, never concurrent.
- **Large-corpus latency.** A first-run `extractBacklog` over hundreds of history
  entries + many meetings could be a long LLM batch. Mitigation: chunk + run at
  `.utility`, cap the first pass (e.g. most-recent 200 entries), and let subsequent
  incremental runs catch the rest. Heuristic Stage 1 is instant regardless.
- **JSON growth.** Soft caps + pruning (§6) bound file size; the `[EntityID: Entity]`
  in-memory index keeps `lookup`/`biasPhrases` O(n) over a bounded n.
- **Concurrency.** Store is `@MainActor`; extractor is an `actor`; snapshot is an
  immutable `Sendable` value (mirrors `ProjectIndexSnapshot`). `apply(_:)` merges on
  the main actor so `@Published` stays consistent. No new lock primitive needed.

## 13. Testing & verification

- **Unit (pure, no model):** add the first test target to the repo
  (`Package.swift` currently has none — `_CURRENT_STATE.md` §8). Cover:
  `EntityID.make` normalization (diacritics, case, punctuation); `Entity.merge`
  (display-name selection, provenance dedup, mention/recency bumps); the commitment
  cue regex (positive + negative cases); `biasPhrases` ranking order; the LLM
  line-grammar parser (well-formed, malformed-dropped, injection-resistant).
  `ContextGraphExtractor.extract` with a **stub `Summarizer`** (deterministic
  fixture output) → asserts the right `ExtractionResult`, proving the on-device path
  without invoking Foundation Models.
- **Manual / `/run`:** dictate three lines naming a person + a project + a commitment
  ("I'll send Sarah the Coralate deck Friday") into a couple of apps; confirm after
  the debounce that `entities.json`/`commitments.json` contain a Person (Sarah),
  Project (Coralate), and an open Commitment with `dueHint: "Friday"`, each with
  `Provenance(.dictation)` + the app name. Record a short meeting **[branch]** and
  confirm participants become Person nodes and the meeting text adds provenance.
  Open the Memory tab → search "Sarah" → see the note + provenance. Open the Brief →
  confirm it now reflects the commitment count, not a free LLM render.
- **Degradation check:** toggle Apple Intelligence off → re-run; confirm the graph
  still builds nodes (heuristic-only) and the Brief renders the templated version.
- **`/verify`:** assert `grep -rniE "URLSession|http"` over `Sources/` still returns
  nothing (privacy invariant intact) and the entitlements file is unchanged.

## 14. Effort & phasing

| Sub-step | Size | What |
|---|---|---|
| **MVP slice** | | **Heuristic graph + truthful Brief, no new tab** |
| Data model (`Entity`/`Provenance`/`EntityID`/snapshot) + JSON persistence | **M** | The node table, merge, `graphDirectory()`, atomic save/load. |
| `ContextGraphExtractor` Stage 1 (heuristics only) + scheduling/debounce/exclusivity | **M** | Reuse `PhraseMiner`; commitment regex; watermarks; `extractBacklog`. |
| `biasPhrases` + rewire `AppDelegate` bias union | **S** | Drop-in replacement at `:336-339`, keep live phrases. |
| Rewrite Brief as graph projection | **S** | `ContextSummaryStore.refresh(graph:)`; preserve persisted shape. |
| → *MVP shippable here.* | | Graph exists, biases recognition, powers a truthful Brief; all on-device, no model required. |
| **Full feature** | | |
| Extractor Stage 2 (LLM via `Summarizer`) + line-grammar parser | **M** | Alias merge, structured commitments, entity notes; the "do-not-invent" prompt. |
| Memory / recall tab (chips, search, detail, provenance, commitment status) | **M/L** | New `SettingsTab`, reuses `FlowLayout`/`.talkieCard()`/feather tints. |
| `DictionaryStore` ↔ Term-store sync (pinned terms) | **S** | Curated vocab becomes pinned `.term` nodes. |
| Pruning/caps + first-run backlog tuning + tests | **M** | Horizon setting, soft caps, the new test target. |

Recommended order: data model → Stage 1 + scheduling → bias rewire → Brief rewrite
(**MVP**) → Stage 2 → Memory tab → dictionary sync → pruning/tests.

## 15. Dependencies & interactions

- **Needs (soft):** the **`Summarizer` protocol** (`_UNIFICATION.md` §2.2) for a
  clean Stage-2 LLM seam — recommended to land *alongside* 05 (Tier 0); 05 works
  without it (wrapping `CleanupEngine`-style generation directly) but should adopt it
  to avoid a later untangle. Far-end meetings **[branch]** (feature 01) give the graph
  its richest feed (Me/Them transcripts + participants) — 05 works on `main`'s mic-only
  meetings too, just with fewer Person nodes.
- **Enables (the whole capstone tier — 05 is the gate, `_UNIFICATION.md` §5):**
  - **04 calendar** — writes Person entities (`Provenance(.calendar)`) + feeds bias.
  - **06 MCP** — `lookup_entity`/`list_commitments`/`get_brief`/`search` all read the
    graph (snapshot replicated against on-disk JSON, read-mostly).
  - **07 connector** — exposes the graph via the 06 server.
  - **09 cross-surface** — "email Sarah the action items from my last meeting" reads
    recent meetings + entities + open commitments + provenance. THE demo.
  - **19 search** — entities are first-class hits with provenance for jump-to-source.
  - **08/12 commands** — `CommandContext.graph` is this snapshot (people/commitments
    as command context).
  - **13 per-app profiles** — filter `biasPhrases` per bundle id.
  - **15 privacy proof** — the graph + provenance is the "what's on your Mac" data.
- **Overlaps / supersedes:** `ContextSummary` (Brief → projection), `DictionaryStore`
  vocab (→ pinned Term slice), `PhraseMiner` (ephemeral → persisted candidates),
  `AppDelegate`'s bias union (→ `biasPhrases`). None are deleted; they are re-rooted.
