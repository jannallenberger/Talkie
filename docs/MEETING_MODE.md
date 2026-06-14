# Talkie — Meeting Mode (design)

Goal: Talkie detects when a meeting starts, transcribes the **whole** conversation
(you + the other participants), labels **who said what**, applies your dictionary,
and saves a clean transcript to a local folder so a separate Claude session can be
pointed at it to summarize. Works **online and offline**.

> Status: design only (researched 2026-06-14). Built incrementally — see Phasing.

---

## The one insight that makes this tractable

Apple's `SpeechTranscriber` (what Talkie already uses) is excellent at *words* but
**does not do speaker diarization** at all. Naively you'd reach for a heavy ML
"who-spoke-when" model. But there's a shortcut:

**Capture the two sides as two separate audio streams and transcribe each on its
own — then you know the speaker for free.**

- **Your mic** → one `SpeechTranscriber` → every word is labeled **"Me"**.
- **The far-end audio** (what the Mac plays from Zoom/Meet/Teams) → a *second*
  `SpeechTranscriber` → every word is labeled **"Them"**.

For the overwhelmingly common 1:1 call, that's **perfect diarization with zero ML**.
You only need a real diarizer when **3+ people** share the far-end stream — and even
then it only has to split "Them", not "Me vs Them".

This is the spine of the whole design.

---

## Architecture (boxes)

```
                    ┌─────────────── meeting auto-detect ───────────────┐
                    │ Core Audio: is a NON-Talkie process recording the │
                    │ mic now?  AND is it a known meeting app?           │
                    └───────────────────────┬───────────────────────────┘
                                             │ start / stop
        ┌────────────────────────────────────┼────────────────────────────────────┐
        │                                                                           │
   ┌────▼─────┐  mic (AVAudioEngine)      ┌────────────┐                            │
   │  "Me"    │─────────────────────────► │ Transcriber│──► turns (t, "Me", text)   │
   └──────────┘                           │   #1       │                            │
                                          └────────────┘                            ▼
   ┌──────────┐  far-end (Core Audio tap) ┌────────────┐        ┌────────────────────────────┐
   │ "Them"   │─────────────────────────► │ Transcriber│──► ──► │ merge by timestamp →        │
   └────┬─────┘                           │   #2       │        │ apply dictionary →          │
        │  (3+ speakers?)                 └────────────┘        │ assemble speaker-labeled MD │
        └──► FluidAudio diarizer (splits "Them" into S1/S2/…)   └──────────────┬──────────────┘
                                                                               ▼
                                                          ~/Talkie/Meetings/2026-06-14-1430-zoom.md
```

### Components & exact tech

| Stage | Choice | API / package |
|---|---|---|
| Transcription | **Reuse Talkie's `TranscriptionEngine`**, one instance per source | `SpeechAnalyzer` + `SpeechTranscriber` with `attributeOptions:[.audioTimeRange]` (the timestamp is the join key) |
| Your mic | reuse existing `AudioCapture` | `AVAudioEngine` |
| Far-end audio | **Core Audio process tap** (global, excluding Talkie's own PID) → private aggregate device | `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice` (macOS 14.4+; **target 26.1+**, 26.0 had capture bugs) |
| Diarization (3+ far-end speakers) | **FluidAudio** (Swift, CoreML, runs on the Neural Engine) | `OfflineDiarizerManager.process(audio:)` → timeline of `{speakerId, start, end}`; align to transcript by max-overlap |
| Dictionary | **reuse `DictionaryStore`** | `contextualStrings` biasing during capture + `TextProcessor` find/replace before write |
| Online mode (opt-in) | **AssemblyAI** (best) or **Deepgram** (cheaper) behind a `Diarizer` protocol | WebSocket streaming, sub-300ms, returns words + speaker labels |
| Storage | Markdown + YAML frontmatter, atomic write | `~/Talkie/Meetings/` |

**Why Core Audio tap, not per-app or ScreenCaptureKit:** a *per-app* tap records
**silence** for Zoom/Teams (WebRTC emits from helper subprocesses). A *global* tap
excluding self is the reliable path and only needs the light **"Audio"** permission
(not Screen Recording). ScreenCaptureKit is the fallback for the rare WebRTC app
that bypasses the system mixer — but it needs full Screen-Recording consent.

---

## Meeting auto-detection

**Trigger = "some process *other than Talkie* is actively capturing the mic."**

- Enumerate `kAudioHardwarePropertyProcessObjectList`; for each, read
  `kAudioProcessPropertyIsRunningInput`. Poll every 1–2 s (the change-listener is
  documented-flaky). Exclude Talkie's own PID.
- **Confirm identity** against a known-meeting-app allowlist via the capturing
  process's bundle ID: `us.zoom.xos`, `com.microsoft.teams2`,
  `com.cisco.webexmeetingsapp`, `com.apple.FaceTime`, `com.tinyspeck.slackmacgap`,
  `com.hnc.Discord`, plus browsers (Chrome/Safari) for web meetings.
- **Rule:** *trigger* on mic-hot-by-another-process; *raise confidence* with the
  app allowlist (and optionally Zoom's `CptHost` child process, a held
  display-sleep assertion, or a hot camera via CoreMediaIO).
- **No false positives from music/YouTube/Netflix** — those are *output*, not mic
  input, so they structurally never trigger.
- **End** = the flag flips to false, debounced 15–30 s (survives brief mutes/holds).
- First releases: show a **"Meeting detected — recording?"** banner with one-tap
  cancel rather than silently recording, for trust + to cover the false-positive tail.

---

## Storage format (built for Claude to summarize)

One Markdown file per meeting in `~/Talkie/Meetings/`, named
`YYYY-MM-DD-HHMM-<app>.md`:

```markdown
---
title: Meeting (Zoom)
date: 2026-06-14T14:30:00+02:00
duration_min: 47
app: us.zoom.xos
participants: [Me, Them]   # or [Me, Speaker 1, Speaker 2]
source: offline            # offline | assemblyai | deepgram
dictionary_applied: true
---

[00:00:04] Me: Let's start with the Coralate roadmap.
[00:00:11] Them: Sounds good — where did the LiDAR scan land?
[00:01:02] Speaker 2: I can take the backend piece.
```

Then you literally tell Claude *"summarize the meetings in `~/Talkie/Meetings/`"* and
it has clean, speaker-attributed, dictionary-correct text to work from. (Optionally
also keep the raw `.caf` audio next to it; off by default for privacy.)

---

## Privacy & legal — non-negotiable from the first build

Recording other people's voices is a legal/ethical matter (11–12 US **all-party
consent** states; GDPR in the EU). Talkie MUST:

1. Show a **persistent, obvious "Recording" indicator** whenever meeting capture is on.
2. Offer **one-keystroke Stop**.
3. Be **local-only by default**; cloud mode is **opt-in** behind an explicit toggle + disclosure.
4. Make auto-record **confirmable** (banner), not silent, at least initially.
5. Keep everything in the user's folder; never upload without consent.

---

## Phasing (each phase ships something usable)

| Phase | What you get | Builds | Reuses | Effort |
|---|---|---|---|---|
| **1 — Mic-only record** | A "Record meeting" command: transcribes *your* side, saves a Markdown transcript to `~/Talkie/Meetings/`. (No far-end yet — useful for your own notes / talks.) | a `MeetingRecorder`, the MD writer, a recording pill | `TranscriptionEngine`, `AudioCapture`, `DictionaryStore`, `AppPaths` | **S** |
| **2 — Far-end audio** | Captures the *whole* call (you + them) as two streams → "Me"/"Them" labels for free. The real meeting transcriber. | Core Audio process tap + aggregate device; second transcriber; stream→disk buffering | Phase 1 + `TranscriptionEngine` | **M** |
| **3 — Multi-speaker diarization** | Splits "Them" into Speaker 1/2/3… for group calls. | FluidAudio integration + timestamp-overlap alignment | Phase 2 | **M** |
| **4 — Online accuracy mode** | Opt-in cloud transcription/diarization for top accuracy. | `Diarizer`/`Transcriber` protocol + AssemblyAI/Deepgram client + consent toggle | Phase 2/3 | **M** |
| **5 — Auto-detect** | Talkie notices a meeting started and offers to record. | Core Audio process scan + allowlist + banner | all above | **M** |

**Recommended start:** Phase 1 (a weekend-sized MVP that already produces useful
transcripts) → Phase 2 (the part that makes it a real meeting tool). Diarization,
cloud, and auto-detect layer on top without rework.

## Build-vs-buy calls

- **Diarization:** build on **FluidAudio** (free, on-device, Apache-2.0 code) — do
  *not* hand-roll diarization or take a paid SDK (Argmax SpeakerKit is good but
  commercial + batch-only). Cloud is an *optional* accuracy mode, not the default.
- **Audio capture:** build directly on **Core Audio process taps** — do *not*
  require users to install a virtual-audio driver (BlackHole) or default to
  ScreenCaptureKit's heavier Screen-Recording permission.
- **Everything else** reuses Talkie's existing engine/dictionary/paths.

## Open risks to watch

- **Core Audio long-session zero-sample bug:** a 1–2 hr tap can keep firing but
  deliver all-zero PCM. Add an all-zero watchdog that rebuilds the tap.
- **Clock drift** between mic and tap — set `kAudioSubTapDriftCompensationKey:true`,
  resample both to 16 kHz mono, align on transcript timestamps.
- **`NSAudioCaptureUsageDescription`** must be added to Info.plist manually (not in
  the Xcode dropdown) or capture fails silently.
- **License:** FluidAudio code is Apache-2.0 but its diarization weights derive from
  pyannote Community-1 (CC-BY-4.0 + attribution) — fine for personal/co-founder use;
  verify before any public release.
