# Talkie — Current-State Map (ground truth)

> The single authoritative map of the codebase as it exists today. Every other
> planning agent should rely on this. All paths are absolute. `file:line` anchors
> point at `main` (HEAD `261ed66`) unless explicitly marked **[branch]**.
>
> **Generated:** 2026-06-14 by the codebase-cartographer pass.
> **Floor:** macOS 26.0, Apple Silicon, Swift 6 strict concurrency (`.v6` mode).
> **Privacy invariant (verified):** zero network code anywhere. `grep -rniE
> "URLSession|NSURLConnection|http://|https://"` over `Sources/` returns NOTHING
> on both `main` and `feat/meeting-far-audio`. The only entitlement is
> `com.apple.security.device.audio-input`. Everything is on-device.

---

## 0. Source inventory (33 files, ~6,673 LoC on main)

All Swift lives flat in `/Users/jann/Talkie/Sources/Talkie/`. Build target is a
single SwiftPM executable (`/Users/jann/Talkie/Package.swift` — `swift-tools-version:6.0`,
`.macOS("26.0")`, `.swiftLanguageMode(.v6)`, no external dependencies).

| Area | Files |
|---|---|
| **Entry / app shell** | `main.swift`, `AppDelegate.swift` |
| **Dictation pipeline** | `HotKeyMonitor.swift`, `AudioCapture.swift`, `TranscriptionEngine.swift`, `CleanupEngine.swift`, `DictationAssembler.swift`, `TextInjector.swift`, `LanguageDetector.swift` |
| **Learning / dictionary / context** | `LearningEngine.swift`, `DictionaryStore.swift`, `AppContext.swift`, `VibeCoding.swift`, `ContextSummary.swift` |
| **Meetings** | `Meeting.swift`, `MeetingRecorder.swift`, `MeetingsView.swift` (+ **[branch]** `SystemAudioCapture.swift`, `MeetingTranscript.swift`) |
| **Persistence / stores** | `HistoryStore.swift`, `StatsStore.swift`, `AppUsageStore.swift`, `ActivityStore.swift`, `AppPaths.swift` |
| **UI** | `DashboardView.swift`, `SettingsView.swift`, `OnboardingView.swift`, `VibeCodingView.swift`, `HUD.swift`, `MarkdownText.swift`, `DesignSystem.swift` |
| **Config / settings / misc** | `AppSettings.swift`, `Permissions.swift`, `LaunchAtLogin.swift`, `Feedback.swift` |

Resources: `/Users/jann/Talkie/Resources/{Info.plist, talkie.entitlements,
AppIcon.icon/, Fonts/}`. Scripts: `/Users/jann/Talkie/scripts/{build_app.sh,
run.sh, notarize.sh}`. Docs: `/Users/jann/Talkie/docs/{BRAND.md, MEETING_MODE.md,
CLAUDE_DESIGN_PROMPT.md}`.

---

## 1. The end-to-end dictation pipeline

### 1.1 Lifecycle / orchestration — `AppDelegate.swift`

`AppDelegate` (`@MainActor`, owns every store) is the conductor. It is a regular
Dock app (`setActivationPolicy(.regular)`, `main.swift:22`) **plus** a menu-bar
status item. `main.swift:8-16` enforces single-instance (hands off to an existing
PID and exits).

`applicationDidFinishLaunching` (`AppDelegate.swift:49`):
- builds the shared `TranscriptionEngine(localeIdentifier:)` (`:56`),
- builds `MeetingRecorder(engine:store:)` reusing that engine (`:57`) and wires
  `isDictating` + `recoverPartialIfNeeded()` (`:58-59`),
- `setupMainMenu/StatusItem/EngineHandler/HotKey` (`:61-64`),
- warms each spoken language's speech model in the background (`:71-73`),
- opens the main window on the Dashboard tab (`:77`).

**Hotkey → dictation funnel (`:240-263`):** press/release edges are funneled through
ONE ordered `AsyncStream<DictationEvent>` consumed by a single `@MainActor` task
(`:244-253`). This is deliberate — two independent Tasks have no FIFO guarantee on
the MainActor executor, so a `begin` could otherwise be scheduled after its `end`.

**`beginDictation()` (`:291-384`):**
1. Guards: not already dictating, engine available, no meeting recording in flight
   (shared engine, `:299`).
2. Recursive self-improvement: if `learnFromEdits`, drains `LearningEngine.collectCorrections()`
   into the dictionary BEFORE the session (`:306-310`).
3. Bumps `sessionID` (generation token), shows the HUD, plays the start cue.
4. `ContextCapture.capture(...)` grabs the target app + (optionally) mined phrases
   (`:323-326`); snapshots the vibe-coding project index (`:327`).
5. Builds the recognizer bias set = custom vocab ∪ on-screen names ∪ project
   filenames, deduped, capped at **180** phrases (`:331-334`).
6. Captures the cleanup config at session START so a mid-session toggle can't skew
   end-of-session accounting (`:342-345`).
7. Async: requests mic, re-checks `sessionID == myID` after every `await`
   (`:351,363`), sets contextual strings, `engine.beginSession()`, starts
   `AudioCapture`. `bufferAudio:` is true only when multiple languages are set
   (for re-transcription). Sets `sessionLive`/`recordingStartedAt` (`:375-376`).

