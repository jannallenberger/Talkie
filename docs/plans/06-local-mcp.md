# 06 — Local MCP Server (stdio) for local agents

> Engineer-ready plan. Read `_CURRENT_STATE.md` (ground truth) and
> `_UNIFICATION.md` (the spine) first. This plan obeys the per-feature contract in
> `_UNIFICATION.md` §6 (block **06**) and the module boundary in §3 (`TalkieMCP/`).
> External facts (MCP spec revision, Swift SDK version/license/deps, client config)
> were verified against current sources June 2026 — citations at the end.

## 1. Summary

Ship a **separate, on-device SwiftPM executable** (`talkie-mcp`) that speaks the
Model Context Protocol over **stdio**, so Claude Code / Cursor / any local MCP
client can query Talkie's own data — meetings, transcripts, the dictionary, the
context graph (feature 05), and the daily Brief — and make exactly one curated
write ("add a dictionary term"). It reads the same on-disk JSON/Markdown stores
**read-mostly**, runs out-of-process (the app need not be open), and adds **zero**
network code.

> **Correction (2026-07-03, package A5 — the one write shipped, differently).**
> This plan specified the write as a **direct atomic read-modify-write of
> `dictionary.json`** from the peer binary (see §"DictionaryWriter", the
> `add_dictionary_term` rows in the tool table, and the flock-sidecar notes). That
> design was **not built as written**, because it races the app: `DictionaryStore.save()`
> overwrites the *whole* `dictionary.json` unconditionally, so a peer write would be
> silently clobbered on the next in-app save — and, worse, it would let a
> prompt-injected Claude session change speech recognition **silently**. A5 ships the
> same capability behind an **inbox handshake** instead: the peer exposes **two**
> tools — `add_vocabulary_term` and `add_replacement` — that each write **one atomic
> JSON file per suggestion** into `~/Library/Application Support/Talkie/inbox/`
> (uuid-named, so concurrent sessions can't clobber each other) and **never touch
> `dictionary.json`**. The app (`Sources/Talkie/DictionaryInbox.swift`) watches that
> folder, validates (length / dedup / rate-cap), applies via the existing
> `addVocabularyTerm` / `addLearnedReplacement`, and **shows the HUD-Undo pill** — the
> same apply-with-visible-Undo contract the LearningEngine uses. So "the one write"
> is now "queued suggestions the user confirms," which is strictly safer. See
> `docs/MCP_TEACH_BACK.md`. The read tools in this plan are unchanged.

## 2. Why it matters

This is one of the moat features the strategic thesis names explicitly: *"a local
MCP server"* that exposes the shared on-device brain to local agents. Wispr Flow
and Granola are separate cloud products; neither can hand you a local, private,
stdio endpoint that fuses **both** of your voice surfaces (dictation + meetings)
into one queryable graph. Concretely it turns these into one-liners a developer
already living in Claude Code / Cursor can run:

- *"What did I commit to this week?"* → `list_commitments` over the graph's
  `.commitment` entities with provenance ("because you said it to Slack Tuesday").
- *"Summarize my last meeting"* → `get_meeting` returns the on-device summary +
  speaker-labeled transcript already written to `~/Talkie Meetings/`.
- *"Add `Coralate` to my dictionary so it stops mis-transcribing"* → the one safe
  write, `add_dictionary_term`.
- *"What's my brief today?"* → `get_brief` returns the projection of the graph.

It is a **read surface for the moat** (the context graph), and because it runs
locally over stdio it is the privacy-preserving counterpart to the *remote* Claude
connector (07) and the *outbound* Claude bridge (18) — those send data off the
machine; this never does. It is also the substrate feature 07a wraps into a
one-click `.mcpb` bundle.

## 3. Current state in the code

**Nothing of this feature exists yet.** There is no MCP code, no second executable,
no package dependency. The relevant *consumed* surfaces:

- **Package** is a single executable, **zero external dependencies**, Swift 6
  `.v6`, `.macOS("26.0")` — `Package.swift:1-18`. Adding a second target + the
  first SPM dependency is the structural change this feature introduces.
- **On-disk stores** (the read surface) all live under two roots defined in
  `AppPaths.swift`:
  - `~/Library/Application Support/Talkie/` — `supportDirectory()`
    (`AppPaths.swift:7-13`): `meetings.json`, `dictionary.json`,
    `history.json`, `context_summary.json`, `stats.json`, etc.
  - `~/Talkie Meetings/` — `meetingsDirectory()` (`AppPaths.swift:17-22`): one
    `.md` per meeting (the **durable** copy), `yyyy-MM-dd-HHmm-meeting.md`.
    Deliberately a plain home folder, NOT `~/Documents`, *"so meeting transcripts
    are easy to point Claude at"* (`AppPaths.swift:15-16`) — this feature is the
    cash-in on that decision.
- **Meetings:** `Meeting` (Codable) `Meeting.swift:5-16` (+ branch: `participants`
  / `source` with back-compat `init(from:)`); `MeetingStore` writes `meetings.json`
  index + Markdown (`Meeting.swift:88-109`). The `.md` files are durable; the JSON
  index is a convenience.
- **Dictionary:** `DictionaryStore` → `dictionary.json` as
  `{replacements:[Replacement], vocabulary:[String]}` (`DictionaryStore.swift:37-58`).
  `addVocabularyTerm` / `addLearnedReplacement` (`:83-98`) are the in-app write
  paths the MCP write must mirror byte-compatibly.
- **History:** `DictationEntry` + `HistoryStore` → `history.json`, newest-first,
  7-day retention (`HistoryStore.swift:4-99`). Carries `appName`/`appCategory` —
  the per-mention provenance source.
- **Brief:** `ContextSummaryStore` → `context_summary.json`
  (`{summary, generatedAtUnix?}`, `ContextSummary.swift:90-106`).
- **Context graph (feature 05): NOT BUILT YET.** `_UNIFICATION.md` §1 specifies
  `~/Library/Application Support/Talkie/graph/{entities.json, commitments.json,
  graph_meta.json}` and the `ContextGraphSnapshot` read model. This feature's
  graph-backed tools (`list_commitments`, `lookup_entity`, and graph-aware
  `search`) **depend on 05 landing first**; until then they degrade (see §12).

Honest status: **0% built.** Everything below is greenfield, but it slots into a
well-defined module boundary (`_UNIFICATION.md` §3) and reads stores that already
exist on disk in stable formats.

## 4. Design & approach

### 4.1 The dependency: the official Swift MCP SDK

Adopt **`modelcontextprotocol/swift-sdk`** (the *official* SDK maintained by the
modelcontextprotocol org). Current release **0.12.1** (May 2026), license **MIT
for existing code, Apache-2.0 for new contributions** (both permissive, fine for
an open-source ship). It targets **Swift 6.0+** and **macOS 13.0+** — comfortably
under Talkie's macOS-26 floor. It implements the protocol and ships a
`StdioTransport` for *"local subprocess communication."* Do **not** use the
MacPaw/loopwork forks — the canonical org repo is the one to track.

**Dependency-footprint caveat (this is the single biggest design tension —
flagged in §16):** the SDK pulls in `swift-system`, `swift-log`,
`swift-nio` (≥2.65), and `mattt/eventsource`. That breaks the repo's prized
**"zero external dependencies"** property — *for the MCP target only*. Because
`TalkieMCP` is a **separate target**, the **main app keeps zero deps** (it never
links the SDK). The NIO/eventsource transitive deps exist for the SDK's *HTTP/SSE*
transport, which we never use; a stdio-only server links them but never opens a
socket. We accept this for the executable; an optional hardening path
("vendor a ~600-line minimal stdio JSON-RPC core, drop the SDK") is noted in §12.

Pin the dependency exactly (`exact: "0.12.1"` or `from:` with a committed
`Package.resolved`) so an OSS contributor's build is reproducible.

### 4.2 Architecture: a peer reader, not a second app

```
  Claude Code / Cursor / any MCP client (the "host")
        │  spawns:  talkie-mcp        (stdio: JSON-RPC over stdin/stdout)
        ▼
 ┌─────────────────────────────────────────────────────────────┐
 │  talkie-mcp  (TalkieMCP executable target)                    │
 │   • MCP Server (swift-sdk) + StdioTransport                   │
 │   • TalkieDataReader  ── reads, never holds a lock the app    │
 │        holds; failure-tolerant decode (house style)          │
 │   • DictionaryWriter  ── the ONE write: atomic add-term       │
 │   • file-watch (DispatchSource .vnode) for freshness          │
 └─────────────────────────────────────────────────────────────┘
        │  reads (read-mostly)
        ▼
  ~/Library/Application Support/Talkie/*.json   +   graph/*.json (05)
  ~/Talkie Meetings/*.md
```

Key properties:

- **Out-of-process & app-independent.** `talkie-mcp` reads files on disk; the
  Talkie app does not need to be running. This is exactly the boundary rule in
  `_UNIFICATION.md` §3 ("launched out-of-process; the app is not required to be
  running").
- **Read-mostly.** Every tool except `add_dictionary_term` is a pure read. The
  app's stores all write with `.atomic` (rename-into-place), so a concurrent
  read either sees the old file or the new one whole — **no torn reads, no shared
  lock**. The reader takes **no `NSLock`/`NSFileCoordinator` lock the app holds**.
- **The one write is atomic-and-mergeable.** `add_dictionary_term` performs a
  read-modify-write on `dictionary.json` with `.atomic`, appending a vocabulary
  term iff absent. Because both the app and the server write `.atomic`, the
  last-writer-wins on the whole file; we minimise the lost-update window with an
  `flock(2)` advisory lock **on a sidecar lock file** (`dictionary.json.lock`),
  *not* on the JSON the app opens, so we never block the app (see §12 for the
  race analysis and the recommended IPC alternative).
- **Freshness without polling.** A `DispatchSource.makeFileSystemObjectSource`
  (`.vnode`, events `.write/.rename/.delete`) on `supportDirectory()` and
  `meetingsDirectory()` invalidates an in-memory cache so long-lived clients see
  new meetings/dictations without restarting the server. (Atomic writes fire
  `.rename` on the directory; watch the **directory**, re-arm on `.delete`.)

### 4.3 The MCP surface (tools + resources)

Per the contract (`_UNIFICATION.md` §6/06): tools `list_meetings`, `get_meeting`,
`search`, `get_brief`, `list_commitments`, `lookup_entity`, `add_dictionary_term`.
We expose both **tools** (model-callable functions) and **resources** (browsable
data the host can attach as context) — the SDK supports both via `withMethodHandler`.

**Tools** (name → behavior; all on-device):

| Tool | Args | Returns | Backed by |
|---|---|---|---|
| `list_meetings` | `limit?`, `since?` (ISO date), `query?` | meeting id, title, date, duration, participants, source, one-line summary | `meetings.json` + `.md` |
| `get_meeting` | `id` **or** `date`/`title` match | full summary + transcript (+ Me/Them labels if present) | `~/Talkie Meetings/*.md` (durable) |
| `get_brief` | _(none)_ | today's Brief text + `generatedAt` | `context_summary.json` |
| `list_commitments` | `status? (open\|done\|dropped)`, `involving?`, `since?` | commitments with text, owner, counterparty, dueHint, **provenance** | graph `commitments.json` (05); **degrades** → grep history for commitment cues (§12) |
| `lookup_entity` | `query`, `kinds?` | matched entities (displayName, kind, notes, mentionCount, **provenance**) | graph `entities.json` (05); **degrades** → dictionary + meeting participants |
| `search` | `query`, `limit?`, `sources? (meetings\|dictations\|entities)` | ranked snippets + jump-to-source (file path / meeting id / dictation id) | feature 19 if present; **degrades** → keyword scan over meetings + history |
| `add_dictionary_term` | `term` (required), `replaceFrom?`+`replaceTo?` (optional rule) | confirmation + the resulting count | **writes** `dictionary.json` |

`add_dictionary_term` is the only **mutating** tool — annotate it
`isMutating`-style (the MCP `Tool` `annotations.readOnlyHint: false`,
`destructiveHint: false`); the rest get `readOnlyHint: true` so well-behaved hosts
can auto-approve reads and gate the write.

**Resources** (browsable, `resource://` URIs — let a host attach data as context
without a tool call):

- `talkie://brief/today` — the Brief (mirrors `get_brief`), `text/markdown`.
- `talkie://meetings/{id}` — a meeting's full Markdown (the on-disk `.md`),
  `text/markdown`. `ListResources` enumerates recent meetings.
- `talkie://dictionary` — current vocabulary + replacement rules,
  `application/json`.
- `talkie://entities` (when 05 exists) — the entity table snapshot, `application/json`.

`ListResources` returns recent meetings + the fixed brief/dictionary resources;
`ReadResource` switches on the URI and returns `Resource.Content.text(...,
mimeType:)`. (Matches the SDK's documented `ListResources`/`ReadResource` pattern.)

### 4.4 Flow of one call (`get_meeting`)

1. Host spawns `talkie-mcp`; SDK does the JSON-RPC `initialize` handshake +
   capability negotiation (the server declares `tools` + `resources`).
2. Client calls `tools/call name=get_meeting {"id": "…"}`.
3. The `CallTool` handler resolves the id against the cached `meetings.json`
   index, reads the **`.md`** file (durable copy) from `~/Talkie Meetings/`, and
   returns `.init(content: [.text(markdown)], isError: false)`.
4. If the file is missing (deleted) → `isError: true` with a clear message; the
   server never crashes the transport on a data error.

## 5. New & changed files/types

New module `Sources/TalkieMCP/` (per `_UNIFICATION.md` §3). Pure Sendable readers,
no SwiftUI, no AppKit.

```
Sources/TalkieMCP/
  main.swift                 // entry: build Server, register handlers, run StdioTransport
  TalkieMCPServer.swift      // assembles tools + resources onto an MCP Server
  TalkieDataReader.swift     // read-mostly access to the on-disk stores (cached + file-watched)
  DictionaryWriter.swift     // the ONE safe write (atomic, flock sidecar)
  MCPModels.swift            // small Codable DTOs mirroring the on-disk schemas
  ToolHandlers.swift         // one func per tool, pure where possible
  ResourceHandlers.swift     // ListResources / ReadResource
```

Sketches (signatures, not full bodies):

```swift
// main.swift
import MCP
@main struct TalkieMCPMain {
    static func main() async throws {
        let logger = Logger(label: "com.coralate.talkie.mcp")   // swift-log → stderr only
        let reader = TalkieDataReader()                          // starts the file-watch
        let server = Server(
            name: "talkie",
            version: TalkieMCPVersion.string,
            capabilities: .init(
                resources: .init(listChanged: true),
                tools: .init(listChanged: false)
            )
        )
        await TalkieMCPServer.register(on: server, reader: reader)
        let transport = StdioTransport(logger: logger)
        try await server.start(transport: transport)
        await server.waitUntilCompleted()  // or a ServiceGroup; block until stdin closes
    }
}
```

```swift
// TalkieDataReader.swift — peer reader, NO lock the app holds.
actor TalkieDataReader {
    func meetingsIndex() -> [MeetingDTO]                 // decodes meetings.json (failure-tolerant)
    func meetingMarkdown(id: UUID) -> String?            // reads the durable .md
    func brief() -> BriefDTO?                             // context_summary.json
    func dictionary() -> DictionaryDTO                   // dictionary.json
    func entities() -> [EntityDTO]                        // graph/entities.json  (empty if 05 absent)
    func commitments() -> [CommitmentDTO]                // graph/commitments.json (empty if 05 absent)
    func dictations(since: Date?, limit: Int) -> [DictationDTO] // history.json (for degraded search)
    // file-watch invalidates the per-file cache; each accessor re-reads on miss.
}
```

```swift
// DictionaryWriter.swift — the single mutation.
enum DictionaryWriter {
    /// Atomic read-modify-write. Returns the new vocabulary count, or throws a typed error.
    static func addTerm(_ term: String,
                        replacement: (from: String, to: String)?) throws -> Int
    // flock() a sidecar lock file; decode dictionary.json; append if absent;
    // re-encode; write .atomic. Byte-compatible with DictionaryStore's Payload.
}
```

```swift
// MCPModels.swift — DTOs DELIBERATELY duplicated (not shared with the app target).
// Rationale: the MCP target must not import the app target (separate executables);
// these mirror the on-disk JSON exactly and decode with decodeIfPresent for
// forward/back-compat, the same as the app's stores.
struct MeetingDTO: Codable, Sendable { var id: UUID; var title: String; var startUnix: Double
    var durationSec: Double; var transcript: String; var summary: String
    var participants: [String]?; var source: String?; var fileName: String }
struct DictionaryDTO: Codable, Sendable { var replacements: [ReplacementDTO]; var vocabulary: [String] }
// EntityDTO / CommitmentDTO mirror _UNIFICATION.md §1.2 (only when 05 lands).
```

**Changed file:**

- `Package.swift` — add the SDK dependency + the `TalkieMCP` executable target:

```swift
// swift-tools-version:6.0
let package = Package(
    name: "Talkie",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git",
                 exact: "0.12.1"),
    ],
    targets: [
        .executableTarget(name: "Talkie", path: "Sources/Talkie",
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "TalkieMCP",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            path: "Sources/TalkieMCP",
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
```

The app target gains **no** dependency (it never imports `MCP`) — the zero-dep
invariant for the shipping app holds.

## 6. Data model & persistence

- **Reads, no new storage.** The server adds **no** new persisted data; it reads
  the existing files (§3) and, when present, feature 05's
  `graph/{entities,commitments}.json`. Paths come from the same `AppPaths` logic,
  re-derived in `TalkieDataReader` (it can't call the app's `AppPaths` across
  targets, so it recomputes `~/Library/Application Support/Talkie` and
  `~/Talkie Meetings` identically — a 6-line helper, kept in sync by a comment +
  a build-time assertion test).
- **The one write** appends to `dictionary.json` in the **exact `Payload`
  shape** `DictionaryStore` uses (`{replacements, vocabulary}`,
  `DictionaryStore.swift:37-40`) so the running app re-reads it cleanly. We mirror
  `addVocabularyTerm`'s dedupe (`DictionaryStore.swift:84-87`) and, for an
  optional rule, `Replacement`'s default flags (`learned: false` —
  it's a deliberate user/agent term, not a passively learned one).
- **Migration / back-compat:** none needed (read-only of existing formats).
  All DTO decode is `decodeIfPresent`/`try?` so a future field addition (e.g. when
  the far-end branch's `participants`/`source` land on main) won't break the
  server. The `.md` files remain the durable source of truth for transcripts; the
  server prefers them over the JSON index for `get_meeting`.

## 7. Unification contract

Per `_UNIFICATION.md` §6 (block **06**) and §3:

**EXPOSES (what other features / external clients consume):**
- The MCP tool/resource surface in §4.3 — the public, documented contract:
  `list_meetings`, `get_meeting`, `search`, `get_brief`, `list_commitments`,
  `lookup_entity`, `add_dictionary_term`, plus `talkie://` resources.
- A reusable, on-device **read replica of the graph query surface**
  (`lookup`, `openCommitments`, `entities(fromMeeting:)`) implemented against the
  **file snapshot** rather than the live `ContextGraphStore` — this is the
  contract's *"the Graph query surface (§1.6) replicated against the file
  snapshot."* It is the substrate **feature 07a** wraps into a `.mcpb` bundle.

**CONSUMES:**
- The on-disk graph / meetings / dictionary **read-mostly** (§1.4, §3 boundary).
- **Feature 05 (Context Graph) — the keystone dependency.** `list_commitments`,
  `lookup_entity`, and the entity hits in `search` read
  `graph/{entities,commitments}.json` and reproduce `ContextGraphSnapshot`'s
  `lookup`/`openCommitments` ranking against that file data. If 05 is absent these
  tools **degrade** (§12), never error.
- **Feature 19 (search)** for the `search` tool's semantic ranking; degrades to
  keyword scan if 19 is absent.
- The existing meeting/dictionary/brief stores' on-disk formats (no app import).

**Note (the coherence rule from the contract):** *separate `TalkieMCP` executable
target; stdio only; no network; no lock contention with the app; runnable while
the app is closed.* This plan honors every clause: separate target (§5), stdio
transport (§4.1), zero network (§10), no app-held lock (§4.2/§12), app-independent
(§4.2). Critically, the server is a **consumer of the brain, never a second copy
of it** (`_UNIFICATION.md` §0) — it replicates the *read* logic, but the graph is
written only by 05's extractor inside the app.

## 8. UI / UX

The MCP server itself is **headless** — its "UI" is the developer's MCP client.
But the app needs a small, on-brand surface to make it discoverable and to honor
the "user consent and control" principle in the MCP spec (the spec mandates the
*host* gate tool use; we also let the *user* see/disable the exposure):

- **A "Developer / Local agents" row** in `SettingsHome` (the index pattern at
  `SettingsView.swift:399-476`), pushing a focused `SubPage`
  (`SettingsView.swift:479-497`) — *not* a new top-level tab (keeps the
  6-tab nav clean).
- The page contains:
  1. One honest sentence (second person, sentence case per `BRAND.md`):
     *"Let local AI tools on this Mac read your meetings, dictionary, and brief
     over a private connection. Nothing leaves your machine."*
  2. A **copy-paste setup block** with the exact `claude mcp add` /
     `~/.cursor/mcp.json` snippets (§13), in a monospaced card
     (`.talkieCard()`, `DesignSystem.swift:159-169`), with a "Copy" button reusing
     the History tab's copy affordance pattern.
  3. A **read/write disclosure**: a `FlowLayout` of chips
     (`DesignSystem.swift`, the dictionary-chip pattern) — read chips
     (`featherBlue`) for meetings/brief/dictionary/graph and one write chip
     (`featherGold`) for `add_dictionary_term` — so the user sees exactly what an
     agent can touch. One accent per view (blue, `Theme.coral`); feather palette
     for the data chips only (`BRAND.md` feathers-for-data rule).
  4. A path readout: *"Reads from `~/Library/Application Support/Talkie` and
     `~/Talkie Meetings`."*
- No HUD involvement; no live indicator needed (the server is request/response and
  prints nothing visible). If we later want activity visibility, a tiny
  "last queried by an agent: 3m ago" line could read a timestamp the server
  touches — deferred, optional.

The settings page is the only app-side code; everything else is the executable.

## 9. Permissions / entitlements / Info.plist

- **No new entitlement, no new TCC prompt** in the default path. The server is a
  CLI reading two folders the *user* owns; it inherits the spawning client's
  permissions. `~/Talkie Meetings` is a plain home folder (chosen precisely to
  avoid TCC, `AppPaths.swift:15`), and Application Support is not TCC-gated.
- **No `com.apple.security.network.client`** — the executable never opens a socket
  (stdio only). It should ship with the **same hardened-runtime, no-network**
  posture as the app; if notarized for distribution (feature 16) it needs its own
  signature but **no special entitlement**.
- **Sandbox caveat (interacts with feature 15):** today the app is *not*
  sandboxed. If feature 15 sandboxes the app, the **CLI is a separate process and
  is not inside the app's sandbox** — it runs with the user's normal file access,
  so it keeps working. But a *sandboxed app cannot itself spawn* the helper with
  arbitrary file access; since the **host (Claude Code) spawns the CLI**, not the
  app, this is a non-issue for the primary flow. Document it; feature 07a (the
  `.mcpb` bundle) must bundle the CLI binary so Claude Desktop can spawn it.
- If a future client spawns the CLI such that it inherits a sandbox lacking
  `~/Talkie Meetings` access (e.g. Claude Desktop's own sandbox), `.mcpb` manifest
  config must grant the path — a 07a concern, noted here.

## 10. Privacy posture

**Zero-network, preserved and strengthened.**

- The server makes **no network connections.** It uses only the SDK's
  `StdioTransport` (stdin/stdout). The SDK *transitively* links `swift-nio` /
  `eventsource` (for its HTTP/SSE transport, which we never instantiate) — we
  must add a **CI grep test** asserting `talkie-mcp` never references `HTTP`/
  `SSE`/`URLSession`/socket APIs, mirroring the app's existing zero-network proof
  (`_CURRENT_STATE.md` §0). Ideally feature 15's proof panel lists the CLI too.
- **All data stays on the machine.** stdio is local IPC between the user's MCP
  client and the user's CLI; bytes never leave the Mac. The *client* may be a
  cloud product (e.g. if someone points Claude.ai's remote infra at it — that's
  feature 07b's separate, opt-in story), but **this server** does not transmit
  anything; it answers on a pipe.
- **The write is contained:** `add_dictionary_term` only ever appends a vocabulary
  term / a replacement rule to `dictionary.json`. It cannot delete meetings,
  cannot modify transcripts, cannot touch history. This is the deliberately
  minimal mutation surface from the contract.
- **Consent layering:** MCP's security model puts tool-approval in the *host*
  (Claude Code prompts before a tool runs). We add the user-side disclosure (§8)
  and mark reads `readOnlyHint: true` so hosts can distinguish the one write.

## 11. Open-source genericity

- **No hardcoded personal stack.** The server speaks **standard MCP** — any
  compliant client works (Claude Code, Cursor, Zed, Windsurf, a hand-rolled
  client). Jann's Obsidian/Claude-Code stack is *not* assumed: the setup doc shows
  Claude Code **and** Cursor **and** a generic `mcp.json`, and the data it serves
  is Talkie's own folders, not any vault.
- **Zero-config default:** `swift build` produces `talkie-mcp`; point any client
  at the binary path — no API key, no config file, no third-party app, no running
  Talkie instance required. The folders it reads are created by the app on first
  run and exist whether or not the user uses any particular editor.
- **Community extension:** the tool/resource surface is data-shaped, not
  tool-shaped, so contributors can add tools (e.g. `export_meeting`,
  `mark_commitment_done` once 05's write API exists) without touching the app.
  The DTO mirroring keeps the CLI buildable standalone. A contributor who wants a
  different transport (HTTP for a remote box) can add it behind feature 15's wall —
  but the default and the shipped binary are stdio-only.

## 12. Risks, edge cases, failure modes

| Risk / edge case | Behavior / mitigation |
|---|---|
| **Feature 05 not yet built** (graph files absent) | `list_commitments`/`lookup_entity` **degrade gracefully**: commitments → regex-scan history for cues (`I'll`, `I need to`, `by Friday` — the same heuristics 05's extractor will use, `_UNIFICATION.md` §1.5) with `appName` provenance; `lookup_entity` → dictionary vocab + meeting participants. Tools advertise reduced fidelity in their description; never error. This lets 06 ship a useful MVP **before** 05. |
| **Lost update on the dictionary write** (app + CLI both edit) | Both write `.atomic` → no torn file, but a simultaneous edit can lose one side's change. Mitigate with an `flock(2)` sidecar lock + immediate re-read. **Recommended hardening:** when the app is running, route the write through it (a tiny localhost-free mechanism: a `dictionary.append.json` *drop file* the app's existing `.onChange` watcher ingests, or a `DistributedNotificationCenter` ping). The drop-file approach keeps the CLI app-independent and lock-free — write a one-line append request the app folds in, falling back to the direct atomic write when the app isn't running. |
| **Torn read** | Impossible for whole-file `.atomic` writes (rename is atomic on APFS); a reader sees old-or-new, never half. The file-watch may briefly serve a stale cache → bounded by the next `.vnode` event. |
| **Corrupt / partial JSON** (e.g. a crash mid-write elsewhere) | `try?`/`decodeIfPresent` decode → the accessor returns empty/partial rather than throwing; the tool returns a clear "couldn't read X" message, transport stays up. |
| **Missing `.md` for an indexed meeting** (user deleted the file) | `get_meeting` returns `isError:true` with the path; `list_meetings` filters to existing files. |
| **Long meeting transcript** blows the client's context | `get_meeting` supports a `section?` arg (`summary`/`transcript`/`both`, default `summary`) and `maxChars?`; `search` returns snippets, not whole files. |
| **Stdout pollution breaks JSON-RPC** | Route **all** logging to **stderr** (swift-log default) and never `print()` to stdout — a stray stdout write corrupts the framing. Add a lint/test asserting no `print(` in `Sources/TalkieMCP`. |
| **SDK drags in NIO/eventsource** (dependency bloat) | Accept for the separate target; app stays zero-dep. Hardening option: replace the SDK with a ~600-line vendored stdio JSON-RPC core (MCP is small over stdio) to restore zero-dep across the board — a fast-follow, not MVP. |
| **Binary path drift / server won't start** | The setup page shows the absolute built path; for distribution, feature 16 installs `talkie-mcp` to a stable location (e.g. `/usr/local/bin` or inside the `.app` bundle's `Contents/MacOS`) and the doc references that. |
| **Client spawns under a sandbox without folder access** | Surfaces as "no meetings found" not a crash; `.mcpb` manifest (07a) declares the needed paths; documented. |
| **Concurrent clients** | Each client spawns its own `talkie-mcp` process; multiple readers are fine (read-mostly). The write's `flock`/drop-file handles cross-process. |

Graceful-degradation principle throughout: **a data problem yields a tool error
message, never a transport crash** — the server must stay responsive so the agent
can recover.

## 13. Testing & verification

**Unit (new `TalkieMCPTests` target — the repo has no tests yet, so this also
introduces the first test target):**
- DTO decode round-trips against **fixture copies** of real `meetings.json` /
  `dictionary.json` / `context_summary.json` / `graph/*.json`, including
  pre-Phase-2 meeting JSON (no `participants`/`source`) to prove back-compat.
- `DictionaryWriter.addTerm` dedupe + atomicity (write, re-decode, assert shape ==
  `DictionaryStore.Payload`); concurrent-write stress (two writers, assert no
  corruption, no lost term beyond the documented window).
- Degraded `list_commitments`/`lookup_entity` paths with the graph files absent.
- A `AppPaths` parity test: assert the CLI's recomputed paths == the app's
  `AppPaths.supportDirectory()`/`meetingsDirectory()` (guards the duplicated path
  logic).
- A **zero-network grep test** over `Sources/TalkieMCP` (no `URLSession`, no
  `HTTP`, no socket); a **no-stdout-print** grep test.

**Protocol-level (manual + scripted):**
- `swift build`, then pipe a canned JSON-RPC session into the binary:
  `printf '{"jsonrpc":"2.0",...initialize...}\n{...tools/list...}\n{...tools/call get_brief...}' | .build/debug/talkie-mcp` and assert the framed responses. (Stdio = newline-delimited JSON-RPC — easy to script.)
- Use the SDK's own `mcp-everything-client` or the MCP **Inspector** to drive the
  server interactively and confirm `tools/list`, `resources/list`,
  `resources/read`, and each `tools/call`.

**End-to-end (the `/run` / `/verify` path):**
- Register with Claude Code: `claude mcp add talkie -- /abs/path/.build/debug/talkie-mcp`,
  then in a Claude Code session ask *"use the talkie MCP: what did I commit to this
  week?"* and *"summarize my last meeting"* and confirm grounded answers citing
  real `~/Talkie Meetings` content.
- Cursor: add to `~/.cursor/mcp.json`:
  `{"mcpServers":{"talkie":{"command":"/abs/path/talkie-mcp"}}}` and verify the
  tools appear.
- Verify `add_dictionary_term` appends to `dictionary.json` **and** the running app
  picks it up (open the Dictionary tab, see the new chip).

## 14. Effort & phasing

- **S** — `Package.swift` second target + SDK dep + `main.swift` skeleton that
  starts a stdio server and answers `initialize`.
- **S** — `TalkieDataReader` (decode the 3 existing JSON stores + read `.md`).
- **M** — Tools `list_meetings`, `get_meeting`, `get_brief` + resources
  (`talkie://brief/today`, `talkie://meetings/{id}`, `talkie://dictionary`).
- **M** — `add_dictionary_term` (atomic write + dedupe + flock sidecar).
- **M** — `list_commitments` / `lookup_entity` / `search` with the **degraded**
  (no-05) implementations.
- **S** — the file-watch cache invalidation.
- **S/M** — the Settings "Local agents" page (§8) + copy-paste setup block.
- **M** — the test target (DTO fixtures, write stress, zero-network grep).
- **L (later, gated on 05/19)** — re-point `list_commitments`/`lookup_entity` to
  real graph files and `search` to feature 19's semantic index; add `section?`
  controls; the drop-file IPC write path.

**MVP slice (ship first, ~S+M):** stdio server + `list_meetings`, `get_meeting`,
`get_brief`, `add_dictionary_term`, the two meeting/brief resources, and the
Settings setup card. This is independently demoable ("Claude Code summarizes my
last meeting, fully local") **without** feature 05.

**Full feature:** + `list_commitments`/`lookup_entity`/`search` (degraded now,
graph-backed once 05/19 land), file-watch freshness, drop-file write IPC, the
test target, and 07a `.mcpb` packaging.

## 15. Dependencies & interactions

- **Needs (soft):** **05 Context Graph** for the graph-backed tools (degrades
  without it — can ship MVP first). **19 Search** for semantic `search` (degrades
  to keyword). The existing meeting/dictionary/brief stores' on-disk formats (no
  app import).
- **Enables:** **07a** (the `.mcpb`/DXT Desktop bundle wraps *this* server — the
  recommended, on-device-first connector) and informs **07b** (remote connector,
  which reuses the same tool surface behind feature 15's network wall). The
  contract calls 07a privacy-safe and primary.
- **Overlaps / aligns with:** **15** (provable zero-network — the CLI must be in
  the proof panel + the network-grep CI). **16** (install/update — must install
  `talkie-mcp` to a stable path and sign/notarize it alongside the app). **01**
  (far-end meeting branch) — once merged, `participants`/`source` flow into
  `list_meetings`/`get_meeting` for free via the back-compat DTO. **02** (notes
  fusion) — fused notes are still `.md` in `~/Talkie Meetings`, so `get_meeting`
  serves them unchanged.
- **Module-boundary rule honored** (`_UNIFICATION.md` §3): `TalkieMCP` reads the
  same on-disk stores read-mostly, takes no app-held lock, runs out-of-process,
  and is the peer reader (never the writer) of the graph — the single write is the
  contract-sanctioned dictionary append.

---

### Sources (verified June 2026)

- Official Swift MCP SDK (server API, StdioTransport, version, license, platforms):
  [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)
  and its [Package.swift](https://github.com/modelcontextprotocol/swift-sdk/blob/main/Package.swift)
  / [StdioTransport.swift](https://github.com/modelcontextprotocol/swift-sdk/blob/main/Sources/MCP/Base/Transports/StdioTransport.swift).
- MCP specification (primitives, transports, security model):
  [Specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25)
  (latest stable revision).
- Claude Code local stdio config (`claude mcp add … -- <command>`):
  [Claude Code MCP guides](https://systemprompt.io/guides/claude-code-mcp-servers-extensions).
