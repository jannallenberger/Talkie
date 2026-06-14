# 18 — Optional opt-in Claude bridge (cloud for heavy lifts)

> **Feature contract source:** `_UNIFICATION.md` §6/18 and §2.2 (the `Summarizer` protocol),
> §3 (the `TalkieBridge` module boundary), §4.1 (the privacy/sandbox model).
> **Ground truth:** `_CURRENT_STATE.md` (HEAD `261ed66`; the app has **zero** network code today).
> **Floor:** macOS 26.0, Apple Silicon, Swift 6 strict concurrency (`.v6`).
> **External facts verified June 2026** (see §15 footnotes): there is **no official Anthropic Swift SDK** —
> raw `URLSession` is the correct path and preserves "zero dependencies."

---

## 1. Summary

An **OFF-by-default, opt-in, separately-compiled** `TalkieBridge` module that adds one networked
`Summarizer` implementation — `ClaudeBridge` — so jobs the on-device Foundation Model can't do well
(long-meeting map-reduce summaries, agentic follow-ups, rich Q&A over the context graph) can route to
the Claude API, behind a Keychain-stored key, a deliberate consent gate, and a per-call data-disclosure
surface; the core app stays 100% on-device and the network entitlement is absent from the default build.

## 2. Why it matters

The strategic thesis is **one private brain fed by two voice surfaces**. The on-device Foundation Model
(`SystemLanguageModel.default`) is excellent for sentence-scale cleanup but is the binding constraint on
exactly the moments that *sell* the product:

- **Long meetings.** `MeetingSummarizer.summarize` hard-caps input at 8000 chars (`Meeting.swift:36`) and
  silently truncates anything longer — a 90-minute call loses ~80% of its transcript before the model sees
  it. This is the single most visible quality gap versus Granola.
