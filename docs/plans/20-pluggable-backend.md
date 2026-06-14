# Feature 20 — Pluggable transcription backend (widen OSS reach)

> Engineer-ready plan. Grounded in the code at `main` (HEAD `5f747fb`) and the
> `feat/meeting-far-audio` branch. Reads with `git show feat/meeting-far-audio:<path>`.
> External facts verified by web research 2026-06-14 (see §15 sources). Honors the
> per-feature contract in `_UNIFICATION.md` §2.1 + §6/20 and the invariants in §4.

## 1. Summary

Generalize Talkie's single `actor TranscriptionEngine` into a `TranscriptionBackend`
protocol with three interchangeable impls — `AppleSpeechBackend` (today's engine,
default on macOS 26), `WhisperKitBackend`, and `ParakeetBackend` (FluidAudio) for
older macOS / wider hardware — and add graceful degradation of Foundation-Models
cleanup when it is unavailable, so Talkie stops hard-requiring macOS 26 + Apple
Silicon and becomes installable by a real open-source audience.

## 2. Why it matters

Today Talkie's floor is **macOS 26.0 + Apple Silicon** (Package.swift:7,
`.macOS("26.0")`) because both pillars — `SpeechTranscriber` (TranscriptionEngine.swift:82)
and Foundation Models (`SystemLanguageModel.default`, CleanupEngine.swift:197) —
require it. macOS 26 shipped in late 2025; the population that has upgraded *and*
runs Apple Silicon is a sliver of the Mac base in mid-2026, and **zero** Intel Macs.
For an "industry-disrupting open-source release," that audience is too small to seed
a community.

This feature is the designated **widening lever** (`_UNIFICATION.md` §4.2, §6/20).
It serves the strategic thesis directly: the moat is the on-device personal context
graph fed by *both* voice surfaces — but a moat with no settlers is worthless. By
letting the dictation + meeting pipelines run on a bundled local model down to
**macOS 14** (the floor of WhisperKit, FluidAudio, and whisper.cpp), and by making
LLM cleanup *optional* rather than *required*, we let users on 2020-era M1 Airs and
even Intel Macs (whisper.cpp path) run the whole privacy-preserving pipeline. That
is something neither Wispr Flow nor Granola does, because they are cloud companies —
their "on-device" story is nonexistent. "Runs entirely on your Mac, even an old one,
$0, no account" is a wedge a subscription competitor structurally cannot copy.

Critically, the protocol is the SAME seam features 01 (far-end), 18 (opt-in cloud),
and 17 (benchmark) plug into. Building it now — while the only impl is the existing
on-device actor — is a cheap refactor; retrofitting it after four features have
forked their own engines is an expensive untangle (`_UNIFICATION.md` §5, decision 2).

## 3. Current state in the code

**Already built (the thing we generalize):**

- `actor TranscriptionEngine` (TranscriptionEngine.swift:44–361) wraps
  `SpeechAnalyzer` + `SpeechTranscriber`. Its public surface is exactly what the
  protocol must capture:
  - `static var isAvailable` → `SpeechTranscriber.isAvailable` (:81–83).
  - `init(localeIdentifier:)` (:61–63); `setLocaleIdentifier(_:)` (:66–68).
  - `setUpdateHandler(_:)` (:70–72) — the live-partials sink for the HUD.
  - `setContextualStrings(_:)` (:76–78) — recognizer biasing via `AnalysisContext`
    (:236–240). **This is the method whisper.cpp/Parakeet cannot honor.**
  - `warmUp(localeIdentifier:)` (:124–136) — model pre-install + `reserve`.
  - `transcribeBuffered(_:localeIdentifier:)` (:141–190) — one-shot re-transcription
    for language auto-detect.
  - `beginSession(segmentHandler:) -> (format: AVAudioFormat, continuation:
    AsyncStream<AnalyzerInput>.Continuation)` (:196–259) — **the load-bearing
    signature.** Returns the format `AudioCapture` must convert to, plus the
    continuation it yields `AnalyzerInput` into.
  - `finishSession() -> String` (:309–344); `cancelSession()` (:347–360).
  - `TranscriptUpdate` struct (:6–19) is the live-update DTO; `TalkieEngineError`
    (:21–39) is the typed error set.
- `final class AudioCapture: @unchecked Sendable` (AudioCapture.swift:48) taps the
  mic via `AVAudioEngine`, converts each buffer to the analyzer format with
  `AVAudioConverter` (converter captured by value, :84–104), and yields
  `AnalyzerInput(buffer:)` into the continuation. It is **backend-agnostic already**:
  it consumes only `(targetFormat, continuation)` — so any backend that returns an
  `AVAudioFormat` + an `AsyncStream<AnalyzerInput>.Continuation` plugs in unchanged.
  **Caveat:** `AnalyzerInput` is a Speech-framework type; see §4.4 for how non-Apple
  backends consume it.
