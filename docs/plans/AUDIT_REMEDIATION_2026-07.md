# Talkie Codebase Audit & Remediation Plan — July 2026

**Status:** Execution spec. Read-only audit complete; this document is the plan the
implementation agents work from.
**Scope of audit:** full tree (`Sources/` ~70k LoC across 7 targets, `Resources/`,
`scripts/`, `ci/`, `Package.swift`, 10-language localization).
**Method:** 17 scoped finder agents (bugs ×5, performance ×2, security ×2,
simplicity ×2, wiring, design, copy, localization, concurrency, regression-status),
each capped to its highest-value findings, then critical/high findings put through
adversarial multi-lens verification (correctness / reproduction / blast-radius,
majority vote). 175 findings total; 12 adversarially **confirmed**, the rest
single-pass (marked `unverified`). Baseline `swift build` is clean (18.6s).

---

## How to read this document

Findings carry a stable id like `bugs-stores-3`. Each execution card gives the
**file(s)**, the **defect**, and the **exact fix**. Cards are grouped into **waves**
by file-ownership so they can be parallelized without two agents editing the same
file at once. The appendix (bottom) lists **all 175** findings with severity/status
so nothing is silently dropped; the long tail of low-severity items links back to the
raw finding JSON.

**Verification status legend**
- `confirmed` — survived adversarial majority verification. Highest confidence.
- `unverified` — single finder pass; credible but re-check the code before acting.
- `skipped` — simplicity/design/copy finders ran without a verify pass by design.

---

## Guardrails — DO NOT "fix" these (they are deliberate)

An executor that "cleans up" any of these is introducing a regression:

1. **Text injection must never be gated on focus detection.** A past bug came from
   that. Optimistic insert gates on settable AX value, not app category (iTerm2
   mis-classifies as `.coding`). The `AXFieldReader` bound fix (`bugs-system-3`) only
   bounds *diagnostic/verification* reads — it must not add focus-gating to injection.
2. **`CleanupEngine.generate()`** uses a fenced-dictation prompt + `looksLikeAnswer()`
   novelty guard. Deliberate fix for the model answering dictated questions. Don't
   simplify it away.
3. **`MeetingDigestBuilder` is lock-based, not an actor.** Deliberate. Don't convert.
4. **The meeting recorder rotates speech analyzers (~30 min).** Deliberate fix for
   far-end diarization collapse. Bugs *inside* rotation are fair game; the rotation
   itself stays.
5. **`Sources/Talkie/Niche/`** (Feature 21 jargon confidence-biasing) is deliberately
   NOT wired into the live dictation path until a WER benchmark gate passes. It is not
   dead code. Do **not** wire it up. (Note: the *ingest* side of niche vocab IS live —
   see `bugs-stores-1` — that is a real purge bug, distinct from the dormant bias path.)
6. **The English-only filler-word cleanup net is deliberately language-gated.**

---

## Executive summary

The codebase is in genuinely good shape: pure decision cores, documented invariants,
atomic writes, a real privacy wall (`PrivacyWall.assertLocal`), zero external SPM
dependencies, and 28/30 view files consuming the design-token layer. The audit is
therefore mostly a list of **outliers**, not a rewrite.

The findings cluster into a few themes:

- **Session-lifecycle concurrency** on the shared `TranscriptionEngine`: a stale
  begin-task can cancel the *next* dictation's session; dictation can start inside
  `MeetingRecorder.start()`'s async window. Fixes are small (a session-generation
  token + one guard).
- **The true-delete contract has two live holes**: niche-vocab keeps deleted
  transcript snippets forever, and "scratch that" skips the derived-memory purge.
- **A "temporary" debug logger became production logging**: it writes full
  transcripts and other apps' field text to a world-readable, predictable
  `/tmp/talkie-lang.log` in release builds — the single worst violation of the
  local-only brand promise, and it sits on the insert-critical path.
- **Meeting-stop is super-linear** in meeting length (an O(frames×words) language
  merge), and several big stores JSON-encode their entire contents on the main actor.
- **Localization drift**: 23 `.loc` keys exist in no catalog, one settings page is
  entirely unlocalized, and the shared settings rows render non-localizing
  `Text(String)`.

The owner's explicit request — **remove the "Clear everything" bulk-wipe control** —
is `security-app-1`; it is the *only* bulk-destructive control in the app (everything
else is per-item), and the removal recipe below is exact.

**Prior-audit note:** the June 2026 `CODE_REVIEW_MVP*.md` reports are gone (were
untracked, deleted). The one recoverable item from them — dead `requiresNetwork`
enforcement — is now **fixed** via `PrivacyWall`.

---

## Wave plan (execution order)

Each wave is a set of cards whose file-sets are disjoint → parallelizable. Between
waves, run `swift build` and `swift test` and commit. Hot files touched by many cards
(`AppDelegate.swift`, `TranscriptionEngine.swift`, `MemoryView.swift`,
`SettingsView.swift`, `MeetingsView.swift`, `MeetingRecorder.swift`) are assigned to a
**single owner per wave** so no two agents write the same file concurrently.

| Wave | Theme | Cards | Risk |
|------|-------|-------|------|
| 1 | Owner ask + confirmed-high + worst security | remove Clear-everything, /tmp log, AudioCapture crash, note-this overwrite, corrupt-JSON wipe, niche purge, scratch-that cascade, AX walk bound, updater rm-rf | Low–Med |
| 2 | Session-lifecycle concurrency + confirmed-medium | session-gen token, isProcessing latch, meeting-start guard, meeting stop/close latches, regen-summary notes loss | Med |
| 3 | Performance | O(n²) language merge, converter cache, MeetingStore/ContextGraph off-main save, staged launch loads, LazyVStack + debounced search, LiveBackground throttle | Med |
| 4 | Dead code + wiring | delete DictationAssembler/ReplaceSelectionIntent/SubpagePlaceholder/VisualEffectView, gate TalkieBridge, stale-comment sweep | Low |
| 5 | Copy + design tokens + l10n | error-string humanization, inkTertiary contrast, catalog-drift keys, unlocalized settings rows | Low–Med |

Waves 1–2 are the ship-relevant correctness/security payload. Waves 3–5 are
quality. The large structural refactors (SettingsView God-file split `simplify-ui-1`,
the shared `TalkieCore` leaf target `simplify-ui-2`, full Dynamic-Type migration
`design-consistency-2`, generic-store helper `simplify-ui-4`) are **deferred** — they
are L-effort, touch everything, and are safer as their own reviewed PRs. They are
documented in the appendix.

---

## WAVE 1 — Owner ask, confirmed-high correctness, worst security

### 1.1 `security-app-1` — Remove the "Clear everything" bulk-wipe control  ★ owner request
**Severity:** high · **Confidence:** unverified (recipe is exhaustive) · **Owner file:** `MemoryView.swift`, `SettingsView.swift`, strings

The only bulk-destructive control in the app. Two-step UI in
[MemoryView.swift](Sources/Talkie/Memory/MemoryView.swift): a header trash button → a
`confirmationDialog` → `clearEverything()` (a 9-store cascade).

**Delete, in `Sources/Talkie/Memory/MemoryView.swift`:**
1. `@State private var showingClearConfirm` + its doc comment (lines ~46–49).
2. The whole `.confirmationDialog` modifier (lines ~70–76): title *"Clear your
   dictation history?"*, the *"Clear everything"* button, Cancel, and the message.
3. The header **Clear** button (lines ~95–100:
   `Button(role: .destructive){ showingClearConfirm = true }`).
4. `private func clearEverything()` (lines ~129–149).
5. The now-dead injected properties `var jobTitle: JobTitleStore?` (~line 40) and
   `var profileImage: ProfileImageStore?` (~line 44) **plus their doc comments**, and
   drop the `jobTitle:` / `profileImage:` arguments at the single construction site in
   [SettingsView.swift:283](Sources/Talkie/SettingsView.swift).

**Becomes prod-unreachable (keep — each is exercised by `Tests/TalkieTests`; do not
delete without also deleting its test):** `HistoryStore.clearAll()`,
`WordFrequencyStore.clearAll()`, `ScratchpadStore.purgeAllDictationSourced()`,
`AutoAddPreviewLog.purgeAllDictationSourced()`, `SearchEngine.clearSidecar()`,
`JobTitleStore.clearCache()`, and the `sourceID: nil` branch of
`ContextGraphStore.purge`.

**MUST STAY (do not touch):** per-item `deleteDictation` (MemoryView ~115–124) and
everything it calls; `ProfileImageStore.clear()` (still used by
[DashboardView.swift:427](Sources/Talkie/DashboardView.swift) "Remove photo");
retention-based auto-delete (`HistoryStore.prune()` + Settings "Your history" card);
`FileShredder` (still used by per-meeting delete, `Meeting.swift:450/461`);
`ContextSummaryStore.clearSummary()` (still called by per-item delete).