- **Agentic follow-ups** (feature 09's headline demo — "email Sarah the action items from my last
  meeting") need multi-step reasoning + drafting that the small on-device model does poorly.
- **Rich graph Q&A** (feature 19/06) over the whole `ContextGraph` benefits from a frontier model's
  recall and synthesis.

The disruption is **not** "we added a cloud model" — every competitor has one. The disruption is that
Talkie is the **only** product where cloud is a *strictly optional accelerator on top of a provably-local
default*. Wispr Flow and Granola are cloud companies: their architecture sends your voice to a server by
construction. Talkie ships zero-network by default and lets the *user* decide, per use, whether a specific
heavy lift is worth a round-trip — with the `ContextGraph`'s provenance (`_UNIFICATION.md` §1.3) showing
*exactly* what bytes would leave. That is a privacy posture a subscription competitor structurally cannot
copy, and it's the honest version of "best of both worlds": local-first, cloud-when-you-say-so.

## 3. Current state in the code

**Everything below is on-device today; none of it is networked.** This feature adds the *first* network
code in the project, so the "current state" is mostly the seams it must plug into without disturbing them.

- **`CleanupEngine.swift`** — `actor CleanupEngine` (`:194`) wraps `SystemLanguageModel.default`
  (FoundationModels). `isAvailable` (`:196-199`) and `unavailableMessage` (`:202-213`) map the
  `.availability` cases. The generation core is `generate(instructions:raw:)` (`:225-239`):
  `LanguageModelSession(instructions:)` + `GenerationOptions(sampling: .greedy, temperature: 0.1)` +
  `session.respond(to:options:)`, then `sanitize(_:)` (`:243-259`) strips preambles/quotes. **This is the
  exact `(instructions, input) -> String?` shape the `Summarizer` protocol generalizes** (`_UNIFICATION.md`
  §2.2). `CleanupLevel` (`:5-80`) and `CleanupStyle` (`:85-189`) own their own prompt strings — the protocol
  must NOT absorb prompts, only the generation call.
- **`ContextSummary.swift`** — `actor ContextSummaryEngine` (`:7`); same FoundationModels call pattern
  (`:43-54`), corpus capped at 6000 chars / 40 entries (`:27,36`). `ContextSummaryStore` (`:60`) persists
  the Brief to `context_summary.json`.
- **`Meeting.swift`** — `actor MeetingSummarizer` (`:19`); same pattern (`:37-48`); the **8000-char cap +
  the explicit comment** "long meetings will get map-reduce summarization later" (`:35-36`) is the single
  best concrete justification for this whole feature. `MeetingStore.writeMarkdown` (`:88-109`) is the durable
  copy; on main `source:` is hardcoded `talkie (mic-only)` (`:95`) — the far-end branch makes it dynamic.
- **`AppDelegate.swift`** — the composition root. Stores are created as stored properties
  (`dictionary`/`history`/`stats`/`appUsage`/`activity`/`projectIndex`/`contextSummary`/`meetingStore`,
  `:7-15`); engines are `private let cleanup = CleanupEngine()` (`:22`) and the shared
  `TranscriptionEngine`/`MeetingRecorder` built in `applicationDidFinishLaunching` (`:60-61`). The cleanup
  call site is `endDictation()` `:473-488` (`cleanupEngine.clean(text, style:)`/`.clean(text, level:)`).
- **`Resources/talkie.entitlements`** — **only** `com.apple.security.device.audio-input`. **No
  `com.apple.security.network.client`.** This is the verified zero-network invariant.
- **`Package.swift`** — single `.executableTarget` `Talkie`, `swift-tools-version:6.0`, **no external
  dependencies**, `.swiftLanguageMode(.v6)`.

**Honestly: nothing of this feature exists yet.** No `Summarizer` protocol, no `TalkieBridge` target, no
network code, no Keychain usage, no consent UI, no second build flavor. Feature 18 also **depends on** two
not-yet-built things: the `Summarizer` protocol (Tier 0 of `_UNIFICATION.md` §5) and the `ContextGraph`
(feature 05) for the "rich Q&A" use. The bridge can ship *before* 05 (summary/follow-up lifts don't need
the graph), but its full value lands after.

## 4. Design & approach

### 4.1 The seam: `Summarizer` protocol (shared, Tier 0 — built by/with this feature)

Per `_UNIFICATION.md` §2.2, all four FoundationModels actors call *through* one protocol. Define it in
`Sources/Talkie/Protocols/Summarizer.swift` (core, always compiled). The on-device default `OnDeviceLLM`
wraps today's exact `CleanupEngine.generate` body. `ClaudeBridge` (in `TalkieBridge`) is the networked impl.

```swift
public protocol Summarizer: Sendable {
    static var isAvailable: Bool { get }
    var requiresNetwork: Bool { get }     // false = on-device; gates the sandbox/consent wall (§2.1/4.1)
    /// One constrained generation. `instructions` = system prompt; `input` = user text.
    /// Impl pins determinism (greedy/low-temp like CleanupEngine). Returns nil on failure.
    func generate(instructions: String, input: String) async -> String?
}
```

`CleanupEngine`, `MeetingSummarizer`, `ContextSummaryEngine`, and (later) the graph extractor each hold
`let llm: any Summarizer` and call `llm.generate(...)`, keeping their own prompt strings and their own
`sanitize`. Default-inject `OnDeviceLLM()` so behavior is byte-identical to today.

> **Scope note:** conforming the four actors to `Summarizer` is its own low-risk refactor (Tier 0). This
> plan *requires* the protocol to exist and *adds* `ClaudeBridge`; if 18 lands first it may introduce the
> protocol, but it must not fork a parallel one.

### 4.2 The networked impl: `ClaudeBridge: Summarizer`

A `final class ClaudeBridge: Summarizer, @unchecked Sendable` (or an `actor`) in the **separate
`TalkieBridge` module**. `requiresNetwork == true`. It is the **only** code in the repo allowed to
construct `URLSession` / touch the network.

- **Transport: raw `URLSession`, not an SDK.** There is no official Anthropic Swift SDK (verified June
  2026 — see §15); the community packages are unofficial and would break "zero dependencies" + the strict
  module-isolation goal. A hand-rolled `POST https://api.anthropic.com/v1/messages` is ~120 lines and keeps
  `TalkieBridge` dependency-free.
- **Request shape** (current API, verified): headers `x-api-key: <key>`, `anthropic-version: 2023-06-01`,
  `content-type: application/json`. Body:

```jsonc
{
  "model": "claude-opus-4-8",          // default; see §4.5 for model choice
  "max_tokens": 16000,
  "thinking": { "type": "adaptive" },  // adaptive only on Opus 4.8 — budget_tokens 400s
  "system": "<the Summarizer `instructions`>",
  "messages": [{ "role": "user", "content": "<the `input`>" }]
}
```

- **Streaming:** add `"stream": true` and consume SSE for any call that may produce long output
  (map-reduce reduce step, long follow-up drafts) — the claude-api skill notes non-streaming requests with
  large `max_tokens` risk HTTP timeouts. Parse `content_block_delta` → `text_delta` lines; accumulate. A
  simple line-buffered SSE reader over `URLSession.bytes(for:)` is sufficient (no dependency).
- **Determinism parity:** Opus 4.8 removed `temperature`/`top_p`/`top_k` (they 400). To match
  `CleanupEngine`'s deterministic intent, rely on `output_config: { effort: "low" }` for cleanup-style lifts
  and a tightened system prompt; do **not** send `temperature`.
- **Errors → graceful nil.** Map `URLError` (offline), 401 (bad key), 429 (rate limit, surface
  `retry-after`), 5xx/529 (overloaded), and timeouts to a typed `BridgeError`; `generate` returns `nil` so
  every caller **automatically falls back to on-device** (or to truncation, exactly as today). The bridge is
  an *accelerator*, never a hard dependency.

```swift
public actor ClaudeBridge: Summarizer {
    public static var isAvailable: Bool { true }          // availability == "key present & enabled"; see §4.4
    public nonisolated var requiresNetwork: Bool { true }

    private let keyProvider: @Sendable () async -> String?  // Keychain read, injected
    private let model: String
    private let disclose: @Sendable (BridgeCall) -> Void     // logs what was sent, for the audit panel
    private let session: URLSession

    public init(model: String = "claude-opus-4-8",
                keyProvider: @escaping @Sendable () async -> String?,
                disclose: @escaping @Sendable (BridgeCall) -> Void) { … }

    public func generate(instructions: String, input: String) async -> String? {
        guard let key = await keyProvider() else { return nil }    // not configured → fall back
        disclose(BridgeCall(model: model, systemChars: instructions.count, inputChars: input.count,
                            at: Date()))                            // record BEFORE the wire
        do { return try await postMessage(key: key, system: instructions, user: input) }
        catch { return nil }                                       // any failure → caller falls back
    }
}

public enum BridgeError: Error, Sendable { case notConfigured, unauthorized, rateLimited(retryAfter: Int?),
                                                 overloaded, offline, badResponse, decoding }
public struct BridgeCall: Sendable { public let model: String; public let systemChars: Int
                                     public let inputChars: Int; public let at: Date }
```

### 4.3 Map-reduce helper (lives ABOVE the protocol, in core)

Per `_UNIFICATION.md` §2.2, map-reduce is a helper that chains `generate` calls so it works with **either**
backend. Put it in `Sources/Talkie/Summarization/MapReduceSummarizer.swift` (core):

```
func summarizeLong(_ transcript: String, using llm: any Summarizer,
                   chunkChars: Int = 6000, mapInstr: String, reduceInstr: String) async -> String?
    1. split transcript into ~chunkChars windows on sentence/turn boundaries
    2. map:    for each chunk → llm.generate(instructions: mapInstr, input: chunk)   (partial summaries)
    3. reduce: llm.generate(instructions: reduceInstr, input: joined-partials)        (final summary)
    4. if any map step returns nil → degrade: on the on-device backend, fall back to the single 8000-char
       pass (today's behavior); on the bridge, the whole call already nil'd → caller falls back to on-device.
```

`MeetingSummarizer.summarize` becomes: if `transcript.count <= 8000` → one `generate`; else →
`summarizeLong`. This fixes the truncation TODO (`Meeting.swift:36`) for **both** backends; the cloud path
just makes the long case dramatically better.

### 4.4 Where the bridge is chosen (composition root + the wall)

`TalkieBridge` is a **separate SwiftPM target** and the core `Talkie` target **never imports it**
(`_UNIFICATION.md` §3 boundary rule). Two build flavors (`_UNIFICATION.md` §4.1, owned by feature 15):

- **`Talkie` (default, sandboxed):** does NOT link `TalkieBridge`, has NO
  `com.apple.security.network.client`. The whole networked module is *absent from the binary*. This is what
  makes "provably zero-network" literally true.
- **`Talkie (Connected)`:** links `TalkieBridge`, adds the network entitlement, conditionally compiled
  behind a `BRIDGE` flag (`#if BRIDGE`).

In `AppDelegate` the active `Summarizer` is resolved at startup behind a guard:

```
let onDevice = OnDeviceLLM()
#if BRIDGE
    let bridge: (any Summarizer)? = (settings.bridgeEnabled && KeychainKey.exists)
        ? ClaudeBridge(model: settings.bridgeModel, keyProvider: { KeychainKey.read() },
                       disclose: { bridgeAudit.record($0) })
        : nil
#else
    let bridge: (any Summarizer)? = nil
#endif
```

Each consumer gets a **policy object** (`SummarizerRouter`) rather than a raw backend, so the *user's*
per-feature choice decides routing:

```swift
struct SummarizerRouter: Sendable {
    let onDevice: any Summarizer
    let cloud: (any Summarizer)?          // nil unless Connected build + enabled + key present
    /// Returns the cloud backend only when the user opted this job-kind into cloud AND it's available;
    /// otherwise on-device. `requiresNetwork == true` backends refuse to exist in the sandboxed flavor.
    func backend(for kind: LiftKind) -> any Summarizer {
        guard let cloud, settings.cloudKinds.contains(kind), cloud.requiresNetwork == false || networkAllowed
        else { return onDevice }
        return cloud
    }
}
enum LiftKind: String, Codable, Sendable, CaseIterable { case dictationCleanup, meetingSummary, brief, followUp, graphQA }
```

`networkAllowed` is feature 15's structural check (entitlement present + consent flipped). Default
`cloudKinds` is **empty** — even in the Connected build, nothing goes to cloud until the user ticks a box.

### 4.5 Model & pricing (current, from the claude-api skill — do not guess at build time, re-verify)

| Lift | Default model | Why | Input $/MTok | Output $/MTok |
|---|---|---|---|---|
| Meeting map-reduce summary | `claude-opus-4-8` | best synthesis; long context (1M) | $5.00 | $25.00 |
| Agentic follow-up (draft email + propose reminder) | `claude-opus-4-8` | reasoning + drafting quality | $5.00 | $25.00 |
| Rich graph Q&A | `claude-opus-4-8` | recall/synthesis | $5.00 | $25.00 |
| (optional) high-volume cleanup | `claude-haiku-4-5` | speed/cost for trivial lifts | $1.00 | $5.00 |

Expose `bridgeModel` as a setting (default `claude-opus-4-8`) with a small picker; show a **live cost
estimate** per call using `messages/count_tokens` (or a local char/4 estimate) so the user sees "~$0.03"
before sending. Use `thinking: {type:"adaptive"}` + `output_config: {effort}` per the skill; **never**
append date suffixes to model ids, **never** send `budget_tokens`/`temperature` on Opus 4.8.

## 5. New & changed files / types

### New (core `Talkie` target)
- `Protocols/Summarizer.swift` — the protocol (§4.1).
- `Backends/OnDeviceLLM.swift` — `actor OnDeviceLLM: Summarizer` wrapping today's `CleanupEngine.generate`
  body (greedy, temp 0.1, `sanitize`). `requiresNetwork = false`.
- `Summarization/MapReduceSummarizer.swift` — backend-agnostic chunk→map→reduce (§4.3).
- `Bridge/SummarizerRouter.swift` — the policy object + `LiftKind` (§4.4). (Core knows the *shape*, not the
  network impl.)
- `Bridge/BridgeAudit.swift` — `@MainActor final class BridgeAuditStore: ObservableObject` holding the
  rolling log of `BridgeCall`s for the disclosure/proof panel; persists to `bridge_audit.json`.
- `Security/KeychainKey.swift` — thin `Keychain` wrapper (`SecItemAdd`/`Copy`/`Delete`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, service `com.coralate.talkie.claude`).

### New (separate `TalkieBridge` target — only present in the Connected flavor)
- `ClaudeBridge.swift` — `actor ClaudeBridge: Summarizer` (§4.2); raw `URLSession` POST + SSE reader.
- `ClaudeBridge+SSE.swift` — line-buffered SSE delta accumulation.
- `BridgeError.swift` — typed errors → caller-side nil + user-facing messages.

### Changed
- `CleanupEngine.swift` — add `let llm: any Summarizer = OnDeviceLLM()`; `generate` delegates to
  `llm.generate` (keep `sanitize` + prompt strings). No behavior change on default build.
- `ContextSummary.swift` — `ContextSummaryEngine` takes an injected `any Summarizer`; `summarize` calls
  through it. (Later the Brief becomes a graph projection — out of scope here.)
- `Meeting.swift` — `MeetingSummarizer` takes an injected `any Summarizer` + uses `MapReduceSummarizer`
  for `> 8000` chars; `writeMarkdown` gains a `source:` value that records cloud assistance honestly
  (e.g. `source: talkie (on-device)` vs `talkie (on-device + Claude API)`), aligning with the far-end
  branch's dynamic `source` field.
- `AppDelegate.swift` — build `SummarizerRouter`, inject it into the engines; `#if BRIDGE` block (§4.4).
- `AppSettings.swift` — new keys: `bridgeEnabled: Bool = false`, `bridgeModel: String = "claude-opus-4-8"`,
  `cloudKinds: Set<LiftKind> = []`, `bridgeNetworkConsentedAtUnix: Double?`.
- `SettingsView.swift` — a new `SubPage` "Claude bridge (cloud)" (§8). Hidden entirely in the sandboxed
  build (`#if BRIDGE`).
- `Package.swift` — add the `TalkieBridge` target + a `Talkie` product variant; `Talkie` core does NOT
  depend on `TalkieBridge` (the Connected executable depends on both).
- `Resources/` — a second entitlements file `talkie-connected.entitlements` adding
  `com.apple.security.network.client`; the default `talkie.entitlements` is untouched.

## 6. Data model & persistence

| What | Where | Format | Notes |
|---|---|---|---|
| API key | **Keychain**, service `com.coralate.talkie.claude` | `SecItem` generic password | NEVER in `UserDefaults`/JSON/files. `…AfterFirstUnlockThisDeviceOnly`. |
| Bridge prefs | `UserDefaults` (`AppSettings`) | scalars + `Set<LiftKind>` (encoded array) | `bridgeEnabled`, `bridgeModel`, `cloudKinds`, consent timestamp. |
| Disclosure log | `~/Library/Application Support/Talkie/bridge_audit.json` | `[BridgeCall]` newest-first, capped (e.g. 500), `.atomic`, failure-tolerant decode | What the bridge sent and when (model, char counts, timestamp) — the honest "here's exactly what left" record. **Stores char counts + lift kind, NOT the content**, so the audit itself never re-persists sensitive text. |
| Meeting `source` | existing `.md` frontmatter + `meetings.json` | string | Becomes "on-device" / "on-device + Claude API". Back-compat: pre-existing notes' `source` decodes as-is (optional field, house style). |

**Migration/back-compat:** all new `AppSettings` keys have safe defaults (`bridgeEnabled=false`,
`cloudKinds=[]`), so an upgrade in-place is silent and stays on-device. The Keychain item is absent until
the user pastes a key. `bridge_audit.json` is created lazily. No existing on-disk format changes shape;
`Meeting`'s `source` was already a string the far-end branch made dynamic.

## 7. Unification contract (per `_UNIFICATION.md` §6/18)

**EXPOSES** (what other features may consume):
- **`ClaudeBridge: Summarizer`** (`requiresNetwork == true`) in `TalkieBridge` — a drop-in for any heavy
  lift (long-meeting map-reduce, agentic follow-ups, rich graph Q&A) that 02/05/09 can route to *through the
  `Summarizer` protocol* without importing the bridge.
- **The consent + data-disclosure UX** and **Keychain key handling** — reused by 07b (remote connector) and
  16 (Sparkle update check) as the canonical "deliberate enable + disclose exactly what is sent" pattern.
- **`BridgeAuditStore`** — feeds 15's privacy/proof panel with the actual record of outbound calls.
- **`MapReduceSummarizer`** (core) — backend-agnostic long-input summarization usable by 02 and the brief.

**CONSUMES** (what it depends on):
- **The `Summarizer` protocol** (Tier 0, `_UNIFICATION.md` §2.2) — the drop-in seam. Must NOT fork it.
- **Feature 15's network wall** (`_UNIFICATION.md` §4.1): the two build flavors + the `requiresNetwork`
  enforcement point. `ClaudeBridge` must **refuse to instantiate** in the sandboxed-default flavor
  (it isn't even compiled in) and require a deliberate user enable in the Connected flavor.
- **The personal context graph** (feature 05, `ContextGraphSnapshot`, `_UNIFICATION.md` §1.6) — for the
  "rich Q&A over the context graph" lift, the bridge takes a graph snapshot as `input`. **Crucially, the
  graph's Provenance (§1.3) is the data behind the disclosure panel**: it lets the consent UI show *exactly
  which entities/snippets* a cloud Q&A would expose, "because you said it to Slack on Tuesday." 18 reads the
  graph; it never writes it.

**Honoring the contract:** OFF by default; discloses exactly what is sent and when; lives in the separate
`TalkieBridge` module behind 15's wall; uses accurate current model ids/pricing from the claude-api skill
(do not guess). Aligns with 01's cloud `Diarizer`/`Transcriber` idea (a future
`MeetingTranscriptionBackend` with `requiresNetwork==true` would sit behind the same wall) and 20's backend
protocol.

## 8. UI / UX

A single new Settings `SubPage` — **"Claude bridge (cloud)"** — reached from `SettingsHome`
(`SettingsView.swift:399`), present **only in the Connected build** (`#if BRIDGE`). On-brand per
`DesignSystem.swift` / `BRAND.md` (warm, honest, calm; one accent — `Theme.coral` (now blue) per view;
serif titles via `Font.talkieDisplay`; squircle `.talkieCard()`; whisper shadow; no invented metrics):

1. **Eyebrow + serif title + honest body.** "Cloud is off. Talkie works fully on your Mac. You can let a
   specific job use Anthropic's Claude API for higher quality — you decide which, and you'll always see
   exactly what's sent." (Second person, honest — `BRAND.md` voice.)
2. **The enable gate (the deliberate action, `_UNIFICATION.md` §4.1b).** A prominent disclosure card the
   user must read + a toggle that, on first enable, shows a confirm sheet listing: *what leaves* (the
   transcript/draft text + your system prompt), *where* (api.anthropic.com over TLS), *retention*
   (Anthropic's API default — short retention, not used for training; link out — see §10), *cost* (your
   own API key, billed to you). Flipping it records `bridgeNetworkConsentedAtUnix`.
3. **API key field.** Secure `SecureField`, "Paste your Anthropic API key (sk-ant-…)". Stored in Keychain
   on commit; a "Test" button does one tiny `count_tokens`/ping and reports success/`unauthorized` with
   the brand's calm copy. A "Remove key" button deletes the Keychain item.
4. **Per-job toggles** (the heart of opt-in granularity) — `FlowLayout` of chips, one per `LiftKind`,
   each off by default: "Long meeting summaries", "Agentic follow-ups", "Ask about your context",
   "(High-volume cleanup)". Each chip shows a one-line cost hint ("~$0.02–0.10 / 90-min meeting").
5. **Model picker** — segmented `Opus 4.8` (best) / `Haiku 4.5` (cheap/fast) with the per-MTok prices
   shown honestly (no invented "X% faster").
6. **Disclosure log** — a collapsible list (rendered like `HistorySettings`) of recent `BridgeCall`s:
   "Apr 2, 14:03 — meeting summary → Claude Opus 4.8 — ~7,400 chars sent." This is the proof surface; it
   feeds 15's privacy panel.

**Per-call confirmation (optional, default on for the first N calls):** when a heavy lift is about to go
to cloud, the HUD (reuse `HUD.swift`'s `glassEffect` pill) shows a brief "Sending to Claude…" phase
distinct from "Polishing…" so cloud use is never invisible. For meetings, `MeetingsView`'s
finishing-state copy gains a "Summarizing with Claude…" variant when the bridge is the chosen backend.

No new accent colors, no pure white/black, no fabricated percentiles — matches the v2 tokens.

## 9. Permissions / entitlements / Info.plist

- **Default `Talkie` build: NO CHANGE.** `talkie.entitlements` stays single-entitlement
  (`device.audio-input`); `TalkieBridge` is not linked; no network code in the binary. The zero-network
  invariant is preserved by *construction*.
- **`Talkie (Connected)` build only:** a separate `talkie-connected.entitlements` adds
  `com.apple.security.network.client`. No new TCC prompts (network client needs no user TCC dialog), no
  sandbox file-access changes. No new Info.plist usage strings are required for outbound HTTPS.
- **Notarization:** the Connected flavor signs with the same Developer ID + Hardened Runtime
  (`scripts/notarize.sh`); the added network entitlement is allowed under Hardened Runtime. Two products =
  two notarization runs (feature 16's pipeline handles both).
- **No App Sandbox today** (the app isn't sandboxed — only Hardened Runtime). Feature 15 may add the App
  Sandbox; if so, the Connected flavor needs `network.client` *under* the sandbox too. This plan assumes
  15 defines the exact sandbox shape; 18 just declares it needs outbound HTTPS in the Connected flavor.

## 10. Privacy posture

**The default experience stays provably zero-network.** The networked module is *absent from the default
binary*, the network entitlement is *absent from the default entitlements*, and the policy default is
`cloudKinds = []`. Even in the Connected build, **nothing reaches the network until** (a) the user installs
the Connected build, (b) flips the explicit enable with the confirm sheet, (c) pastes a key, and (d) ticks
a specific job kind. Four deliberate actions.

**Exactly what leaves the device, and when:**
- *What:* for a chosen lift kind, the **text input for that one job** — a meeting transcript, a follow-up
  draft request, or (for graph Q&A) the relevant graph entities/snippets the question touches — plus the
  fixed system prompt. Nothing else: no other dictations, no audio, no full graph, no telemetry.
- *When:* only at the moment that specific job runs *and* its kind is opted in. Each send is recorded in
  `bridge_audit.json` (char count + kind + model + time, not content) and surfaced in the disclosure log.
- *Where:* `https://api.anthropic.com/v1/messages` over TLS, authenticated with the user's own key.

**Retention disclosure (must be accurate; re-verify at build time against Anthropic's commercial privacy
page).** As of the June-2026 research: the Anthropic **API/Developer Platform** default retention is short
(reported as 7-day automatic deletion for standard API logs since Sept 2025), API inputs/outputs are **not
used for model training**, and a **Zero Data Retention** agreement is available to qualifying enterprise
customers. Newer reporting suggests retention windows can vary by model tier — so the consent copy must
**link to** Anthropic's live commercial privacy/data-usage page rather than hard-assert a number, and state
plainly "this is Anthropic's policy for *your own* API key — Talkie sends nothing to its own servers." This
keeps the honest-copy invariant (`BRAND.md`) intact.

**The graph never leaves except through this explicit path** (`_UNIFICATION.md` §4.1) — and Provenance
makes the exposure auditable before the user consents.

## 11. Open-source genericity

- **No hardcoded personal stack.** The bridge talks to the Anthropic API generically; it does not assume
  Jann's Obsidian/Claude-Code setup. The *zero-config default is "no cloud at all"* — the OSS download is
  the sandboxed `Talkie` with no network code, which is the strongest possible default for a privacy tool.
- **The `Summarizer` protocol is the extension point.** A contributor can ship an `OpenAIBridge`,
  `OllamaBridge` (local network!), or `GeminiBridge` as another `Summarizer` in its own module **without
  touching core** — exactly the pluggability `_UNIFICATION.md` §2 mandates. The router's `cloudKinds` and
  model picker generalize; only the per-vendor request shape differs.
- **Keychain + consent UX are vendor-neutral** and reusable by those community backends.
- **Floor caveat:** the on-device default still needs macOS 26 + Apple Silicon (FoundationModels). The
  bridge is, ironically, a *widening* lever — on a Mac where Apple Intelligence is off
  (`CleanupEngine.unavailableMessage`), an opted-in Connected build could still summarize via cloud. Note
  this honestly; it does not change the default's hardware floor.

## 12. Risks, edge cases, failure modes

- **Network wall leak (highest risk).** If core ever `import`s `TalkieBridge`, the invariant breaks. Guard
  with: separate target (compiler-enforced), a CI grep that fails the build if `URLSession`/`http` appears
  in the `Talkie` core target, and feature 15's "no network entitlement in default" check.
- **Key exposure.** Never log the key; never write it to JSON; Keychain only. The audit log stores char
  counts, not content, so it can't leak transcripts either.
- **Offline / 401 / 429 / 5xx / timeout.** All map to `generate → nil → caller falls back to on-device`
  (or to today's truncation for meetings). The user never gets a dead end; worst case is "we used the local
  model instead." Surface a calm one-line HUD/toast on auth failures so a wrong key is discoverable.
- **Cost runaway.** Map-reduce on a 3-hour meeting could be many calls. Mitigate: per-call cost estimate
  shown pre-send, a configurable per-day spend cap (soft, client-side count), and Haiku as the cheap model
  option.
- **Determinism drift.** Cloud output differs from on-device; meetings summarized with Claude read
  differently. Honest `source:` frontmatter records which backend produced each note so the difference is
  never silent.
- **Streaming partials lost on disconnect.** Accumulate incrementally; on mid-stream failure, return nil
  (fall back) rather than a truncated summary.
- **Model id drift.** Pricing/model strings change; the table in §4.5 is a snapshot. Read model id from a
  setting, default to the skill's current `claude-opus-4-8`, and re-verify at release.
- **User pastes a key but never opts a job in.** Correct behavior: still zero cloud traffic — `cloudKinds`
  gates independently of key presence.

## 13. Testing & verification

- **Unit (needs a test target — none exists today; add one):**
  - `OnDeviceLLM` conforms and is byte-identical to old `CleanupEngine` output on a fixed input (golden).
  - `MapReduceSummarizer` chunking: boundary splitting, the `nil`-on-any-map → fallback path (inject a stub
    `Summarizer` that returns nil for chunk 2).
  - `SummarizerRouter.backend(for:)` truth table: cloud only when (Connected build) ∧ enabled ∧ key present
    ∧ kind opted-in ∧ networkAllowed; on-device otherwise.
  - `KeychainKey` round-trip (add/read/delete) on the build machine.
  - `BridgeError` mapping from synthetic `URLResponse` status codes.
- **Bridge integration (gated, manual / opt-in CI with a real key):** one live `count_tokens` ping + one
  small `messages` call asserting `response.model` starts with the requested id and a non-empty completion.
- **Network-wall regression (the important one):** a CI step that builds the **default** flavor and greps
  the linked binary/sources for `URLSession`/`api.anthropic.com` — must find **nothing**. Plus an assertion
  that `talkie.entitlements` contains no `network.client`.
- **Manual / `/run` path:** Connected build → enable bridge → paste key → tick "Long meeting summaries" →
  record a >10-min meeting → confirm the `.md` `source:` reads "on-device + Claude API", the summary covers
  the *whole* transcript (not truncated at 8000 chars), and `bridge_audit.json` has one entry. Then toggle
  airplane mode and re-run → confirm graceful on-device fallback and no crash. Default build → confirm the
  Claude-bridge SubPage is absent and no network entitlement is present.

## 14. Effort & phasing

- **Tier-0 prereq (S–M):** `Summarizer` protocol + `OnDeviceLLM` + conform the 4 actors (no behavior
  change). Cheap now, expensive later (`_UNIFICATION.md` §5 decision #2).
- **MVP slice (M):** `TalkieBridge` target + `ClaudeBridge` (non-streaming first) + Keychain + the
  enable/consent SubPage + **one** lift kind (`meetingSummary`) + `MapReduceSummarizer` + the second build
  flavor/entitlements + the network-wall CI grep. This alone fixes the headline 8000-char truncation gap
  and proves the wall.
- **Full feature (M–L):** SSE streaming; the remaining lift kinds (`followUp` needs feature 09's intent
  layer; `graphQA` needs feature 05); per-call cost estimate + spend cap; disclosure log UI; Haiku option;
  HUD "Sending to Claude…" phase.
- **S add-ons:** model picker, "Test key" button, "Remove key".

Suggested order: protocol → OnDeviceLLM → MapReduce (on-device only, ships value with **zero** network) →
TalkieBridge + Keychain + consent UI + meeting lift → wall CI → streaming → other lifts.

> Note: `MapReduceSummarizer` on the on-device backend is a fully-local win that can ship *before* any
> network code — it fixes the long-meeting truncation TODO without touching the privacy invariant. Land
> that first.

## 15. Dependencies & interactions

- **Needs:** **15** (the network wall + two build flavors + `requiresNetwork` enforcement — build this
  first so the wall is structural); the **`Summarizer` protocol** (Tier 0); **05 ContextGraph** for the
  graph-Q&A lift (the bridge can ship without it for summary/follow-up).
- **Enables / overlaps:** **02** (notes×transcript fusion routes its long-meeting summary through the same
  `Summarizer`, gaining map-reduce + optional cloud for free); **09** (cross-surface follow-ups — the
  `followUp` lift is 09's drafting step on the bridge); **19** (graph Q&A / search synthesis); **01** (a
  future cloud `MeetingTranscriptionBackend` sits behind the same wall — same consent pattern); **07b**
  (remote connector reuses this consent/Keychain/disclosure UX); **16** (Sparkle update check reuses the
  "opt-in network, disclosed" pattern). **20** (a non-Apple on-device backend) is the *other* answer to the
  hardware floor; this feature is the cloud answer.

---

### External-fact footnotes (verified June 2026; re-verify at implementation)
- **No official Anthropic Swift SDK** exists; only unofficial community packages
  (tthew/anthropic-swift-sdk, GeorgeLyon/SwiftClaude, AnthropicKit) and Apple's Foundation Models /
  Xcode 26.3 Claude Agent SDK integration. → raw `URLSession` chosen to keep zero deps + module isolation.
- **API shape:** `POST https://api.anthropic.com/v1/messages`, headers `x-api-key` + `anthropic-version:
  2023-06-01` + `content-type: application/json`; SSE streaming via `"stream": true` →
  `content_block_delta`/`text_delta`. (claude-api skill + web confirm.)
- **Models/pricing (claude-api skill, cached 2026-05-26):** Opus 4.8 `claude-opus-4-8` $5/$25 per MTok,
  1M context; Haiku 4.5 `claude-haiku-4-5` $1/$5. Opus 4.8 uses adaptive thinking only
  (`thinking:{type:"adaptive"}`); `budget_tokens`/`temperature`/`top_p`/`top_k` 400. Use exact id strings —
  no date suffixes.
- **Data retention/training:** API default retention short (reported 7-day auto-delete since Sept 2025);
  API inputs/outputs **not** used for training; **Zero Data Retention** available to qualifying enterprises;
  retention may vary by tier. Consent copy must **link to** Anthropic's live commercial privacy page rather
  than hard-assert a number.
