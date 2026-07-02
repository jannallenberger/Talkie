# 01 — Far-end capture, diarization & speaker-labeled transcript

> **STATUS UPDATE (2026-06-14): far-end capture is now MERGED to `main`** (commits
> `99a69ff` far-end Me/Them + `1fa7624` German-meeting/locale fix + merge `a3f95c6`).
> `SystemAudioCapture.swift` and `MeetingTranscript.swift` are in the tree on `main`.
> The "merge the branch" step in this plan is **DONE** — ignore the branch/`git show`
> instructions below. The REMAINING 01 work is: (a) the **Audio-Recording permission
> UX**, (b) the **two concurrent `SpeechAnalyzer`** load measurement + fallback,
> (c) the **all-zero-PCM tap watchdog** + clock-drift robustness, and (d) **Phase-3
> multi-speaker diarization** (FluidAudio, license-gated). Treat those as the live
> scope of this feature.
>
> Engineer-ready plan to take Phase-2 far-end meeting capture (now merged) to
> production, plus the remaining diarization, permission, and robustness work.
>
> Ground truth: `docs/plans/_CURRENT_STATE.md` (§2) and `docs/plans/_UNIFICATION.md`
> (§6, contract **01**). Floor: macOS 26.0, Apple Silicon, Swift 6 `.v6`.
> Anchors tagged **[branch]** below are now on `main` (the branch was merged).

---

## 1. Summary

Merge the existing two-stream far-end capture (mic = "Me", Core-Audio system tap =
"Them") to `main`, harden it for long real calls (a zero-PCM tap watchdog, robust
two-analyzer load handling, a real "Audio Recording" permission UX), and add 3+
speaker diarization that splits only the "Them" stream via on-device FluidAudio
aligned to the turn-log timeline — keeping the "two streams = free 1:1 diarization"
spine and the zero-network invariant intact.

## 2. Why it matters

The whole strategic thesis is *both voice surfaces feed one on-device brain*.
Dictation already feeds it; meetings only become a rich feed once Talkie captures
**the other people on the call**, attributed to **who said what**. A mic-only
recorder (Phase 1) is a memo tool; a speaker-labeled `[mm:ss] Me/Them:` transcript
is a Granola-class meeting tool — and unlike Granola it is 100% on-device, free,
and open source. Concretely:

- **Disrupts Granola/Otter/Fireflies:** they are cloud companies; their transcript
  and diarization leave your machine. Talkie's never does (verified: zero
  `URLSession`, single audio-input entitlement). "Provably private meeting notes"
  is a claim no subscription incumbent can structurally match.