**`endDictation()` (`:386-528`)** — the heavy post-processing pipeline, all off
the begin task:
1. If never went live, just resets UI (`:394-397`).
2. `engine.finishSession()` → raw transcript (`:425`).
3. **Language auto-detect** (`:430-439`): if >1 language and `LanguageDetector.detect`
   finds a *different* one, re-transcribes the buffered audio in that language via
   `engine.transcribeBuffered(...)` and sticks to it.
4. **On-device LLM cleanup** (`:447-460`): one pass on the whole transcript when
   `≤ wholeCleanupCharLimit` (2200 chars, `:560`) so cross-pause self-corrections
   resolve with full context; else sentence-batched (`cleanInBatches`, `:564-592`).
   Adaptive style vs. fixed level chosen per the session config.
5. **Dictionary applied AFTER the LLM** so the user's exact spellings always win
   (`TextProcessor.apply`, `:465-470`). Fillers are skipped here if the AI already
   handled them (`aiHandledFillers`, `:461`).
6. **Vibe coding** filename snapping (`SpokenFileMatcher.format`, `:476-480`).
7. Logs to `HistoryStore`, lifetime `StatsStore`, `ActivityStore`, `AppUsageStore`
   (`:489-504`). `AppUsage` is skipped when the target is Talkie itself.
8. `TextInjector.insert(finalText, mode:)` (`:506`); outcome drives HUD + the
   learning snapshot (`recordInsertion` after a 350ms delay, `:514-520`).

`sessionCleanup` accounting and `wordEditCount`/`splitIntoBatches` are static
helpers at `:558-599`.

### 1.2 Hotkey — `HotKeyMonitor.swift`

`@unchecked Sendable`, lock-guarded. A **listen-only** `CGEventTap`
(`.listenOnly`, `:75`) so it needs only **Input Monitoring** and never swallows
the key (the modifier still works normally elsewhere). The tap is created
synchronously on the caller's thread; its run-loop runs on a dedicated named
thread (`:86-104`) so a busy main thread can't trip the system tap-timeout.

- Keys: Right ⌥ / Left ⌥ / Right ⌃ only. **Fn/Globe was removed** — macOS reserves
  it for input-source switching (`AppSettings.swift:8-9`, `HotKeyMonitor.swift:243-262`).
  Left/right of a modifier pair are distinguished by device-dependent flag bits
  (`isDown(in:)`, `:255-261`).
- Modes: `holdToTalk` and `toggle` (`:194-211`).
- Self-healing: a 3s `DispatchSourceTimer` re-enables a disabled tap and calls
  `reconcileLiveState()` to release a stuck key if a key-up was dropped (`:152-169,
  219-238`). `start()` returns false if Input Monitoring isn't granted yet.

### 1.3 Mic capture — `AudioCapture.swift`

`@unchecked Sendable`. `AVAudioEngine` input tap (`:95`), converts each buffer via
`AVAudioConverter` to the format `SpeechAnalyzer` requested. The converter is
captured by value in the tap block (never read from a mutable property on the
render thread) — the documented Swift-6-clean concurrency pattern. `primeMethod
= .none` avoids streamed-buffer drift (`:87`). Optional `CapturedAudio` ring
(NSLock-guarded, capped ~90 s, `:19-41`) retains converted audio for
language re-transcription. `level(of:)` produces the 0…1 dB-mapped RMS for the
HUD waveform (`:116-129`). `SingleShotInput` (`:7-14`) hands one buffer to the
converter exactly once.

### 1.4 Transcription — `TranscriptionEngine.swift`

An `actor` wrapping Apple's **`SpeechAnalyzer` + `SpeechTranscriber`** (macOS 26).
One instance reused across sessions; the heavy model load lingers for process
life.

- `isAvailable` = `SpeechTranscriber.isAvailable` (`:81`).
- `resolvedLocale()` falls back to `en-US` (`:86-94`); `ensureModelInstalled`
  triggers the one-time per-locale download via `AssetInventory` (`:98-108`).
- `makeTranscriber` requests `.volatileResults` so the HUD gets live partials;
  `attributeOptions: []` — **timestamps/`.audioTimeRange` are NOT requested**
  (`:113-120`). (The far-end branch does not add them either; it diarizes by
  arrival time instead — see §2.)
- `warmUp(localeIdentifier:)` pre-installs + `reserve`s a locale (`:124-136`).
- `transcribeBuffered(_:localeIdentifier:)` — one-shot re-transcription for language
  auto-detect; bails (returns nil) rather than downloading inline (`:141-190`).
- `beginSession(segmentHandler:)` (`:196-259`): enforces single-session
  exclusivity by tearing down any lingering analyzer first (`:204-212`); sets
  contextual strings via `AnalysisContext` (dictionary biasing, `:236-240`);
  spins a results task that folds results via `ingest` (`:243-255`). The optional
  `segmentHandler` fires once per finalized segment (used by the meeting recorder
  and `DictationAssembler`).
