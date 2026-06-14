# 07 — Custom Claude Connector (.mcpb Desktop Extension + Claude.ai directory)

> Engineer-ready implementation plan. Grounded in the code at `main` (HEAD `5f747fb`)
> and the unmerged `feat/meeting-far-audio` branch. Read `_CURRENT_STATE.md` (ground
> truth) and `_UNIFICATION.md` (the spine) first; this plan honors the **07** contract
> in `_UNIFICATION.md §6` and builds directly on feature **06** (the local MCP server)
> and feature **15** (the network wall / build flavors).
>
> Floor: macOS 26.0, Apple Silicon, Swift 6 strict concurrency (`.v6`).
>
> **External facts in this plan were verified by web research on 2026-06-14**
> (current month June 2026). The .mcpb manifest spec referenced is **v0.3**
> (updated 2025-12-02). Re-verify before shipping — Anthropic iterates these fast.

---

## 1. Summary

Make Talkie's on-device brain reachable from Claude two ways: **(7a)** package
feature-06's local MCP server as a one-click **`.mcpb` Desktop Extension** that
runs entirely on the user's Mac (zero network — ship this FIRST), and **(7b)** a
**remote Claude.ai connector** (Streamable HTTP + OAuth 2.1) that is OFF by default,
opt-in, and architecturally walled off in a separate `TalkieBridge`-class module so
the zero-network default stays provably intact.

---

## 2. Why it matters

**User value.** "Summarize my last three meetings," "what did I commit to this
week," "who is Sarah and what do I owe her" — answered by Claude itself, drawing on
the personal context graph (05), meetings (01/02), and dictionary, with a single
click to install and no copy-paste. Talkie becomes the *voice memory layer* a Claude
power-user reaches for inside the tool they already live in.

**Strategic thesis.** The moat is "both voice surfaces feed ONE on-device brain."
A connector is how that brain leaves the app *on the user's terms* and becomes
useful everywhere Claude is. Crucially:

- **7a is something neither incumbent can match honestly.** Wispr Flow and Granola
  are separate cloud companies; a *local, on-device* connector that exposes your
  meetings + dictation + commitments to Claude **without anything leaving your Mac**
  is a claim only an on-device, open-source product can make. The privacy story
  ("provably nothing leaves your machine") becomes a *feature you can demo*: the
  `.mcpb` runs a stdio binary against local files; there is no server to phone home.
