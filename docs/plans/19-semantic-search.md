# 19 — Local semantic + keyword search (second-brain recall)

> Feature contract source: `docs/plans/_UNIFICATION.md` §6 / **19**, §1 (the graph),
> §2.2 (`Summarizer`), §3 (`Search/` folder), §4 (cross-cutting invariants).
> Ground-truth map: `docs/plans/_CURRENT_STATE.md`.
> Floor: macOS 26.0, Apple Silicon, Swift 6 strict concurrency (`.v6`), zero deps.

## 1. Summary

A fully on-device search engine that lets you recall anything you've ever said —
across every dictation, every meeting transcript, and every entity in the personal
context graph — by **meaning** (semantic embeddings) **and** by **word** (keyword
index), blended into one ranked result list with snippets and one-click jump-to-source.
It ships as a new **Search** tab + a global command-palette and is re-exposed
verbatim through the MCP `search` tool (feature 06).

## 2. Why it matters

This is the payoff of the whole strategic thesis. Wispr Flow throws your dictations
away; Granola search is cloud-side and meetings-only; neither can search *across both
surfaces* because they are separate companies. Talkie already funnels both voice
surfaces into one local corpus — search is the surface that makes that corpus feel
like a **second brain you can ask**: "what did I decide about the Q3 launch", "who is
Sarah", "that thing I dictated into Slack last Tuesday." It is the recall half of the
moat (the graph is the memory; search is the way in), it stays 100% on-device so the
privacy line holds, and it is the engine behind the headline cross-surface demo
(feature 09) and the MCP/connector story (06/07). It is also the feature a skeptic
can verify is private: every hit cites its provenance ("because you said it to Slack
on Tuesday"), so nothing is asserted that the corpus can't back.

## 3. Current state in the code

**Nothing search-specific exists yet.** There is no index, no embeddings, no search
UI, and the `Search/` folder from `_UNIFICATION.md` §3 is not created. What exists is
the *corpus* and the read APIs search will sit on top of:

- **Dictations** — `HistoryStore` (`HistoryStore.swift:24`) holds
  `@Published private(set) var entries: [DictationEntry]` (`:26`), newest-first,
  **7-day retention, cap 2000** (`:29-30`, pruned on load+add `:56,82-85`). Each
  `DictationEntry` (`:4-21`) has `id: UUID`, `timestampUnix`, `text`, `wordCount`,
  `durationSec`, optional `appName`/`appCategory`. **Critical constraint: history is
  pruned to 7 days** — so a semantic index built only over `HistoryStore` would
  silently forget everything older. (See §6 / §12 — search must read the durable
  corpora, and the context graph (§7) is the long memory.)
- **Meetings** — `Meeting` (`Meeting.swift:5-16`, branch adds `participants`/`source`,
  `:7-20`) with `id`, `title`, `transcript`, `summary`, `fileName`. `MeetingStore`
  (`:53`) keeps `@Published private(set) var meetings: [Meeting]` and writes the
  durable `.md` files to `~/Talkie Meetings/` (`writeMarkdown`, `:88-109`). Meetings
  are **kept indefinitely** (no pruning) — the durable long corpus.
- **The Brief** — `ContextSummaryStore` (`ContextSummary.swift:59`) is a throwaway
  LLM render over 7 days of history; per `_UNIFICATION.md` §1.7 it is being rewritten
  as a projection of the graph. Search does **not** index the Brief text; it indexes
  the graph entities the Brief is built from.
- **Context graph (feature 05)** — **not built yet.** `_UNIFICATION.md` §1 specifies
  `ContextGraphStore` + `ContextGraphSnapshot` (`lookup`, `biasPhrases`,
  `openCommitments`, `entities(fromMeeting:)`, `snapshot()`), `Entity`,
  `Provenance`. Search **depends on 05** for entity hits and for the canonical
  `Provenance` jump-to-source type. (See §15 — search degrades to history+meetings
  if 05 isn't landed yet.)
- **On-device NLP already in the tree** — `LanguageDetector.swift:2` imports
  `NaturalLanguage` (`NLLanguageRecognizer`). No embedding API is used anywhere
  (`grep` for `NLEmbedding`/`NLContextualEmbedding` → none). NaturalLanguage is the
  zero-dependency lever for both the embeddings and the keyword tokenizer.
- **Persistence convention** — `AppPaths.supportDirectory()` (`AppPaths.swift:7`),
  `.atomic` writes, failure-tolerant decode, `@MainActor … ObservableObject` stores
  with `actor` workers and `Sendable` snapshots. There is **no test target**
  (`_CURRENT_STATE.md` §8).

Honest status: **the corpus and its read APIs are ready; 100% of the search feature
is to be built.** It is blocked on feature 05 for entity hits but can ship a
history+meetings MVP without it.

## 4. Design & approach

### 4.1 Three building blocks

1. **Embedding provider (semantic).** On-device, zero-network, zero new SwiftPM deps
   by default. macOS 26 gives two choices in the `NaturalLanguage` framework; we use
   the better one and keep a protocol seam for the rest:

   | Option | API | Dim | Network | New dep | Verdict |
   |---|---|---|---|---|---|
   | **A — Contextual (default)** | `NLContextualEmbedding` (transformer; Latin/Cyrillic/CJK script models, 512-dim, ≤256 tok/req) | 512 | none at inference; **per-script model assets are downloaded on demand** via `requestEmbeddingAssets` / gated by `hasAvailableAssets` | none | **Chosen default.** Real transformer quality, on-device, no SwiftPM dep. |
   | **B — Static (fallback)** | `NLEmbedding.sentenceEmbedding(for:)` (word-vector averaged) | 512 | none, no download | none | Shallower (no real sentence context), narrower language list (no Russian/Kazakh). Used only when contextual assets are unavailable. |
   | **C — MLX / model2vec (opt-in)** | `MLXEmbedders` (BGE) or `model2vec.swift` (Apache-2.0, bundled `safetensors`) | 256–1024 | none at inference | **yes — SwiftPM dep + bundled model (binary size)** | Documented optional backend behind the protocol for users who want stronger multilingual recall. Breaks the "zero deps" default → **off by default, never in the core build.** |

   The **asset-download caveat is load-bearing for the privacy thesis**:
   `NLContextualEmbedding` model assets are fetched by the OS the first time a script
   model is needed. This is an Apple-system asset fetch (like the SpeechAnalyzer
   per-locale model download the app already triggers via `AssetInventory`,
   `_CURRENT_STATE.md` §1.4) — **not Talkie network code**, no `URLSession`, the
   entitlement set is unchanged. We treat it exactly like the existing speech-model
   warm-up: kick `requestEmbeddingAssets` in the background at idle, gate on
   `hasAvailableAssets`, and fall back to option B (or pure keyword) until ready.
   This must be disclosed in copy (§10) so it isn't mistaken for app telemetry.

2. **Keyword index (lexical).** A small inverted index built with
   `NLTokenizer(unit: .word)` (NaturalLanguage, zero-dep): `term → [chunkID]`, plus a
   per-term document frequency for **BM25** scoring. Catches exact names, code tokens,
   numbers, and rare jargon that embeddings smear — and is the **only** path that
   works when embedding assets aren't ready or the language is unsupported.

3. **Blended ranker.** For a query, run both: cosine similarity over embeddings
   (semantic) and BM25 over the keyword index (lexical), normalize each to 0…1, and
   combine with **Reciprocal Rank Fusion** (RRF, `score = Σ 1/(k + rank_i)`, k≈60) —
   robust to the two scores living on different scales, no hand-tuned weights, and a
   well-understood default. A small recency prior and a graph-confidence/pin boost
   are added (see §4.4). Results never claim an invented "relevance %" — they show the
   snippet + provenance and let the match speak (BRAND §9, honest copy).

### 4.2 The indexable unit — `SearchChunk`

Everything searchable is normalized into one `SearchChunk` value (a *projection*, not
a copy of truth — the source stores remain authoritative):

- A **dictation** → one chunk (its `text`; short, already one utterance).
- A **meeting** → chunked: the `summary` is one chunk; the `transcript` is split into
  ~600–900-char windows on turn/sentence boundaries (so a hit lands on a passage, not
  a 1-hour wall of text), each carrying its `[mm:ss]` offset for jump-to-source.
- A **graph entity** (feature 05) → one chunk per entity (`displayName` + `aliases` +
  joined `notes`), so "who is Sarah" surfaces the Person node directly, with the
  entity's own `Provenance` chain for jump-to-source.

Each chunk stores its source `Provenance` so a hit can deep-link back (§4.5).

### 4.3 The index pipeline (incremental, off-main, idle)

Mirrors `ContextGraphExtractor` (`_UNIFICATION.md` §1.5) and the
`ProjectScanner`/`ContextSummaryEngine` patterns:

```
new/changed dictations, meetings, entities
        │  (watermark per source — only re-embed what changed)
        ▼
 SearchIndexer (actor, .utility)
   1. build SearchChunks for the new items
   2. keyword: tokenize → update inverted index + doc-freqs
   3. semantic: NLContextualEmbedding.embeddingResult(for:language:)
        → mean-pool token vectors → L2-normalize → 512-d Float vector
        (gate on hasAvailableAssets; else mark chunk "lexical-only")
   4. append vectors to the on-disk vector store; persist index meta
        │
        ▼
 SearchEngine (actor) answers queries from the in-memory index
```

- **Triggers:** after `endDictation()` logs a `HistoryStore` entry; after
  `MeetingRecorder.stop()` adds a `Meeting`; after the graph extractor updates
  entities. **Debounced** (coalesce ~30–60s) and **never while a dictation/recording
  is live** — reuse the existing `isDictating`/`isRecording` probes (model/CPU
  exclusivity, `_UNIFICATION.md` §4.4). Embedding is cheap vs. transcription but we
  still yield to live sessions.
- **Brute-force cosine is correct here.** Corpus is small (history ≤2000 entries over
  7 days; meetings chunked; entities in the low thousands) → low tens of thousands of
  512-d vectors at most. A linear scan of N×512 floats is sub-millisecond-to-low-ms on
  Apple Silicon (vectorize with `vDSP`/Accelerate). **No ANN library, no new
  dependency.** Re-evaluate (HNSW/compact ANN) only past ~100k vectors — the same
  threshold `_UNIFICATION.md` §1.4 sets for the graph.

### 4.4 Ranking detail

`finalScore(chunk) = RRF(semanticRank, keywordRank)`
`              + recencyBoost(chunk.unix)      // gentle log-decay; recent slightly favored`
`              + sourceBoost(chunk.kind)        // entity hits and pinned/curated terms nudged up`

Filters (chips in the UI): source kind (dictation / meeting / person / project / term
/ commitment), date range, app. A pure-keyword fallback mode kicks in automatically
when no embeddings are available (assets not ready, or an unsupported language).

### 4.5 Jump-to-source

Every result carries a `Provenance` (the canonical type from feature 05,
`_UNIFICATION.md` §1.3). The `SearchResultAction` resolver maps it:

- `.dictation` → select that row in the History tab (and copy text).
- `.meeting` → open the meeting in the Meetings tab, scroll the transcript to the
  chunk's `[mm:ss]` offset; "Reveal in Finder" opens the `.md` in `~/Talkie Meetings/`.
- entity → open the entity in the graph/recall surface (feature 05's UI) or, if that's
  not built, jump to the entity's first provenance.

## 5. New & changed files/types

All new files live in **`Sources/Talkie/Search/`** (the folder named in
`_UNIFICATION.md` §3). No change to `Package.swift` for the default build (zero new
deps; `NaturalLanguage` + `Accelerate` are system frameworks).

### 5.1 New

```swift
// Search/SearchChunk.swift
struct SearchChunk: Codable, Sendable, Identifiable {
    let id: String                 // stable: "\(kind):\(sourceID):\(ordinal)"
    let kind: SearchSourceKind     // .dictation | .meetingSummary | .meetingTranscript | .entity
    let title: String              // app name / meeting title / entity displayName
    let text: String               // the chunk body (what gets embedded + tokenized)
    let unix: Double               // for recency + date filtering
    let provenance: Provenance     // feature-05 canonical type → jump-to-source
    let offsetLabel: String?       // "[12:34]" for transcript chunks
}

enum SearchSourceKind: String, Codable, Sendable, CaseIterable {
    case dictation, meetingSummary, meetingTranscript, entity
}

// Search/EmbeddingProvider.swift  — the protocol seam (lets MLX/option-C drop in)
protocol EmbeddingProvider: Sendable {
    var dimension: Int { get }
    var isReady: Bool { get }                 // assets present & model loadable
    func prepare() async                      // request/await assets in background
    func embed(_ text: String, language: NLLanguage?) async -> [Float]?  // L2-normalized, nil if unavailable
}

// Search/AppleContextualEmbedder.swift  — DEFAULT impl
//   wraps NLContextualEmbedding; picks the script model by detected language;
//   hasAvailableAssets gate; requestEmbeddingAssets in prepare(); mean-pool + vDSP L2-normalize.
final class AppleContextualEmbedder: EmbeddingProvider { … }
// Search/AppleStaticEmbedder.swift   — FALLBACK impl (NLEmbedding.sentenceEmbedding)

// Search/KeywordIndex.swift  — inverted index + BM25 (NLTokenizer), Codable
struct KeywordIndex: Codable, Sendable {
    func search(_ query: String, limit: Int) -> [(chunkID: String, score: Double)]
    mutating func add(_ chunk: SearchChunk)
    mutating func remove(chunkID: String)
}

// Search/VectorStore.swift  — id→Float[dim], brute-force cosine via Accelerate
struct VectorStore: Sendable {
    func topK(_ query: [Float], k: Int) -> [(chunkID: String, score: Float)]
}

// Search/SearchIndexer.swift  (actor) — incremental build, watermarks, debounce, off-main
actor SearchIndexer {
    func reindex(history: [DictationEntry],
                 meetings: [Meeting],
                 graph: ContextGraphSnapshot?) async      // honors per-source watermarks
}

// Search/SearchEngine.swift  (actor) — query → blended, ranked results
struct SearchResult: Sendable, Identifiable {
    let id: String
    let chunk: SearchChunk
    let snippet: AttributedString    // query terms highlighted; ≤2 lines
    let score: Double
}
actor SearchEngine {
    func query(_ q: String, filters: SearchFilters, limit: Int) async -> [SearchResult]
}

// Search/SearchStore.swift  (@MainActor ObservableObject) — the DI/UI front door
@MainActor final class SearchStore: ObservableObject {
    @Published private(set) var indexState: IndexState   // .empty/.building(p)/.ready/.lexicalOnly
    func search(_ q: String, filters: SearchFilters) async -> [SearchResult]
    func reindexIfNeeded() async
    func snapshotForMCP() -> SearchSnapshot              // off-main read model for feature 06
}

// Search/SearchView.swift + Search/CommandPaletteView.swift  — UI (§8)
```

### 5.2 Changed

- **`AppPaths.swift`** — add `static func searchDirectory() -> URL` →
  `supportDirectory()/search/` (next to the graph's `graphDirectory()`).
- **`SettingsView.swift`** — add `case search` to `SettingsTab` (`:4-46`) with title
  "Search", icon `magnifyingglass`, a feather tint (e.g. `featherBlue`/`featherGold` —
  pick one not already taken; meetings=plum, vibe=blue, so **gold** is free if history
  moves, else reuse a feather honestly), and a `content` switch arm.
- **`AppDelegate.swift`** — create `let search = SearchStore(...)` alongside the other
  stores; inject it; call `search.reindexIfNeeded()` from the same idle/debounce point
  the graph extractor uses; trigger an incremental index after `endDictation()` logs an
  entry and after `MeetingRecorder.stop()`.
- **`main.swift` / menu** — register a global "Search" command (⌘⇧F or ⌘K) that raises
  the command palette (the palette is in-app, not a global hotkey that needs Input
  Monitoring — see §9).
- **`TalkieMCP`** (feature 06, separate target) — its `search` tool calls a file-backed
  replica of `SearchEngine.query` over `SearchSnapshot` (read-only, no locks the app
  holds), per `_UNIFICATION.md` §3.

## 6. Data model & persistence

Root: **`~/Library/Application Support/Talkie/search/`** (new subfolder; sibling of
`graph/`). House style: `.atomic`, failure-tolerant decode, optional fields for
back-compat (`_CURRENT_STATE.md` §3, §7).

| File | Format | Contents |
|---|---|---|
| `chunks.json` | `[SearchChunk]` | the projected indexable units (text + provenance + offsets) |
| `keyword.json` | `KeywordIndex` (Codable) | inverted index + per-term doc-freqs for BM25 |
| `vectors.bin` | **compact binary sidecar** | `count × dimension` little-endian `Float32` rows, ordered to match a parallel `vectorIDs.json` |
| `index_meta.json` | `{ schemaVersion, dimension, embedderID, perSourceWatermarks, builtUnix }` | makes indexing incremental + detects model/dim changes |

- **Why a binary sidecar for vectors (not JSON):** this is the one place
  `_UNIFICATION.md` §1.4 / §6-19 explicitly anticipates a "compact binary sidecar."
  512 floats per chunk as JSON is ~6× the bytes and slow to parse; a flat `Float32`
  blob memory-maps and feeds `vDSP` directly. It is still trivially inspectable
  (documented layout) so the privacy/auditability thesis holds.
- **The index is a derived cache, not a source of truth** — it can always be rebuilt
  from `HistoryStore` + `~/Talkie Meetings/` + the graph. So:
  - **Migration / back-compat:** if `index_meta.schemaVersion` or `dimension` or
    `embedderID` changed (e.g. user switched to the MLX backend, or Apple bumped a
    model), **discard `vectors.bin` and rebuild** — never try to migrate float vectors
    across models. The keyword index and chunks survive a dimension change.
  - **Retention coupling:** because `HistoryStore` prunes at 7 days, dictation chunks
    older than the window will lose their source row. The index keeps the chunk (its
    text + provenance snippet are self-contained), but jump-to-source for a pruned
    dictation degrades to "show the snippet" instead of selecting a live row. The
    **graph** (§7) is the durable home for older facts; meetings never prune.
- **Caps & pruning:** mirror the graph — prune index chunks whose source no longer
  exists *and* that aren't backed by a pinned/curated entity. Cap total vectors;
  rebuild from scratch is cheap at this scale.

## 7. Unification contract

Per `docs/plans/_UNIFICATION.md` §6 / **19** and §1.6:

**EXPOSES (what other features consume):**
- A stable **search API** — `SearchStore.search(_:filters:)` (UI) and a `SearchEngine`
  / `SearchSnapshot` off-main read model — returning blended-ranked `SearchResult`s
  with **snippets + `Provenance` for jump-to-source**, over dictations + meetings +
  graph entities.
- The engine behind **feature 06's MCP `search` tool** (`_UNIFICATION.md` §6-06):
  `TalkieMCP` runs a file-backed replica of `SearchEngine.query` against
  `SearchSnapshot` (read-mostly, no app-held locks), so an external agent searches the
  same brain.
- A reusable **`EmbeddingProvider`** seam — the same on-device embedder can later power
  graph alias-clustering or semantic dedupe if 05 wants it.

**CONSUMES:**
- **The context graph (feature 05) — primary dependency.** Entities are first-class
  search hits; the canonical **`Provenance`** type (§1.3) is reused verbatim for
  jump-to-source (search does **not** define its own); `ContextGraphSnapshot` is read
  off-main for the entity chunks. Search must **not** read graph JSON directly — it
  goes through `ContextGraphStore.snapshot()` (§1.6 rule).
- **`HistoryStore`** (dictations) and **`MeetingStore`** / `~/Talkie Meetings/`
  (meeting summaries + transcripts) — the two corpora.
- On-device embeddings via `NaturalLanguage` (no Summarizer/LLM needed for indexing;
  search is retrieval, not generation). Optional: a future "ask my brain" answer mode
  would call the `Summarizer` protocol (§2.2) over the top-k results — explicitly out
  of scope for this feature, noted for 09.

**Contract honored:** stays on-device; embeddings index is the sanctioned binary
sidecar (§1.4); ranking blends semantic + keyword; **results cite provenance, never
invented relevance** (§6-19, BRAND §9). Search is a *consumer* of the brain, never a
second copy of it — chunks are projections; the graph/history/meetings remain truth.

## 8. UI / UX

Two surfaces, both reusing existing components (no invented UI — `_UNIFICATION.md` §4.3):

1. **Search tab** (new `SettingsTab.search`, sidebar icon `magnifyingglass`, a feather
   nav tint). Native `NavigationSplitView` content like every other tab. Top: a single
   search field (serif placeholder is wrong — field is functional SF Pro; the **page
   title** is Young Serif per BRAND §4). Below: filter **chips** in a `FlowLayout`
   (the existing chip component, `DesignSystem.swift`) for source kind / date / app.
   Results are `.talkieCard()` rows: an SF Symbol per kind in `inkTertiary`/feather
   tint, the title, a 2-line snippet with **query terms highlighted in `Theme.coral`
   (blue)**, and a provenance line in `inkSecondary` ("Slack · Tue 2:14pm" /
   "Standup · 12:34"). Click → jump-to-source (§4.5).
2. **Command palette** (⌘K / ⌘⇧F) — a floating panel for "search from anywhere in the
   app." Reuse the **`glassEffect` / NSPanel** pattern from `HUD.swift` (real macOS 26
   glass, `:152`) rather than a new chrome. Type → live results → ↩ jumps to source.
   (Phase 2 can promote this to a global hotkey; MVP keeps it in-app, §9.)

**On-brand specifics:** one accent (blue `Theme.coral`) for the active field + selected
result; feather palette only on the per-kind icons (data, not chrome); Young Serif for
the tab title and any hero count ("1,204 things you've said"); squircle cards +
hairline + whisper shadow; calm spring on result insert (`response 0.28, damping 0.8`).
**Honest copy:** empty state "Nothing indexed yet — talk a little and it'll show up
here"; building state shows real progress, not a fake spinner; **never** a "98% match"
badge. Index-building and the one-time embedding-model download are surfaced as calm
status, not hidden (§10).

## 9. Permissions / entitlements / Info.plist

**No new entitlements, no new TCC prompts, no Info.plist usage strings.** Search reads
data the app already owns (its own Application Support files + `~/Talkie Meetings/`,
already accessible). It posts no events, captures no audio, reads no other app's AX —
so it needs **none** of Accessibility / Input Monitoring / Microphone / AudioCapture.
The entitlement set stays exactly `com.apple.security.device.audio-input`
(`_CURRENT_STATE.md` §6) — search does not widen the attack surface at all.

- The command palette uses an **in-app** menu command + first-responder key handling
  (⌘K), **not** a global `CGEventTap` — so it does **not** require Input Monitoring.
  (A future *global* "search from anywhere" hotkey would reuse `HotKeyMonitor` and its
  existing Input-Monitoring grant; out of scope for MVP.)
- `NLContextualEmbedding` asset download is an **OS-managed** fetch (like the existing
  SpeechAnalyzer model download) — it needs no entitlement and adds no Talkie network
  code (§10).
- **Sandbox note for feature 15:** when the app is later sandboxed, confirm
  `NLContextualEmbedding` asset download + load works under the App Sandbox **without**
  a network-client entitlement (the OS daemon does the fetch). This is on 15's
  validation list (`_UNIFICATION.md` §6-15); flag it there.

## 10. Privacy posture

**Zero-network is preserved.** Search adds **no `URLSession`, no network code**. All
indexing and querying is local: `NaturalLanguage` embeddings + an in-process inverted
index + brute-force cosine via `Accelerate`. The default build's "provably zero
connections" claim (feature 15) is untouched.

- **The one nuance to disclose honestly (BRAND §9, "privacy stated not sold"):** the
  first time a script's `NLContextualEmbedding` model is needed, **macOS downloads that
  model asset** (Apple's own on-device model files, same mechanism as the speech models
  the app already pulls). This is **not Talkie sending your data anywhere** — *no text,
  no embeddings, nothing about you* leaves the device; only Apple's generic model
  weights come *down*. We say exactly that in the Search settings/empty state:
  *"The first time, macOS downloads Apple's on-device language model (a one-time system
  download). Nothing you've said is ever uploaded — search runs entirely on your Mac."*
  Until the asset is present, search runs **keyword-only** so it works offline-first.
- **Graceful opt-out:** the static embedder (option B) needs no download at all; a
  "keyword-only / no model download" toggle is available for users who want zero OS
  fetches.
- The MCP `search` exposure (06) is a **local stdio** read of the same on-disk index —
  still no network (`_UNIFICATION.md` §3). Any *networked* "ask my brain" answer mode
  would be the `Summarizer`/`ClaudeBridge` path (18), off by default, behind 15's wall
  — **not part of this feature.**

## 11. Open-source genericity

- **Zero-config default that needs no third-party app or account:** the moment you
  dictate or record, the index builds itself; the Search tab works with nothing to set
  up. No vault, no editor, no cloud key, no API.
- **No hardcoded personal stack.** Search indexes Talkie's own corpora and the generic
  graph — not Obsidian, not a specific folder, not Claude Code. Jump-to-source targets
  Talkie's own tabs and the plain `~/Talkie Meetings/` folder (revealable in Finder for
  any editor).
- **Pluggable embeddings via `EmbeddingProvider`:** the community can drop in
  `MLXEmbedders` (BGE) or `model2vec.swift` (Apache-2.0) for stronger/multilingual
  recall **without touching core** — it's a protocol conformance + an optional SwiftPM
  dep they opt into, exactly the genericity rule (`_UNIFICATION.md` §4.2). The default
  stays Apple-only / zero-dep.
- **Widened-hardware note:** `NLContextualEmbedding` is macOS 14+ (wider than the app's
  macOS 26 floor), and the keyword index needs no model at all — so search is one of
  the few features that already degrades gracefully toward feature 20's wider audience.

## 12. Risks, edge cases, failure modes

| Risk / edge case | Behavior / mitigation |
|---|---|
| **7-day history pruning** silently drops old dictation rows | Chunks are self-contained (text + provenance snippet survive); jump-to-source for a pruned row degrades to "show snippet." The **graph** is the durable long memory; meetings never prune. Document clearly. |
| Embedding **assets not yet downloaded** / unsupported language | `hasAvailableAssets` gate → fall back to **keyword-only** ranking; `prepare()` requests assets in background; re-index those chunks once ready. Never block the UI. |
| **Apple changes the model / dimension**, or user switches backend | `index_meta` carries `dimension`+`embedderID`; on mismatch, **discard `vectors.bin` and rebuild** (keyword index + chunks survive). Never migrate floats across models. |
| Mixed-language corpus | Detect per-chunk language (`NLLanguageRecognizer`, already in `LanguageDetector`) → route to the right script model; cross-language semantic recall is weaker — keyword catches the exact-term cases. |
| **Stale index** (app crashed mid-build) | Watermarks + a "derived cache" mindset: on launch, reconcile against current source counts; partial builds are safe to resume; worst case, full rebuild is cheap at this scale. |
| Index/query **during a live dictation/recording** | Indexer yields to `isDictating`/`isRecording` (model/CPU exclusivity, §4.3). Querying is read-only and fine, but defer reindex. |
| **Feature 05 not landed** | Search ships history+meetings only; entity hits absent; define a tiny local `Provenance` mirror or import 05's type guarded by availability so search compiles standalone (§15). |
| Empty corpus / no Apple Intelligence | Search still works (keyword + static embeddings need no LLM); empty state copy. Foundation Models being off does **not** disable search (it's retrieval, not generation). |
| Concurrency safety | `SearchIndexer`/`SearchEngine` are `actor`s; `VectorStore`/`KeywordIndex` are `Sendable` value types; the MCP reader takes no app-held locks (read-mostly file replica). |
| Very long meeting transcript | Already chunked into ~600–900-char windows on boundaries; ranking surfaces the best passage, not the whole meeting. |

## 13. Testing & verification

There is **no test target today** (`_CURRENT_STATE.md` §8) — this feature is a good
reason to add a first one (a SwiftPM test target in `Package.swift`), but the MVP can
verify with pure-Swift unit logic on the Sendable value types (no UI/main-actor needed):

- **Unit (deterministic, no model):** `KeywordIndex` (tokenization, BM25 ordering,
  add/remove), `VectorStore.topK` (cosine ranking on hand-made vectors), the RRF
  blender (known semantic+keyword rank lists → expected fused order),
  `SearchChunk` chunking of a long transcript on boundaries, and `index_meta`
  dimension-mismatch → rebuild logic.
- **Embedding smoke (needs the OS model):** embed two paraphrases and an unrelated
  sentence; assert paraphrase cosine > unrelated cosine (sanity, not a fixed
  threshold). Skips cleanly if `hasAvailableAssets == false`.
- **Manual / `/run`:** dictate three distinct things and record a short meeting; open
  the Search tab; (a) keyword query for an exact rare token → hit; (b) **semantic**
  query using *different words* than were dictated → still hits (proves embeddings, not
  just keyword); (c) click a result → lands on the right History row / scrolls the
  meeting transcript to the `[mm:ss]`; (d) toggle airplane mode after the asset is
  cached → search still works (proves offline). Use `/verify` to confirm the
  no-network claim (`grep -rniE "URLSession|http"` over `Sources/Search/` returns
  nothing — the §15-style invariant check).
- **MCP (feature 06):** call the `search` tool over the file replica and assert it
  returns the same top hit as the in-app engine for the same query.

## 14. Effort & phasing

| Sub-step | Size | Notes |
|---|---|---|
| `SearchChunk` + chunking from history/meetings | **S** | pure value types |
| `KeywordIndex` (NLTokenizer + BM25) | **M** | the lexical half; works with zero model |
| `AppleContextualEmbedder` + `VectorStore` (Accelerate cosine) | **M** | asset gating is the fiddly part |
| `SearchIndexer` (incremental, watermarks, debounce, off-main) | **M** | mirror the graph extractor |
| RRF blended `SearchEngine` + filters + snippets | **M** | ranking + highlight |
| `SearchView` tab + jump-to-source | **M** | reuse cards/chips |
| Command palette (glass NSPanel) | **S–M** | reuse HUD panel pattern |
| MCP `search` file replica (feature 06) | **M** | lives in `TalkieMCP` |
| First test target + units | **S–M** | also unblocks future regression work |

- **MVP slice (ship first):** keyword index + Apple static/contextual embedder + a
  Search tab over **history + meetings only** (no graph entities yet) with RRF ranking,
  snippets, and jump-to-source. This is independently demoable and unblocks "find that
  thing I said" immediately. Total ≈ M+M+M+M.
- **Full feature:** add graph-entity chunks (after 05), the command palette, backend
  pluggability (option C), and the MCP `search` tool (06).

## 15. Dependencies & interactions

- **Needs:** **05 Context Graph** (entity hits + the canonical `Provenance` type;
  search compiles standalone over history+meetings if 05 isn't landed, then gains
  entity hits when it is). `HistoryStore`, `MeetingStore` (corpora; already exist).
  `NaturalLanguage` + `Accelerate` (system, no dep).
- **Enables:** **06 MCP** (`search` tool is this engine over a file replica) → **07
  connector** (exposes search to local agents); **09 cross-surface** ("the action items
  from my last meeting" first *finds* the meeting via search, then drafts via the
  command/Summarizer path); the redefined **Brief** (07) and recall surfaces lean on
  the same provenance-cited retrieval ethic.
- **Overlaps / shares with:** **20 pluggable backends** — the `EmbeddingProvider` seam
  is the search-side analogue of `TranscriptionBackend`; the heuristic/lexical-only
  degrade matches 20's `supportsContextualStrings = false` philosophy. **18 Claude
  bridge** — only relevant if a future "ask my brain" *answer* mode is added on top of
  search results (off by default, behind 15's wall; **not** this feature).
- **Guarded by:** **15 provable zero-network** — confirm `NLContextualEmbedding` asset
  download/load works under the App Sandbox without a network entitlement (added to
  15's validation list).

---

### Sources (on-device embedding research)

- [NLContextualEmbedding — Apple Developer Documentation](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)
- [hasAvailableAssets — Apple Developer Documentation](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding/hasavailableassets)
- [Explore Natural Language multilingual models — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10042/) (Latin/Cyrillic/CJK script models, 512-dim, ≤256 tokens)
- [On-Device Text Embeddings with Apple NLP framework — Callstack](https://www.callstack.com/blog/on-device-ai-introducing-apple-embeddings-in-react-native)
- [Apple Embeddings API surface — react-native-ai docs](https://www.react-native-ai.dev/docs/apple/embeddings)
- [NLEmbedding sentence embedding (512-dim) — Mark Brownsword](https://markbrownsword.com/2020/12/23/natural-language-framework-sentence-embedding-with-swift/)
- [model2vec.swift — on-device static embeddings (Apache-2.0)](https://github.com/shubham0204/model2vec.swift)
- [MLXEmbedders / mlx-swift-lm (BGE on-device)](https://github.com/ml-explore/mlx-swift-lm)