- `SystemAudioCapture` [branch] (`git show feat/meeting-far-audio:Sources/Talkie/SystemAudioCapture.swift`)
  has the *identical* `start(targetFormat:continuation:onLevel:)` shape — so it plugs
  into the same protocol as the mic path. This is what makes "the protocol both the
  mic and far-end engines adopt" (the brief) true with no change to either capturer.
- `actor CleanupEngine` (CleanupEngine.swift:194–260): `static var isAvailable`
  (:196–199) gates on `SystemLanguageModel.default.availability`;
  `static var unavailableMessage` (:202–213) already produces user copy for the
  three unavailable cases. The whole cleanup path is **already guarded**: AppDelegate
  only cleans when `CleanupEngine.isAvailable` (AppDelegate.swift:476). So
  degradation #1 (skip cleanup) is *partly* built — what is missing is the
  *protocol seam* + a *small-local-model* fallback.

**Call sites the refactor must touch (AppDelegate.swift):**

- `private var engine: TranscriptionEngine!` (:17); built at `:60`
  `engine = TranscriptionEngine(localeIdentifier:)`.
- `engine.warmUp` (:76, :280); `engine.setUpdateHandler` (:225);
  `engine.setLocaleIdentifier` (:286, :464); `engine.setContextualStrings` (:373);
  `engine.beginSession()` (:374); `engine.cancelSession()` (:377, :397, :403);
  `engine.finishSession()` (:452); `engine.transcribeBuffered` (:461);
  `TranscriptionEngine.isAvailable` (:200, :304).
- `MeetingRecorder` [branch] takes `engine: TranscriptionEngine` and builds a
  second `TranscriptionEngine(localeIdentifier:)` for the far end (`farEngine`,
  MeetingRecorder.swift). Both become `any TranscriptionBackend` / a backend factory.

**Missing (this feature):** the protocol itself; any non-Apple impl; the model-
download UX; the per-OS/per-hardware backend selection; the small-local-model cleanup
fallback; the `Backends/` folder (`_UNIFICATION.md` §3). There are **no external
dependencies** today (Package.swift) and **no test target** — both change here.

## 4. Design & approach

### 4.1 The protocol (the seam)

Adopt the `TranscriptionBackend` from `_UNIFICATION.md` §2.1 verbatim in spirit,
adapting to the *actual* current signatures so the refactor is behavior-preserving.
The protocol is a near-mechanical lift of `TranscriptionEngine`'s public surface.

Two honest deviations from the unification sketch, justified:

1. The sketch's `beginSession(onUpdate:onSegment:)` folds the update handler into
   `beginSession`. Today the update handler is set *once* via `setUpdateHandler`
   (AppDelegate.swift:225) and reused across sessions. Keep `setUpdateHandler` to
   avoid churning that call site; `beginSession` keeps its existing
   `segmentHandler:` parameter. (Either is fine; minimizing diff wins.)
2. The sketch returns `AsyncStream<AnalyzerInput>.Continuation`. `AnalyzerInput` is
   an Apple Speech type. For non-Apple backends we keep the SAME continuation type
   (so `AudioCapture`/`SystemAudioCapture` are untouched) and have the backend read
   the raw `AVAudioPCMBuffer` *out* of each `AnalyzerInput` on its own side. See §4.4.

### 4.2 Backend selection (the algorithm)

A `BackendKind` enum + a resolver picks the backend at app launch and on a settings
change. Default resolution is **automatic and zero-config**:

```
resolveBackend(setting):
  switch setting:
    .automatic:                       // the default
       if AppleSpeechBackend.isAvailable   → AppleSpeechBackend   (macOS 26 + AS, best)
       else if WhisperKitBackend.isAvailable → WhisperKitBackend  (macOS 14+, AS)
       else → unavailable (show install/onboarding CTA)
    .apple      → AppleSpeechBackend (or unavailable message if not 26)
    .whisperKit(model) → WhisperKitBackend(model)
    .parakeet   → ParakeetBackend
```

- **`AppleSpeechBackend.isAvailable`** stays `SpeechTranscriber.isAvailable` (true
  only on 26 + AS). On 26 the automatic path is a no-op change — Apple stays default.
- **Apple Silicon vs Intel:** WhisperKit and FluidAudio both require/recommend Apple
  Silicon (CoreML/ANE). The **whisper.cpp** path (Metal/CPU, optional) is the only
  one that reaches Intel Macs — keep it as a documented "Phase 2" extension, not the
  MVP (§14), so we don't carry C++ bridging for the first slice.