- **7b is the discoverability play** — a listing in Claude's connector directory is
  marketing surface a subscription competitor can't deny you. But it carries a hard
  privacy tension (a remote connector implies your local data is reachable from
  Claude's cloud), so we phase it last and design the consent/data model so the
  honest claim survives (§10).

**It reuses, doesn't rebuild.** 7a is *packaging* around 06; 7b is a thin remote
shell over the same query surface, gated by 15's wall. Low marginal cost.

---

## 3. Current state in the code

Honest status: **feature 06 (the local MCP server) and feature 05 (the context
graph) are NOT built yet.** No `TalkieMCP` target, no `ContextGraph/` module, no
network code anywhere. This plan therefore (a) states its hard dependency on 06/05
and (b) specifies a **degraded 7a-MVP that works against the data that exists on
disk today**, so 07 can ship value even slightly ahead of a full 05.

What exists today that 07 builds on:

- **On-disk data the server reads (verified live on this machine):**
  - `~/Talkie Meetings/2026-06-14-2105-meeting.md` — durable Markdown w/ YAML
    frontmatter; `~/Library/Application Support/Talkie/meetings.json` — the index
    (`{summary, id, title, transcript, fileName, startUnix, durationSec, …}`).
    The branch `Meeting` struct adds `participants: [String]` / `source: String`
    with back-compat decode (`git show feat/meeting-far-audio:Sources/Talkie/Meeting.swift:5-38`).
  - `~/Library/Application Support/Talkie/dictionary.json` —
    `{"vocabulary":[…],"replacements":[{from,to,wholeWord,id,caseSensitive}]}`.
  - `history.json`, `stats.json`, `context_summary.json` (the Brief),
    `project_index.json`, `activity.json` (`_CURRENT_STATE.md §3`).
- **`AppPaths.swift`** (`AppPaths.swift:6-22`) — the two roots the server will read:
  `supportDirectory()` (`~/Library/Application Support/Talkie/`) and
  `meetingsDirectory()` (`~/Talkie Meetings/`, deliberately NOT TCC-protected,
  chosen precisely so "Claude can be pointed at it" — see the comment at `:15-16`).
  The MCP target will share this file (or a copy) so paths never drift.
- **Zero network, single entitlement** (`Resources/talkie.entitlements`: only
  `com.apple.security.device.audio-input`; `_CURRENT_STATE.md §6`) — the invariant
  7b must not break in the default build.
- **`Package.swift`** — one `.executableTarget` (`Talkie`), `swift-tools-version:6.0`,
  `.macOS("26.0")`, `.v6`, **zero external dependencies**. Adding the MCP SDK + a
  second/third target is the structural change 06/07 introduce.
- **`MeetingSummarizer` / `ContextSummaryEngine` / `CleanupEngine`** — on-device
  Foundation-Models actors (`Meeting.swift`, `ContextSummary.swift`,
  `CleanupEngine.swift`). 07 does **not** call these directly; it reads their
  *outputs* on disk (summaries, the Brief) so the server stays a pure reader.

What is missing (the prerequisites, tracked against their own features):

- **Feature 06** — the `TalkieMCP` stdio executable + tool/resource set. 07a is its
  distribution wrapper; this plan assumes 06's tool surface (`_UNIFICATION.md §6/06`)
  and specifies the wrapper precisely.
- **Feature 05** — `ContextGraphStore`/`ContextGraphSnapshot`. The richest tools
  (`lookup_entity`, `list_commitments`) need it. 7a-MVP degrades to
  meetings+dictionary+history without it.
- **Feature 15** — the two build flavors + the `requiresNetwork` enforcement point
  that 7b's remote module must sit behind.

---

## 4. Design & approach

### 4.0 The shape (one paragraph)

The local server (06) is one Swift executable speaking MCP over **stdio**. **7a**
wraps that executable's *compiled binary* in a `.mcpb` zip with a `manifest.json`
(server `type: "binary"`) so Claude Desktop installs and launches it with one click;
it reads the on-disk Talkie stores read-mostly and **makes zero network calls**.
**7b** stands up the *same tool surface* behind a **Streamable-HTTP** endpoint with
**OAuth 2.1 + PKCE**, living in a separate networked module/target so it is absent
from the default sandboxed build; it is exposed to Claude's cloud only when the user
runs the local endpoint and (optionally) a tunnel, after an explicit consent flow.

### 4.1 7a — the `.mcpb` Desktop Extension (PRIMARY, on-device)

**Verified format facts (2026-06):**
- Desktop Extensions are now packaged as **`.mcpb`** (MCP Bundle) files — a **zip**
  containing the server + a **`manifest.json`**. The older `.dxt` name still works
  but `.mcpb` is the going-forward convention (renamed late 2025). Manifest spec is
  **v0.3** (2025-12-02). Server `type` ∈ `{node, python, binary, uv}`.
  ([modelcontextprotocol/mcpb MANIFEST.md], [MCP blog: adopting .mcpb])
- A **`binary`** server is a pre-compiled, self-contained executable declared via
  `server.entry_point`; ".exe" is auto-appended on Windows; **no runtime field
  needed**. Static linking preferred. This is exactly right for a Swift binary.
- Build/sign/validate with the **`@anthropic-ai/mcpb`** npm CLI: `mcpb init`
  (scaffold manifest), `mcpb validate`, `mcpb pack` (produce the `.mcpb`), `mcpb
  sign`. Tooling is Apache-2.0/MIT. Users install by **opening the `.mcpb` in Claude
  for macOS** → an install dialog; Claude handles config + auto-update.
  ([modelcontextprotocol/mcpb])

**Why binary, not node/python:** 06 is a Swift `StdioTransport` MCP server (official
`modelcontextprotocol/swift-sdk` v0.11.0, Swift 6, stdio + HTTP transports). We
already produce a signed Mach-O via the existing toolchain (`scripts/notarize.sh`).
Shipping the compiled binary means **zero Node/Python runtime dependency** on the
user's machine — the leanest, most private option and the cleanest privacy claim.

**Architecture of the bundle:**

```
talkie-connector.mcpb               (a zip)
├── manifest.json                   (v0.3, server.type=binary)
├── icon.png                        (the macaw)
├── server/
│   └── talkie-mcp                  (universal-ish arm64 Mach-O, signed+notarized)
└── README.md                       (+ Privacy Policy section — required, §10)
```

**`manifest.json` (sketch, the load-bearing fields):**

```json
{
  "manifest_version": "0.3",
  "name": "talkie",
  "display_name": "Talkie — your voice memory",
  "version": "0.1.0",
  "description": "Read your on-device Talkie meetings, dictation history, brief, commitments and dictionary. 100% local — nothing leaves your Mac.",
  "long_description": "Talkie fuses on-device dictation and meeting recording into one private brain on your Mac. This connector lets Claude read that brain — meetings, transcripts, the daily brief, your commitments, people/projects, and your custom dictionary — entirely locally. No network, no account, no cloud.",
  "author": { "name": "Talkie (Coralate)", "url": "https://github.com/<org>/talkie" },
  "homepage": "https://github.com/<org>/talkie",
  "documentation": "https://github.com/<org>/talkie/blob/main/docs/CONNECTOR.md",
  "license": "MIT",
  "icon": "icon.png",
  "privacy_policies": ["https://github.com/<org>/talkie/blob/main/PRIVACY.md"],
  "server": {
    "type": "binary",
    "entry_point": "server/talkie-mcp",
    "mcp_config": {
      "command": "${__dirname}/server/talkie-mcp",
      "args": ["--read-only"],
      "env": {
        "TALKIE_SUPPORT_DIR": "${user_config.support_dir}",
        "TALKIE_MEETINGS_DIR": "${user_config.meetings_dir}",
        "TALKIE_ALLOW_DICTIONARY_WRITE": "${user_config.allow_dictionary_write}"
      }
    }
  },
  "tools": [
    { "name": "list_meetings",      "title": "List meetings",        "description": "List recent Talkie meetings (date, title, participants).", "readOnlyHint": true },
    { "name": "get_meeting",        "title": "Get a meeting",        "description": "Full transcript + summary for one meeting by id.",          "readOnlyHint": true },
    { "name": "get_brief",          "title": "Get today's brief",    "description": "The on-device daily brief projection.",                     "readOnlyHint": true },
    { "name": "list_commitments",   "title": "List commitments",     "description": "Open commitments from the context graph.",                  "readOnlyHint": true },
    { "name": "lookup_entity",      "title": "Look up a person/project/term", "description": "Recall an entity with provenance.",               "readOnlyHint": true },
    { "name": "search",             "title": "Search",               "description": "Keyword/semantic search over meetings, history, entities.",  "readOnlyHint": true },
    { "name": "add_dictionary_term","title": "Add a dictionary term","description": "Append a custom vocabulary term (only if write enabled).",  "readOnlyHint": false, "destructiveHint": false }
  ],
  "tools_generated": false,
  "keywords": ["dictation","meetings","transcription","notes","privacy","on-device","voice"],
  "compatibility": {
    "claude_desktop": ">=1.0.0",
    "platforms": ["darwin"]
  },
  "user_config": {
    "meetings_dir": {
      "type": "directory", "title": "Talkie Meetings folder",
      "description": "Where Talkie saves meeting Markdown.",
      "default": "${HOME}/Talkie Meetings", "required": false
    },
    "support_dir": {
      "type": "directory", "title": "Talkie data folder",
      "description": "Talkie's Application Support folder.",
      "default": "${HOME}/Library/Application Support/Talkie", "required": false
    },
    "allow_dictionary_write": {
      "type": "boolean", "title": "Allow adding dictionary terms",
      "description": "Let Claude append terms to your custom vocabulary. Off = read-only.",
      "default": false
    }
  }
}
```

Key design choices baked in above, all on-brand and on-thesis:
- **`platforms: ["darwin"]`** — honest (the binary is macOS-only); a node/python
  fallback is explicitly out of scope (we don't have one).
- **`user_config` directory pickers** default to the real Talkie paths but are
  **overridable** — this is the OSS-genericity lever (someone who relocated their
  meetings folder, or a fork, isn't hardcoded). The bundle never assumes the app is
  installed in a particular place.
- **Read-only by default.** Every tool is `readOnlyHint: true` except
  `add_dictionary_term`, which is the **single** write path and is gated behind a
  `user_config` boolean that defaults **off** (and the binary refuses the write if
  the flag is absent). This matches the directory policy's "minimal, necessary data"
  posture and the unification §3 rule that MCP is "read-mostly."
- **The app does not need to be running.** The binary reads files; it is a *peer
  reader* of the same on-disk stores (`_UNIFICATION.md §3`). If the app is open and
  writing, file reads tolerate it (atomic writes + failure-tolerant decode are the
  house style); the one write path uses an atomic append the app tolerates on next
  load.

**The `talkie-mcp` binary (feature 06, summarized here because 07a ships it):**
A second SwiftPM `.executableTarget` (`TalkieMCP`) depending on
`modelcontextprotocol/swift-sdk`, using `StdioTransport`. It registers the tools
above; each tool is a thin reader over a **file-snapshot** of the stores (it
re-implements the §1.6 query surface against `entities.json`/`meetings.json`/
`dictionary.json` rather than importing the `@MainActor` stores). It takes
**no locks the app holds**, uses `NSFileCoordinator`/a lightweight stat-watch, and
**imports no network client** (build-time guarantee, §10).

### 4.2 7b — the remote Claude.ai connector (SECONDARY, opt-in, walled)

**Verified facts (2026-06):**
- Remote connectors must use **Streamable HTTP** transport (legacy HTTP+SSE
  deprecated); root path `/`, session management, protocol-version handshake.
  ([claude.com/docs/connectors/building], [sunpeak SSE→Streamable migration])
- Auth: **OAuth 2.1 with PKCE (S256)**. Claude supports **Dynamic Client
  Registration (DCR)**, **Client ID Metadata Documents (CIMD)**, and
  Anthropic-held static credentials. Register redirect
  **`https://claude.ai/api/mcp/auth_callback`** (hosted) and a loopback redirect for
  Claude Code. Pure machine-to-machine `client_credentials` is **not** accepted as a
  user connector flow — **every user completes a consent flow**.
  ([claude.com/docs/connectors/building/authentication], [sunpeak OAuth])
- **Adding a custom connector (user side):** Pro/Max → *Customize → Connectors → +
  Add custom connector → paste URL → (optional OAuth advanced) → Add → Connect*
  (OAuth sign-in). Team/Enterprise → an **Owner** adds it at the org level first.
  All tiers including Free can add custom connectors (Free limited to one); feature
  is in beta. ([support: get started with custom connectors])
- **Directory submission** (optional, for discoverability) requires a **Team or
  Enterprise org** with directory-management access (Owner / Primary owner / custom
  role); portal at `claude.ai/admin-settings/directory/submissions/new` (alt form
  `clau.de/mcp-directory-submission`). Listing fields + caps: **name ≤100**,
  **tagline ≤55**, **description ≤2000**, 1–5 categories, documentation URL,
  **privacy-policy URL (required)**, support contact, icon, permanent URL slug.
  **All tools must carry `title` + `readOnlyHint`/`destructiveHint`.** Missing/weak
  privacy policy = **immediate rejection**. Reviews are initial **and ongoing**;
  escalation `mcp-review@anthropic.com`. Prohibited categories incl. advertising
  vehicles, standalone media generation, financial-transaction execution.
  ([claude.com/docs/connectors/building/submission], [Anthropic software directory policy])

**The honest-privacy architecture (this is the whole ballgame):** a directory
listing would normally mean "point Claude's cloud at a server you host that holds
user data" — which is *exactly* what Talkie must not be. So 7b is designed as a
**user-run local endpoint + secure tunnel**, not a multi-tenant cloud service:

```
Claude.ai (cloud)
   │  Streamable HTTP + OAuth 2.1/PKCE
   ▼
[secure tunnel]  ── e.g. a per-user reverse tunnel the USER starts
   │              (Cloudflare Tunnel / Tailscale Funnel / ngrok), or
   │              a self-hosted box the user controls
   ▼
talkie-mcp --transport http --bind 127.0.0.1:<port>   ← runs on the USER's Mac
   │   same tool surface as 7a, same read-mostly file access
   ▼
the user's own on-disk Talkie data (never copied to any server we run)
```

There is **no Talkie-operated backend** that ever holds user data. We operate (if
anything) only the OAuth/registration metadata for a *directory* listing; the data
plane is the user's own machine. This keeps the moat ("nothing leaves your machine
except by your explicit action") technically true: data leaves only when the user
(a) starts the local HTTP endpoint, (b) starts the tunnel, (c) consents in Claude.

**Module boundary (per `_UNIFICATION.md §3/§4.1):** the HTTP transport + OAuth code
lives in a **separate target** (working name `TalkieConnector`, the §3 `TalkieMCP`
peer / `TalkieBridge`-class networked module). Core `Talkie` never imports it. It is
compiled only into the explicitly-labeled **"Talkie (Connected)"** build flavor
(feature 15), which is the *only* flavor that carries
`com.apple.security.network.client` / `network.server`. The default sandboxed build
has neither the module nor the entitlement — so the zero-network claim is structural,
not a promise.

**Recommendation & phasing (explicit):** ship **7a first and treat it as the
canonical integration.** Treat **7b** as a power-user / advanced opt-in and
**defer the directory *listing* until after 15 lands and a hosted-OAuth story is
real**; a directory listing of a "you must run a local server + tunnel" connector is
unusual and the review bar (privacy policy, ongoing review, business-tier submitter)
is real friction. The first 7b deliverable is **"add Talkie as a *custom* connector
by URL"** (no directory listing needed) documented in `docs/CONNECTOR.md` — that
unlocks the capability for anyone, today, without the directory.

### 4.3 Algorithm / flow (install → use, 7a)

1. CI builds `talkie-mcp` (arm64), signs + notarizes it (reuse `notarize.sh`).
2. CI runs `mcpb validate` then `mcpb pack server/ → talkie-connector.mcpb`, then
   `mcpb sign` with the Developer ID, and attaches the `.mcpb` to the GitHub release.
3. User downloads `talkie-connector.mcpb`, double-clicks → Claude Desktop shows the
   install dialog (icon, description, the `user_config` pickers).
4. Claude launches `talkie-mcp --read-only` over stdio; tool list appears.
5. User asks Claude something; Claude calls e.g. `list_meetings` → `get_meeting` →
   summarizes. All file reads are local; no network.

---

## 5. New & changed files / types

**New SwiftPM targets (in `Package.swift`):**

```swift
// Adds the official MCP SDK as the FIRST external dependency (06 introduces it).
.package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.11.0"),

.executableTarget(                       // feature 06; 07a ships its binary
  name: "TalkieMCP",
  dependencies: [.product(name: "MCP", package: "swift-sdk")],
  path: "Sources/TalkieMCP",
  swiftSettings: [.swiftLanguageMode(.v6)]
),
.executableTarget(                       // feature 07b (and 18-class networked code)
  name: "TalkieConnector",               // ONLY target allowed to import a net client
  dependencies: [.product(name: "MCP", package: "swift-sdk"),
                 .target(name: "TalkieMCP")],
  path: "Sources/TalkieConnector",
  swiftSettings: [.swiftLanguageMode(.v6)]
),
```

**New files:**

```
Sources/TalkieMCP/                        ← feature 06 (07a depends on its binary)
  main.swift                              ← stdio server bootstrap; flag parse (--read-only, --transport)
  TalkieStoreReader.swift                 ← file-snapshot readers (meetings/dictionary/history/brief)
  GraphSnapshotReader.swift               ← reads entities.json/commitments.json (feature 05 output)
  Tools.swift                             ← tool registration + handlers (the 7 tools, §4.1)
  AppPaths.swift                          ← SHARED copy/symlink of Sources/Talkie/AppPaths.swift

Sources/TalkieConnector/                  ← feature 07b (networked, separate target)
  main.swift                              ← --transport http bootstrap; binds 127.0.0.1
  HTTPTransport.swift                     ← Streamable-HTTP transport (SDK provides; thin glue)
  OAuth.swift                             ← OAuth 2.1 + PKCE(S256); /.well-known + DCR/CIMD
  ConsentGate.swift                       ← refuses to serve unless explicit opt-in flag present

packaging/mcpb/
  manifest.json                           ← the v0.3 manifest (§4.1)
  icon.png                                ← the macaw
  README.md                               ← incl. Privacy Policy section (required for local)

docs/CONNECTOR.md                         ← user docs: install .mcpb; add as custom connector
PRIVACY.md                                ← stable privacy-policy URL target (required)
scripts/build_connector.sh               ← build+sign binary, mcpb validate/pack/sign
```

**Sketched types (Swift 6, matching house conventions):**

```swift
// TalkieMCP/TalkieStoreReader.swift — a Sendable, read-mostly file reader.
// Mirrors ProjectIndexSnapshot/ContextGraphSnapshot: immutable value read model.
struct TalkieStoreReader: Sendable {
    let supportDir: URL
    let meetingsDir: URL

    func meetings() throws -> [MeetingRecord]          // decodes meetings.json (+ .md fallback)
    func meeting(id: String) throws -> MeetingRecord?
    func brief() throws -> String?                     // context_summary.json → .summary
    func dictionary() throws -> DictionarySnapshot
    func appendDictionaryTerm(_ term: String) throws   // ONLY write; atomic; gated by flag
}

// A tiny decode-only mirror of Meeting (do NOT import the app target).
struct MeetingRecord: Codable, Sendable {
    var id: String; var title: String; var startUnix: Double; var durationSec: Double
    var transcript: String; var summary: String
    var participants: [String]?; var source: String?; var fileName: String
}

// TalkieMCP/Tools.swift — registration is data-driven so the manifest stays in sync.
enum TalkieTools {
    static func register(on server: Server, reader: TalkieStoreReader,
                         graph: GraphSnapshotReader?, allowWrite: Bool) async
}

// TalkieConnector/ConsentGate.swift — the structural opt-in (feature 15 alignment).
struct ConsentGate: Sendable {
    /// Refuses to start the HTTP transport unless the user flipped the explicit
    /// opt-in (a file/env set by the app's privacy panel). Default: refuse.
    static func assertOptedIn() throws
}
```

**No changes to the core `Talkie` target's behavior** are required for 7a (it is
pure packaging around 06). 7b adds (in 15's connected flavor only) a Settings
affordance that writes the opt-in flag and shows the consent/disclosure copy.

---

## 6. Data model & persistence

07 introduces **no new persistent app data** for 7a — it is a reader. Specifics:

- **Reads** (read-mostly, file-snapshot, never holds an app lock):
  `~/Library/Application Support/Talkie/{meetings.json, dictionary.json, history.json,
  context_summary.json, graph/entities.json, graph/commitments.json}` and
  `~/Talkie Meetings/*.md`. Formats are exactly as in `_CURRENT_STATE.md §3` and §1.4
  of the unification doc; decode is failure-tolerant + optional-field tolerant so a
  newer app schema never breaks an older connector binary and vice-versa.
- **Single write path:** `add_dictionary_term` appends to `dictionary.json` via an
  **atomic** read-modify-write (load → de-dup against `vocabulary` → write `.atomic`),
  honoring the existing `{vocabulary,replacements}` shape and the `talkie→Talkie`
  seed. It is gated by `allow_dictionary_write` (default off). The app tolerates an
  externally-appended term on next load (it already failure-tolerant-decodes).
- **7b** persists only: the **opt-in flag** (a file in `supportDirectory()`, e.g.
  `connector_optin.json` `{enabled, enabledAtUnix, scope}`) and, if hosted OAuth is
  used, **OAuth client metadata in the Keychain** (never on disk in plaintext). No
  user content is ever stored by any server we run.
- **Back-compat / migration:** none needed (additive). The connector binary is
  versioned (`manifest.version`); Claude Desktop auto-updates `.mcpb`s. The binary
  tolerates the pre-05 world (no `graph/` dir → graph tools return "context graph not
  built yet" instead of erroring).

---

## 7. Unification contract (what 07 EXPOSES / CONSUMES)

Per `_UNIFICATION.md §6/07` and §3/§5:

**07 EXPOSES:**
- **(7a)** a one-click on-device `.mcpb`/DXT bundle wrapping the 06 server —
  *recommended first, stays on device*. This is the canonical "expose the brain to a
  local agent" surface.
- **(7b)** a remote-connector design: a user-run local Streamable-HTTP endpoint +
  OAuth, walled in `TalkieConnector`, plus the directory-submission playbook.
- The **packaging contract**: the manifest's tool list is the published, stable
  surface; downstream features (06's tools, 19's `search`) appear here unchanged.

**07 CONSUMES:**
- **Feature 06** — the local MCP server (the binary 7a ships, the tool surface 7b
  re-exposes). 07 must not fork 06's tools; it packages/transports them. **06 before
  07** (sequencing decision, §5 of unification).
- **Feature 05** — `ContextGraphSnapshot`'s on-disk projection
  (`entities.json`/`commitments.json`) for `lookup_entity` / `list_commitments`.
  Consumed **read-only via a file snapshot**, NOT by importing `ContextGraphStore`
  (the §3 rule: MCP is a peer reader, never a writer, of the graph). Degrades when
  05 is absent.
- **Feature 15** — the `TalkieBridge`/connected build flavor + the `requiresNetwork`
  enforcement wall. 7b's networked target compiles ONLY into the connected flavor and
  `ConsentGate` refuses to serve without the opt-in. 07 must not introduce a network
  entitlement into the default build.
- **Feature 19** — its `search` API backs the `search` tool (blended ranking +
  provenance snippets). Until 19 lands, `search` falls back to keyword grep over
  meeting `.md` + history.

**The boundary 07 must honor (verbatim intent from §3):** *"`Talkie` (core) must
never import anything from `TalkieBridge`/`TalkieConnector`."* 07's networked code is
injected/absent at the composition root, behind a feature flag + consent. The
`.mcpb` binary is built from `TalkieMCP` only (no network symbols).

---

## 8. UI / UX

07a needs **almost no in-app UI** — the install experience lives in Claude Desktop.
What Talkie adds, on-brand (`DesignSystem.swift` v2 tokens; `BRAND.md` philosophy —
warm, honest, calm, one accent per view, `MarkdownText` for any rendered copy):

- **A "Connect to Claude" row** in `SettingsHome` (`SettingsView.swift:399-476`),
  pushing a focused `SubPage` (`:479-497`) — matching the existing index-of-rows
  pattern so no screen floods the user. Eyebrow + a short serif heading + honest
  second-person body. Contents:
  - **7a card:** "One-click connector for Claude Desktop. Runs on your Mac. Nothing
    leaves your machine." A primary action (one accent, `Theme.coral` = blue v2) →
    **Reveal `.mcpb` in Finder** (the bundle ships beside the app) or **Open
    download page**. A `Show me how` disclosure with the 3 install steps + the
    macaw icon, reusing the onboarding keycap/step visuals.
  - **A read-only tool list** (FlowLayout chips, `DesignSystem.swift` `FlowLayout`):
    the 7 tools, each a chip; the one write tool wears a coral `sparkles`-style badge
    exactly like learned dictionary rules do (`SettingsView.swift:634-721`) and a
    toggle "Allow Claude to add dictionary terms" (default off) that writes the
    `user_config` hint / a local guard the binary also checks.
- **7b (connected flavor only):** a clearly-labeled **"Advanced: remote connector
  (off by default)"** sub-section behind a disclosure, with:
  - the consent/disclosure copy (§10) rendered via `MarkdownText`,
  - an explicit **toggle** (default off) that is the opt-in flag,
  - a **provenance-style "what Claude could read" list** (reusing the graph's
    provenance idea, `_UNIFICATION.md §1.3`) — honest, never overstated,
  - a **Stop endpoint** button and a persistent indicator while the endpoint is live
    (mirrors the meeting "recording" indicator requirement in `MEETING_MODE.md`).
- **No HUD changes.** The HUD stays dictation-only.

Copy follows `BRAND.md § "Plain, warm, second person"` and the "never invent
metrics" rule — e.g. "Talkie can read your meetings and dictionary locally," not
"trusted by millions."

---

## 9. Permissions / entitlements / Info.plist

**7a — none new for the *app*.** The `.mcpb` binary runs as a Claude-Desktop child
process; it reads files in the user's home (`~/Talkie Meetings/` is deliberately not
TCC-protected, `AppPaths.swift:15-16`; `~/Library/Application Support/Talkie/` is the
app's own container-adjacent dir). Notes:
- **The MCP binary is NOT sandboxed** (the official Swift SDK notes stdio servers run
  as spawned processes; the binary needs plain file read in `$HOME`). It is **signed
  + notarized** (reuse `notarize.sh` → Developer ID + Hardened Runtime) so Gatekeeper
  passes and `mcpb sign` can attach the bundle signature.
- **No entitlement is added to the core `Talkie` app** for 7a. The default build's
  entitlement set stays exactly `com.apple.security.device.audio-input`
  (`_CURRENT_STATE.md §6`) — the invariant holds.
- **No new TCC prompt** in the common case. If a future store path moves under
  `~/Documents`/`~/Desktop` (TCC-protected), the connector would trigger a one-time
  Files-and-Folders prompt against *Claude Desktop* — another reason the data lives
  in the un-protected `~/Talkie Meetings/`.

**7b — network entitlements, connected flavor ONLY (feature 15 owns this):**
`com.apple.security.network.server` (to bind the local HTTP listener) and possibly
`network.client`. These are **absent from the default sandboxed build**. The
`TalkieConnector` target is the only one that links a network/HTTP transport.
`ConsentGate.assertOptedIn()` is a runtime backstop on top of the build-time wall.

---

## 10. Privacy posture

**This feature is where the zero-network promise is most at risk; it is designed to
keep it provably honest.**

**7a — preserves zero-network, absolutely.** The `.mcpb` binary makes **no network
calls** (enforced at build time: `TalkieMCP` does not depend on any URL/HTTP/network
product; a CI check greps the linked symbols for `URLSession`/`Network`/`nw_` and
fails the build if present — the same kind of grep `_CURRENT_STATE.md §0` already
runs over `Sources/`). Data flows *only* between local files and the local Claude
Desktop process over stdio. **What leaves the device: nothing.** The required local
Privacy Policy (README section + `privacy_policies` URL) states exactly this.

**7b — network is required, so it is OFF by default, opt-in, disclosed, and
architecturally separated** (the four §4.1 unification rules):
- **OFF by default:** absent from the default build entirely (no module, no
  entitlement). `ConsentGate` refuses to serve even in the connected flavor unless
  the user flipped the explicit opt-in.
- **Deliberate user action to enable:** the user must (1) run the connected build,
  (2) toggle the opt-in in Settings, (3) start the local endpoint, (4) start their
  own tunnel, (5) add the connector + complete OAuth in Claude. Five intentional
  steps; nothing automatic.
- **Discloses exactly what is sent and when:** *what* = only the results of tool
  calls the user's Claude session triggers (a meeting's text, a brief, a
  commitment), each call logged; *when* = only while the endpoint + tunnel are
  running and Claude is connected. The Settings panel lists the readable surfaces and
  shows a persistent "endpoint live" indicator. **Provenance (05) is the honest
  ledger** behind "here's what Claude could see."
- **Architecturally separated:** `TalkieConnector` is a distinct target, the only one
  importing a network/HTTP stack, compiled only into the labeled connected flavor
  (feature 15). Core never imports it.
- **No Talkie-operated data plane.** The remote design is a *user-run* local endpoint
  + *user-controlled* tunnel. We never host a server that holds user content. (If a
  directory listing later needs a hosted OAuth metadata endpoint, it holds **only**
  OAuth registration data, never user content — and that distinction is stated in the
  privacy policy.)

**Data the connector can never reach** (state it explicitly for trust): live audio,
the microphone, anything not already written to the on-disk stores, and any other
app's data. The connector is strictly a reader of files Talkie already wrote.

---

## 11. Open-source genericity

- **No hardcoded personal stack.** 7a wraps the *generic* local server; it works for
  any Talkie user with zero third-party app. The `user_config` directory pickers
  default to the standard paths but are user-overridable, so a fork or a relocated
  data folder needs no code change. Nothing about Obsidian/Claude-Code/a specific
  editor is assumed — Claude Desktop is the host, and even that is swappable (the
  same binary serves any MCP-capable client over stdio, and any custom-connector
  client over HTTP).
- **Zero-config default:** download `.mcpb` → double-click → it finds the standard
  Talkie paths → works. No account, no key, no network.
- **Community extension points:** (a) the manifest is data; adding a tool is editing
  06's `Tools.swift` + the `tools` array; (b) because the binary speaks plain MCP
  stdio, any MCP client (not just Claude) can use it — the OSS audience isn't locked
  to Anthropic; (c) the `TalkieConnector` HTTP shell is the template for any
  community remote-host recipe (Cloudflare Tunnel / Tailscale Funnel docs in
  `docs/CONNECTOR.md`), none of which we have to operate.
- **Floor caveat:** the binary itself only needs file IO + the MCP SDK, so it is NOT
  bound to macOS 26 / Apple Silicon the way the app is — it could run on older macOS
  or even Linux against copied data, widening the OSS reach (a nice side effect of
  keeping the server a pure reader).

---

## 12. Risks, edge cases, failure modes

| Risk / edge case | Mitigation / graceful degradation |
|---|---|
| **06/05 not built yet** | 7a-MVP ships against today's on-disk data (meetings, dictionary, history, brief). Graph tools return a clear "context graph not built yet" message rather than failing. |
| **`.mcpb` spec churn** (renamed `.dxt`→`.mcpb` late 2025; manifest at v0.3) | Pin `@anthropic-ai/mcpb` CLI version in CI; `mcpb validate` in CI; re-verify manifest_version before each release. |
| **Unsigned/unnotarized binary blocked by Gatekeeper** | Reuse `notarize.sh` (Developer ID + Hardened Runtime + staple) for the binary; `mcpb sign` the bundle. Document the first-run flow. |
| **Stale read** (app writing while connector reads) | Atomic writes + failure-tolerant decode (house style). Connector re-reads per call; no long-lived cache. The one write is an atomic append the app tolerates. |
| **`add_dictionary_term` abuse / unwanted writes** | Default off (`allow_dictionary_write=false`); binary double-checks the flag; de-dups; `destructiveHint:false` but still a write — the only one. |
| **7b: directory submission needs a Team/Enterprise org + ongoing review** | Don't gate the capability on the directory. Ship "add as custom connector by URL" first (works on all tiers incl. Free). Pursue the listing only when a hosted-OAuth story justifies the review burden. |
| **7b: privacy policy missing → immediate rejection** | `PRIVACY.md` is a required deliverable, written before any submission; both README section (local) and a stable URL (remote). |
| **7b: a user exposes their endpoint insecurely** | Default-deny (`ConsentGate`); bind `127.0.0.1` only; OAuth 2.1 + PKCE mandatory; `docs/CONNECTOR.md` prescribes the tunnel options and warns against naked port-forwarding; persistent "endpoint live" indicator. |
| **OAuth complexity** ("the most common stumbling block" per the docs) | Use DCR/CIMD per the current spec; register `https://claude.ai/api/mcp/auth_callback`; test against Claude's auth reference, not the generic MCP spec. |
| **Tool result > 150k chars / 300s timeout** (Claude.ai/Desktop limits) | Paginate `list_meetings`/`search`; `get_meeting` truncates very long transcripts with a note + offset param; keep handlers fast (file reads, no model calls). |
| **App not installed / paths empty** | Tools return empty lists with an honest message; install card in `docs/CONNECTOR.md` explains Talkie must have produced data first. |

---

## 13. Testing & verification

- **Unit (new test target — the repo has none today, `_CURRENT_STATE.md §8`):**
  `TalkieStoreReader` decoding against fixture `meetings.json`/`dictionary.json`
  (including pre-Phase-2 notes without `participants`/`source`, and a pre-05 world
  with no `graph/`); `appendDictionaryTerm` atomicity + de-dup + flag-gating;
  `GraphSnapshotReader` tolerance of a missing file.
- **MCP protocol test:** drive `talkie-mcp` over stdio with a scripted MCP client
  (the SDK's client side) — assert `tools/list` matches the manifest, each tool
  returns well-formed content, `add_dictionary_term` refuses when the flag is off.
- **`mcpb validate`** in CI (manifest conformance) + a build-time **no-network grep**
  over the linked `TalkieMCP` binary (fails if `URLSession`/`nw_`/`Network` symbols
  appear) — the structural privacy proof.
- **Manual / the `/run` path:** build the `.mcpb`, install into Claude Desktop, and
  drive the real flows: "list my meetings," "summarize the last one," "what's in my
  dictionary," "add 'Coralate' to my dictionary" (with the toggle on/off). Confirm in
  Activity Monitor / Little Snitch that the binary opens **no** network connections.
- **7b manual:** run `talkie-mcp --transport http`, expose via a tunnel, add as a
  custom connector by URL in a Pro account, complete OAuth, verify a tool call
  round-trips and the "endpoint live" indicator shows; verify the **default
  (non-connected) build cannot even start the HTTP endpoint** (build-time absence +
  `ConsentGate`).
- **Privacy regression:** the same `grep -rniE "URLSession|http://|https://"` that
  `_CURRENT_STATE.md §0` runs must still return nothing over the **core `Talkie`**
  target (network code is allowed ONLY under `Sources/TalkieConnector/`).

---

## 14. Effort & phasing

| Sub-step | Size | Notes |
|---|---|---|
| **0. Prereq: feature 06 (local MCP server)** | **M** | Not 07's deliverable but 07a's hard dependency; do first. |
| **7a-MVP: `.mcpb` packaging of 06** | **S** | manifest.json + icon + README/Privacy + `build_connector.sh` (sign/notarize/`mcpb pack`). The bulk is CI plumbing. |
| **7a: in-app "Connect to Claude" Settings card** | **S** | Reveal-in-Finder + install steps + tool chips + the write toggle. Pure SwiftUI, reuses existing patterns. |
| **7a: test target + no-network grep + `mcpb validate` in CI** | **S–M** | First tests in the repo; sets up the harness 19/06 reuse. |
| **7b: `TalkieConnector` target — Streamable-HTTP transport** | **M** | SDK provides the transport; glue + `127.0.0.1` bind + ConsentGate. |
| **7b: OAuth 2.1 + PKCE + DCR/CIMD** | **M–L** | "The most common stumbling block." Test against Claude's auth reference. |
| **7b: connected-flavor wiring (needs feature 15)** | **M** | Build flavor, entitlements, opt-in flag, consent UI. Blocked on 15. |
| **7b: directory submission** | **M** (mostly non-eng) | Privacy policy, listing copy, Team/Enterprise submitter, review cycle. Defer. |

**MVP slice (ship this):** 7a-MVP + the Settings card + tests, on top of 06. That
delivers the headline value (one-click, on-device, zero-network connector) and the
honest privacy story, with no network code anywhere.

**Full feature:** add 7b's custom-connector-by-URL path (after 15), then the
directory listing last.

---

## 15. Dependencies & interactions

- **Needs (hard):** **06** (the local MCP server it packages/transports — *06 before
  07*), **05** (graph projection for the richest tools; degrades without it), **15**
  (the network wall + connected build flavor for any of 7b). Introduces the **first
  external SwiftPM dependency** (`modelcontextprotocol/swift-sdk`) and the
  **multi-target** structure (`_UNIFICATION.md §3`).
- **Enables:** **09** cross-surface ("email Sarah the action items from my last
  meeting") becomes usable *from inside Claude* via the connector, not just in-app;
  the connector is how external agents reach the moat.
- **Consumes (soft):** **19** (`search` tool), **01/02** (richer meeting transcripts
  + fused notes make `get_meeting`/`search` results better — purely additive),
  **18** (the Claude bridge is a *sibling* networked module under the same §3 wall;
  07b and 18 should share the `TalkieConnector`/`TalkieBridge` boundary and the 15
  consent plumbing, not duplicate it).
- **Overlaps to coordinate:** 07b, 18, and 16 (Sparkle update check) are the three
  networked features; all must respect 15's wall and the "off by default, disclosed,
  separate module" rule. Agree the single opt-in/consent surface (one privacy panel,
  not three) so the user sees one honest network ledger.

---

## Sources (verified 2026-06-14)

- [modelcontextprotocol/mcpb — MANIFEST.md (.mcpb v0.3 spec)](https://github.com/modelcontextprotocol/mcpb/blob/main/MANIFEST.md)
- [modelcontextprotocol/mcpb — toolchain (init/pack/sign/validate, binary servers, install)](https://github.com/modelcontextprotocol/mcpb)
- [MCP blog — Adopting the .mcpb format (.dxt→.mcpb rename)](https://blog.modelcontextprotocol.io/posts/2025-11-20-adopting-mcpb/)
- [Anthropic engineering — Desktop Extensions](https://www.anthropic.com/engineering/desktop-extensions)
- [Claude docs — Building custom remote MCP connectors (Streamable HTTP, OAuth, limits)](https://claude.com/docs/connectors/building)
- [Claude docs — Submitting to the Connectors Directory (fields, caps, review)](https://claude.com/docs/connectors/building/submission)
- [Claude Help — Get started with custom connectors using remote MCP (add-by-URL, tiers)](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp)
- [Anthropic Software Directory Policy (acceptance/prohibited/data handling)](https://support.claude.com/en/articles/13145358-anthropic-software-directory-policy)
- [modelcontextprotocol/swift-sdk (official Swift MCP SDK, StdioTransport, Swift 6)](https://github.com/modelcontextprotocol/swift-sdk)
- [sunpeak — Connector Directory submission requirements (May 2026)](https://sunpeak.ai/blogs/claude-connector-directory-submission/)
- [sunpeak — SSE → Streamable HTTP migration (May 2026)](https://sunpeak.ai/blogs/claude-connector-sse-to-streamable-http/)
- [sunpeak — Connector OAuth authentication (May 2026)](https://sunpeak.ai/blogs/claude-connector-oauth-authentication/)