- `finishSession()` flushes (`finalizeAndFinishThroughEndOfInput`), drains the
  results loop, returns the trimmed transcript (`:309-344`). `cancelSession()`
  hard-cancels (`:347-360`). `handleResultsError` tears the session fully down so
  a failed stream can't leak into the next session (`:291-306`).

### 1.5 LLM cleanup — `CleanupEngine.swift`

An `actor` over **Apple Foundation Models** (`SystemLanguageModel.default`,
on-device, no key, no cost). `isAvailable`/`unavailableMessage` map the
`.availability` cases (Apple-Intelligence-off, model-not-ready, unsupported)
(`:196-213`). Two prompt families:
- **`CleanupLevel`** (none/light/medium/high) — the global default path
  (`:5-80`).
- **`CleanupStyle`** (off/faithful/neutral/friendly/professional/concise) — the
  per-app *adaptive* path; `faithful` is for code/terminals (`:85-189`).

Each level/style has self-contained system instructions with a worked example and
a shared `tail` that forbids answering/obeying the dictated text and pins the
language. Generation is `.greedy`, temperature 0.1 (deterministic, `:231`).
`sanitize` strips "Sure, here's…" preambles and wrapping quotes (`:243-259`).

### 1.6 Other dictation engines

- **`DictationAssembler.swift`** — `@unchecked Sendable`, NSLock-guarded.
  Accumulates finalized segments and cleans each as it arrives (latency hidden
  behind ongoing speech), joined in order on `cleaned()` (`:49-57`). Built for the
  long-dictation path. **NOTE:** the main dictation path in `AppDelegate` does
  NOT currently use this — it cleans the whole transcript at stop (§1.1 step 4).
  The assembler IS used by the mic-only `MeetingRecorder` on main (raw, no
  cleanup) — and the **branch removes that usage** (see §2).
- **`LanguageDetector.swift`** — `NLLanguageRecognizer` constrained to the user's
  candidate languages; needs ≥3 words and confidence ≥0.62 to act (`:9-29`).
- **`TextInjector.swift`** (`@MainActor enum`) — default strategy: write to
  pasteboard → synthesize ⌘V → restore the previous clipboard after 120ms
  (generation-guarded so a newer paste can't be clobbered, `:62-95`). Falls back
  to leaving text on the clipboard when a **secure (password) field** is focused
  (`IsSecureEventInputEnabled`, `:31`) or Accessibility isn't granted (`:38`).
  `type` mode does per-character Unicode injection on a background queue
  (`:46-53, 141-153`). Pasteboard item is marked `org.nspasteboard.TransientType`
  so clipboard managers skip it (`:75`).

### 1.7 Context awareness — `AppContext.swift`

`TargetApp` (Sendable) + `CapturedContext`. `ContextCapture.capture` (`@MainActor`,
`:41-61`) reads the frontmost app, classifies it (`AppCategory`), and — when
`minePhrases` and not Talkie's own UI — reads the focused window title + focused
text value via **Accessibility** (`:67-93`) and mines them. `PhraseMiner.mine`
(`:99-151`) extracts proper nouns, CamelCase/snake_case identifiers, and filename
tokens, deduped, capped at 40, with a stopword list. Read-only, degrades
gracefully when AX is unavailable (Electron/sandboxed apps).

### 1.8 Vibe coding — `VibeCoding.swift`

`ProjectIndexStore` (`@MainActor ObservableObject`) persists a scanned folder's
filenames+symbols to `project_index.json` and rebuilds an immutable Sendable
`ProjectIndexSnapshot` on change. `ProjectScanner.scan` (`:109-136`) walks the
folder off-main, skips heavy dirs (`node_modules`, `.git`, …), keeps known code
extensions, caps at **6000** files. `SpokenFileMatcher` (`:143-309`):
`buildSnapshot` generates every spoken key for a filename ("exercise library tsx",
"dot t s x", contiguous, etc.); `format` greedily matches the longest spoken
window against the key map and substitutes the canonical, correctly-cased filename,
returning a hit count. Interior punctuation tokens BLOCK a match (`:226`) so words
on either side can't masquerade as adjacent.

### 1.9 Learning — `LearningEngine.swift`

`@MainActor`. After insertion, `recordInsertion` snapshots the focused AX element's
value (`:23-29`). Before the next dictation, `collectCorrections` re-reads it; if
it's the SAME element and changed, `CorrectionExtractor.extract` (`:62-98`) does a
word-level diff and learns ONLY an unambiguous single-word swap (exactly one
removal + one insertion) — multi-word diffs are rejected because the
remove/insert offsets live in different coordinate spaces and would poison the
dictionary. Best-effort: native fields expose AX values; some web/Electron apps
don't.

---

## 2. The meeting recorder — main (mic-only) vs. `feat/meeting-far-audio`

### 2.1 What's on `main` (Phase 1, mic-only)

`MeetingRecorder.swift` (`@MainActor ObservableObject`) reuses the **shared**
`TranscriptionEngine` (so dictation and recording are mutually exclusive — guarded
both ways, `AppDelegate.swift:299` and `MeetingRecorder.swift:39`).

- `start()` (`:36-66`): mic permission → `engine.beginSession(segmentHandler:)`
  feeding a `DictationAssembler` with `clean: { _ in nil }` (raw, no per-segment
  LLM) → `audio.start`. Writes an empty `.recording.partial.txt` and starts a 1s
  timer.
- `tick()` (`:68-75`): flushes the running raw transcript to the partial file for
  crash safety.
- `stop()` (`:78-109`): `engine.finishSession()` → `MeetingSummarizer.summarize`
  (`Meeting.swift:19-50`, capped at 8000 chars, greedy temp 0.3) → `store.add`.
- `recoverPartialIfNeeded()` (`:113-128`): on launch, turns a crash-left partial
  into a Meeting (no summary) before any new recording overwrites the file.

`Meeting.swift`: `Meeting` struct (Codable), `MeetingSummarizer` actor, and
`MeetingStore` (`@MainActor ObservableObject`) which writes one Markdown file per
meeting to `~/Talkie Meetings/` with YAML frontmatter (`writeMarkdown`, `:88-109`,
hardcodes `source: talkie (mic-only)` on main) plus a lightweight `meetings.json`
index. The `.md` files are the durable copy.

`MeetingsView.swift`: record card (start/stop/finishing states), folder row
("Saved to ~/Talkie Meetings/"), meeting rows with summary (rendered via
`MarkdownText`) + collapsible transcript. On main the record-card subtitle says
"Mic only for now (captures your side and anyone in the room)."

### 2.2 What the `feat/meeting-far-audio` branch ADDS (Phase 2)

**Branch status (precise):**
- Branch HEAD `aa477a3`, **single commit** "feat(meeting): Phase 2 — far-end
  audio capture (Me / Them labels)".
- Merge-base with main is `c31618a` (the "macos26 p4" commit — i.e. the branch
  was cut AFTER the full v2 visual redesign).
- The branch is **3 commits behind main** (`261ed66` Monday-week heatmap,
  `f9f673e` dictionary chips, `9d82160` dashboard card heights). The diffs that
  appear in `DesignSystem.swift`, `DashboardView.swift`, `ActivityStore.swift`,
  `SettingsView.swift` when you `git diff main..feat/meeting-far-audio` are
  **those 3 main-only commits showing in reverse** — they are NOT changes the
  branch made. The branch's own feature touches only the meeting files + Info.plist
  + the `AppDelegate`/`MeetingsView` wiring below.
- **Not merged. Cleanly rebaseable** (no overlap between the branch's feature
  files and the 3 main-only UI commits).

**New files [branch]:**

- **`SystemAudioCapture.swift`** (266 lines, `@unchecked Sendable`). The
  far-end capture. Core Audio **global process tap excluding Talkie's own PID**
  → private **aggregate device** → realtime I/O proc → `AVAudioConverter` →
  yields `AnalyzerInput` into a second analyzer. Key mechanics:
  - `audioObject(forPID:)` translates self via
    `kAudioHardwarePropertyTranslatePIDToProcessObject`.
  - `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, `isPrivate = true`,
    `muteBehavior = .unmuted` (you still hear the call).
  - `AudioHardwareCreateProcessTap` → `kAudioTapPropertyFormat` (`tapFormat`) →
    `AudioHardwareCreateAggregateDevice` with `kAudioSubTapDriftCompensationKey:
    true` and `kAudioAggregateDeviceTapAutoStartKey: true`.
  - `AudioDeviceCreateIOProcIDWithBlock` on a dedicated `DispatchQueue`; the
    block wraps the bufferlist no-copy, converts, yields. Converter captured by
    value (Swift-6-clean).
  - `cleanUpCoreAudio()` tears down in dependency order, safe from a partial
    state. Typed `SystemAudioError`. `isSupported` gate (macOS 14.4+; ships on 26).
  - **Rationale (from `docs/MEETING_MODE.md`):** a *global* tap excluding self is
    the reliable path — a *per-app* tap records silence for WebRTC apps (Zoom/Teams
    emit from helper subprocesses). Needs only the light "Audio" permission, not
    Screen Recording.

- **`MeetingTranscript.swift`** (93 lines). `MeetingSpeaker` enum (`.me`/`.them`).
  `TurnLog` (`@unchecked Sendable`, NSLock-guarded) stamps every finalized segment
  with its **arrival time** relative to recording start — this is the diarization
  key: no `.audioTimeRange`, no ML, "the stream tells you the speaker for free."
  `MeetingTranscriptRenderer.render` sorts by elapsed time; if only one speaker
  spoke it renders plainly (identical to Phase 1 shape); if both spoke it coalesces
  consecutive same-speaker turns and labels each block `[mm:ss] Me: …` /
  `[mm:ss] Them: …` (`timecode` gives `h:mm:ss` past an hour).

**Modified files [branch]:**

- **`MeetingRecorder.swift`** (rewired, +110 lines): adds `@Published
  capturingFarEnd`; a `farEngine: TranscriptionEngine?` (dedicated, built per
  recording for "Them"); replaces the `DictationAssembler` with a `TurnLog`. Two
  streams started in `start()` — mic → `engine` tagged `.me`; far-end → `farEngine`
  + `SystemAudioCapture` tagged `.them` (best-effort, **degrades cleanly to
  mic-only** on any failure: unsupported OS, permission denied, two-analyzers
  refused). Adds `isStarting`/`cancelStart` flags to make the multi-`await` start
  window abortable by a mid-start `stop()`. `stop()` stops both captures, finalizes
  both engines, renders via `MeetingTranscriptRenderer`, sets `participants` =
  `["Me","Them"]` or `["Me"]` **from capture state (not who spoke)**, and `source`
  = "talkie (mic + system audio)" / "talkie (mic-only)". `recoverPartialIfNeeded`
  infers participants from whether the partial contains `"] Them:"`.

- **`Meeting.swift`** [branch]: adds `participants: [String]` and `source: String`
  fields with a custom `init(from:)` that `decodeIfPresent`s them (back-compat for
  pre-Phase-2 notes); `writeMarkdown` now emits `participants: [...]` and the
  dynamic `source`.

- **`AppDelegate.swift`** [branch]: injects `meetingRecorder.primaryLocale = { ...
  spokenLanguages.first ... }` so the far-end transcriber tracks the language
  setting (+3 lines at `:59`).

- **`Resources/Info.plist`** [branch]: adds `NSAudioCaptureUsageDescription`
  ("During meeting recording, Talkie captures your Mac's audio … Audio stays on
  your Mac."). **This key must be present or tap creation fails/prompts silently.**

- **`MeetingsView.swift`** [branch]: honest status copy — "Recording you + the
  call…" vs "Recording (mic only)…", and the record-card subtitle now describes
  Me/Them labeling.

### 2.3 Precise remaining gaps (per `docs/MEETING_MODE.md` phasing)

- **Phase 3 — multi-speaker diarization: NOT built.** Far-end "Them" is one bucket;
  3+ people on the far end aren't split. The design calls for **FluidAudio**
  (Apache-2.0 code, CoreML/ANE) aligned by timestamp-overlap. (License caveat:
  FluidAudio's weights derive from pyannote Community-1 CC-BY-4.0 — verify before
  public release.)
- **Phase 4 — online accuracy mode: NOT built.** No `Diarizer`/`Transcriber`
  protocol, no AssemblyAI/Deepgram client, no consent toggle. (Would be the FIRST
  network code in the app — must be opt-in + disclosed + architecturally separated
  per the privacy invariant.)
- **Phase 5 — auto-detect: NOT built.** No Core Audio process scan, no meeting-app
  allowlist, no "Meeting detected — recording?" banner. Today recording is
  fully manual (a button in the Meetings tab; **no global hotkey or menu item**).
- **Open risks not yet mitigated** (from the design doc): the Core Audio
  long-session all-zero-PCM watchdog is NOT implemented; no `.caf` raw-audio
  retention option; map-reduce summarization for long meetings is NOT done
  (`MeetingSummarizer` hard-caps input at 8000 chars — long meetings are truncated).
- **No persistent global "recording" indicator** beyond the in-app pill + the
  menu-bar mic; the design's "persistent, obvious recording indicator" and
  "one-keystroke Stop" are only partially met (in-window only).

---

## 3. Persistence / data stores — on-disk paths & formats

`AppPaths.swift` defines the two roots:
- **`~/Library/Application Support/Talkie/`** (`supportDirectory()`, `:7-13`) —
  app data (JSON).
- **`~/Talkie Meetings/`** (`meetingsDirectory()`, `:17-22`) — deliberately a
  plain home folder, **NOT** `~/Documents` (which is TCC-protected), so meeting
  Markdown is trivial to point Claude at.

| Store | File | Format | Notes |
|---|---|---|---|
| `DictionaryStore` | `dictionary.json` | `{replacements:[Replacement], vocabulary:[String]}` | Seeds one default rule `talkie→Talkie`. Persistence driven by view `.onChange`. `Replacement` has `from/to/caseSensitive/wholeWord/learned?`. |
| `HistoryStore` | `history.json` | `[DictationEntry]` newest-first | **7-day retention**, cap 2000, pruned on load+add. Carries `appName/appCategory`. |
| `StatsStore` | `stats.json` | lifetime totals | Words/dictations/duration/`bestWPM` + fix tallies (`dictionaryFixes/fillersRemoved/aiWordsChanged`). Optional fields for back-compat. Kept SEPARATE from 7-day history so totals survive pruning. |
| `AppUsageStore` | `appusage.json` | `[String:AppUsage]` keyed by bundleID | Per-app word/dictation counts → "where your words go". |
| `ActivityStore` | `activity.json` | `[String:DayStat]` keyed `yyyy-MM-dd` | One tiny record per active day, kept **indefinitely** → streak + heatmap. Calendar `firstWeekday = Monday` (`:38`). |
| `ContextSummaryStore` | `context_summary.json` | `{summary, generatedAtUnix?}` | The on-device daily "Brief". |
| `ProjectIndexStore` | `project_index.json` | `{folderPath, scannedAtUnix, files, symbols}` | Vibe-coding folder scan. |
| `MeetingStore` | `meetings.json` (index) + per-meeting `.md` in `~/Talkie Meetings/` | JSON index + Markdown w/ YAML frontmatter | `.md` is the durable copy; `.md` name = `yyyy-MM-dd-HHmm-meeting.md`. |
| `MeetingRecorder` | `~/Talkie Meetings/.recording.partial.txt` | plain text | Crash-safety flush during recording. |
| `AppSettings` | `UserDefaults` (not a file) | scalar prefs | See §4.5. |

All file writes use `.atomic`. Decoding is failure-tolerant (try?/decodeIfPresent)
throughout for forward/back-compat.

---

## 4. App wiring

### 4.1 Entry & windows
- `main.swift`: single-instance guard, regular Dock app.
- `MainWindowController` (`SettingsView.swift:56-115`): a 980×700 `NSWindow`,
  `.fullSizeContentView`, hidden/transparent titlebar, movable by background,
  opaque white/black canvas (the `NavigationSplitView` supplies the Liquid Glass
  sidebar). `isReleasedWhenClosed = false`; frame autosaved.
- Closing the window keeps Talkie alive
  (`applicationShouldTerminateAfterLastWindowClosed → false`,
  `AppDelegate.swift:92`); Dock-click reopens (`:86-89`).

### 4.2 Menu bar & main menu
- Status item (`AppDelegate.swift:151-193`): `mic.fill` (→ `waveform` red while
  dictating), tooltip, and a menu (status line, hint line, Dictionary…, Settings…,
  Quit). Has a title fallback so a missing SF Symbol can't make it zero-width.
- Main menu (`:107-147`): App / Edit / Window menus so ⌘Q, ⌘C/⌘V/⌘A, etc. work
  (needed because it's a regular app with text fields & a History list).

### 4.3 Navigation / tabs
`SettingsTab` (`SettingsView.swift:4-46`): **dashboard, history, meetings,
dictionary, vibeCoding, general** — each with an SF Symbol and a per-item macaw
**feather tint** (`.listItemTint`). `SidebarList` (`:176-208`) is a native
`List(... selection:)` inside `NavigationSplitView` → automatic macOS 26 Liquid
Glass sidebar; the activation hint pins to the bottom via `.safeAreaInset`. A red
badge appears on **general** when permissions aren't all granted.

`MainView` (`:117-167`) gates on `settings.hasOnboarded`: shows `OnboardingView`
or the split view. `content` switches to the per-tab view (`:149-167`).

### 4.4 Settings panes (`SettingsView.swift`)
`SettingsHome` (`:399-476`) is an index of rows each pushing a focused `SubPage`
(`:479-497`) via `NavigationStack` — so no single screen floods the user:
- **Profile** (name), **Activation & insertion** (key/mode/insertion),
  **Cleanup & style** (adaptive toggle + per-`AppCategory` `CleanupStyle` pickers
  via `AppStylePickers`, OR the fixed `CleanupLevel` segmented control; surfaces
  `CleanupEngine.unavailableMessage`), **Languages** (multi-select catalog),
  **Context & learning** (two toggles), **Behavior** (sounds, login),
  **Permissions** (the 3-permission grid + Re-check + Quit&Reopen relaunch).
- `DictionarySettings` (`:634-721`): custom-vocab chips (FlowLayout) + replacement
  rows; learned rules wear a coral `sparkles` badge. `HistorySettings` (`:232-297`):
  copy-all/clear + rows. `PermissionsSettings`/`PermissionRow` (`:783-878`).

### 4.5 `AppSettings.swift` (UserDefaults-backed `@MainActor ObservableObject`)
Keys/defaults (`:151-211`): `activationKey` (rightOption), `activationMode`
(holdToTalk), `insertionMode` (paste), `localeIdentifier`/`spokenLanguages`
(`talkieLanguageCatalog`, 11 langs, `:58-70`), `autoCapitalize` (true),
`cleanupFillers` (true), `learnFromEdits` (true), `cleanupLevel` (medium),
`appAdaptiveCleanup` (true) + `appCleanupStyles` (per-category defaults at
`:193-202`: coding/terminal→faithful, mail→professional, chat→friendly, …),
`contextAwareness` (true), `vibeCoding` (false), `userName`, `hasOnboarded`,
`playSounds` (true), `launchAtLogin` (false). Mutations that affect the hotkey/
language/sounds post `.talkieSettingsChanged`; `AppDelegate.observeSettings`
(`:265-287`) re-binds the hotkey, re-warms languages, and switches the live engine
locale.

### 4.6 Onboarding (`OnboardingView.swift`)
3 steps (welcome+name → gesture explainer → 3 permissions). Finishing sets
`hasOnboarded`. Coral progress dots, parrot icon, keycap visuals.

### 4.7 HUD (`HUD.swift`)
`HUDController` manages a borderless **non-activating** `NSPanel`
(`.canJoinAllSpaces`, floating, ignores mouse) near the bottom-center of the
active screen. The SwiftUI pill uses real macOS 26 **`.glassEffect`** (`:152`) and
shows ONLY a live `Waveform` while active — **the transcript never appears in the
pill** (it goes to the focused app + History). Phases: listening / transcribing /
processing ("Polishing…") / inserting / error. Levels arrive via `updateLevel`
from the mic tap.

---

## 5. Design system & brand tokens (`DesignSystem.swift`, `docs/BRAND.md`)

**IMPORTANT — the code is "v2", which has DIVERGED from `docs/BRAND.md`.** The
doc still describes the v1 *ivory/coral* identity; the shipped tokens are a
native macOS 26 *white/blue/true-black* system. Treat `DesignSystem.swift` as the
source of truth for *values* and `BRAND.md` for *philosophy* (warm/honest/quick,
voice & tone, the macaw, feathers-for-data-only).

- **Surfaces:** `canvas` pure white / true black; `surface`, `surfaceSunken`,
  `canvasRaised` lift by contrast + a whisper shadow (borderless, `:28-34`).
- **Brand accent:** **macaw BLUE** kept under the historical name `Theme.coral`
  (light `0x1F66B3` / dark `0x4AA0E6`) so every call site stays valid — value is
  blue, not coral (`:44-56`). Aliases `Theme.brand/brandDeep/brandWash`.
- **Feather palette (data + nav tints only):** `featherCoral`(red)/Gold/Blue/
  Green/Plum, `categorical` ramp (`:58-70`).
- **Heatmap:** deep-red ramp `Theme.heat(0…4)` (`:75-83`).
- **Type:** `Font.talkieDisplay/.talkieMetric` = bundled **Young Serif**
  (`Resources/Fonts/`, registered via `ATSApplicationFontsPath`), graceful
  `.system(design:.serif)` fallback when unbundled (`TalkieFonts`, `:139-152`).
  `talkieHeading` = SF Pro; `talkieEyebrow` 11pt caps.
- **Shape/elevation:** squircle corners (`Radius.card 22`/control 13/chip 9),
  `.talkieCard()` = surface fill + two whisper shadows, **no outline** (`:159-169`).
- Helpers: `VisualEffectView` (real NSVisualEffectView vibrancy), `FlowLayout`
  (wrapping chips), `Eyebrow`, `NSColor(hex:)`. `MarkdownText.swift` renders the
  model's `**bold**` + `* bullets` (the literal-markers fix from commit `3d5ca58`).

---

## 6. Entitlements / Info.plist / permissions

- **Entitlements** (`Resources/talkie.entitlements`): ONLY
  `com.apple.security.device.audio-input` (required so Hardened Runtime allows mic
  capture). **No network, no sandbox, no file-access entitlements.**
- **Info.plist** (`Resources/Info.plist`): bundle id `com.coralate.talkie`,
  `LSMinimumSystemVersion 26.0`, `ATSApplicationFontsPath Fonts`, and 3 usage
  strings: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`,
  `NSInputMonitoringUsageDescription`. **[branch]** adds
  `NSAudioCaptureUsageDescription`.
- **Runtime TCC** (`Permissions.swift`): three permissions reflected/requested —
  **Accessibility** (`AXIsProcessTrusted`, for posting ⌘V), **Input Monitoring**
  (`CGPreflightListenEventAccess`, for the global hotkey), **Microphone**
  (`AVCaptureDevice`). `allGranted` gates the status line. Each has an
  open-System-Settings deeplink. Far-end capture adds a 4th prompt
  (NSAudioCapture) on the branch.
- **Codesigning note** (`scripts/build_app.sh`): an **ad-hoc** signature changes
  hash every rebuild → macOS re-asks for TCC. Use a stable Apple Development /
  Developer ID identity (`TALKIE_SIGN_ID`) so permissions persist. `run.sh`
  installs ONE canonical copy to `/Applications`. `notarize.sh` does Developer ID
  + Hardened Runtime + notarytool + staple for sharing.

---

## 7. Concurrency patterns & conventions a new contributor MUST match

- **Strict Swift 6 (`.v6`).** Engines that own mutable state are **`actor`s**
  (`TranscriptionEngine`, `CleanupEngine`, `MeetingSummarizer`,
  `ContextSummaryEngine`). UI/store types are **`@MainActor final class …
  ObservableObject`**.
- **Real-time-safe captures:** in audio tap/IO blocks, capture the converter and
  callbacks **by value**; never read a property the main thread can mutate from the
  render thread. Wrap single-use buffers in a reference type (`SingleShotInput`).
  (`AudioCapture.swift`, `SystemAudioCapture.swift` [branch].)
- **`@unchecked Sendable` + `NSLock`** for value-ish types crossing threads:
  `CapturedAudio`, `DictationAssembler`, `HotKeyMonitor`, `TurnLog` [branch].
  Always `lock.withLock { … }` or `lock.lock(); defer { lock.unlock() }`.
- **Generation tokens** to make async setup cancellable/race-safe: `sessionID`
  (AppDelegate), `restoreGeneration` (TextInjector), `isStarting`/`cancelStart`
  (MeetingRecorder [branch]). Re-check the token after EVERY `await`.
- **Ordered event funnel:** route press/release through ONE `AsyncStream` consumed
  by ONE task to guarantee FIFO on the MainActor (AppDelegate hotkey).
- **`AsyncStream<AnalyzerInput>`** is the audio→analyzer transport;
  `continuation.yield/.finish`.
- **C-callback bridging:** `Unmanaged.passUnretained(self).toOpaque()` +
  `fromOpaque().takeUnretainedValue()` (HotKeyMonitor trampoline); a `@MainActor`
  static weak (`AppDelegate.sharedHUD`) to route a `@Sendable` engine handler back
  to the main actor.
- **Off-main heavy work:** `Task.detached(priority:.utility)` for the project scan;
  pure Sendable post-processing (`TextProcessor`, `PhraseMiner`, `SpokenFileMatcher`,
  `MeetingTranscriptRenderer`) so it can run off the main actor.
- **Persistence convention:** `@Published private(set)` arrays, `.atomic` writes,
  failure-tolerant decode, optional fields for forward/back-compat.
- **Voice/UX convention:** sentence case, second person, honest metrics (no
  invented percentiles — the gauge compares to an office typist & the world
  record, `DashboardView.swift:7-12`).

---

## 8. Honest list of TODOs, shortcuts & limits already in the code

- **`MeetingSummarizer` truncates** at 8000 chars (`Meeting.swift:36`) — comment
  explicitly defers map-reduce summarization for long meetings.
- **`ContextSummaryEngine` caps** the corpus at 6000 chars / 40 entries
  (`ContextSummary.swift:36-38`).
- **`DictationAssembler` is effectively unused on the main dictation path** — the
  AppDelegate cleans the whole transcript at stop instead of per-segment; the
  assembler is wired only into the mic-only `MeetingRecorder` (and the **branch
  removes even that**, replacing it with `TurnLog`). The per-segment "clean as you
  speak" latency-hiding design is therefore not actually exercised for dictation.
- **Learning is single-word-swap only** (`LearningEngine.swift:77-78`) — multi-word
  corrections are intentionally NOT learned (offset-space mismatch would poison the
  dictionary). Also AX-dependent: silently learns nothing in Electron/web fields.
- **Context mining is AX-best-effort** — sandboxed/Electron apps contribute fewer
  or no phrases (`AppContext.swift` docstring).
- **Recognizer bias cap 180 phrases** (AppDelegate), snapshot bias cap 250
  (VibeCoding), phrase-mine cap 40 — silent truncation if exceeded.
- **Pasteboard save/restore can't capture promised/lazy types** (e.g. dragged
  files) — documented limitation (`TextInjector.swift:69-71`).
- **`transcribeBuffered` bails rather than downloading a model inline** — a
  not-yet-installed second language won't re-transcribe until `warmUp` finishes in
  the background (`TranscriptionEngine.swift:148-149`); first switch may no-op.
- **`bestWPM`/avg WPM gated** to ≥1.5s & ≥4 words & <400 wpm to avoid absurd bursts
  (`StatsStore.swift:35-39`).
- **Fn/Globe activation key removed** — OS reserves it (`AppSettings.swift:8-9`).
- **`BRAND.md` is stale relative to `DesignSystem.swift`** (v1 ivory/coral doc vs.
  v2 white/blue code) — a doc/code drift to reconcile (see §5).
- **`docs/MEETING_MODE.md` 26.0 caveat:** process-tap capture had bugs on 26.0;
  the doc targets 26.1+ — worth validating on the actual deployment OS.
- **No tests** in the repo (no test target in `Package.swift`).
- **Branch is 3 commits behind main** and unmerged (see §2.2) — needs a rebase
  before merge (clean, no feature-file overlap).

---

## Executive summary

Talkie is a single-target Swift 6 / SwiftUI macOS-26 app (~6.7k LoC, 33 files,
no external deps) that fuses Wispr-Flow-class on-device dictation with a
Granola-class meeting recorder, and — critically — has **zero network code and a
single audio-input entitlement**, so the privacy thesis holds today. The
dictation pipeline is mature and complete: a listen-only `CGEventTap` hotkey →
`AVAudioEngine` mic capture → an `actor`-wrapped `SpeechAnalyzer`/`SpeechTranscriber`
→ on-device Foundation-Models cleanup (level or per-app adaptive style) → dictionary
+ filler post-processing → vibe-coding filename snapping → clipboard-paste injection,
with language auto-detect, AX-based context mining, single-word edit-learning, and a
full v2 dashboard (speed gauge, fixes, usage, streak heatmap, on-device daily Brief).
On `main`, meetings are **mic-only** (Phase 1): record → on-device summary →
Markdown in `~/Talkie Meetings/`. The **`feat/meeting-far-audio` branch (1 commit,
unmerged, 3 commits behind main, cleanly rebaseable)** adds the real Phase 2:
`SystemAudioCapture.swift` (Core Audio global process tap excluding self →
private aggregate device → a *second* transcriber) and `MeetingTranscript.swift`
(a `TurnLog` that diarizes "Me"/"Them" for free by stream-of-origin + arrival
time, rendered as timestamped `[mm:ss] Me/Them:` Markdown), with mic-only
fallback, `participants`/`source` metadata, the `NSAudioCaptureUsageDescription`
key, and honest UI copy. The concrete remaining gaps are everything above Phase 2:
no multi-speaker diarization (Phase 3 / FluidAudio), no opt-in cloud accuracy mode
(Phase 4 — which would be the first network code), no meeting auto-detect or
persistent global recording indicator (Phase 5), no long-meeting map-reduce
summarization, and no all-zero-PCM tap watchdog. The other live caveats are doc
drift (`BRAND.md` v1 ivory/coral vs. shipped v2 white/blue), the unused
per-segment `DictationAssembler` on the dictation path, and the absence of any
test target.