- The resolver lives in a tiny `enum BackendFactory` (Sendable) so off-main
  consumers (MeetingRecorder's far engine, the benchmark harness #17) build backends
  the same way.

### 4.3 `AppleSpeechBackend` — conform, don't rewrite

Rename the file `TranscriptionEngine.swift` → keep the file, rename the type to
`AppleSpeechBackend` (move to `Sources/Talkie/Backends/AppleSpeechBackend.swift` per
`_UNIFICATION.md` §3), add `: TranscriptionBackend`, and implement the two protocol-
only members:

- `var requiresNetwork: Bool { false }`
- `var supportsContextualStrings: Bool { true }`

Everything else already matches. `transcribeBuffered` and `warmUp` are Apple-specific
extras — keep them on the concrete type and gate their use behind a capability check
(see §4.5). Net behavior change on macOS 26: **none**.

### 4.4 `WhisperKitBackend` (the headline fallback)

Use **WhisperKit** (now `argmaxinc/argmax-oss-swift`, **MIT**, CoreML/ANE, macOS
14+). It is Swift-native (async/await, structured concurrency) — far less friction
than whisper.cpp's C bridging, and it runs on the Neural Engine, not just CPU/Metal.

Flow inside the backend (mirrors `AppleSpeechBackend`'s shape so callers don't care):

1. **`isAvailable`** → `#available(macOS 14, *)` AND a model is installed (or
   installable). Apple-Silicon-gated (CoreML ANE).
2. **`beginSession`** returns a 16 kHz mono `AVAudioFormat` (Whisper's native input)
   + an `AsyncStream<AnalyzerInput>.Continuation`. Internally the backend spins a
   consumer `Task` that:
   - pulls each `AnalyzerInput`, reads its `AVAudioPCMBuffer`, appends Float samples
     to a ring buffer;
   - drives WhisperKit's streaming transcription. WhisperKit's OSS streaming is
     **chunked/sliding-window**, not token-by-token like SpeechTranscriber: feed
     ~1–2 s windows, run `transcribe` on the rolling buffer, diff the result to emit
     `TranscriptUpdate(finalizedText:volatileText:isComplete:)` and fire
     `segmentHandler` on committed sentences. (This is the standard WhisperKit
     real-time pattern; latency is higher than Apple's but acceptable for the
     wider-hardware tier.)
   - **Reading the buffer out of `AnalyzerInput`:** `AnalyzerInput` exposes its
     `buffer` (the `AVAudioPCMBuffer` `AudioCapture` put in). Confirm the accessor
     name at build time; if it is not public on the target OS, add a thin
     `BufferProducing` protocol that `AudioCapture` yields instead and have
     `AppleSpeechBackend` wrap it into `AnalyzerInput` — keeps both capturers
     framework-agnostic. (Low risk; isolated to one adapter.)
3. **`finishSession`** flushes the tail window, returns the trimmed full transcript.
4. **`requiresNetwork = false`** (after model download); **`supportsContextualStrings
   = false`** — WhisperKit has no contextual-strings biasing. Callers MUST tolerate
   this (they already branch on `contextualStrings.isEmpty`, TranscriptionEngine.swift:236;
   the graph's `biasPhrases` simply goes unused — the matching degrade is the
   heuristic-only graph path, `_UNIFICATION.md` §1.5).

**Model choice:** default to **`base` or `small`** (good accuracy/speed on M-series;
WhisperKit auto-recommends per device). `large-v3` (~626 MB) is an opt-in "best
accuracy" download for users who want it. Word/segment timestamps are available
(WhisperKit `timestamp_granularities`) — useful later for #01 Phase-3 alignment.

### 4.5 `ParakeetBackend` (FluidAudio) — the accuracy-leaning alternative

FluidAudio (**Apache-2.0 code**) ships **Parakeet TDT 0.6B v3** as CoreML, runs on
the ANE, ~110× RTF on M4 Pro (much faster than Whisper-large), 25 European languages
+ Japanese, **macOS 14+**, and supports **streaming** via `SlidingWindowAsrManager`
(not just batch). It is arguably the better *quality-per-watt* fallback than Whisper
on Apple Silicon. Implement it behind the same protocol; same `supportsContextualStrings
= false`, `requiresNetwork = false` (after download).

**Licensing caveat to surface (not block):** the v3 model card lists
`license: cc-by-4.0` (it derives from `nvidia/parakeet-tdt-0.6b-v3`) while FluidAudio
*code* is Apache-2.0. CC-BY-4.0 permits commercial + redistribution **with
attribution** — fine for an OSS app **if we (a) download weights at runtime rather
than committing them to the repo, and (b) attribute NVIDIA + FluidAudio in an
in-app credits screen and the model-download UI.** Do not vendor the weights into
the git tree. (Same posture as WhisperKit's HF-hosted weights.) Verify the exact
v3 card text at integration time — the card is internally inconsistent (metadata
says CC-BY-4.0, prose says Apache-2.0).

### 4.6 Cleanup degradation (the FoundationModels half of the brief)

Two-tier graceful degradation, exposed through the `Summarizer` protocol so it's
consistent with `_UNIFICATION.md` §2.2 (don't fork cleanup):

- **Tier A — already-built skip:** when `CleanupEngine.isAvailable == false` the
  pipeline already inserts the raw (post-dictionary, post-filler) text
  (AppDelegate.swift:476 guard). Keep this as the universal floor. Surface
  `unavailableMessage` (already written, CleanupEngine.swift:202–213) in Settings so
  the user understands *why* cleanup is off. **No new model, still fully useful** —
  dictation works, just verbatim-ish.
- **Tier B — optional small local LLM (opt-in download):** a `LocalLLMCleanup:
  Summarizer` that wraps a tiny instruct model for users without Apple Intelligence
  who *want* cleanup. Pragmatic default = **leave Tier A as the only fallback for
  MVP** (a bundled LLM is ~1–4 GB and a separate dependency); Tier B is a clearly-
  scoped later add. If built, route it through the SAME `Summarizer.generate`
  signature so `CleanupEngine`'s prompt strings (CleanupEngine.swift level/style
  `instructions`) are reused unchanged.

This keeps the brief's "skip cleanup OR use a small local model" promise: skip is
shipped; small-model is a designed, protocol-clean opt-in.

### 4.7 What does NOT change

`AudioCapture`, `SystemAudioCapture`, `HotKeyMonitor`, `TextInjector`,
`DictationAssembler`, `LanguageDetector`, the entire post-processing chain
(`TextProcessor`, `SpokenFileMatcher`), and all stores are untouched. The protocol
is a strict interposition at the engine boundary.

## 5. New & changed files / types

```
Sources/Talkie/Protocols/
  TranscriptionBackend.swift   (NEW)
  Summarizer.swift             (NEW — shared with 02/05/18; 20 only adds the cleanup conformance)

Sources/Talkie/Backends/
  AppleSpeechBackend.swift     (MOVED+RENAMED from TranscriptionEngine.swift; conformed)
  WhisperKitBackend.swift      (NEW)
  ParakeetBackend.swift        (NEW — phase 2 of this feature)
  BackendFactory.swift         (NEW — resolver + BackendKind)
  ModelManager.swift           (NEW — download/install/state for non-Apple models)

Sources/Talkie/
  CleanupEngine.swift          (conform to Summarizer via OnDeviceLLM; add LocalLLMCleanup later)
  AppDelegate.swift            (engine: any TranscriptionBackend; build via BackendFactory)
  MeetingRecorder.swift [branch] (engine + farEngine become backends via factory)
  SettingsView.swift           (new "Speech engine" subpage; model-download UI)
  AppSettings.swift            (transcriptionBackend setting + chosen model id)

Package.swift                  (add argmaxinc/argmax-oss-swift and/or FluidInference/FluidAudio deps,
                                guarded so the Apple-only build can exclude them — see §10/§14)

Tests/TalkieTests/             (NEW target — backend conformance + factory tests)
```

Protocol sketch (adapted to current signatures):

```swift
// Protocols/TranscriptionBackend.swift
protocol TranscriptionBackend: Sendable {
    static var isAvailable: Bool { get }
    var requiresNetwork: Bool { get }              // false for all three impls here
    var supportsContextualStrings: Bool { get }    // Apple: true; Whisper/Parakeet: false

    func setLocaleIdentifier(_ id: String) async
    func setContextualStrings(_ phrases: [String]) async   // no-op when unsupported
    func setUpdateHandler(_ handler: @escaping @Sendable (TranscriptUpdate) -> Void) async

    func beginSession(
        segmentHandler: (@Sendable (String) -> Void)?
    ) async throws -> (format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation)

    func finishSession() async -> String
    func cancelSession() async
}

// Apple-only extras stay on the concrete type, behind a capability probe:
protocol BufferedRetranscribing {           // adopted only by AppleSpeechBackend
    func warmUp(localeIdentifier: String?) async throws
    func transcribeBuffered(_ buffers: [AVAudioPCMBuffer], localeIdentifier: String) async -> String?
}
// AppDelegate language auto-detect: `if let b = engine as? BufferedRetranscribing { … }`
// (whisper/parakeet just keep the original transcript — graceful no-op).

enum BackendKind: String, Codable, Sendable, CaseIterable {
    case automatic, apple, whisperKit, parakeet
}
enum BackendFactory {
    static func resolve(_ kind: BackendKind, locale: String) -> (any TranscriptionBackend)?
}
```

`Summarizer` conformance for cleanup:

```swift
// Protocols/Summarizer.swift
protocol Summarizer: Sendable {
    static var isAvailable: Bool { get }
    var requiresNetwork: Bool { get }
    func generate(instructions: String, input: String) async -> String?
}
// CleanupEngine's generate(...) becomes the body of `OnDeviceLLM: Summarizer`;
// CleanupEngine keeps clean(_:level:)/clean(_:style:) calling through it.
```

## 6. Data model & persistence

- **No change to existing stores.** Transcripts/history/meetings are persisted
  exactly as today (HistoryStore, MeetingStore — `_CURRENT_STATE.md` §3).
- **New: downloaded speech models.** WhisperKit/FluidAudio cache to their own
  app-support locations by default; to keep the privacy-thesis "everything is in one
  inspectable place" story, point them at
  **`~/Library/Application Support/Talkie/models/`** (add
  `AppPaths.modelsDirectory()` next to `supportDirectory()`/`meetingsDirectory()`,
  AppPaths.swift:7–22). Layout: `models/whisperkit/<model-id>/`,
  `models/parakeet/v3/`.
- **New tiny state file:** `models/manifest.json` — `{ installed: [{kind, id, sizeBytes,
  installedUnix, sourceURL, licenseNote}], … }`. `.atomic` write, failure-tolerant
  decode, optional fields — house style (`_CURRENT_STATE.md` §7). Drives the Settings
  "installed / not installed / downloading" UI and the in-app license attribution.
- **Settings (UserDefaults, AppSettings.swift:151+):** add
  `transcriptionBackend: BackendKind = .automatic` and
  `whisperModelID: String = "<device-recommended>"`. Mutations post
  `.talkieSettingsChanged` (existing mechanism, AppSettings → AppDelegate.observeSettings
  AppDelegate.swift:265–287) so the live backend is rebuilt on change, exactly like
  the locale switch already is (:286).
- **Migration / back-compat:** brand-new keys default to `.automatic`, which selects
  Apple on macOS 26 — so existing users see **no change**. No data migration needed.

## 7. Unification contract (what this EXPOSES / CONSUMES)

Per `_UNIFICATION.md` §6/20 and §2.1:

**EXPOSES**
- The `TranscriptionBackend` protocol (canonical home `Sources/Talkie/Protocols/`) —
  the SAME seam features **01** (mic + far-end as two backends), **18** (opt-in cloud
  `requiresNetwork == true`), and **17** (run any corpus through any backend) adopt.
- Concrete impls `WhisperKitBackend`, `ParakeetBackend`, and the conformed
  `AppleSpeechBackend`.
- Graceful LLM-cleanup degradation via the `Summarizer` protocol (skip when
  unavailable; optional small-local-model `Summarizer`).
- `supportsContextualStrings` capability flag — the signal that tells **05**'s
  `graph.biasPhrases(...)` whether its output will be honored, and tells callers to
  expect the **heuristic-only graph path** (`_UNIFICATION.md` §1.5) on this hardware.
- `BackendFactory.resolve` — the single construction point so far-end / MCP /
  benchmark all build backends identically.

**CONSUMES**
- The `TranscriptionBackend` protocol itself (defined alongside, in Tier 0). 20 does
  NOT fork a parallel engine — it conforms the existing actor (`_UNIFICATION.md` §5,
  decision 2).
- The `Summarizer` protocol for the cleanup-degradation half.
- Nothing from the context graph at runtime *except* the contract that biasing may be
  absent: when `supportsContextualStrings == false`, `graph.biasPhrases` (05) is
  simply not fed to the backend. 20 must keep that branch clean so 05 doesn't special-
  case backends.
- `requiresNetwork` is consumed by **15** (the sandbox/consent wall refuses to
  instantiate any backend whose `requiresNetwork == true` unless opted in). All three
  impls here are `false`, so they instantiate freely in the sandboxed default build —
  this is the load-bearing reason to keep them network-free after download.

**Honoring the "both mic and far-end adopt the protocol" requirement (the brief +
01's contract):** `MeetingRecorder` [branch] today holds `engine: TranscriptionEngine`
and builds a `farEngine: TranscriptionEngine`. Both become `any TranscriptionBackend`
built via `BackendFactory`. Because `AudioCapture` and `SystemAudioCapture` already
share the `(targetFormat, continuation)` shape, neither capturer changes. **Open
load question deferred to 01:** can two concurrent CoreML backends (mic + far-end on
WhisperKit/Parakeet) run on the ANE at once? Apple's own two-`SpeechAnalyzer` case
is 01's measurement; for non-Apple backends the same protocol makes the fallback
(far-end mic-only, or far-end on a cheaper model) a clean swap, not a rewrite.

## 8. UI / UX

A new **"Speech engine"** sub-page in Settings (SettingsView.swift `SettingsHome`
index + a `SubPage`, mirroring the existing "Cleanup & style" / "Languages" panes,
:399–497), reached from the General tab. On-brand per `DesignSystem.swift` (v2 tokens
are source of truth) / `BRAND.md` (philosophy):

- **Engine picker:** a segmented or list control — *Automatic (recommended)* /
  *Apple (macOS 26)* / *Whisper* / *Parakeet*. One accent only (`Theme.coral`, now
  the macaw blue) on the selected row. Honest second-person copy: "Automatic uses
  Apple's on-device speech on macOS 26, and a bundled local model on older Macs."
  Never invent accuracy percentages (BRAND honesty rule, `_UNIFICATION.md` §4.3).
- **Model card / download row:** when a non-Apple engine is chosen and its model
  isn't installed, show a `talkieCard()` row with model name, size (e.g. "Whisper
  base · ~57 MB" / "Whisper large-v3 · ~626 MB" / "Parakeet v3"), a download button,
  and — once downloading — a calm determinate progress bar (`Theme.brand`, whisper
  shadow, squircle `Radius.card 22`). Use the feather palette only if a data viz
  appears; here a single accent suffices.
- **License attribution:** a quiet caption under the model row — "Whisper model ·
  MIT" / "Parakeet · CC-BY-4.0, © NVIDIA / FluidInference" — satisfying CC-BY
  attribution in-product. Link to a credits screen.
- **Cleanup-unavailable banner:** in the existing "Cleanup & style" pane, when
  `CleanupEngine.unavailableMessage != nil`, render that message (already surfaced
  per `_CURRENT_STATE.md` §4.4) and, if Tier B exists, an opt-in "Use a local cleanup
  model" download row.
- **HUD:** unchanged. The glass pill (HUD.swift) shows only the waveform; backend
  identity never appears mid-dictation. (A backend badge could later live in #14's
  HUD switcher, not here.)
- **First-run on older macOS:** OnboardingView gains one conditional step — if Apple
  speech is unavailable, offer the default-model download before the permissions step,
  so the app is usable immediately. Coral progress dots, parrot icon — match existing
  onboarding (OnboardingView.swift).

## 9. Permissions / entitlements / Info.plist

- **No new TCC prompts** for the engines themselves — mic permission
  (`NSMicrophoneUsageDescription`) already covers audio input; the speech models are
  local files. `NSSpeechRecognitionUsageDescription` is Apple-Speech-specific and can
  stay (harmless on the fallback path).
- **Model download = network.** This is the one wrinkle: WhisperKit/FluidAudio fetch
  weights from Hugging Face on first use. This is the FIRST network access in the
  app. It MUST be: (a) only triggered by an explicit user "Download" tap (never
  silent), (b) clearly disclosed ("downloads a ~57 MB model from Hugging Face, once"),
  (c) absent entirely from the Apple-default path. See §10 for how this coexists with
  the zero-network invariant.
- **Entitlements:** the *default Apple-Silicon-macOS-26* build keeps the current
  single `com.apple.security.device.audio-input` entitlement and **no** network
  entitlement. A build that includes the fallback engines needs *outbound network for
  the one-time download* — handled as a **build flavor** (`_UNIFICATION.md` §4.1 /
  feature 15): `Talkie` (Apple-only, zero-network, default) vs. `Talkie (Wide)` which
  adds `com.apple.security.network.client` solely for model fetch. The user choosing a
  download-requiring engine is the consent.
- **Sandbox:** model dir under `~/Library/Application Support/Talkie/models/` is
  inside the app container — no extra file entitlement. (#15 validates the fallback
  engines work under the sandbox.)

## 10. Privacy posture

The invariant (zero network, default-on) is **preserved for the default experience**:

- On macOS 26 + Apple Silicon, `automatic` → `AppleSpeechBackend` → **zero network,
  unchanged**. The verified `grep` for `URLSession` etc. stays clean for the default
  build because the fallback engines' network code lives behind a build flavor /
  compile-time flag and is **not compiled into the Apple-only release**.
- The only data that ever leaves the device for this feature is a **model-weights
  download from Hugging Face**, and only when: the user is on hardware without Apple
  speech (or explicitly picks Whisper/Parakeet) AND taps Download. **What leaves:** an
  HTTPS GET for model files (no audio, no transcript, no user data — just "give me
  this public model"). **When:** once, at install time, then never again. After
  download, transcription is 100% on-device (`requiresNetwork == false`).
- This is materially different from the competitors and must be messaged as such: even
  the widened path sends *nothing about you* — it downloads a public file the way
  `brew install` does, then goes dark.
- The structural enforcement is feature 15's `requiresNetwork` wall + the two build
  flavors. 20's job is to keep all three impls `requiresNetwork == false` *at runtime*
  and to confine the *download* network call to the model-manager, behind explicit
  consent, in the wide flavor only.

## 11. Open-source genericity

- **No hardcoded personal stack** — this feature is the opposite of personal; it's
  the genericity lever itself.
- **Zero-config default that needs no third-party app:** `automatic`. On 26+AS it's
  Apple (already bundled, no download). On older Macs the first-run flow offers a
  small bundled-fallback download with a sensible default model — the app is useful
  out of the box without the user choosing anything.
- **Community extension point:** because everything is behind `TranscriptionBackend`,
  a contributor can add (e.g.) a `MoonshineBackend` or a `whisper.cpp` Metal/Intel
  backend by writing one file conforming to the protocol + registering it in
  `BackendFactory` — no core changes. Document this in CONTRIBUTING. The protocol's
  `supportsContextualStrings`/`requiresNetwork` flags make new backends' capabilities
  explicit so the rest of the app degrades correctly without special-casing.
- **Licensing is OSS-clean:** WhisperKit/argmax-oss-swift = MIT; whisper.cpp = MIT;
  FluidAudio code = Apache-2.0. Model weights are downloaded at runtime (never
  vendored), with in-app attribution for the CC-BY-4.0 Parakeet weights. No GPL, no
  copyleft contamination of Talkie's own license.

## 12. Risks, edge cases, failure modes

- **`AnalyzerInput` buffer extraction.** Risk the public accessor for the wrapped
  `AVAudioPCMBuffer` isn't stable across OS versions. Mitigation: the `BufferProducing`
  adapter (§4.4) isolates this to one type; if it breaks, only the adapter changes.
- **Two concurrent CoreML backends (mic + far-end).** ANE contention / memory.
  Mitigation: protocol makes mic-only fallback a clean swap; measured by 01.
  Degradation: far-end falls back to a cheaper model or mic-only.
- **Streaming latency on the fallback.** Whisper's sliding-window streaming is
  higher-latency than Apple's token stream. Mitigation: default to `base`/`small`,
  document "older Macs trade some latency for working at all," show live partials so
  the HUD never looks frozen. This is an honest, acceptable tradeoff for the tier.
- **Model download fails / offline.** Mitigation: typed errors, retriable download,
  clear "couldn't reach Hugging Face — check connection" copy; the app still runs
  Apple speech if available, or shows the onboarding CTA. Never crash; never silently
  hang in "listening."
- **Disk usage.** large-v3 ≈626 MB; Parakeet v3 sizeable. Mitigation: default to a
  small model; show sizes before download; offer a "remove model" action; store under
  the inspectable Talkie support dir.
- **No contextual biasing on fallbacks.** Dictionary/graph bias silently does
  nothing. Mitigation: `supportsContextualStrings == false` is surfaced; dictionary
  *post-processing* (TextProcessor.apply, applied AFTER the engine, AppDelegate.swift:465)
  still corrects spellings — so the user's exact spellings still win even without
  recognizer biasing. This is a real silver lining worth noting in UI copy.
- **Cleanup absent + fallback engine = double quality drop.** A user on an old Mac
  with no Apple Intelligence gets fallback ASR AND no LLM cleanup. Mitigation: Tier A
  still inserts dictionary-corrected, filler-stripped text; Tier B (small local LLM)
  is the opt-in remedy. Set expectations honestly in onboarding.
- **License inconsistency on the Parakeet v3 card** (CC-BY-4.0 vs Apache-2.0 prose).
  Mitigation: treat as CC-BY-4.0 (stricter), attribute, download-not-vendor; re-verify
  at integration; if unresolved, ship WhisperKit (MIT, unambiguous) as the default
  fallback and make Parakeet opt-in.

## 13. Testing & verification

- **Unit (new `Tests/TalkieTests/` target — first tests in the repo):**
  - `BackendFactory.resolve` returns Apple on a simulated-available environment,
    WhisperKit when Apple is unavailable, nil only when nothing is installable.
  - A `MockBackend: TranscriptionBackend` proves the protocol is sufficient to drive
    the full pipeline (feed canned buffers → assert `TranscriptUpdate`s + final string)
    — this also future-proofs 01/17/18 against signature drift.
  - `supportsContextualStrings == false` path: assert dictionary post-processing still
    applies (TextProcessor) so spellings are corrected.
  - Cleanup degradation: with `CleanupEngine.isAvailable == false`, assert the
    pipeline still returns dictionary+filler-processed text (no crash, no empty).
- **Manual / `/run` (the real proof):**
  - macOS 26 + AS: `automatic` → Apple; confirm dictation behaves identically to
    today (regression gate — the refactor must be invisible).
  - Same machine, force `whisperKit`: download `base`, dictate a paragraph, confirm
    insertion + History entry + live waveform.
  - Meeting recording on the branch with a non-Apple backend: confirm Me/Them still
    works (or degrades to mic-only cleanly).
  - Toggle Apple Intelligence off in System Settings → confirm cleanup-unavailable
    banner appears and verbatim+dictionary insertion still works.
- **Benchmark (#17 doubles as regression):** run a fixed corpus (LibriSpeech subset)
  through each backend via the protocol; record WER + RTF; chart on-brand. Validates
  20's backends and Apple's side-by-side, honestly (cold vs warm model documented).
- **Privacy verification (ties to #15):** in the default/Apple build, `grep -rniE
  "URLSession|http://|https://"` over compiled sources must STILL return nothing
  (the fallback engines + their HF download must be excluded from that build flavor).
  This is the acceptance test that the invariant survived.

## 14. Effort & phasing

- **MVP slice (the strategic minimum):**
  1. **Define `TranscriptionBackend` + `Summarizer` protocols** and **conform the two
     existing actors** (`AppleSpeechBackend`, `OnDeviceLLM`). Behavior-preserving
     refactor; rewire AppDelegate + MeetingRecorder to `any TranscriptionBackend` via
     `BackendFactory`. **(M)** — touches many call sites but each is mechanical.
  2. **`WhisperKitBackend` + `ModelManager` + download UI + `automatic` resolver.**
     One real fallback, MIT-clean, Swift-native. **(L)** — streaming adapter is the
     hard part.
  3. **Cleanup Tier A surfacing** (the skip is built; just expose the message + ensure
     the path is clean under a non-Apple engine). **(S)**
  4. **Build flavor split** (Apple-only zero-network default vs. wide) coordinated with
     #15. **(M)** — can be a compile flag initially.
  Result: Talkie installs and dictates on macOS 14+ Apple Silicon with no Apple
  Intelligence, fully on-device after one disclosed download. That is the OSS unlock.

- **Full feature (post-MVP):**
  5. **`ParakeetBackend` (FluidAudio)** — accuracy/speed alternative; resolve the
     license-card attribution. **(M)**
  6. **Cleanup Tier B** — optional small local LLM `Summarizer`. **(M/L)** — model
     choice + download + memory budget.
  7. **whisper.cpp Metal/CPU backend** — the only path to **Intel Macs**; carries C++
     bridging, so isolate it. **(L)** — widest reach, highest integration cost; ship
     last if Intel demand is real.
  8. **Per-app / per-locale backend overrides** (ties to #13). **(S)**

## 15. Dependencies & interactions

- **NEEDS (Tier 0):** the `TranscriptionBackend` + `Summarizer` protocols — define
  them *here, alongside 05*, since 20 is the first concrete multi-impl consumer
  (`_UNIFICATION.md` §5, decision 2). New SwiftPM deps: `argmaxinc/argmax-oss-swift`
  (WhisperKit, MIT) and optionally `FluidInference/FluidAudio` (Apache-2.0) — the
  first external dependencies in `Package.swift` (currently zero-dep), added only to
  the wide build flavor.
- **ENABLES / aligns with:**
  - **01 (far-end):** both mic + far-end engines become backends via the same
    protocol; mic-only fallback is a clean protocol swap. 20 must land the protocol
    before/with 01's rebase so 01 conforms rather than forks.
  - **18 (opt-in Claude bridge):** a networked `Summarizer`/`TranscriptionBackend`
    (`requiresNetwork == true`) is a drop-in behind the same seam + 15's wall.
  - **17 (benchmark):** runs any corpus through any backend via the protocol — both
    the validation harness for 20 and the WER/RTF marketing chart.
  - **05 (graph):** `supportsContextualStrings` is the signal that gates whether
    `graph.biasPhrases` is honored; the heuristic-only graph path is the matching
    degrade on fallback hardware.
- **OVERLAPS:** **15 (sandbox/zero-net)** owns the build-flavor + `requiresNetwork`
  enforcement that 20's download relies on — coordinate so the wall is built, not
  bolted on. **16 (install/update)** shares the "first network access, must be opt-in"
  shape (Sparkle appcast ↔ model download) — reuse the same disclosure pattern.

### Sources (research, 2026-06-14)

- [argmaxinc/argmax-oss-swift (WhisperKit, MIT, macOS 14+, CoreML/ANE)](https://github.com/argmaxinc/argmax-oss-swift)
- [WhisperKit on macOS — integration walkthrough](https://www.helrabelo.dev/blog/whisperkit-on-macos-integrating-on-device-ml)
- [FluidInference/FluidAudio (Apache-2.0 code; Parakeet v3 + diarization; streaming)](https://github.com/FluidInference/FluidAudio)
- [Parakeet TDT 0.6b v3 CoreML model card (cc-by-4.0 metadata; ex nvidia/parakeet-tdt-0.6b-v3)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/blob/main/README.md)
- [ggml-org/whisper.cpp (MIT; GGML model sizes)](https://github.com/ggml-org/whisper.cpp)
- [whisper.cpp models README (tiny 75MiB / base 142MiB / small 466MiB; quantized sizes)](https://github.com/ggml-org/whisper.cpp/blob/master/models/README.md)
- [rcourtman/parakey — Parakeet TDT v3 push-to-talk dictation reference impl (ANE, 2.2 MB app, ~80 MB RAM)](https://github.com/rcourtman/parakey)