**Orphaned strings** — remove these keys from **all 10** `*.lproj/Localizable.strings`
(en, de, fr, es, it, pt-BR, nl, ja, ko, zh-Hans): `"Clear everything"`,
`"Clear your dictation history?"`, and the long *"Deletes your dictation history …
notes you wrote in your Scratchpad, stay. …"* message. The older variant without the
Scratchpad clause is already orphaned — drop it in the same pass. **Do NOT remove**
`"Clear"` (still used by the search-field clear button's `.help`) or `"Delete"`.

**Also:** sweep the stale doc comments that describe the cascade (MemoryView ~17–44,
`WordFrequencyStore.swift:76`, `ScratchpadStore.swift:104`,
`AutoAddPreviewLog.swift:22/151`, `AppDelegate.swift:24/42`, `ProfileImage.swift:16/73`,
`VectorSidecar.swift:196`, `JobTitleEngine.swift:244–245`, `SettingsView.swift:220`).

---

### 1.2 `security-app-2` / `simplify-core-3` / `perf-pipeline-2` — The `/tmp` transcript log  ★ worst security issue
**Severity:** high · **Confidence:** unverified (three finders independently flagged) · **Owner file:** `TranscriptionEngine.swift` (+ 84 call sites, `BugBundle.swift`)

`talkieDebugLog` ([TranscriptionEngine.swift:8–18](Sources/Talkie/TranscriptionEngine.swift))
writes full dictation transcripts, learned corrections, and other apps' AX field text
to `/tmp/talkie-lang.log` — world-readable, predictable path — **unconditionally in
release**, with a synchronous open/seek/write/close per message on the insert-critical
path, and no rotation (unbounded growth). Header says *"TEMPORARY."*

**Fix:**
1. Guard the whole body: `guard Dev.isEnabled else { return }` (flag already exists in
   [DevTools.swift](Sources/Talkie/DevTools.swift)) → release builds write nothing.
2. Move the file from `/tmp` to
   `AppPaths.supportDirectory().appendingPathComponent("debug.log")`, created with
   `[.posixPermissions: 0o600]` via `FileManager.createFile` before first append.
3. When enabled, keep one open `FileHandle` behind a serial utility-QoS queue; append
   async; truncate past ~1 MB (rotation) — this also fixes `concurrency-6` (multiple
   threads racing the append).
4. Update `BugBundle.debugLogPath` ([BugBundle.swift:205](Sources/Talkie/BugBundle.swift))
   to the new location; add the file to the truncate-on-history-clear path.
5. Even in dev mode, stop logging full transcript bodies: trim
   `CleanupEngine.swift:279`, `OutputTranslator.swift:196` to lengths/language-codes,
   and `TranscriptionEngine.swift:339` to confidence stats (this also removes the
   per-word string build on the user-waiting stop path).

---

### 1.3 `bugs-dictation-3` — AudioCapture crashes next session after a transient engine-start failure
**Severity:** high · **Confidence:** confirmed · **File:** `AudioCapture.swift`

[`start()`](Sources/Talkie/AudioCapture.swift:155) installs the mic tap (line ~223)
*before* `try engine.start()` (~244). If `engine.start()` throws (device flake/vanish),
the error propagates, `isRunning` stays false, and `stop()` early-returns
(`guard isRunning`), so the stale tap is never removed. The next session installs a
second tap on the same bus → uncatchable `NSException` (`nullptr == Tap()`) → **crash**.
`handleConfigurationChange` already does the right cleanup in its catch; `start()` lacks
the symmetric one.

**Fix:** wrap `installAndStart` in do/catch in `start()`; on failure do
`engine.inputNode.removeTap(onBus: 0); engine.stop()` before rethrowing. Belt-and-braces:
`removeTap(onBus: 0)` unconditionally at the top of `installAndStart` (safe when no tap
exists).

---

### 1.4 `bugs-system-1` — "Note this" voice notes overwrite each other and lack `.md`
**Severity:** high · **Confidence:** confirmed · **File:** `Export/TalkieFolderDestination.swift`

[`TalkieFolderDestination.write`](Sources/Talkie/Export/TalkieFolderDestination.swift:14)
uses `note.suggestedFileName` verbatim. Dictation "note this …" notes come from
`NoteTemplate.fileName("{datetime}-note", …, existing: [])` — **no extension, empty
collision set**. With the default `.talkieFolder` destination, a note is written as
`2026-07-09-1432-note` (no `.md`), and a second "note this" in the same minute writes
the identical filename with `.atomic` — **silently destroying the first** while the HUD
says "Saved". Minute-granular timestamps make this normal usage.

**Fix:** in `write`, mirror `ObsidianVaultDestination`: when
`!note.suggestedFileName.hasSuffix(".md")`, list the target dir's base names, run the
base through `NoteTemplate.deCollide` (real `existing` set), and append `.md`. Leave
meeting filenames (already `.md` + embedded uuid) untouched.

---

### 1.5 `bugs-stores-3` — A corrupt JSON file loads as empty and is overwritten on next save (7+ stores)
**Severity:** high · **Confidence:** confirmed · **Files:** `HistoryStore.swift` + 6 more

`HistoryStore.load()` is `guard let data = try? …, let decoded = try? … else { return }`
— any read/decode failure leaves the store empty, and the next mutation's atomic save
**destroys the old bytes with no backup**. Same pattern in `ContextGraphStore` (worse:
watermark still decodes so backfill won't re-seed), `StatsStore` (lifetime totals),
`ActivityStore` (irreplaceable streak/heatmap history), `WordFrequencyStore`,
`ScratchpadStore` (user-typed notes that "Clear everything" promised to keep),
`AppUsageStore`, `ContextSummary`. `DictionaryStore.load` already solves this with a
quarantine-move.

**Fix:** factor `DictionaryStore`'s pattern into one shared helper: file absent → empty;
file present but undecodable → move aside to `<name>.json.corrupt` (removing any stale
quarantine first) and start empty so the next save can't clobber recoverable bytes.
Adopt in all 7 stores. For `ContextGraphStore`, also reset the `.dictation`/`.meeting`
watermark when `entities.json` is quarantined so backfill re-seeds from retained
history/meetings.

---

### 1.6 `bugs-stores-1` — Deleted dictations' text survives forever in `niche/vocab.json`
**Severity:** high · **Confidence:** confirmed · **Files:** `Niche/NicheVocabStore.swift`, `MemoryView.swift`, `AppDelegate.swift`

Every non-private dictation is harvested into `NicheVocabStore` with provenance quoting
`String(finalText.prefix(120))` ([AppDelegate.swift:2250–2255](Sources/Talkie/AppDelegate.swift)),
persisted to `niche/vocab.json`. But `NicheVocabStore` has **no `purge` API at all**, and
neither `deleteDictation` nor `clearEverything` touches it. This violates the app's own
contract ("a grep of deleted text over the support dir must come up empty") and the
Clear dialog copy. (This is the *live ingest* side, distinct from the dormant bias path
in guardrail 5.)

**Fix:** add `purge(sourceID:)` and `purgeAllDictationSourced()` to `NicheVocabStore`
(drop provenance entries whose `(source, sourceID)` match, decrement occurrences by the
removed count, drop terms with `userConfirmed == 0` and no provenance left, `save()`).
Wire both into `deleteDictation` / the shared delete helper from 1.7. Keep
pinned/user-confirmed terms (drop only their snippets) per "rules you taught stay".
*(Note: after Wave 1.1 removes `clearEverything`, wire `purgeAllDictationSourced()` only
where a dictation-scoped purge already runs.)*

---

### 1.7 `bugs-stores-2` — "Scratch that" skips the entire derived-memory purge
**Severity:** medium · **Confidence:** confirmed · **File:** `AppDelegate.swift`, `MemoryView.swift`

[`runVoiceEdit`'s `ScratchThatIntent` path](Sources/Talkie/AppDelegate.swift:2606) calls
only `history.delete(target)`. By then the dictation was ingested everywhere
(context graph provenance, wordFreq counts, scratchpad lines, autoAdd log, the Brief).
`MemoryView.deleteDictation` shows the required cascade; the voice path does none of it →
extracted facts and quoted snippets persist, and wordFreq counts drift permanently.

**Fix:** extract `deleteDictation`'s body into a shared helper on `AppDelegate` (which
owns all the stores): `deleteDictationEverywhere(_ entry:)` = `history.delete` +
`contextGraph.purge(source:.dictation, sourceID:)` + `wordFreq.purge(text:)` +
`scratchpad.purge(sourceID:)` + `autoAddPreviewLog.purge(sourceID:)` +
`nicheVocab.purge(sourceID:)` (from 1.6) + `contextSummary.clearSummary()`. Call it from
both `MemoryView` and the `ScratchThatIntent` branch. *(Coordinate with 1.1/1.6 — same
files.)*

---

### 1.8 `bugs-system-3` — Unbounded synchronous AX tree walk on the main thread
**Severity:** high · **Confidence:** confirmed · **File:** `AXFieldReader.swift`

[`findTextDescendant`](Sources/Talkie/AXFieldReader.swift:58) recurses depth 8 × 40
children with **no total node cap** and **no AX messaging timeout** (default 6s per
call). It triggers precisely in Electron apps (Claude, Slack, VS Code) with the largest
AX trees, and runs up to 3× per read. Callers are `@MainActor` (`InsertionVerifier`
polls 4×/insertion, `LearningEngine`'s edit watcher polls repeatedly). Same hang class
that once wedged `isProcessing`.

**Fix (bounds diagnostics only — no injection focus-gating, per guardrail 1):**
1. Add an inout visited-node budget (~500) to `findTextDescendant` → linear-bounded.
2. On each `AXUIElement` in `AXFieldReader` (and `ContextCapture`), call
   `AXUIElementSetMessagingTimeout(el, 0.5)`. Both preserve behavior on responsive apps
   (reader is best-effort; callers handle nil).

---

### 1.9 `bugs-system-2` — Updater deletes the running app after a 30s timeout
**Severity:** medium · **Confidence:** confirmed · **File:** `TalkieUpdater/UpdateInstaller.swift`

[`spawnSwap`](Sources/TalkieUpdater/UpdateInstaller.swift:134)'s wait loop breaks after
~30s (`[ "$i" -gt 150 ] && break`) and then **`rm -rf "$DEST"` regardless** of whether
the old process exited. If termination stalls, the script deletes
`/Applications/Talkie.app` out from under the running instance and races two copies on
`history.json`. (Dev-channel only, but data-loss class.)

**Fix:** replace `[ "$i" -gt 150 ] && break` with `[ "$i" -gt 150 ] && exit 1` (abort,
leave the staged app for retry; optionally log so the settings card can surface "update
staged but the app didn't exit — relaunch to retry").

---

## WAVE 2 — Session-lifecycle concurrency + confirmed-medium

Owner file `AppDelegate.swift` and `TranscriptionEngine.swift` are shared by 2.1/2.2/2.3
— **one agent owns both files for this wave.**

### 2.1 `bugs-dictation-1` + `concurrency-2` — Stale `cancelSession()` kills the next session
**Severity:** medium · **Confidence:** confirmed · **Files:** `AppDelegate.swift`, `TranscriptionEngine.swift`

Rapid press→release→press: an abandoned `beginSession(1)` task, on completing, enqueues
`engine.cancelSession()` which — via actor reentrancy — can run *after* `beginSession(2)`
set up the new session, destroying it. The user then speaks into a finished continuation
and gets an empty transcript with no error. `cancelSession`
([TranscriptionEngine.swift:579](Sources/Talkie/TranscriptionEngine.swift)) has no
session-generation guard; abandoned-path sites are `AppDelegate.swift:1268–1272`,
`1316–1320`, `1326–1327`, and `handleCaptureFailure` (~1357).

**Fix (minimal, matches `concurrency-2`):** never blanket-cancel when superseded. At the
abandoned-path sites, guard with `if self.sessionID == myID { await engine.cancelSession() }`
— when a newer session took over, `beginSession`'s own exclusivity teardown already
retired the stale one. **More robust (preferred if time allows):** give
`TranscriptionEngine` a per-session generation token — `beginSession` increments/returns
it; add `cancelSession(ifCurrent:)` / `finishSession(ifCurrent:)` that no-op on mismatch;
route all stale-abort sites through the token captured for *that* task.

### 2.2 `bugs-dictation-2` — Press during the ~1s post-insert verify window is swallowed
**Severity:** medium · **Confidence:** confirmed · **File:** `AppDelegate.swift`, `HUD.swift`

In the `.inserted` branch, `await InsertionVerifier.verify(...)` runs inside
`endDictation` **before** `defer { isProcessing = false }`. In AX-unreadable apps (the
heavy dictation targets) all 4×250ms polls run, so `isProcessing` stays true ~1s after
every paste. A press in that window hits `guard !isProcessing else { hud.nudgeBusy() }`,
and `nudgeBusy` is a no-op because the HUD already left `.processing` → the whole
utterance is lost silently.

**Fix:** release the latch before verify — set `isProcessing = false` immediately after
the insert outcome is handled, and move verify+heal+learn-watcher into a follow-up `Task`
(keep internal ordering: verify before `learning.beginWatching`). Also make `nudgeBusy`
fire for the `.inserting` phase so any residual-busy press gets visible feedback.

### 2.3 `concurrency-1` — Dictation can start during `MeetingRecorder.start()`'s async window
**Severity:** high · **Confidence:** unverified · **File:** `AppDelegate.swift`, `MeetingRecorder.swift`

`beginDictation` guards on `isRecording`/`isFinishing` but not on the invisible
`isStarting` window, so a dictation press during meeting startup makes both sessions
stomp the shared `TranscriptionEngine`.

**Fix:** make `MeetingRecorder.isStarting` `private(set)` (set at
[MeetingRecorder.swift:242](Sources/Talkie/MeetingRecorder.swift), cleared via `defer`)
and extend the guard in `beginDictation` (~line 1014) to also reject
`meetingRecorder?.isStarting == true` with the same HUD error. Both main-actor; no lock.

### 2.4 `bugs-meetings-2` + `concurrency-3` — Late mic-tap buffer truncates finalized meeting audio
**Severity:** high · **Confidence:** unverified · **File:** `MeetingRecorder.swift`

`MeetingAudioFileWriter` has no `closed` latch, so a mic-tap buffer landing after
`close()` re-creates the `AVAudioFile` and truncates (or resurrects) the just-finalized
m4a.

**Fix:** add `private var closed = false`, set it inside `close()`'s `queue.sync` block,
and change `append()`'s guard to `guard !failed, !closed else { return }`.

### 2.5 `bugs-meetings-1` — Watchdog give-up discards the multilingual merge and mislabels the meeting
**Severity:** high · **Confidence:** unverified · **File:** `MeetingRecorder.swift`

If the far-end watchdog gives up mid-meeting, `stop()` discards the entire multilingual
far-end merge, mixes wall-clock and audio-clock turns, and labels the meeting mic-only.

**Fix:** track a separate `farEverActive` flag (set true when the far stream starts,
never reset by the watchdog downgrade). In `stop()`, apply the merged spans + language
correction whenever the far stream ran at all (gate on `farMulti != nil` / `farEngine !=
nil` + `farEverActive`, not the live `capturingFarEnd`); derive `participants`/`source`
from `farEverActive`.

### 2.6 `bugs-meetings-5` — "Regenerate summary" destroys the user's typed notes
**Severity:** medium · **Confidence:** unverified · **File:** `MeetingsView.swift`, `Meetings/…`

Regenerating a meeting summary permanently overwrites notes the user typed.

**Fix:** preserve user-typed notes across regeneration (store generated summary and
user notes separately, or confirm-before-replace). Re-read the current code to pick the
cleanest split before implementing.

### 2.7 `bugs-meetings-4` (`concurrency-4`) — Queued tick can overlap `finish()`
**Severity:** medium · **Confidence:** unverified · **File:** `MeetingRecorder.swift`

A tick queued before timer invalidation can start an analyzer rotation that interleaves
with `stop()`'s `finish()` via actor reentrancy — worst case wedges `isFinishing`.

**Fix:** gate `tick()`'s rotation on `!isFinishing` (and re-check after each await), so a
late tick can't start a rotation once stop has begun.

---

## WAVE 3 — Performance

All cards here touch different files except the two Meetings/Memory view ones — assign
`MeetingsView.swift` + `Meeting.swift` to one agent, `MemoryView.swift` to another.

- **`perf-pipeline-1` (confirmed)** — `StreamLanguageVoter.mergeWords` is O(frames×words)
  (~10⁹ comparisons for a 2-h meeting, ×2 streams) → multi-second stall at meeting stop.
  Replace the inner full scan with a time-ordered interval sweep (sort `valid` by start
  once; cursor + active set / min-heap keyed by `end`). O((frames+words)·log words),
  identical winner. [StreamLanguageVoter.swift:70](Sources/Talkie/Meetings/StreamLanguageVoter.swift)
- **`perf-pipeline-3` (confirmed)** — `TranscriptionEngine.conform` builds a new
  `AVAudioConverter` per call (per chunk on import, per buffer in multilang fanout).
  Cache it keyed by `(source, target)` format, owned per Lane / per decode loop.
- **`perf-app-3`** — `MeetingStore.save()` JSON-encodes all ~200 meetings (full
  transcripts inline) synchronously on the main actor. Adopt `HistoryStore`'s existing
  pattern: snapshot value type → `MeetingIndexWriter` actor, generation-tokened,
  off-main. No format change.
- **`perf-app-6` / `bugs-stores-8`** — `ContextGraphStore.save()` re-encodes the whole
  graph synchronously on the main actor after every dictation. Same off-main
  generation-tokened writer treatment.
- **`perf-app-4`** — ~19 stores block first frame with serial main-thread JSON decodes.
  Stage loads: keep tiny stores eager; load the big three (History, Meeting,
  ContextGraph) off-main via `Task.detached` + `apply(loaded:)` on the main actor.
- **`perf-app-1`** — `MeetingsView` rebuilds every row (word-counting full transcripts)
  at 1 Hz while recording + on every notes keystroke. `LazyVStack`; cache word count;
  move the elapsed readout into a small child view that alone observes the tick; give the
  notes editor a local `@State` draft committed on debounce/blur; `MeetingRow: Equatable`
  + `.equatable()`.
- **`perf-app-2` / `bugs-ui-7`** — Memory search runs a full semantic scan synchronously
  on the main thread per keystroke. Debounce ~200ms; run off-main via `.task(id:)` over
  the Sendable `SemanticIndex`; render cached `hits`.
- **`perf-app-9`** — `LiveBackground` runs two 30fps `TimelineView`s whenever the
  dashboard is visible. Throttle to ~12fps / pause when window occluded or backgrounded
  (respect `NSWindow.occlusionState`). Matches the memory note: subtle single-direction
  ember gradient, not a busy procedural effect.
- **`perf-pipeline-4/6`, `perf-app-12`, `perf-pipeline-7`** — smaller: replace
  `Array.removeFirst` rolling window with a ring/index (O(1)); reduce per-callback
  allocations; batch the 6 whole-file JSON writes at dictation-end; make the 1.5s Core
  Audio poll event-driven where the API allows. Lower priority; do if wave has budget.

---

## WAVE 4 — Dead code + wiring (low risk, high signal)

- **`simplify-core-1` / `wiring-4` (confirmed dead)** — delete
  [DictationAssembler.swift](Sources/Talkie/DictationAssembler.swift) (58 lines, zero
  refs; superseded by `StreamingCleanup`).
- **`wiring-3`** — delete `ReplaceSelectionIntent`
  ([Commands/ReplaceSelectionIntent.swift](Sources/Talkie/Commands/ReplaceSelectionIntent.swift))
  — never constructed. *(Confirm the "re-dictate this selection" feature is truly
  unreachable first; if it's meant to ship, wire it instead — but audit found no
  construction site.)*
- **`wiring-5` / `simplify-ui-9`** — delete `SubpagePlaceholder`
  ([SettingsView.swift:581](Sources/Talkie/SettingsView.swift)) — unused; all subpages
  shipped.
- **`wiring-6`** — delete unused `VisualEffectView`
  ([DesignSystem.swift:293](Sources/Talkie/DesignSystem.swift)).
- **`wiring-1`** — `TalkieBridge` is compiled into every default build but never linked
  for a "Connected" flavor that no build path can produce. **Gate it** (preferred, 5
  lines mirroring the `TalkieUpdater` pattern): in `Package.swift`, add
  `let connected = ProcessInfo…["TALKIE_CONNECTED"] …`, move the `TalkieBridge` target
  inside `if connected`, add `.define("TALKIE_CONNECTED")` + the dependency under that
  condition. Makes the "opt-in flavor" claim true and stops compiling networked code in
  default builds.
- **`wiring-2`** — `requiresNetwork` enforcement is fixed via `PrivacyWall`, but 5
  backend/summarizer instantiation sites still bypass the wall. Add the one-line
  `PrivacyWall.assertLocal` wrap at each.
- **`wiring-7/8`, `simplify-core-14`, and the stale-comment items** — trim the
  half-consumed `TranscriptionBackend` seam to what `PrivacyWall` needs; fix the
  `SettingsRouter.pendingPage` doc that says "nothing sets it" (MeetingsView sets it —
  the stale comment invites deleting live wiring); update `HotKeyMonitor` comments that
  still describe the removed tap-tap-to-lock gesture.
- **`simplify-ui-3`** — remove the 19 unreferenced Brand PNGs (~3.7 MB) from
  `Resources/Brand/` that ship in every bundle. **Verify each is truly unreferenced**
  (grep the asset name across `Sources/` and asset catalogs) before deleting.

---

## WAVE 5 — Copy, design tokens, localization

**Cross-cutting rule:** every English string change to
`Resources/Localizations/en.lproj/Localizable.strings` must ripple to the other 9
`.lproj` files (de, es, fr, it, ja, ko, nl, pt-BR, zh-Hans) — translate or mark for
translation. Bare literals being wrapped in `.loc` must be added as new keys in all 10.

**Copy (humanize error paths first — they surface verbatim in the HUD):**
- `copy-humanize-1` — *"No supported speech locale could be resolved."* →
  *"Dictation isn't available for your language on this Mac yet. Pick another language in
  Settings → Languages, then try again."*
- `copy-humanize-2` — *"The speech model could not be installed: %@"* →
  *"Couldn't get the speech model — macOS downloads it once. Check your internet
  connection and free disk space, then try again. (%@)"*
- `copy-humanize-3` — *"No compatible audio format was found for the microphone."* →
  *"Talkie couldn't get audio from that microphone. Pick a different mic under Settings →
  Input device, then try again."*
- Wrap all `TalkieEngineError` descriptions in `.loc` (they are currently unlocalized).
- `copy-humanize-4/6/7/8/9` and the low-severity casing items — apply the terminology
  canon: **dictation** = one spoken entry; **transcript** = the text it/a meeting
  produces; **recording** = a meeting capture; inserted output is always "your words /
  your text" (never "the transcribed text"); the polish pass is **cleanup** (not "smart
  cleanup"). Fix "Copy All" → "Copy all", the one-sample "median", the "optimistic"/
  "chars" dev-jargon on the speed page, and the write-only calendar spec-voice.

**Design tokens:**
- `design-consistency-1` (high) — `Theme.inkTertiary` fails WCAG contrast for the small
  text it styles everywhere. Darken/lighten the token
  ([DesignSystem.swift:40](Sources/Talkie/DesignSystem.swift)) to ~4.5:1 in both modes,
  or add `Theme.inkCaption` at AA values and swap it in where `inkTertiary` styles real
  text.
- `design-consistency-4/5` — replace system `.orange` in the HUD error state with the
  warning token, and `Color.red` for the meetings recording dot with `Theme.featherRed`
  (matches the HUD pill).
- `design-consistency-3/6` — meeting pill should honor Increase Contrast / Reduce
  Transparency like its HUD sibling; add `accessibilityLabel` to icon-only hover buttons
  in Meetings/Dashboard/Commands.
- Low-severity token nits (magic pill radius 17, page-gutter 28, near-miss radii,
  BirdBuddy hardcoded color) — batch if budget allows.

**Localization mechanics (`l10n-integrity-*`):**
- `l10n-1/2` — 23 `.loc` keys reference keys in **no** catalog (hold-to-lock rewrite +
  the meeting consent/picker/pill UI ship English-only in all 10 languages while dead
  translations of the old copy linger). Add the missing keys to all 10 catalogs; drop
  the dead ones.
- `l10n-4` — the shared `SettingsRow`/`SettingsToggleRow`/`SettingsCard` render
  non-localizing `Text(String)` — the root cause behind several unlocalized pages. Route
  their titles/footers through `.loc`.
- `l10n-3` — `CommandsView` (Voice Commands settings page) is entirely unlocalized: 0
  `.loc` calls, 0 keys. Localize it.
- `l10n-5/6/7/9/10` — dashboard stat chips, main/status menu items, the split
  "Press ⌘⇧V to paste" fragment (make it one localizable format string with the keycap
  interpolated), dictionary settings controls, onboarding/memory fields.
- `l10n-8` — naive `s`-appending pluralization in visible UI; introduce a `.stringsdict`
  (none exists) for the plural strings.

---

## Execution outcome (what actually shipped)

This PR implemented Waves 1–5 as six commits (plan + five waves). Every wave was gated
by `swift build` + `swift test` (1205 tests) + `scripts/check-no-network.sh`, all green;
Wave 4 also builds the `TALKIE_CONNECTED` flavor. Shipped:

- **Wave 1** — removed the "Clear everything" control (owner ask); neutralized the
  `/tmp` transcript log; fixed the AudioCapture double-tap crash, the "note this"
  overwrite, the corrupt-JSON wipe (7 stores), the niche-vocab true-delete hole, the
  "scratch that" cascade, the unbounded AX walk, and the updater `rm -rf`-on-timeout.
- **Wave 2** — session-generation token, `isProcessing` latch release, meeting-start
  guard, meeting close/watchdog latches, regenerate-summary confirmation.
- **Wave 3** — O(n log n) language merge, converter cache, off-main MeetingStore/
  ContextGraph writers, LazyVStack + debounced Memory search + LiveBackground throttle.
- **Wave 4** — deleted 4 dead types + 19 unused PNGs, gated TalkieBridge, tightened
  PrivacyWall at 5 sites, fixed stale comments.
- **Wave 5** — humanized + localized the HUD error strings and terminology; lifted
  `inkTertiary` to WCAG AA; token + accessibility-label consistency.

## Deferred (documented, not in this PR)

Large or judgment-heavy; safer as their own reviewed PRs.

- `perf-app-4` — **staged off-main launch loads** (deferred during execution): reorders
  app startup and needs careful empty-state handling in every view; unverified and the
  riskiest perf item. Own PR.
- **l10n-integrity refactor** (`l10n-integrity-3/4/5/6/7/8/9/10/11/12`) — CommandsView
  full localization, routing `SettingsRow`/`SettingsToggleRow`/`SettingsCard`
  `Text(String)` through `.loc`, dashboard chips, menu items, the split "Press ⌘⇧V"
  string, and a `.stringsdict` for plurals. Mechanical but touches hundreds of keys ×
  10 languages; a dedicated localization pass with native review.
- **Pre-existing catalog drift** — 9 milestone-tier keys (e.g. `Fledgling`,
  `Golden Voice`) differ between `en` and the other 9 catalogs *at the base commit* —
  not introduced here. Fold into the l10n pass above.
- **Non-English translation review** — the Wave 5 error/calendar strings were
  translated by the model into de/es/fr/it/ja/ko/nl/pt-BR/zh-Hans and want a
  native-speaker check before shipping.
- **Chart/heatmap accessibility** — the Dashboard bar chart and streak heatmap expose
  data only via hover tooltips; a grouped/summarized VoiceOver treatment is a follow-up
  (a task chip was spawned during Wave 5).
- `simplify-ui-1` — split the 2,509-line `SettingsView.swift` God-file (mechanical but
  huge; own PR).
- `simplify-ui-2` — extract a dependency-free `TalkieCore` leaf target to de-dup the
  MCP/CLI "mirror-don't-import" copies (aligns with the Windows-port shared text brain;
  own PR).
- `simplify-ui-4` — generic JSON load/save store helper (10 stores). Builds on Wave 1's
  `StoreLoad` quarantine helper.
- `design-consistency-2` — full fixed→Dynamic-Type migration (179 `.font(.system(size:))`
  call sites).
- `simplify-core-2/7/8/10/11`, `simplify-ui-5/6/7/8` — de-dup passes (converter, chunker,
  notch-panel math, locale helper, SRT/VTT renderers, language tiles). Nice-to-have.
- The rest of the low-severity long tail in the appendix — triage per release priority.

---

## Verification gates (run after every wave)

1. `swift build` — must stay green.
2. `swift test` — must stay green (watch the tests named in `security-app-1`; if a
   cascade method is deleted, delete its test in the same commit).
3. `scripts/check-no-network.sh` — the zero-network gate must still pass (Wave 4's
   `TalkieBridge` gating and Wave 1.2's log-path change both touch its concerns).
4. Spot-run the app via `./scripts/run.sh` for the dictation happy-path and the meeting
   happy-path before the PR is marked ready (per repo convention: rebuild or you test a
   stale `/Applications/Talkie.app`).

---

## Appendix — all 175 findings

Full raw findings (with evidence quotes, verifier notes, and per-finding fixes) are in
the workflow output JSON referenced in the PR description. Table below is the index;
`conf` = adversarially confirmed.

| id | sev | status | eff | location | title |
|----|-----|--------|-----|----------|-------|
| bugs-dictation-1 | medium | confirmed | M | Sources/Talkie/AppDelegate.swift:1270 | Stale cancelSession() from an aborted begin task can kill the NEXT dictation session |
| bugs-dictation-2 | medium | confirmed | M | Sources/Talkie/AppDelegate.swift:2355 | Dictation press during the ~1s post-insert verification window is silently swallowed |
| bugs-dictation-3 | high | confirmed | S | Sources/Talkie/AudioCapture.swift:155 | AudioCapture.start() leaves the mic tap installed if engine.start() throws — next session crashes on double tap install |
| bugs-dictation-4 | medium | unverified | M | Sources/Talkie/TranscriptionEngine.swift:360 | beginSession's exclusivity teardown cancels the old resultsTask without awaiting it — a stale segment can leak into the new session |
| bugs-dictation-5 | medium | unverified | S | Sources/Talkie/AppDelegate.swift:2361 | Self-healing retype fires into whichever app is focused after the ~1s verify — can type the transcript into the wrong app |
| bugs-dictation-6 | medium | unverified | S | Sources/Talkie/AppDelegate.swift:797 | Hands-free lock event is silently dropped when the latch fires before the session goes live (cold start) |
| bugs-dictation-7 | medium | unverified | S | Sources/Talkie/TextInjector.swift:311 | Clipboard restore races slow paste consumers: 120ms is not enough for busy Electron targets |
| bugs-dictation-8 | low | unverified | S | Sources/Talkie/TextInjector.swift:299 | insert() reports .inserted even when the mid-flight secure-input recheck aborts the paste |
| bugs-dictation-9 | low | unverified | S | Sources/Talkie/TranscriptionEngine.swift:556 | finishSessionDetailed never clears finalizedText — an unmatched finishSession returns the PREVIOUS session's transcript |
| bugs-dictation-10 | low | unverified | S | Sources/Talkie/DictationAssembler.swift:13 | DictationAssembler is dead code in the core pipeline (superseded by StreamingCleanup) |
| bugs-dictation-11 | low | unverified | S | Sources/Talkie/DictionaryStore.swift:514 | stripFillers drops sentence punctuation attached to a filler token |
| bugs-meetings-1 | high | unverified | S | Sources/Talkie/MeetingRecorder.swift:673 | Far-end watchdog give-up silently discards the multilingual merge and mislabels the meeting |
| bugs-meetings-2 | high | unverified | S | Sources/Talkie/MeetingRecorder.swift:39 | A late mic-tap buffer after close() re-creates the kept-audio m4a, truncating the finalized recording |
| bugs-meetings-3 | medium | unverified | S | Sources/Talkie/MeetingRecorder.swift:325 | Multilingual mic lanes leak when audio.start() throws — analyzers left running, later sessions degraded |
| bugs-meetings-4 | medium | unverified | S | Sources/Talkie/MeetingRecorder.swift:561 | A queued tick surviving timer invalidation can start an analyzer rotation that overlaps stop()'s finish |
| bugs-meetings-5 | medium | unverified | M | Sources/Talkie/MeetingsView.swift:480 | 'Regenerate summary' permanently destroys the user's typed meeting notes |
| bugs-meetings-6 | medium | unverified | S | Sources/Talkie/Meeting.swift:459 | MeetingStore.delete's path-escape guard misses ".." — FileShredder would recursively delete outside the meetings folder |
| bugs-meetings-7 | medium | unverified | M | Sources/Talkie/Meetings/InboxWatcher.swift:279 | InboxWatcher silently moves a never-transcribed file to Transcribed/ when its filename matches any past import |
| bugs-meetings-8 | low | unverified | S | Sources/Talkie/Meetings/StreamLanguageVoter.swift:66 | StreamLanguageVoter.mergeWords is O(frames × words) — multi-hour multilingual meetings stall the stop pipeline |
| bugs-meetings-9 | low | unverified | S | Sources/Talkie/MeetingsView.swift:228 | 'Start recording' button uses && instead of // — enabled-but-dead when speech recognition is unavailable |
| bugs-meetings-10 | low | unverified | S | Sources/Talkie/MeetingRecorder.swift:474 | Mic-capture-failure callback is dropped during the start() window — meeting can go live recording silence |
| bugs-meetings-11 | low | unverified | S | Sources/Talkie/SystemAudioCapture.swift:262 | Watchdog tap rebuild discards the rolling far-end audio buffer used for stop-time language correction |
| bugs-stores-1 | high | confirmed | M | Sources/Talkie/Niche/NicheVocabStore.swift:93 | Deleted dictations' literal text survives forever in niche/vocab.json — no purge path at all |
| bugs-stores-2 | medium | confirmed | S | Sources/Talkie/AppDelegate.swift:2606 | "Scratch that" voice-delete removes only the history entry — the entire derived-memory purge cascade is skipped |
| bugs-stores-3 | high | confirmed | M | Sources/Talkie/HistoryStore.swift:228 | A corrupt/unreadable JSON file silently loads as empty and is permanently overwritten on the next save (7+ stores) |
| bugs-stores-4 | medium | unverified | S | Sources/Talkie/HistoryStore.swift:257 | HistoryStore.flush() has zero callers and there is no applicationWillTerminate — the debounced history write is lost on quit |
| bugs-stores-5 | medium | unverified | S | Sources/Talkie/MeetingsView.swift:139 | Deleting a meeting leaves the persisted Brief (context_summary.json) quoting the meeting's extracted commitments |
| bugs-stores-6 | medium | unverified | S | Sources/Talkie/HistoryStore.swift:184 | Voice-edit updateText breaks WordFrequencyStore's record/purge inverse — later delete corrupts other dictations' counts |
| bugs-stores-7 | low | unverified | S | Sources/Talkie/Search/SearchEngine.swift:85 | Cancelled search rebuild still writes the vector sidecar — a stale save can overwrite a newer one (including right after 'Clear everything') |
| bugs-stores-8 | low | unverified | M | Sources/Talkie/ContextGraph/ContextGraphStore.swift:184 | ContextGraphStore re-encodes the entire graph synchronously on the main actor on every dictation completion |
| bugs-stores-9 | low | unverified | S | Sources/Talkie/HistoryStore.swift:195 | clearAll's shred-race comment is wrong: an in-flight writer-actor write is not stopped by pendingSave.cancel() |
| bugs-stores-10 | low | unverified | S | Sources/Talkie/DictionaryStore.swift:67 | DictionaryStore quarantines the user's dictionary on a transient READ failure, not just on decode failure |
| bugs-ui-1 | medium | unverified | S | Sources/Talkie/MeetingsView.swift:174 | Pinned meeting-transcription language survives removal from spoken languages: blank Picker + silent wrong-language pinning |
| bugs-ui-2 | medium | unverified | S | Sources/Talkie/MeetingsView.swift:226 | "Start recording" silently no-ops when MeetingRecorder.start() refuses (mic denied, dictation in flight, speech unavailable) |
| bugs-ui-3 | medium | unverified | S | Sources/Talkie/SettingsView.swift:178 | Main window position is reset every launch: window.center() runs after setFrameAutosaveName restores the saved frame |
| bugs-ui-4 | medium | unverified | M | Sources/Talkie/MeetingsView.swift:641 | Hand-edited transcript is invisible for meetings with kept audio — playback view keeps rendering stale segment text |
| bugs-ui-5 | medium | unverified | S | Sources/Talkie/Settings/AppProfilesSettings.swift:357 | Per-app "Insert in" picker shows a duplicate "As spoken" row (synthetic placeholder is iterated into the menu) |
| bugs-ui-6 | medium | unverified | S | Sources/Talkie/SettingsView.swift:2099 | Import-preview sheet identity churns: PreviewBox mints a fresh UUID on every binding read, so any re-render re-presents the sheet |
| bugs-ui-7 | medium | unverified | M | Sources/Talkie/Memory/MemoryView.swift:215 | Memory search runs the full semantic scan synchronously inside body on every keystroke |
| bugs-ui-8 | low | unverified | S | Sources/Talkie/MCPSetupPrompt.swift:82 | MCP setup prompt omits the retitle_meeting tool (17 of 18 tools) and the drift gate doesn't cover it |
| bugs-ui-9 | low | unverified | S | Sources/Talkie/SettingsView.swift:1449 | Microphone "Input device" Picker goes blank when the pinned device is absent, and the device list never refreshes |
| bugs-ui-10 | low | unverified | S | Sources/Talkie/SettingsView.swift:1810 | Dictionary pane persists the whole dictionary to disk on every keystroke |
| bugs-ui-11 | low | unverified | S | Sources/Talkie/DashboardView.swift:55 | DashboardView observes a SettingsRouter it never uses |
| bugs-system-1 | high | confirmed | S | Sources/Talkie/Export/TalkieFolderDestination.swift:14 | "Note this" voice notes are written without .md extension and silently overwrite each other within the same minute |
| bugs-system-2 | medium | confirmed | S | Sources/TalkieUpdater/UpdateInstaller.swift:134 | Updater swap script deletes the running app bundle even when the old process never exited (30s timeout falls through to rm -rf) |
| bugs-system-3 | high | confirmed | M | Sources/Talkie/AXFieldReader.swift:58 | AXFieldReader's descendant search is a combinatorially unbounded synchronous AX walk on the main thread with no messaging timeout |
| bugs-system-4 | medium | unverified | S | Sources/Talkie/Permissions.swift:126 | Permissions 'Relaunch now' races the app's exit (fixed 0.4s sleep) and breaks on paths with shell metacharacters |
| bugs-system-5 | medium | unverified | S | Sources/Talkie/Privacy/DoctorReport.swift:254 | Privacy doctor report reads the context-graph store from the wrong path — always reports it as 'not created yet' |
| bugs-system-6 | medium | unverified | M | Sources/TalkieUpdater/UpdaterSupport.swift:94 | Updater Shell.run can deadlock on large stderr output (sequential pipe drain), hanging the update check/download forever |
| bugs-system-7 | medium | unverified | S | Sources/TalkieFileKit/FileTranscriber.swift:322 | talkie CLI --locale silently falls back to en-US for unsupported locales while claiming to prepare the requested model |
| bugs-system-8 | medium | unverified | M | Sources/Talkie/LaunchAtLogin.swift:17 | Launch-at-login registration failures are swallowed and the persisted toggle never reconciles with SMAppService status |
| bugs-system-9 | low | unverified | S | Sources/TalkieMCP/main.swift:29 | MCP server silently drops malformed JSON-RPC requests instead of returning -32700 Parse Error |
| bugs-system-10 | low | unverified | S | Sources/TalkieMCP/MCPServer.swift:117 | retitle_meeting advertises a 'note' parameter in its schema but the handler silently discards it |
| perf-pipeline-1 | medium | confirmed | M | Sources/Talkie/Meetings/StreamLanguageVoter.swift:70 | StreamLanguageVoter.mergeWords is O(frames x words): multi-second CPU stall at meeting stop |
| perf-pipeline-2 | medium | confirmed | S | Sources/Talkie/TranscriptionEngine.swift:11 | talkieDebugLog does synchronous open/seek/write/close per message, unconditionally in release, with unbounded file growth |
| perf-pipeline-3 | low | confirmed | M | Sources/Talkie/TranscriptionEngine.swift:621 | TranscriptionEngine.conform builds a new AVAudioConverter per call — per chunk in file import, per buffer in multilang fanout |
| perf-pipeline-4 | medium | unverified | S | Sources/Talkie/SystemAudioCapture.swift:36 | Rolling PCM window uses Array.removeFirst — O(n) memmove on every far-end audio callback once the 10-min cap is hit |
| perf-pipeline-5 | medium | unverified | M | Sources/Talkie/MeetingRecorder.swift:599 | Meeting partial flush re-renders the whole transcript, JSON-encodes, and writes to disk on the main actor |
| perf-pipeline-6 | medium | unverified | M | Sources/Talkie/SystemAudioCapture.swift:278 | Per-callback allocations in both audio capture callbacks (fresh AVAudioPCMBuffer + SingleShotInput per buffer) |
| perf-pipeline-7 | medium | unverified | L | Sources/Talkie/Meetings/ActiveMeetingDetector.swift:176 | ActiveMeetingDetector polls Core Audio every 1.5s forever — all-day timer wake-ups that could be event-driven |
| perf-pipeline-8 | low | unverified | S | Sources/Talkie/CleanupEngine.swift:263 | CleanupEngine.generate re-runs NLLanguageRecognizer on the same strings up to twice each, per segment, on the insert-critical path |
| perf-pipeline-9 | low | unverified | S | Sources/Talkie/TranscriptionEngine.swift:385 | Analyzer input streams use unbounded AsyncStream buffering — a stalled consumer accumulates PCM without bound in long meetings |
| perf-pipeline-10 | low | unverified | S | Sources/Talkie/LatencyStore.swift:253 | LatencyStore encodes and writes latency.json synchronously on the main actor after every dictation |
| perf-app-1 | high | unverified | M | Sources/Talkie/MeetingsView.swift:72 | MeetingsView rebuilds every meeting row (word-counting full transcripts) once per second while recording and on every notes keystroke |
| perf-app-2 | high | unverified | M | Sources/Talkie/Memory/MemoryView.swift:215 | Memory search runs the full semantic scan synchronously on the main thread on every keystroke, with no debounce |
| perf-app-3 | high | unverified | M | Sources/Talkie/Meeting.swift:674 | MeetingStore.save() JSON-encodes all 200 retained meetings — full transcripts and timed segments inline — synchronously on the main actor |
| perf-app-4 | high | unverified | M | Sources/Talkie/AppDelegate.swift:11 | All ~19 stores synchronously read + JSON-decode their files on the main thread before the first frame |
| perf-app-5 | medium | unverified | S | Sources/Talkie/SettingsView.swift:206 | MainView observes ~18 stores it never reads — any @Published change anywhere re-evaluates the entire window body |
| perf-app-6 | medium | unverified | M | Sources/Talkie/ContextGraph/ContextGraphStore.swift:175 | ContextGraphStore.save() re-encodes the whole 2000-entity graph synchronously on the main actor after every dictation |
| perf-app-7 | medium | unverified | S | Sources/Talkie/AppDelegate.swift:409 | Context-graph backfill mines phrases over the entire history + all meeting transcripts on the main actor at launch |
| perf-app-8 | medium | unverified | M | Sources/Talkie/Search/SearchEngine.swift:69 | Every dictation triggers a full search-index rebuild — re-chunking, re-hashing and re-tokenizing the entire corpus and rewriting the whole vector sidecar |
| perf-app-9 | medium | unverified | S | Sources/Talkie/LiveBackground.swift:121 | LiveBackground runs two 30 fps TimelineViews (full-window image transform + three ~100 px-blur glows) the entire time the dashboard is visible |
| perf-app-10 | low | unverified | S | Sources/Talkie/DashboardView.swift:1094 | Heatmap rebuilt with fresh UUID identities for all ~180 cells on every layout pass |
| perf-app-11 | low | unverified | S | Sources/Talkie/MeetingsView.swift:898 | Meeting playback ticker fires at 12.5 Hz whenever the transcript is expanded (even paused) and re-renders every segment row while playing |
| perf-app-12 | low | unverified | S | Sources/Talkie/AppDelegate.swift:2162 | Dictation-end fans out 6+ separate synchronous whole-file JSON writes on the main actor |
| security-app-1 | high | unverified | M | Sources/Talkie/Memory/MemoryView.swift:72 | Remove the 'Clear everything' bulk-wipe control from MemoryView (exact removal recipe) |
| security-app-2 | high | unverified | S | Sources/Talkie/TranscriptionEngine.swift:10 | Release builds write full dictation transcripts and other apps' field text to world-readable, predictable /tmp/talkie-lang.log |
| security-app-3 | medium | unverified | M | Sources/TalkieUpdater/UpdateInstaller.swift:52 | Dev updater verifies size/SHA-256 over HTTPS but performs no code-signature check and fails open when a release omits the digest |
| security-app-4 | medium | unverified | S | Sources/Talkie/AppPaths.swift:17 | Transcripts, memory graph, and meeting notes are written with default permissions; ~/Talkie Meetings is deliberately outside TCC and nothing sets 0600/0700 |
| security-app-5 | medium | unverified | M | Sources/Talkie/DictionaryInbox.swift:303 | Dictionary inbox applies mutations from ANY local process and attributes them all to 'Claude'; replacement rules can rewrite future dictated text |
| security-app-6 | low | unverified | S | Sources/Talkie/Memory/MemoryView.swift:90 | Bulk 'Copy All' places the entire dictation history on the shared clipboard in one click |
| security-supply-chain-1 | high | unverified | M | Sources/TalkieUpdater/UpdateInstaller.swift:106 | In-app dev updater de-quarantines and installs downloads with no code-signature check |
| security-supply-chain-2 | medium | unverified | S | Sources/TalkieUpdater/UpdateInstaller.swift:52 | Updater SHA-256 gate is fail-open when the release body omits a digest |
| security-supply-chain-3 | medium | unverified | S | scripts/check-no-network.sh:142 | check-no-network.sh silently skips any .swift file whose path contains whitespace |
| security-supply-chain-4 | medium | unverified | M | scripts/check-no-network.sh:153 | Zero-network gate has no tier for process-spawn escapes (Process → /usr/bin/curl passes CI) |
| security-supply-chain-5 | medium | unverified | S | ci/release.yml:51 | GitHub Actions pinned by mutable tag (@v4), including the workflow that holds the Developer ID cert |
| security-supply-chain-6 | medium | unverified | S | Casks/talkie.rb:16 | Release pipeline is inert: ci/release.yml is not under .github/workflows/, though the cask says it is |
| security-supply-chain-7 | medium | unverified | S | scripts/build_mcpb.sh:22 | .mcpb connector bundles an unsigned talkie-mcp binary inside the signed app |
| security-supply-chain-8 | medium | unverified | S | .gitignore:1 | .gitignore covers neither release zips nor the documented voice/benchmark corpora in the repo root |
| security-supply-chain-9 | low | unverified | S | scripts/check-no-network.sh:286 | 'Entitlements prove no network' claim overstates enforcement — the app is not sandboxed |
| security-supply-chain-10 | low | unverified | S | Sources/Talkie/Permissions.swift:126 | Permissions.relaunch() interpolates the bundle path into a /bin/sh -c string |
| security-supply-chain-11 | low | unverified | S | scripts/install.sh:4 | Documented install path is curl / sh with no integrity anchor |
| security-supply-chain-12 | low | unverified | S | ci/release.yml:174 | Tag-triggered release workflow pushes directly to main via checkout -B |
| simplify-core-1 | high | skipped | S | Sources/Talkie/DictationAssembler.swift:13 | DictationAssembler is fully dead code — superseded by StreamingCleanup |
| simplify-core-2 | high | skipped | M | Sources/Talkie/TranscriptionEngine.swift:634 | PCM buffer conversion duplicated: TranscriptionEngine.OneShot/convertOne mirrors AudioCapture.SingleShotInput/convert |
| simplify-core-3 | high | skipped | S | Sources/Talkie/TranscriptionEngine.swift:8 | talkieDebugLog is a 'TEMPORARY' debug facility that became the app's logging system, writing transcript content to /tmp in production |
| simplify-core-4 | medium | skipped | S | Sources/Talkie/TranscriptionEngine.swift:225 | TranscriptionEngine.transcribeBuffered has no callers — the meeting shim it served is gone |
| simplify-core-5 | medium | skipped | S | Sources/Talkie/Protocols/MeetingContextProvider.swift:10 | MeetingContextProvider protocol has no protocol-typed consumer; detectActiveMeeting() on the actor is dead and both conformers stub half the protocol |
| simplify-core-6 | medium | skipped | M | Sources/Talkie/Backends/AppleSpeechBackend.swift:18 | AppleSpeechBackend typealias and beginSession(onUpdate:onSegment:) overload are dead; TranscriptionBackend is only ever used for requiresNetwork |
| simplify-core-7 | medium | skipped | S | Sources/Talkie/Meetings/MeetingNotesFusion.swift:147 | MeetingNotesFusion.chunk is an acknowledged copy of MeetingSummarizer.chunk (plus a duplicated compress-loop) |
| simplify-core-8 | medium | skipped | S | Sources/Talkie/MeetingRecorder.swift:1086 | locale→language-code helper implemented three times |
| simplify-core-9 | medium | skipped | M | Sources/Talkie/MeetingRecorder.swift:20 | MeetingRecorder is a 1141-line god-file: audio writer class and crash-recovery codec should move out |
| simplify-core-10 | medium | skipped | M | Sources/Talkie/Meetings/NotchPanel.swift:7 | Notch-panel construction and positioning math exists in three copies (NotchPanel + two in HUD.swift) |
| simplify-core-11 | medium | skipped | S | Sources/Talkie/MeetingRecorder.swift:361 | MeetingRecorder.start() repeats the abort-teardown block three times |
| simplify-core-12 | low | skipped | S | Sources/Talkie/Meetings/InboxWatcher.swift:357 | The "(imported: <filename>)" dedup marker is composed in three places |
| simplify-core-13 | low | skipped | S | Sources/Talkie/OutputTranslator.swift:174 | OutputTranslator.Decision is shared across two phases, producing unreachable switch arms |
| simplify-core-14 | low | skipped | S | Sources/Talkie/HotKeyMonitor.swift:22 | HotKeyMonitor still documents the removed tap-tap-to-lock gesture; deferTimer comments describe behavior that no longer exists |
| simplify-core-15 | low | skipped | S | Sources/Talkie/Meetings/StreamLanguageVoter.swift:121 | StreamLanguageVoter.mergedText is production code used only by tests |
| simplify-ui-1 | high | skipped | L | Sources/Talkie/SettingsView.swift:1664 | SettingsView.swift is a 2,509-line God file mixing window chrome, shell, design system, and four full panes |
| simplify-ui-2 | high | skipped | L | Sources/TalkieMCP/SemanticCore.swift:187 | MCP/CLI 'mirror-don't-import' copies have already drifted once; the shared leaf target the comments promise is overdue |
| simplify-ui-3 | medium | skipped | S | Resources/Brand/AmbientDark.png:1 | 19 unused Brand PNGs (~3.7 MB) ship inside every app bundle |
| simplify-ui-4 | medium | skipped | M | Sources/Talkie/ActivityStore.swift:251 | Ten stores hand-roll the identical JSON load/save persistence boilerplate |
| simplify-ui-5 | medium | skipped | M | Sources/Talkie/SettingsView.swift:103 | 26 dependencies threaded twice by hand: MainWindowController.init forwards every store 1:1 into MainView |
| simplify-ui-6 | medium | skipped | M | Sources/TalkieCLI/OutputFormats.swift:42 | SRT/VTT/JSON renderers implemented twice (app vs CLI) with divergent cue-repair policies |
| simplify-ui-7 | medium | skipped | S | Sources/Talkie/Settings/LanguageSettings.swift:115 | LanguageStripTile and LanguageCard are near-duplicate tiles with byte-identical flag and badge builders |
| simplify-ui-8 | medium | skipped | M | Sources/Talkie/OnboardingView.swift:137 | Onboarding sealed try-it UI and toggle logic duplicated between the tryIt step and the privacy dare |
| simplify-ui-9 | low | skipped | S | Sources/Talkie/SettingsView.swift:581 | Dead code: SubpagePlaceholder is unreferenced — its scaffold routes now resolve to real pages |
| simplify-ui-10 | low | skipped | S | Sources/Talkie/SettingsView.swift:877 | Copy-to-clipboard + 1.4 s 'Copied' flash pattern hand-rolled at six sites |
| simplify-ui-11 | low | skipped | S | Sources/Talkie/DashboardView.swift:248 | EditableNameTitle and EditableParrotName duplicate the same inline click-to-edit state machine |
| simplify-ui-12 | low | skipped | S | Sources/Talkie/MeetingsView.swift:1040 | MeetingAppChip and MutedAppChip live in MeetingsView.swift but are used only by Settings/MeetingsSettings.swift |
| wiring-1 | high | unverified | S | Package.swift:92 | TalkieBridge (77 lines) is compiled into every default build's package graph but never linked, imported, or injectable — the 'Connected' flavor it exists for does not exist |
| wiring-2 | medium | unverified | S | Sources/Talkie/AppDelegate.swift:1998 | Known suspect 'requiresNetwork dead enforcement' is now FIXED via PrivacyWall — but 5 backend/summarizer instantiation sites still bypass the wall |
| wiring-3 | medium | unverified | S | Sources/Talkie/Commands/ReplaceSelectionIntent.swift:9 | ReplaceSelectionIntent is never constructed anywhere — the 're-dictate this selection' command (feature 12) is unreachable dead code |
| wiring-4 | medium | unverified | S | Sources/Talkie/DictationAssembler.swift:13 | DictationAssembler (58 lines) has zero references — superseded by StreamingCleanup |
| wiring-5 | low | unverified | S | Sources/Talkie/SettingsView.swift:581 | SubpagePlaceholder ('This settings page is coming soon.') is unused — all three L6 subpages shipped their real panes |
| wiring-6 | low | unverified | S | Sources/Talkie/DesignSystem.swift:293 | VisualEffectView in DesignSystem.swift is unused and its doc claims a sidebar role it doesn't have |
| wiring-7 | low | unverified | S | Sources/Talkie/Backends/AppleSpeechBackend.swift:9 | TranscriptionBackend seam is half-consumed: AppleSpeechBackend typealias, supportsContextualStrings, and the beginSession(onUpdate:onSegment:) overload have no production callers |
| wiring-8 | low | unverified | S | Sources/Talkie/SettingsView.swift:79 | SettingsRouter.pendingPage doc says 'nothing sets it yet' — but MeetingsView sets it; the stale comment invites deletion of live wiring |
| design-consistency-1 | high | skipped | S | Sources/Talkie/DesignSystem.swift:40 | Theme.inkTertiary fails WCAG contrast for body-size text (2.6:1 light, 3.6:1 dark) |
| design-consistency-2 | medium | skipped | L | Sources/Talkie/DesignSystem.swift:130 | Entire type system is fixed-size — ignores the system Text Size accessibility setting |
| design-consistency-3 | medium | skipped | M | Sources/Talkie/Meetings/MeetingPill.swift:63 | Meeting pill ignores Increase Contrast / Reduce Transparency that the sibling HUD pill honors |
| design-consistency-4 | medium | skipped | S | Sources/Talkie/HUD.swift:1601 | HUD error state uses system .orange instead of the warning token — inconsistent within the same file |
| design-consistency-5 | medium | skipped | S | Sources/Talkie/MeetingsView.swift:531 | Two recording dots, two reds: MeetingsView uses Color.red while MeetingPill uses Theme.featherRed |
| design-consistency-6 | medium | skipped | M | Sources/Talkie/MeetingsView.swift:592 | Icon-only hover buttons have tooltips but no accessibilityLabel — and only appear on hover |
| design-consistency-7 | low | skipped | S | Sources/Talkie/HUD.swift:1086 | HUD pill radius 17 is a magic number repeated six times — no token |
| design-consistency-8 | low | skipped | M | Sources/Talkie/OnboardingView.swift:164 | Near-miss corner radii (12, 10, 8) shadow the 13/9 tokens across Onboarding, Settings, Meetings |
| design-consistency-9 | low | skipped | S | Sources/Talkie/OnboardingView.swift:165 | strokeBorder outlines contradict the documented 'never an outline (borderless)' v2 doctrine |
| design-consistency-10 | low | skipped | S | Sources/Talkie/Meetings/MeetingConsentBanner.swift:148 | Meeting consent banner's hardcoded white hairline vanishes in light mode |
| design-consistency-11 | low | skipped | S | Sources/Talkie/Settings/LanguageSettings.swift:175 | White-on-brand badges drop to ~2.8:1 in dark mode because the accent flips light |
| design-consistency-12 | low | skipped | S | Sources/Talkie/BirdBuddy.swift:193 | BirdBuddy glow color is a hardcoded Color(red:…) outside the token system |
| design-consistency-13 | low | skipped | S | Sources/Talkie/DashboardView.swift:127 | Page gutter '28' is repeated in 9 screens with no Theme.Space token |
| design-consistency-14 | low | skipped | S | Sources/Talkie/Niche/BiasABTestView.swift:44 | BiasABTestView is the one screen styled like a different app (dev-only) |
| copy-humanize-1 | high | skipped | S | Sources/Talkie/TranscriptionEngine.swift:59 | HUD error 'No supported speech locale could be resolved.' is passive jargon with no next step |
| copy-humanize-2 | high | skipped | S | Sources/Talkie/TranscriptionEngine.swift:61 | HUD error 'The speech model could not be installed: %@' is passive and appends a raw system error |
| copy-humanize-3 | high | skipped | S | Sources/Talkie/TranscriptionEngine.swift:63 | HUD error 'No compatible audio format was found for the microphone.' is jargon with no next step |
| copy-humanize-4 | medium | skipped | S | Sources/Talkie/TranscriptionEngine.swift:57 | Two different phrasings for the same 'no on-device speech' condition |
| copy-humanize-5 | medium | skipped | S | Resources/Localizations/en.lproj/Localizable.strings:325 | 'Couldn't save that note anywhere — nothing was typed, try again.' is confusing |
| copy-humanize-6 | medium | skipped | S | Sources/Talkie/SettingsView.swift:2397 | Settings permission rows read like an OS spec and clash with the warmer onboarding copy |
| copy-humanize-7 | medium | skipped | S | Sources/Talkie/Diagnostics/SpeedDetailView.swift:373 | 'optimistic' tag chip on the Dictation speed page is developer jargon |
| copy-humanize-8 | medium | skipped | S | Sources/Talkie/Settings/CalendarSettings.swift:51 | Calendar status 'Write-only — Talkie needs read access' uses API vocabulary and no fix path |
| copy-humanize-9 | medium | skipped | S | Sources/Talkie/CleanupEngine.swift:190 | CleanupEngine says 'smart cleanup' (term drift) and its worst case is a dead end |
| copy-humanize-10 | low | skipped | S | Sources/Talkie/MeetingsView.swift:398 | Watched-folder card: 'Off.' sentence-opener and 'No folder — this feature is off' are robotic |
| copy-humanize-11 | low | skipped | S | Sources/Talkie/Diagnostics/SpeedCard.swift:111 | 'median of your last dictation' — a median of one reads as nonsense |
| copy-humanize-12 | low | skipped | S | Sources/Talkie/Memory/MemoryView.swift:156 | History search placeholder uses a slashed 'name/project/term' construction |
| copy-humanize-13 | low | skipped | S | Sources/Talkie/Diagnostics/SpeedDetailView.swift:375 | '%d chars' abbreviation on the Dictation speed page |
| copy-humanize-14 | low | skipped | S | Sources/Talkie/Memory/MemoryView.swift:92 | 'Copy All' is Title Case in a sentence-case app |
| copy-humanize-15 | low | skipped | S | Sources/Talkie/SettingsView.swift:2393 | Permissions footer 'for the change to take effect' is stiff bureaucratic phrasing |
| l10n-integrity-1 | medium | unverified | S | Sources/Talkie/HUD.swift:1588 | Hold-to-lock copy rewrite left all new strings out of every catalog (stale old translations remain) |
| l10n-integrity-2 | medium | unverified | S | Sources/Talkie/Meetings/MeetingConsentBanner.swift:106 | Meeting consent banner, app picker, and recording pill: every key missing from all 10 catalogs |
| l10n-integrity-3 | medium | unverified | M | Sources/Talkie/CommandsView.swift:42 | CommandsView (Voice Commands settings page) is entirely unlocalized — 0 .loc calls, 0 catalog keys |
| l10n-integrity-4 | medium | unverified | S | Sources/Talkie/SettingsView.swift:1306 | SettingsRow/SettingsToggleRow titles and SettingsCard footers render non-localizing Text(String) — the trap behind several unlocalized pages |
| l10n-integrity-5 | medium | unverified | S | Sources/Talkie/DashboardView.swift:662 | Dashboard speed-comparison and stat-chip strings bypass localization (plain String, no .loc, not in catalog) |
| l10n-integrity-6 | medium | unverified | S | Sources/Talkie/AppDelegate.swift:537 | Main-menu and status-menu NSMenuItems hardcode English titles while sibling items are localized |
| l10n-integrity-7 | medium | unverified | M | Sources/Talkie/HUD.swift:1325 | HUD 'Press ⌘⇧V to paste' sentence is split into two untranslatable fragments around the keycap view |
| l10n-integrity-8 | medium | unverified | M | Sources/Talkie/DashboardView.swift:1009 | Naive English 's'-appending pluralization in visible UI; no .stringsdict anywhere in the repo |
| l10n-integrity-9 | medium | unverified | S | Sources/Talkie/SettingsView.swift:1714 | Dictionary settings core controls bypass the catalog (placeholders, hint, tooltips) |
| l10n-integrity-10 | medium | unverified | S | Sources/Talkie/OnboardingView.swift:502 | Onboarding try-it field and Memory search field miss the catalog |
| l10n-integrity-11 | low | unverified | S | Sources/Talkie/Scratchpad/ScratchpadCard.swift:119 | Scratchpad Chirp-suggestion labels not in any catalog |
| l10n-integrity-12 | low | unverified | M | Sources/Talkie/SettingsView.swift:1156 | Dev-update channel UI (Settings ▸ Developer and TalkieUpdater alerts) is English-only |
| concurrency-1 | high | unverified | S | Sources/Talkie/AppDelegate.swift:1014 | Dictation can start during MeetingRecorder.start()'s async window and both sessions stomp each other on the shared TranscriptionEngine |
| concurrency-2 | high | unverified | S | Sources/Talkie/AppDelegate.swift:1268 | Abandoned dictation-begin task calls blanket engine.cancelSession(), killing the NEXT session's analyzer (fast press–release–press loses the whole utterance) |
| concurrency-3 | medium | unverified | S | Sources/Talkie/MeetingRecorder.swift:39 | MeetingAudioFileWriter has no 'closed' latch — a late mic-tap buffer arriving after close() re-creates the AVAudioFile and destroys the finished meeting audio |
| concurrency-4 | medium | unverified | S | Sources/Talkie/MeetingRecorder.swift:536 | MeetingRecorder.tick() can fire during stop()'s awaits and spawn an analyzer rotation that interleaves with finish() via actor reentrancy — worst case wedges isFinishing forever |
| concurrency-5 | low | unverified | S | Sources/Talkie/HotKeyMonitor.swift:119 | HotKeyMonitor.stop() racing the tap thread's startup can re-enable the tap and leak the run-loop thread, delivering duplicate gesture edges |
| concurrency-6 | low | unverified | S | Sources/Talkie/TranscriptionEngine.swift:8 | talkieDebugLog appends to /tmp/talkie-lang.log from many threads with no synchronization — concurrent writers interleave and clobber each other |