- **Feeds the keystone (feature 05):** every labeled turn is a graph
  `Provenance(.meeting)`; "Them" turns surface counterparties; meeting participants
  become Person entities. The cross-surface demo ("email Sarah the action items from
  my last meeting", feature 09) only works because meetings are attributed.
- **The diarization shortcut is the moat-in-miniature:** two separate audio streams
  give perfect 1:1 attribution with **zero ML** — something only a *local* app that
  owns both the mic and the system tap can do. A cloud recorder gets one mixed
  stream and must pay for ML diarization on every call.

## 3. Current state in the code

### 3.1 Already built (Phase 1, on `main`)

- `MeetingRecorder.swift` (`@MainActor ObservableObject`) — mic-only: reuses the
  **shared** `TranscriptionEngine` (so dictation and recording are mutually
  exclusive, guarded at `AppDelegate.swift:310` and inside the recorder), feeds a
  `DictationAssembler` with `clean: { _ in nil }`, flushes a `.recording.partial.txt`
  every 1 s for crash safety, summarizes via `MeetingSummarizer` on stop.
- `Meeting.swift` — `Meeting` (Codable), `MeetingSummarizer` (actor, Foundation
  Models, **hard-capped at 8000 chars**, `:36`), `MeetingStore` (writes one
  Markdown file per meeting to `~/Talkie Meetings/` + a `meetings.json` index).
- `MeetingsView.swift` — record card, folder row, meeting rows with summary +
  collapsible transcript.
- `TranscriptionEngine.swift` — the `actor` over `SpeechAnalyzer`/`SpeechTranscriber`.
  Note: `makeTranscriber` requests `reportingOptions: [.volatileResults]` and
  **`attributeOptions: []`** (`:113-120`) — **no `.audioTimeRange`**. Far-end
  diarization therefore relies on *arrival time*, not recognizer audio-time ranges.
- `AudioCapture.swift` — `AVAudioEngine` mic tap → `AVAudioConverter` → analyzer
  format; converter captured **by value** in the tap block (Swift-6-clean RT
  pattern); optional ~90 s ring (`CapturedAudio`).

### 3.2 Already built (Phase 2, on `feat/meeting-far-audio` — NOT merged)

Branch HEAD `aa477a3`, single commit, merge-base `c31618a`, **3 commits behind
main**, cleanly rebaseable (the only diffs vs. main outside the meeting files are
the 3 main-only UI commits showing in reverse — not branch changes).

- **`SystemAudioCapture.swift`** [branch] (`@unchecked Sendable`, 266 lines) — the
  far-end capture, and it is genuinely complete and well-built:
  - `audioObject(forPID:)` via `kAudioHardwarePropertyTranslatePIDToProcessObject`
    to resolve self.
  - `CATapDescription(stereoGlobalTapButExcludeProcesses:[selfObject])`,
    `isPrivate = true`, `muteBehavior = .unmuted` → `AudioHardwareCreateProcessTap`.
  - `kAudioTapPropertyFormat` → `AVAudioFormat`; `AudioHardwareCreateAggregateDevice`
    with `kAudioSubTapDriftCompensationKey: true` and
    `kAudioAggregateDeviceTapAutoStartKey: true`.
  - `AudioDeviceCreateIOProcIDWithBlock` on a dedicated `DispatchQueue`; RT block
    wraps the bufferlist **no-copy**, converts (converter captured by value),
    `continuation.yield`.
  - `cleanUpCoreAudio()` tears down in dependency order, safe from partial state.
    Typed `SystemAudioError`. `isSupported` gate (macOS 14.4+; ships on 26).
- **`MeetingTranscript.swift`** [branch] (93 lines) — `MeetingSpeaker` (`.me`/`.them`);
  `TurnLog` (`@unchecked Sendable`, NSLock) stamps each finalized segment with its
  **arrival time relative to recording start** (the diarization key);
  `MeetingTranscriptRenderer.render` sorts by elapsed, renders plainly if one
  speaker, else coalesces consecutive same-speaker turns into `[mm:ss] Me/Them:`
  blocks. `timecode` gives `h:mm:ss` past an hour.
- **`MeetingRecorder.swift`** [branch] (rewired, +110) — adds `@Published
  capturingFarEnd`; a per-recording `farEngine: TranscriptionEngine?` for "Them";
  replaces the assembler with a `TurnLog`; starts two streams in `start()` (mic →
  shared `engine` tagged `.me`; far-end → `farEngine` + `SystemAudioCapture` tagged
  `.them`); **degrades cleanly to mic-only** on any far-end failure; `isStarting`/
  `cancelStart` make the multi-`await` start abortable; `stop()` finalizes both,
  renders, sets `participants`/`source` from **capture state, not who spoke**.
- **`Meeting.swift`** [branch] — adds `participants: [String]` + `source: String`
  with a custom `init(from:)` that `decodeIfPresent`s them (back-compat);
  `writeMarkdown` emits `participants:` and the dynamic `source`.
- **`AppDelegate.swift`** [branch] — injects `meetingRecorder.primaryLocale = { ...
  spokenLanguages.first ... }` (+3 lines at `:59`) so the far-end transcriber tracks
  the language setting.
- **`Resources/Info.plist`** [branch] — adds `NSAudioCaptureUsageDescription`.
- **`MeetingsView.swift`** [branch] — honest status copy ("Recording you + the
  call…" vs "Recording (mic only)…").

### 3.3 Honestly missing (the production gaps this plan closes)

1. **3+ speaker diarization (Phase 3): not built.** "Them" is one bucket; a group
   call collapses every remote speaker into "Them".
2. **The Audio Recording TCC permission UX: not built.** There is **no entry in the
   Permissions tab**, no preflight, no denial handling, no recovery path. The
   permission prompt fires implicitly on the first `AudioHardwareCreateProcessTap`
   and is **never surfaced or explained**.
3. **Two-analyzer concurrency is assumed, never verified or measured.** The code
   *tries* two `SpeechAnalyzer` instances and falls back on throw — but there's no
   evidence two concurrent Apple analyzers are sanctioned on 26, and no CPU/ANE/
   memory measurement.
4. **Long-session robustness: not built.** No all-zero-PCM tap watchdog (a
   documented Core Audio bug on long sessions); drift compensation is enabled but
   unverified over hours.
5. **Long-meeting summarization still truncates at 8000 chars** (`Meeting.swift:36`)
   — a 60-minute two-person transcript blows past this; the tail is silently
   dropped from the summary (transcript itself is fine).
6. **Not merged / 3 commits behind main.**

## 4. Design & approach

### 4.1 Keep the spine; rebase first

Do **not** redesign the two-stream capture — it is correct and complete. Step one is
a clean rebase of `feat/meeting-far-audio` onto `main` (§4.7). Everything below is
*additive hardening* on top of the rebased branch.

### 4.2 Production hardening of the existing tap

**(a) Zero-PCM watchdog (the documented long-session bug).** Confirmed via the Apple
Developer Forums thread "AudioHardwareCreateProcessTap delivers all-zero buffers":
on long sessions a tap can keep firing its IOProc while delivering **all-zero PCM**,
indistinguishable from legitimate silence; **only a full teardown + rebuild of both
the process tap *and* the aggregate device restores real audio** — restarting the
IOProc or rebuilding only the aggregate is not reliable.

Implementation in `SystemAudioCapture`:
- In the IOProc, compute the existing per-buffer RMS (`level(of:)` already does
  this) and maintain two NSLock-guarded counters: `lastNonSilentAtHost` (host time
  of the last buffer with RMS above a small floor, e.g. > ~1e-4) and
  `everReceivedNonSilent`.
- A `MeetingRecorder`-owned `Timer` (reuse the existing 1 s `tick()`) calls a new
  `systemAudio.checkHealth()`. If the tap has been running > a grace period
  (e.g. 20 s after first non-silent audio) AND no non-silent buffer has arrived for
  a **continuous window** (e.g. 90 s — long enough that a genuinely quiet stretch on
  a real call doesn't trip it, short enough to recover a 1-2 hr meeting), trigger a
  **rebuild**: `cleanUpCoreAudio()` then re-run the `start()` body against the *same*
  `targetFormat`/`continuation`. Because the far-end engine and `TurnLog` are
  upstream of the continuation, a rebuild is transparent to transcription — the
  stream just resumes.
- Guard against rebuild storms: cap to N rebuilds/hour; after the cap, give up on
  far-end and set `capturingFarEnd = false` (degrade to mic-only mid-session,
  surfaced honestly in the UI). Distinguish "the call is genuinely silent" (don't
  rebuild forever) from "the tap died" by requiring that the MIC stream is still
  producing audio when we decide the far-end is unexpectedly dead.

> **IMPLEMENTED 2026-07-02 (package C6) — thresholds refined + a correctness fix
> vs. this sketch.** The watchdog shipped as a pure `FarEndWatchdog` state machine
> (`Sources/Talkie/Meetings/FarEndWatchdog.swift`, unit-tested like
> `ActiveMeetingDetector`) driven from `MeetingRecorder.tick()`. Deviations from the
> sketch above, all deliberate:
> - **Cap is per *meeting*, not per hour** (default **3**), with an inter-rebuild
>   **backoff** (~20 s) so a tap that keeps dying can't burn the cap in a burst.
> - **Never-received grace is ~10 s** (a born-dead tap), separate from the ~90 s
>   mid-meeting silence window.
> - **The mic-alive cross-check gates BOTH silence branches, not just the
>   mid-meeting one.** The sketch's never-received path (grace → rebuild → give up)
>   was *not* mic-alive-gated, which would falsely downgrade a real call where nobody
>   has spoken in the first minute (joining early is common). Fix: the never-received
>   branch also requires the mic to be delivering buffers, so a genuinely quiet start
>   (mic also silent) holds at `.ok` indefinitely and never gives up. Covered by
>   `FarEndWatchdogTests.testEarlyJoinQuietCallNeverDowngrades`.
> - Mic-alive is read via a new lock-guarded `AudioCapture.secondsSinceLastBuffer()`.
> - The **30-min soak** and the **real Zoom/YouTube-audio no-false-trip** checks
>   below (§13) are the two acceptance items that need a live call — left PENDING
>   HUMAN; the code + unit gate + rebuild path are done.

**(b) Clock drift.** `kAudioSubTapDriftCompensationKey: true` is already set on the
sub-tap. Because diarization is by **arrival time into the `TurnLog`**, not by
audio-sample timestamps, small residual drift only nudges interleave ordering by a
fraction of a turn — acceptable. **Do not** switch to `.audioTimeRange` joining: the
two analyzers have independent, unsynchronized audio timelines, so their time ranges
are not comparable; arrival time is the right key and is already implemented. (This
is why the engine intentionally keeps `attributeOptions: []`.)

**(c) Aggregate-device leak safety.** `cleanUpCoreAudio()` already destroys in
dependency order. Add a process-exit safety net: register an `atexit`/
`NSApplication willTerminate` hook (or ensure `MeetingRecorder.stop()` runs on
`applicationWillTerminate`) so a private aggregate device can't survive a crash and
linger in Core Audio. Private aggregates are auto-reaped when the creating process
dies, but an explicit teardown on graceful quit is cleaner.

### 4.3 Two concurrent SpeechAnalyzer instances — verify, measure, fall back

**Status of the fact:** Apple's docs describe `SpeechAnalyzer` as concurrent/async
and do not document a per-process instance cap, but there is **no published
guarantee** that two independent live analyzers (two transcribers, two audio
streams) are sanctioned, and the public sample apps (e.g. FluidInference's
swift-scribe) use a single analyzer. So we treat "two concurrent Apple analyzers
work and are affordable" as an **assumption to be validated on the deployment OS**,
not a given.

**Validation protocol (must run before merge sign-off):**
- Run a real 30-min two-person call. Capture, via `os_signpost`/Instruments + a
  lightweight in-app sampler: process CPU %, ANE residency (Instruments "Neural
  Engine" / power), RSS memory, and whether either transcriber's results stream ever
  errors or stalls. Record dropped-buffer counts (the analyzer back-pressures via the
  `AsyncStream`; watch for continuation buffering growth).
- Compare against the mic-only baseline. Acceptance: combined CPU stays well under
  one P-core's worth at steady state, memory plateaus (no unbounded growth over the
  session), and neither stream stalls.

**Fallback design if two analyzers are disallowed or too heavy:**
1. **Preferred fallback — single analyzer, two inputs interleaved with a speaker
   tag.** `SpeechAnalyzer` accepts one `AnalyzerInput` stream. We could merge mic +
   far-end into one stream — but that **destroys** the free diarization (the
   recognizer can't tell the sources apart) and reintroduces the ML-diarization
   problem for *every* call. Reject unless forced.
2. **Realistic fallback — time-sliced single engine is not viable** for live
   bidirectional audio (you'd drop whichever side isn't currently owned). So the true
   fallback is **mic-only** (Phase 1 behavior) with honest UI — which the branch
   already implements as the degradation path. The `TranscriptionBackend` protocol
   (feature 20 / §7) makes this a clean swap: if `farEngine` can't be instantiated,
   `capturingFarEnd = false` and we record one stream.
3. **If two *Apple* analyzers are too heavy but concurrency is allowed:** run the
   far-end through a lighter `TranscriptionBackend` (feature 20's `WhisperCppBackend`
   / Parakeet-CoreML) so the ANE isn't double-booked by two SpeechTranscribers. This
   is the architectural reason to land the `TranscriptionBackend` seam (§7).

### 4.4 3+ speaker diarization (Phase 3) — split only "Them"

**The key simplification (keep it):** we never diarize "Me vs Them" — that's free
from the two streams. We only sub-split the **far-end** stream when 3+ remote people
share it. So diarization runs on **one mono 16 kHz stream** (the far-end), offline,
at `stop()`, and re-labels only the `.them` turns.

**Engine: FluidAudio (`OfflineDiarizerManager`).** Verified current facts:
- Swift, CoreML, runs on the ANE; SPM:
  `.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.x")`
  (latest on Swift Package Index is v0.15.3 as of research; pin an exact tag).
- API: `OfflineDiarizerManager` (full pyannote-parity pipeline: powerset
  segmentation + WeSpeaker + VBx clustering) → a `DiarizationResult` of segments
  with `startTime`/`endTime`/`duration` + a speaker id per segment. Input is
  **16 kHz mono Float32** (exactly the analyzer target format we already convert to).
- Min OS macOS 14 / iOS 17 — fine for our 26 floor.
- **Models auto-download from Hugging Face on first use** — *this introduces a
  network fetch*, which violates the zero-network invariant if done naively. See
  §10 for the mandatory privacy handling (bundle or explicit opt-in; never silently
  fetch).
- **LICENSE FLAG (must resolve before any public OSS release):** FluidAudio *code*
  is **Apache-2.0**, but the diarization **weights derive from pyannote
  Community-1, which is CC-BY-4.0** (attribution required). CC-BY is fine to
  redistribute *with attribution*, but it is a **non-OSI content license on the model
  artifact** — flag it in `NOTICE`/`docs` and the OSS readme; it does not taint our
  Apache/MIT code but the shipped/bundled weights carry the attribution obligation.

**Capture the far-end audio for offline diarization.** The branch currently does NOT
retain far-end PCM — it streams straight into the analyzer. To diarize we need the
samples. Add a far-end ring buffer mirroring `AudioCapture.CapturedAudio`
(NSLock-guarded `[AVAudioPCMBuffer]`), capped generously (a full meeting in 16 kHz
mono Float32 is ~115 KB/s ≈ 415 MB/hr — too much to hold in RAM for long calls).
**Decision:** stream far-end PCM to an on-disk temp `.caf` (16 kHz mono) during
recording and diarize the file at `stop()`; delete it after (or keep it only if the
user opts into raw-audio retention, §6). This also unblocks the optional `.caf`
retention feature noted as missing in `_CURRENT_STATE.md` §2.3.

**Alignment algorithm (turn-log timeline ↔ diarizer timeline):**
- Each `.them` `TurnLog.Turn` already carries `elapsed` (arrival time). But arrival
  time lags the *spoken* time (recognizer latency). For robust overlap we want the
  turn's *audio* span on the far-end timeline. Two options:
  - **(a) Cheap/no-API-change:** approximate each `.them` turn's audio span as
    `[elapsed - estimatedLatency - duration(text), elapsed - estimatedLatency]` and
    max-overlap it against diarizer segments. Coarse but zero new dependencies on the
    recognizer.
  - **(b) Better:** for the **far-end engine only**, build the transcriber with
    `attributeOptions: [.audioTimeRange]` so each `.them` segment carries its true
    audio span on the far-end timeline (the diarizer runs on that same far-end
    audio, so the two timelines are directly comparable — no cross-stream sync
    needed). Assign each `.them` turn the diarizer speaker with **maximum temporal
    overlap**. This is the design the meeting doc specifies and is the correct
    approach. It does **not** affect the mic stream or the Me/Them split.
- After assignment, relabel: `MeetingSpeaker.them` becomes `.thirdParty(index:)` /
  a stable display name ("Speaker 1", "Speaker 2"). Render exactly as today but with
  the resolved labels; `participants` becomes `["Me", "Speaker 1", "Speaker 2"]`.
- **Stable speaker numbering:** order speakers by first-spoken time so "Speaker 1" is
  deterministic per meeting. (Cross-meeting identity / "this is Sarah" is a feature-05
  graph concern, not Phase 3.)

**Phasing within Phase 3:** ship the **two-stream Me/Them merge first** (it's done);
add diarization as a *post-processing enrichment* that only activates when (i)
far-end was captured, (ii) the far-end had meaningful audio, and (iii) FluidAudio
models are present. If diarization is unavailable/fails, the transcript falls back to
plain "Them" — never blocks saving the meeting.

### 4.5 The Audio Recording permission UX (TCC)

**Hard constraint (verified):** there is **no public API to preflight or request**
the audio-capture permission. The OS shows the `NSAudioCaptureUsageDescription`
prompt the **first time** `AudioHardwareCreateProcessTap` runs; on macOS 15+/26 the
permission lives in **System Settings → Privacy & Security → Screen & System Audio
Recording** (it is grouped with Screen Recording, not Microphone). Approaches:

- **Status inference (no private API):** we can't read the TCC bit publicly. Infer
  it from outcomes: if `AudioHardwareCreateProcessTap` returns an error OR the tap
  produces only-silence for the first few seconds while the mic is hot, treat
  far-end as **not granted / blocked** and surface the recovery affordance. Persist a
  "last far-end capture succeeded" flag in `UserDefaults` to drive the Permissions-tab
  state between launches (best-effort, honestly labeled "Last attempt: …").
- **Avoid private TCC API by default.** AudioCap (insidegui) demonstrates a
  private-API check behind a build flag; we keep the **default build free of private
  API** (App Store / OSS hygiene) and rely on outcome inference. A connected/dev
  build *could* opt into the private check, but it's not needed for the UX below.
- **Permissions-tab entry (new, 4th row).** Extend `PermissionsModel` and
  `PermissionsSettings` (`SettingsView.swift:783-878`):
  - Title "System Audio (meetings)", detail "Record the other people on a call
    (Zoom, Meet, Teams). Only used while you're recording a meeting. Audio stays on
    your Mac."
  - Because we can't preflight, the row shows three states: **Not yet used**
    (neutral), **Working** (last meeting captured far-end), **Blocked** (last
    attempt got only silence/error). Not a hard green/red like the other three.
  - "Grant" performs a tiny **probe**: build + immediately tear down a 1-2 s tap
    (this is what triggers the OS prompt deterministically, on the user's terms,
    instead of mid-meeting). "Open Settings" deep-links to the Screen & System Audio
    Recording pane — try `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
    (the screen/system-audio pane anchor); if the anchor is rejected on 26, fall back
    to opening Privacy & Security root. Verify the exact anchor on-device (deep-link
    anchors drift between macOS releases).
- **In-flow denial handling.** When `MeetingRecorder.start()`'s far-end branch
  fails or yields only silence, the recorder already sets `capturingFarEnd = false`.
  Add: a one-time, dismissible inline note in the record card — "Recording your side
  only — Talkie couldn't capture the call audio. [Fix in Permissions]" — that
  deep-links to the new tab row. Never block the meeting; mic-only still saves.
- **First-run education.** The first time the user taps "Start recording", show a
  short pre-record explainer ("To capture the other people, Talkie needs System
  Audio Recording — you'll see a system prompt") so the OS prompt isn't a surprise.
  This is consent-forward and matches the meeting-mode privacy requirements.

### 4.6 Long-meeting summarization (map-reduce)

Lift the 8000-char cap (`Meeting.swift:36`) with a map-reduce summarizer: chunk the
transcript on speaker/turn boundaries into ≤~6000-char windows, summarize each
("partial notes"), then summarize the concatenated partials into the final
Decisions/Action-items output. Implement **above** the `Summarizer` protocol (§7) so
it works with the on-device model today and an opt-in cloud `Summarizer` later. This
is shared with feature 02's fusion path — build it once.

### 4.7 Merge-to-main checklist

1. **Rebase** `feat/meeting-far-audio` onto `main` (`git rebase main`). The 3
   main-only commits (heatmap, dictionary chips, card heights) touch
   `DesignSystem/DashboardView/ActivityStore/SettingsView`; the branch touches
   meeting files + Info.plist + small AppDelegate/MeetingsView wiring. **No feature-
   file overlap** → expected to be conflict-free.
2. **Build** `swift build` (release) — verify zero warnings under `.v6` strict
   concurrency; the two new files must compile clean (they already follow the RT/
   `@unchecked Sendable`/NSLock conventions).
3. **Re-verify the privacy invariant on the merged tree:**
   `grep -rniE "URLSession|NSURLConnection|http://|https://" Sources/` returns
   nothing (FluidAudio, when added in Phase 3, must be gated per §10 so this stays
   true for the default build).
4. **Confirm `NSAudioCaptureUsageDescription` is present** in `Resources/Info.plist`
   (tap creation fails/prompts silently without it).
5. **Entitlements unchanged** — far-end capture needs **no** new entitlement
   (process taps need the TCC grant, not a sandbox entitlement). Confirm
   `Resources/talkie.entitlements` still has only `device.audio-input`.
6. **Signing:** rebuild with a stable `TALKIE_SIGN_ID` (not ad-hoc) so the new TCC
   prompt persists across rebuilds (`scripts/build_app.sh` note).
7. **Manual smoke (§13)** on the deployment OS, including the two-analyzer load run
   (§4.3) and a >30-min stability run for the watchdog.
8. Land the hardening (watchdog, permission UX) **with** the merge; land diarization
   (Phase 3, +dependency) as a **follow-up PR** so the dependency-free merge isn't
   blocked on the FluidAudio licensing decision.

## 5. New & changed files/types

```
Sources/Talkie/
  SystemAudioCapture.swift        [exists, branch] + watchdog hooks (RMS counters,
                                   checkHealth(), rebuild(); optional .caf sink)
  MeetingTranscript.swift         [exists, branch] + speaker model extended for 3+
  MeetingRecorder.swift           [exists, branch] + watchdog timer wiring,
                                   far-end .caf capture, diarization post-pass,
                                   in-flow denial note
  Meeting.swift                   [exists, branch] + map-reduce MeetingSummarizer;
                                   participants already supports >2 names
  Permissions.swift               + systemAudio status (inferred), probe(),
                                   openScreenAudioSettings()
  SettingsView.swift              + 4th PermissionRow (tri-state)
  MeetingsView.swift              [exists, branch] + denial note, diarization label
  Meetings/                       (new folder per _UNIFICATION §3)
    FarEndDiarizer.swift          NEW — FluidAudio wrapper + alignment (Phase 3)
  Protocols/
    TranscriptionBackend.swift    NEW — the seam (land alongside; §7)
```

Sketches:

```swift
// SystemAudioCapture.swift — added health/watchdog surface
extension SystemAudioCapture {
    /// Host time of the last buffer whose RMS exceeded the silence floor.
    func lastNonSilentElapsed() -> TimeInterval?      // nil = never received non-silent
    func isDeliveringSilenceOnly(since window: TimeInterval) -> Bool
    /// Full teardown + rebuild of tap AND aggregate against the same continuation.
    /// Returns false if rebuild failed (caller degrades to mic-only).
    func rebuild() throws
    /// Optional: tee converted far-end PCM to a 16 kHz mono .caf for offline diarization.
    func startFileSink(at url: URL) throws
    func stopFileSink() -> URL?
}

// MeetingTranscript.swift — generalize the speaker
enum MeetingSpeaker: Sendable, Hashable {
    case me
    case them                    // single far-end bucket (1:1 calls / pre-diarization)
    case speaker(Int)            // resolved 3+ far-end speaker (Phase 3)
    var label: String            // "Me" / "Them" / "Speaker 1"
}

// Meetings/FarEndDiarizer.swift — Phase 3 (behind the network/opt-in wall, §10)
import FluidAudio
actor FarEndDiarizer {
    static var modelsAvailable: Bool { get }          // on-disk check; never auto-fetch in default build
    /// Diarize a 16 kHz mono far-end .caf into speaker spans.
    func diarize(fileURL: URL) async -> [SpeakerSpan]?   // nil → caller keeps plain "Them"
    /// Re-label .them turns by max temporal overlap with spans.
    static func assign(turns: [TurnLog.Turn], spans: [SpeakerSpan]) -> [TurnLog.Turn]
}
struct SpeakerSpan: Sendable { let speaker: Int; let start: TimeInterval; let end: TimeInterval }

// Permissions.swift — inferred status (no public preflight API)
extension PermissionsModel {
    enum SystemAudioState { case unknown, working, blocked }
    @Published var systemAudio: SystemAudioState  // persisted hint in UserDefaults
    func probeSystemAudio() async                  // build+teardown a 1-2s tap to trigger the OS prompt
    func openScreenAudioSettings()                 // Privacy_ScreenCapture (verify anchor on-device)
}
```

## 6. Data model & persistence

- **`Meeting`** already carries `participants: [String]` + `source: String` with
  back-compat `init(from:)` [branch] — no further schema change for 3+ speakers;
  `participants` simply holds `["Me","Speaker 1","Speaker 2"]` and `writeMarkdown`
  already joins them.
- **Markdown** (`~/Talkie Meetings/<yyyy-MM-dd-HHmm>-meeting.md`) — frontmatter gains
  nothing new structurally; `participants:` and `source:` already emitted. Transcript
  body lines become `[mm:ss] Speaker 1: …` after diarization. The `.md` is the
  durable copy; `meetings.json` is the index (unchanged).
- **Far-end raw audio (new, transient):** a temp `.caf` under
  `AppPaths.supportDirectory()/meeting-tmp/` during recording, deleted on `stop()`
  after diarization. **Optional retention** (off by default, a setting): if enabled,
  move it next to the `.md` as `<basename>.caf`. Document the privacy tradeoff in the
  setting copy. Add `AppPaths.meetingTempDirectory()`.
- **Permission hint:** `UserDefaults` key `talkie.systemAudioLastResult`
  (`working`/`blocked`/absent) so the Permissions tab shows honest state between
  launches.
- **No migration needed:** pre-Phase-2 notes load via the existing
  `decodeIfPresent` defaults (`["Me"]`, `"talkie (mic-only)"`).

## 7. Unification contract (per `_UNIFICATION.md` §6 / 01)

**EXPOSES (to other features):**
- The merged, **speaker-labeled meeting transcript** + `participants`/`source`
  metadata (already on branch) — consumed by feature **05** (each turn → a graph
  `Provenance(.meeting)`; "Them"/"Speaker N" turns → counterparty/Person entity
  candidates) and feature **02** (notes×transcript fusion).
- **Per-segment turns** (the `TurnLog`) feeding the graph's meeting extraction —
  expose a read accessor so feature 05's extractor can walk turns with timestamps and
  speakers rather than re-parsing Markdown.
- A **`MeetingTranscriptionBackend` shape** — a `TranscriptionBackend` (§2.1 of the
  spine) that *also* emits speaker labels — so the opt-in cloud path (feature 18) and
  Phase-3 diarization slot in behind one seam. Concretely: land
  `TranscriptionBackend` now, conform today's `TranscriptionEngine` as
  `AppleSpeechBackend` with **no behavior change** (the low-risk refactor the spine
  asks for in Tier 0), and have `MeetingRecorder` hold `any TranscriptionBackend` for
  each stream.

**CONSUMES:**
- **`TranscriptionBackend`** — mic and far-end as two backends (the protocol makes
  the "two Apple analyzers too heavy → far-end on a lighter backend" fallback a clean
  swap, §4.3).
- **`MeetingContextProvider`** (feature 04) — when present, feed
  `eventContext(at:).attendeeNames` into **both** backends' `setContextualStrings`
  (bias both Me and Them toward the real names) AND title the note from the calendar
  event instead of the timestamp-only `makeTitle(start:)`. Far-end capture must work
  with **no** provider (graceful: timestamp title, empty bias) so 01 doesn't hard-
  depend on 04.
- The **`Summarizer`** protocol for the map-reduce summary (§4.6) — shared with 02.

**NOTE (the coherence rule):** keep the "two streams = free diarization" spine. 3+
splitting only splits "Them", never "Me vs Them". Rebase to main first. Verify two
concurrent Apple backends' CPU/ANE/memory; if disallowed, fall back to mic-only via
the protocol. **Do not** let far-end capture read the graph JSON directly or fork its
own bias logic — bias terms come from `graph.biasPhrases(near:)` once feature 05
lands (today: empty/contextual strings, as the branch does).

## 8. UI / UX

All in the existing **Meetings tab** + **General → Permissions** sub-page; reuse v2
tokens from `DesignSystem.swift` (the source of truth for values; `BRAND.md` for
philosophy: warm, honest, calm, one accent).

- **Record card** (`MeetingsView.recordCard`, branch) — keep the honest dual copy
  ("Recording you + the call…" / "Recording (mic only)…"). Add a **second
  `RecordingDot`/level meter for the far end** so the user *sees* "Them" audio is
  being captured (drive it from `SystemAudioCapture`'s `onLevel`, already plumbed).
  Add the dismissible **denial note** (§4.5) when `capturingFarEnd` is false during a
  recording that *should* have had a far end.
- **Diarization (Phase 3)** is invisible until it changes the transcript: rows render
  `[mm:ss] Speaker 1:` blocks via the existing `MarkdownText`/transcript view; no new
  screen. Participants chip shows `Me · Speaker 1 · Speaker 2`.
- **Permissions row** (new, 4th) — tri-state (Not yet used / Working / Blocked), not
  the binary green check of the other three, because we can't preflight. Honest copy:
  "We can't pre-check this one — it shows the last result." One accent
  (`Theme.coral`, now blue) for the action; `Theme.warning` for Blocked,
  `Theme.positive` for Working, `Theme.inkTertiary` for unknown.
- **Persistent recording indicator** (meeting-mode privacy requirement): the menu-bar
  mic already turns red while dictating; extend it to also reflect *recording* so the
  obvious global indicator exists even when the window is closed. (Full global
  hotkey/menu Stop is feature-03/05 scope; at minimum surface the state.)
- **Brand:** Young Serif for the "Meetings" title (already), feather palette only for
  the level meters/data, squircle cards (`.talkieCard()`), calm springs. No invented
  metrics.

## 9. Permissions / entitlements / Info.plist

- **Info.plist:** `NSAudioCaptureUsageDescription` — **already added on branch**;
  must remain (tap creation fails/prompts silently without it).
- **Entitlements:** **none new.** Process taps require the **TCC grant** ("System
  Audio Recording"), not a sandbox/network entitlement. `talkie.entitlements` stays
  `device.audio-input` only. (If/when the app is sandboxed for feature 15, validate
  process taps still work under the sandbox — the spine flags this as 15's job; on a
  non-sandboxed build they work today.)
- **New TCC prompt:** "System Audio Recording" (Screen & System Audio Recording pane),
  fired on first tap. No public preflight/request API → handled via the
  probe-on-demand + outcome-inference UX in §4.5.
- **Signing:** use a stable identity so the grant persists across rebuilds
  (ad-hoc re-signing re-prompts).

## 10. Privacy posture

- **Capture stays 100% on-device.** The tap, both transcribers, the turn log, the
  summary, and the Markdown all live on the Mac. No `URLSession` is added by the
  far-end feature itself. The merge keeps the verified invariant true.
- **`muteBehavior = .unmuted`** — the user still hears the call normally; the tap is
  a read of the system mixer, nothing is rerouted.
- **The one network risk is FluidAudio's model auto-download (Phase 3).** This MUST
  be gated, per the invariant:
  - **Default build:** ship with **no automatic Hugging Face fetch.** Either (a)
    **bundle** the CoreML diarization model in the app (size permitting; carries the
    pyannote **CC-BY-4.0** attribution obligation in `NOTICE`), making diarization
    fully offline and zero-network; or (b) make diarization an **opt-in** feature
    whose first enable explicitly discloses "this downloads a ~X MB model from Hugging
    Face once" and performs the *only* network call in that flavor, clearly. Prefer
    (a) for the zero-network thesis; choose based on bundle-size tolerance.
  - Set `ModelRegistry.baseURL` / disable env-driven fetch so the model can't be
    pulled implicitly.
  - The far-end `.caf` (if diarizing) is a **temp file deleted after use**; raw-audio
    retention is **off by default** and disclosed.
- **Consent-forward meeting recording** (meeting-mode doc requirement): persistent
  recording indicator, one-tap Stop, first-run explainer, never silent. Recording
  other people's audio is a legal/ethical matter (all-party-consent states, GDPR) —
  the UI must keep recording obvious.

## 11. Open-source genericity

- **No hardcoded personal stack.** Far-end capture is generic Core Audio + Apple
  Speech; the meeting app allowlist (for auto-detect, feature 03) is data, not code,
  and far-end capture itself is **app-agnostic** (a global tap captures any call app).
- **Zero-config default:** mic + far-end + on-device summary → plain Markdown in
  `~/Talkie Meetings/`. No third-party app, account, or key.
- **The macOS-26/Apple-Silicon floor** is the OSS-reach limit; the
  `TranscriptionBackend` seam (§7) is the designated widening lever (feature 20), and
  far-end capture being expressed as a backend means a community whisper.cpp/Parakeet
  backend can drive the far-end stream on wider hardware without touching the capture
  code.
- **Diarization is pluggable:** `FarEndDiarizer` is one impl; the alignment
  (max-overlap) is generic, so a community CC0/MIT-weighted diarizer could replace
  FluidAudio if the CC-BY weights are a problem for a given distribution.
- **License hygiene:** Apache-2.0 code + CC-BY-4.0 weights documented in `NOTICE`
  and the readme; the default build can ship **without** the CC-BY artifact (Phase 3
  opt-in) to keep the base distribution unencumbered.

## 12. Risks, edge cases, failure modes

| Risk / edge case | Behavior / mitigation |
|---|---|
| **Two Apple analyzers disallowed/too heavy on 26** | Measure first (§4.3). Fall back to mic-only via `TranscriptionBackend`; or run far-end on a lighter backend. Branch already degrades on throw. |
| **All-zero PCM tap bug on long calls** | Watchdog rebuilds tap+aggregate (§4.2). Cap rebuilds; degrade to mic-only after the cap; honest UI. Only rebuild when the MIC is still hot (so genuine silence ≠ dead tap). |
| **Far-end permission denied / never granted** | No public preflight → infer from outcome; record mic-only; show denial note + Permissions row + probe. Never block the meeting. |
| **WebRTC app emits from a helper subprocess** | Global tap excluding self already captures it (the whole reason for global-not-per-app). |
| **Genuine long silence (mute, hold, waiting room)** | Watchdog window long enough (≥90 s) + mic-hot cross-check to avoid false rebuilds. |
| **Clock drift mic↔tap over hours** | Drift compensation on; diarization by **arrival time** not sample time → drift only nudges ordering, not attribution. |
| **3+ speakers, diarizer merges/splits wrong** | Diarization is enrichment, not a gate: on low confidence or failure, keep plain "Them". Stable first-spoken ordering for labels. |
| **FluidAudio model missing in default build** | `modelsAvailable == false` → skip diarization silently, plain "Them". No implicit fetch. |
| **Crash mid-recording** | `recoverPartialIfNeeded()` already turns the partial into a Meeting; participant shape inferred from `"] Them:"` presence. Temp `.caf` orphan cleaned on next launch. |
| **Aggregate device leak on crash** | Private aggregates auto-reap on process death; add graceful teardown on `willTerminate`. |
| **Long meeting > 8000 chars** | Map-reduce summarizer (§4.6); transcript itself is never truncated. |
| **User dictates during a recording** | Already guarded both ways (shared mic engine); far-end's dedicated engine doesn't change this. |
| **Foundation Models unavailable (AI off)** | Transcript + Markdown still save; summary empty (`MeetingSummarizer` returns nil), as today. |

## 13. Testing & verification

- **Unit (add a test target — none exists today):**
  - `MeetingTranscriptRenderer.render` — solo → plain; two-speaker → coalesced
    `[mm:ss] Me/Them:`; 3+ speakers → `Speaker N` labels; ordering by elapsed.
  - `FarEndDiarizer.assign` — max-overlap alignment on synthetic spans/turns
    (boundary cases: turn straddling two speakers, zero overlap → nearest, gaps).
  - `Meeting` decode — pre-Phase-2 JSON (no participants/source) loads with defaults;
    3-name participants round-trips through `writeMarkdown`.
  - `timecode` — sub-hour `mm:ss`, past-hour `h:mm:ss`.
- **Manual (`/run` the app on the deployment OS):**
  1. 1:1 Zoom/Meet call → verify `[mm:ss] Me:` and `[mm:ss] Them:` interleave
     correctly; both level meters move.
  2. **Two-analyzer load run** (§4.3) — Instruments CPU/ANE/memory over 30 min;
     record numbers in the PR.
  3. **>30-min / overnight stability** — confirm the watchdog logs a rebuild if the
     tap goes silent (force by toggling the output device) and recovers; no aggregate
     leak (`AudioObjectGetPropertyData` device list before/after).
  4. **Permission flow** — fresh TCC: first record triggers the prompt; deny →
     mic-only + denial note + Permissions row "Blocked"; grant via probe → "Working".
  5. **Group call (3+ far-end)** — verify Speaker 1/2/3 split and stable numbering.
  6. **Crash recovery** — kill mid-recording; relaunch; partial becomes a Meeting.
- **Privacy verification (`/verify`-style):** with Little Snitch / `nettop`, confirm
  **zero** outbound connections during a full meeting in the default build;
  `grep -rniE "URLSession|http" Sources/` clean.
- **Merge gate:** the §4.7 checklist, all green.

## 14. Effort & phasing

| Sub-step | Size | Notes |
|---|---|---|
| **MVP slice** = rebase + merge the branch as-is | **S** | Conflict-free rebase; build; smoke a 1:1 call; ships Me/Them today. |
| `TranscriptionBackend` seam + conform `TranscriptionEngine` (`AppleSpeechBackend`) | **M** | Tier-0 spine refactor, no behavior change; do alongside merge so far-end holds `any TranscriptionBackend`. |
| Two-analyzer load measurement + fallback wiring | **S–M** | Mostly measurement; fallback path largely exists. |
| Zero-PCM watchdog (RMS counters, `checkHealth`, rebuild, caps) | **M** | The highest-value robustness fix for real long meetings. |
| Audio Recording permission UX (model state, probe, 4th row, denial note, first-run) | **M** | No public API → outcome inference; verify the Settings deep-link anchor on-device. |
| Far-end `.caf` sink + optional retention setting | **S–M** | Reuses the converter; needed for offline diarization. |
| Map-reduce long-meeting summary (above `Summarizer`) | **M** | Shared with feature 02. |
| **Phase 3 — FluidAudio diarization** (dependency, wrapper, alignment, labels) | **M–L** | Separate PR; gated by the CC-BY-4.0 weights decision (§10/§11) and the model-fetch privacy gate. |

**Recommended order:** MVP merge (S) → watchdog + permission UX (the production
must-haves) → `TranscriptionBackend` seam + load verification → map-reduce summary →
Phase-3 diarization last (it carries the dependency + license decision).

## 15. Dependencies & interactions

- **Needs (soft):** **04 calendar** (`MeetingContextProvider`) for names → bias +
  note titles — optional, degrades to timestamp title. **20 `TranscriptionBackend`**
  — land the protocol now (Tier 0) so the two-stream fallback and a lighter far-end
  backend are clean swaps. **`Summarizer` protocol** for map-reduce.
- **Enables:** **05 context graph** (its richest feed — attributed Me/Them/Speaker N
  turns with timestamps → meeting `Provenance`, Person/counterparty entities). **02
  notes fusion** (a real two-sided transcript to fuse with notes). **09
  cross-surface** ("email Sarah the action items from my last meeting" is only
  possible with attributed meeting transcripts). **18 cloud accuracy** (a
  `MeetingTranscriptionBackend` slot for AssemblyAI/Deepgram diarization, opt-in,
  behind 15's wall).
- **Overlaps:** **03 auto-detect** shares the Core Audio process-scan world (process
  list, meeting-app allowlist) — keep capture and detection separate (capture is
  manual today; 03 adds the banner). **15 sandbox/zero-net** — must validate process
  taps + FluidAudio under the sandbox and keep the model-fetch behind the wall.
- **First merge to land (Tier 0, per spine §5):** far-end → main *early*, because it
  gives the graph its best data; its production gaps (watchdog, two-analyzer load,
  TCC UX) are hardening, **not** merge blockers.

---

### Sources (external facts verified for this plan)

- FluidAudio — README / API / Getting Started, Swift Package Index, Hugging Face
  model card: `OfflineDiarizerManager` (pyannote-parity), `DiarizationResult`
  (start/end/speaker), 16 kHz mono Float32 input, auto-download from Hugging Face,
  Apache-2.0 code + **pyannote Community-1 CC-BY-4.0 weights**, macOS 14+, SPM
  `github.com/FluidInference/FluidAudio.git` (latest v0.15.3).
  https://github.com/FluidInference/FluidAudio ·
  https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md ·
  https://huggingface.co/FluidInference/speaker-diarization-coreml ·
  https://deepwiki.com/FluidInference/FluidAudio/3.2.2-diarization-pipeline
- Core Audio process-tap all-zero-buffer bug + "rebuild both tap and aggregate":
  Apple Developer Forums thread 825780.
  https://developer.apple.com/forums/thread/825780
- SpeechAnalyzer / SpeechTranscriber concurrency (no documented multi-instance
  guarantee; sample apps use one analyzer): WWDC25 session 277; Apple Developer
  Forums; FluidInference/swift-scribe.
  https://developer.apple.com/videos/play/wwdc2025/277/ ·
  https://github.com/FluidInference/swift-scribe
- Audio-capture TCC: no public preflight/request API; prompt on first tap;
  `NSAudioCaptureUsageDescription` manual plist key; permission lives in **Screen &
  System Audio Recording**: insidegui/AudioCap; Apple docs; Apple Support.
  https://github.com/insidegui/AudioCap ·
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription ·
  https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac
