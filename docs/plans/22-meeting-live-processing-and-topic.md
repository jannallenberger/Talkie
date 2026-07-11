# 22 — Live meeting processing + a faster, richer topic indicator

> **Owner contract:** **Exposes** an incremental digest seam
> (`MeetingDigestBuilder`) that turns the stop-time map-reduce into a
> during-recording stream, and an upgraded `MeetingSubtopicModel` that carries a
> one-line gloss + an ephemeral "live question" signal. **Consumes** the existing
> live segment feed (`MeetingRecorder.onLiveSegment`), the shared on-device model
> (`OnDeviceLLM` via `MeetingSummarizer` / `MeetingSubtopicEngine`), and the
> deterministic interrogative heuristic factored out of `CleanupEngine`.
> **Note:** never let background processing starve live transcription or the topic
> poll — the shared Neural Engine is the scarce resource.
>
> Grounded against `main` @ `0ad8f27` (worktree
> `claude/talkie-transcription-hallucination-2177a3`). Verified by reading
> `MeetingRecorder.swift`, `Meeting.swift` (`MeetingSummarizer`),
> `Meetings/MeetingSubtopicEngine.swift`, and `Meetings/MeetingPill.swift`.

---

## 1. Summary

Two independent improvements to the meeting experience:

- **Part A — stream the processing.** Transcription is *already* live; the "very
  slow after it's finished" wait is the **stop-time LLM chain**: language
  correction → notes fusion → `summarizeCondensed` (a map-reduce that fires up to
  ~16 sequential on-device calls) → per-chunk graph extraction. Move the
  **map** and **graph-extraction** phases to run *incrementally during the
  recording*, chunk by chunk, so stop only pays the final **reduce** (+ fusion)
  — 1–2 calls instead of ~14–30.
- **Part B — a faster, richer topic indicator.** Today the pill's topic can take
  **~24–40 s** to switch and is a bare 2–5 word phrase. Make it (1) switch faster
  via tuned cadence + a rethought hysteresis, (2) surface **the other person's
  questions at sub-second speed** with a deterministic detector (no LLM, no
  streak — the interview win), and (3) show a **short sentence/gloss** instead of
  one word.

Parts A and B touch different files and can ship independently.

---

## 2. Why it matters

- **Stop latency is the last rough edge of an otherwise-loved feature** (Jann:
  "the meetings transcription is working well, but it's very slow after it's
  finished"). For a 1-hour meeting the map phase alone is ~12 back-to-back model
  calls at the exact moment the user wants their note *now*. Spreading that work
  across the hour (when the machine is idle between utterances) makes stop feel
  instant.
- **The topic pill is the live "am I being understood?" signal.** A 30-second lag
  makes it feel broken; an interviewer's question shown instantly makes it feel
  clairvoyant. This is the Granola-grade "it just knew" moment for the live
  surface, not just the saved note.

---

## 3. Current state (what the code actually does)

### 3.1 Transcription is already live — the wait is the stop-time LLM chain

Both streams transcribe live: finalized segments arrive through
`timedSegmentHandler` / `onLiveSegment` and are appended to `TurnLog` as they're
spoken ([MeetingRecorder.swift:343](../../Sources/Talkie/MeetingRecorder.swift#L343),
[:404](../../Sources/Talkie/MeetingRecorder.swift#L404)). So the transcript text
is essentially done when you press stop.

Everything expensive happens **after** stop, serially, on the shared on-device
model ([MeetingRecorder.swift:656-793](../../Sources/Talkie/MeetingRecorder.swift#L656)):

1. **Stream finalize / language vote** — `mic.finish()` / `far.finish()`
   (multilingual per-segment vote) or `finishSession()`.
2. **Legacy language correction** — `correctStreamLanguage` *re-transcribes*
   buffered audio in other languages (only the single-locale multilingual
   fallback; expensive but conditional).
3. **Notes fusion** — 1 call over the whole transcript, only if notes were typed.
4. **`summarizeCondensed`** — the dominant cost. `mapAll` maps **up to 16
   chunks** with one model call each, then up to 3 compression passes, then a
   reduce ([Meeting.swift:292-298](../../Sources/Talkie/Meeting.swift#L292)).
5. **Stage-2 graph extraction** — `GraphLLMExtractor.extract` over *each* ≤4000-char
   chunk of the condensed text ([MeetingRecorder.swift:774-784](../../Sources/Talkie/MeetingRecorder.swift#L774)).

Steps 4 and 5 operate on chunks of transcript that are **finalized progressively**
during the meeting — everything except the last ~4000 chars is stable minutes
before stop. That's the opening for Part A.

### 3.2 The topic indicator's latency budget

`MeetingSubtopicEngine` ([Meetings/MeetingSubtopicEngine.swift](../../Sources/Talkie/Meetings/MeetingSubtopicEngine.swift))
polls on a loop with these tunables:

| Knob | Value | Effect |
|---|---|---|
| `evalInterval` | **12 s** | poll cadence |
| `minNewCharsToEval` | **180 chars** | must accumulate ~12 s+ of speech before a call |
| `requiredStreak` | **2** | a new topic needs 2 *consecutive* high-confidence hits to show |

So a genuinely new topic surfaces only after **≥ 2 evals × (12 s + speech) ≈
24–40 s**. The gating is deliberately conservative (never show a guess, never
flicker) but it's tuned for calm, not responsiveness. The displayed label is
capped to a **2–5 word phrase** by the prompt + `cleanTopic` (≤ 6 words, ≤ 48
chars, [:225](../../Sources/Talkie/Meetings/MeetingSubtopicEngine.swift#L225)),
and the pill renders it single-line ([MeetingPill.swift:78-88](../../Sources/Talkie/Meetings/MeetingPill.swift#L78)).

---

## 4. Part A — stream the processing during the recording

### 4.1 What can move earlier, and what genuinely can't

| Stop-time step | Move to live? | Why |
|---|---|---|
| Map phase (per-chunk facts) | **Yes** | each chunk is final long before stop |
| Graph extraction (Stage-2) | **Yes** | same — runs per chunk |
| Final reduce | No (1 call) | needs *all* map partials; cheap, keep at stop |
| Notes fusion | No (1 call) | needs whole transcript + final notes; cheap |
| Language correction / vote | No | language only *settles* at stop (see §4.4) |

The win is converting the **N-call map** (the part that scales with meeting
length) into background work, leaving stop with a **fixed, small** cost.

### 4.2 Design: `MeetingDigestBuilder` (incremental map-reduce)

A new actor that the recorder feeds during recording:

```
actor MeetingDigestBuilder {
    // Fed live from the segment feed (finalized, speaker-tagged text).
    func ingest(_ speaker: MeetingSpeaker, _ text: String)
    // At stop: seal the tail chunk, reduce, return the summary + condensed view
    // + graph candidates already gathered — same shape summarizeCondensed returns.
    func finish(notes: String) async -> (summary: String?, condensed: String,
                                         graphCandidates: [ContextGraphExtractor.Candidate])
}
```

Behavior:

- Accumulate incoming text into a rolling buffer. When it crosses `chunkChars`
  (4000) on a line boundary, **seal** that chunk and enqueue two low-priority
  jobs: `mapExcerpt(chunk)` (reuse the existing method on `MeetingSummarizer`)
  and `GraphLLMExtractor.extract(chunk)`. Store the ordered partials + deduped
  candidates.
- At `finish()`: seal the final partial buffer, await any in-flight jobs, then
  run the existing `reduceWithFallback` over the joined partials and compose the
  summary. Graph candidates are already collected; just dedupe + return.
- Reuse, don't reinvent: `mapExcerpt`, `reduceWithFallback`, the compression
  loop, and the `.rateLimited/.concurrentRequests` retry already live in
  `MeetingSummarizer` ([Meeting.swift:277-361](../../Sources/Talkie/Meeting.swift#L277)).
  `MeetingDigestBuilder` is mostly *scheduling* around them, so the summary's
  content and guardrails are unchanged.

Wiring in `MeetingRecorder`:

- Build a `MeetingDigestBuilder` in `start()` (only when `MeetingSummarizer.isAvailable`),
  and feed it from the same place the subtopic engine is fed — the `onLiveSegment`
  hook / `liveFeed` closures ([MeetingRecorder.swift:322-346](../../Sources/Talkie/MeetingRecorder.swift#L322)).
- In `stop()`, replace the `summarizeCondensed` + the Stage-2 extraction loop
  ([MeetingRecorder.swift:760-784](../../Sources/Talkie/MeetingRecorder.swift#L760))
  with `digest.finish(notes:)`. The rest of the finalize block (compose summary,
  action-items section, `store.add`, graph ingest, crash-partial removal) is
  unchanged — it just consumes the same tuple.

### 4.3 The shared-model contention constraint (the one real risk)

The on-device model is a single shared resource, and during recording the Neural
Engine is already running two live `SpeechAnalyzer` streams. Guardrails so the
background map never degrades the live experience:

- **Frequency is naturally low.** One map call per ~4000 chars ≈ ~700 words ≈
  ~5 min of speech → ~12 calls spread across a 1-hour meeting, one every few
  minutes. This is nothing like the back-to-back stop-time burst.
- **Low QoS.** Run digest jobs at `.utility`/`.background` so the scheduler
  favors transcription and the topic poll.
- **Serialize with the topic engine.** Both the subtopic eval and the digest map
  hit the same model; route them so they don't fire concurrently (the summarizer
  already retries `.concurrentRequests`, but avoiding the collision is cleaner).
  *Option:* a tiny shared `MeetingLLMScheduler` actor that runs topic evals at
  higher priority than digest maps. Call this a **stretch** — v1 can rely on the
  existing retry + low QoS and measure.
- **Backpressure.** If a map job is still running when the next chunk seals, don't
  stack — queue at most one pending chunk and merge if we fall behind.

### 4.4 Multilingual caveat — language settles at stop

In multilingual mode the per-segment language **vote** only resolves at `finish()`
([MeetingRecorder.swift:663-677](../../Sources/Talkie/MeetingRecorder.swift#L663)),
and the single-locale fallback may **re-transcribe** whole streams at stop
(§3.1 step 2). Text mapped incrementally from the pre-settlement transcript would
be stale.

**Scope decision:** enable incremental digest **only when the meeting is not
multilingual and not re-transcribing** (the common single-language case). For
multilingual meetings, fall back to today's stop-time `summarizeCondensed`. Detect
this from the same flags `start()` already computes (`multiLang`, `langsAtStart`).
This keeps the change safe and still covers the majority of meetings; a later plan
can tackle incremental digest for multilingual by mapping settled spans as lanes
rotate.

### 4.5 What stop looks like after Part A

1. Finalize streams / language vote (unchanged).
2. `digest.finish(notes:)` → seal tail chunk (1 map call), 1 reduce, return
   pre-gathered graph candidates.
3. Notes fusion (unchanged, 1 call, only if notes).
4. Compose, `store.add`, graph ingest, drop crash-partial (unchanged).

Stop-time model calls drop from **~14–30 → ~2–3**, independent of meeting length.

### 4.6 Edge cases

- **Discarded/empty recording** — if nothing was transcribed, throw the partials
  away exactly like today's empty-transcript branch
  ([MeetingRecorder.swift:706](../../Sources/Talkie/MeetingRecorder.swift#L706)).
- **Very long meeting** — cap sealed partials the way `maxChunks` does today; when
  joined partials exceed `chunkChars`, the existing compression loop applies at
  `finish()`.
- **Model unavailable** — no digest builder; stop path is byte-identical to today.
- **Crash mid-meeting** — recovery is already summary-less
  ([MeetingRecorder.swift:946](../../Sources/Talkie/MeetingRecorder.swift#L946));
  partials are in-memory and simply lost, no regression.

---

## 5. Part B — a faster, richer topic indicator

### 5.1 Faster switching

Retune and rethink the gate ([MeetingSubtopicEngine.swift:38-48](../../Sources/Talkie/Meetings/MeetingSubtopicEngine.swift#L38)):

- **Cadence:** `evalInterval` 12 s → **~5 s**; `minNewCharsToEval` 180 → **~90**.
- **Adaptive poll:** evaluate as soon as `minNewChars` is reached rather than
  waiting for the next fixed tick — i.e. wake on ingest once enough new speech
  has landed, so a fast-moving conversation updates promptly and a quiet one
  doesn't burn calls.
- **Rethink the streak.** `requiredStreak = 2` is the biggest latency multiplier.
  Options: (a) drop to **1** but add a short **dwell** (don't *replace* a topic
  that's < ~8 s old) to kill flicker; (b) keep 2 only for *replacing* an existing
  topic, accept the **first** topic on streak 1 (fills the empty pill fast, then
  refines). Recommend (b): the empty→first transition should be eager; topic→topic
  churn stays damped.
- Contention note: 5 s polling roughly doubles topic calls but they're tiny and
  still far below dictation-cleanup load; measure against the digest jobs (§4.3).

### 5.2 Immediate question detection (the interview win) — deterministic, sub-second

Independent of the LLM path. The far-end feed already delivers finalized,
speaker-tagged segments live (`liveFeed(.them, …)`). On each `.them` (and
optionally `.me`) segment, run a **deterministic interrogative check** and, on a
hit, publish an **ephemeral "live question"** to the pill immediately — no model,
no streak, no 12 s wait.

- **Reuse the heuristic we just built.** `CleanupEngine.isInterrogative` +
  `questionOpeners` (EN + DE, "?" or leading question word) already exist from the
  dictation answer-guard work. **Factor them into a shared
  `Interrogative` helper** so both features use one source of truth.
- **Model change:** add `@Published var liveQuestion: String?` to
  `MeetingSubtopicModel` (or a small sibling). Set it when a far-end question is
  detected; auto-clear after ~6–8 s (or when the next question/topic arrives).
- **Latency:** far-end segments finalize within ~1–2 s of the speaker pausing —
  effectively immediate versus the 24–40 s topic path.
- **Display:** a distinct treatment, e.g. `❓ "So what got you into this?"` in the
  pill's second line, visually differentiated from the topic (color/icon). For an
  interview this is the headline signal.
- **Guardrails:** debounce (don't spam on a run of short "right?" tags); cap
  length (show the tail of a long question); it *augments* the topic line, never
  replaces the confident topic permanently.

### 5.3 Topic as a short sentence/gloss instead of one word

Extend the model's contract to emit a short **gloss** used for *display*, while
keeping a short **topic phrase** for *gating* (stability):

- **Prompt** ([:165-185](../../Sources/Talkie/Meetings/MeetingSubtopicEngine.swift#L165)):
  ask for three lines —
  `TOPIC|<2–5 word phrase for stability>` /
  `GLOSS|<one ≤ ~12-word sentence describing what's being discussed now>` /
  `CONFIDENCE|HIGH|LOW`.
- **Gate on `TOPIC`** (normalized) exactly as today (hysteresis unchanged), but
  **publish the `GLOSS`** for display. Keying the gate on the short phrase keeps
  switching stable even though the visible text is a full sentence (a sentence
  alone would jitter run-to-run and fight the hysteresis).
- **Parsing/bounds:** extend `parse` + `cleanTopic` for the gloss (looser cap,
  e.g. ≤ ~80 chars, ≤ 14 words; fall back to the phrase if the gloss is empty or
  overflows).
- `MeetingSubtopicModel.current` becomes `(topic: String, gloss: String)` (or add
  `currentGloss`).

### 5.4 Pill UI

`MeetingPill` ([MeetingPill.swift:78-88](../../Sources/Talkie/Meetings/MeetingPill.swift#L78))
today shows one `lineLimit(1)` topic line in a `fixedSize` 540-wide capsule:

- Allow the topic/gloss line to wrap to **2 lines** (`lineLimit(2)`), and relax
  `fixedSize` so the capsule can grow vertically (panel height is 104, room to
  spare).
- Render the **live question** as its own line/treatment with the `❓` icon and a
  coral accent, above or replacing the topic line while active, then fade back to
  the topic gloss (reuse the existing `.blurReplace` transition + spring).
- Keep the neutral state (status + timer only) until the first confident topic —
  unchanged contract, never show a guess.

---

## 6. Phasing / sequencing

Ship in this order — each is independently valuable and independently revertible:

1. **B2 — immediate question detection.** Highest wow-per-effort, fully
   deterministic, no model-contention risk. Factor out `Interrogative`, add
   `liveQuestion`, wire the pill. *(small)*
2. **B1 — faster topic switching.** Pure tunables + gate tweak; measure. *(small)*
3. **B3 — sentence gloss.** Prompt + parse + model + pill. *(small–medium)*
4. **A — incremental digest.** The biggest change; scoped to single-language
   meetings first, with the stop-time path as the untouched fallback.
   *(medium)*

## 7. Test plan

- **Digest parity (A):** a unit test that the incremental builder over a
  transcript produces a summary/candidate set equivalent to today's
  `summarizeCondensed` + extraction over the same text (same chunks → same
  partials → same reduce input). Golden-ish; allow model nondeterminism by
  asserting on the *chunking/scheduling* seam with a stub summarizer.
- **Stop-latency measurement (A):** instrument stop with the existing
  `ProcessingTrace`/`talkieDebugLog` timing; compare a 30-min recording before/
  after — expect stop model-call count to drop from ~N to ~2–3.
- **Contention (A):** run a long recording and confirm live transcription
  segment latency and topic cadence don't regress while digest jobs fire (log
  inter-segment gaps).
- **Question detector (B2):** pure unit tests on the shared `Interrogative`
  helper (EN + DE, with and without "?", statements/imperatives not flagged) —
  extend the 26-case table already written for the cleanup guard.
- **Gate stability (B1/B3):** existing `evaluateForTesting` seam
  ([:160](../../Sources/Talkie/Meetings/MeetingSubtopicEngine.swift#L160)) —
  assert eager first-topic accept, damped topic→topic churn, and gloss/topic
  parsing (gloss shown, topic gated).
- **Multilingual fallback (A):** a multilingual recording still takes the
  stop-time path and is byte-identical to today.

## 8. Decisions

_Resolved with Jann 2026-07-09:_

1. **Question detector scope → FAR-END ONLY.** Only the other person's /
   interviewer's questions flash in the pill. Cleaner signal for interviews.
2. **Streak change (B1) → EAGER FIRST, DAMP CHANGES.** Accept the first confident
   topic on streak 1 (fills the empty pill fast); require the 2-hit streak only to
   *replace* an already-shown topic. The single biggest responsiveness win.

_Still open (decide before building those pieces):_

3. **Gloss vs. phrase (B3):** show the full sentence gloss as the primary line, or
   keep the short phrase as a bold headline with the gloss as a lighter subtitle?
4. **Incremental digest for multilingual (A):** fine to defer (stop-time fallback)
   for now, or is a lot of your meeting time multi-language (which would raise its
   priority)?

_Status: plan only — not yet implemented (Jann chose "just the plan for now")._
