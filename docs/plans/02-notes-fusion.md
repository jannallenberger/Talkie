# 02 — Notes × Transcript Fusion (the Granola magic)

> Engineer-ready implementation plan. Grounded in the code at `main` (HEAD `5f747fb`)
> and the unmerged `feat/meeting-far-audio` branch. Read `_CURRENT_STATE.md` and
> `_UNIFICATION.md` first; this plan honors the **02** contract in `_UNIFICATION.md §6`.
>
> Floor: macOS 26.0, Apple Silicon, Swift 6 strict concurrency (`.v6`).

---

## 1. Summary

Add a live **notes pane** to the Meetings tab so the user jots sparse bullets while
recording; on stop, an on-device LLM **fuses** those notes with the (speaker-labeled)
transcript into the polished note they meant to write — never inventing facts — and
the result is written as three Markdown sections (**Notes** kept verbatim, **Summary**
fused, **Transcript** raw) into `~/Talkie Meetings/`.

---

## 2. Why it matters

This is the single feature people actually pay Granola for: you stay present in the
call typing two-word reminders, and the machine turns them into the structured note
you would have written if you'd had time. The strategic payoff is bigger than parity:

- **It feeds the moat.** The user's *notes* are the highest-signal text in the whole
  product — they are the user telling you, in their own words, what matters. Routed
  into the personal context graph (feature 05) as commitments and entities with
  `Provenance(.meeting)`, they make the "one private brain" measurably smarter than
  anything Granola (a cloud company with no dictation surface) can build.
- **It disrupts on price + privacy.** Granola is a subscription cloud product; this
  is the same magic, $0, 100% on-device, open source. "Your notes never leave your
  Mac, and they make your whole brain smarter" is a claim a cloud incumbent cannot
  match.
- **It reuses, doesn't rebuild.** Fusion is one more `Summarizer` call on text the
  app already produces; the note travels the same `NoteDestination` pipe as the plain
  meeting note. Low marginal cost, high marginal value.

---

## 3. Current state in the code

What exists today (cite `file:line`):

- **`Meeting` struct** — `Meeting.swift:5-16` (main) / `:5-20` + custom `init(from:)`
  `:23-38` (branch). Codable. On branch it already carries `participants: [String]`
  and `source: String` with back-compat `decodeIfPresent`. **There is no field for
  user notes and no field for a separate fused summary** — `summary` is the only
  model-generated text field.
- **`MeetingSummarizer` actor** — `Meeting.swift:19-50` (main) / `:41-72` (branch).
  One on-device Foundation-Models pass over the transcript (capped at 8000 chars,
  `.greedy`, temp 0.3) producing the markdown summary. Hard-coded prompt; no notes
  input. This is the sibling I extend (see §4).
- **`MeetingStore`** — `Meeting.swift:53-123` (main) / `:75-145` (branch). Writes one
  `.md` per meeting via `writeMarkdown` (`:88-109` / `:113-138`). On main it emits
  `## Summary` + `## Transcript`; on branch it also emits `participants:` / dynamic
  `source:` frontmatter. **No `## Notes` section exists yet.**
- **`MeetingRecorder`** — `MeetingRecorder.swift` (main mic-only) / branch (two
  streams + `TurnLog`). `start()`/`tick()`/`stop()`/`recoverPartialIfNeeded()`. The
  branch's `stop()` (`:140-200`) already assembles the transcript via
  `MeetingTranscriptRenderer.render`, summarizes, and builds the `Meeting`. **This is
  the exact insertion point for fusion** — the recorder owns no user-notes state today.
- **`MeetingsView`** — `MeetingsView.swift`. `recordCard` (`:43-85`) shows
  start/recording/finishing states; `MeetingRow` (`:149-203`) renders summary
  (`MarkdownText`, `:181`) + a collapsible raw transcript (`:187-198`). **There is no
  notes text editor anywhere in this view.**
- **`CleanupEngine`** — `CleanupEngine.swift:194-260`. The on-device LLM wrapper
  (`SystemLanguageModel.default`), `isAvailable`/`unavailableMessage`, greedy/low-temp
  generation, `sanitize`. Its `generate(instructions:raw:)` pattern (`:225-239`) is
  the template every fusion call follows.
- **`MarkdownText`** — renders `**bold**` + `* bullets` (used at
  `MeetingsView.swift:181`); reuse verbatim for the Notes/Summary render.
- **`AppPaths`** — `AppPaths.swift`. `meetingsDirectory()` = `~/Talkie Meetings/`
  (plain, non-TCC). `supportDirectory()` = app-support JSON root.

**Honest status:** *nothing* of feature 02 is built. The transcript half, the summary
half, the persistence layer, and the markdown writer all exist and are mature; what is
missing is (a) capturing user notes during recording, (b) persisting them, (c) the
fusion prompt/flow, and (d) the three-section rendering. None of it requires new
frameworks — it is wiring + one new prompt + one new view.

**Branch dependency:** this plan is written to land **on top of the rebased
`feat/meeting-far-audio` branch** (feature 01), because fusion is dramatically better
with `[mm:ss] Me/Them:` labels — the LLM can attribute action items to the right side.
It also works on plain mic-only main; §12 covers the degradation. Per `_UNIFICATION.md`
Tier 0/1, 01 merges before 02 starts.

---

## 4. Design & approach

### 4.1 The flow

```
recording starts
   │
   ├─ user types sparse bullets in a NotesPane  ──►  MeetingRecorder.userNotes (live @Published)
   │        (debounced 1s flush to .recording.notes.partial.txt, mirrors the transcript partial)
   │
record stops
   │
   ├─ transcript = MeetingTranscriptRenderer.render(turnLog)        (branch) / raw join (main)
   │
   ├─ FUSION (new):  NoteFuser.fuse(notes: userNotes, transcript: transcript, participants:)
   │        • if notes are empty  → fall back to MeetingSummarizer.summarize (today's path)
   │        • if notes present    → one constrained on-device LLM pass:
   │              "Expand & organize the user's bullets using the transcript as evidence.
   │               Keep every bullet. Add only what the transcript supports. Never invent.
   │               Mark anything you couldn't verify. Attribute action items to Me/Them
   │               when the labels make it clear."
   │
   ├─ Meeting { userNotes, summary(=fused), transcript, participants, source, … }
   │
   └─ MeetingStore.writeMarkdown → ## Notes (verbatim) · ## Summary (fused) · ## Transcript (raw)
                                  → (via NoteDestination once feature 10 lands)
```

### 4.2 The fusion engine (a `MeetingSummarizer` sibling)

Add a new actor `NoteFuser` next to `MeetingSummarizer` in `Meeting.swift` (or a new
`NoteFuser.swift`). It mirrors `MeetingSummarizer` exactly — Foundation Models,
`LanguageModelSession`, `.greedy`, low temperature — but takes **two** inputs and a
"never invent" guardrail that is stricter than the summarizer's, because the user's
bullets are the spine and the transcript is only evidence.

Key prompt design decisions (Apple Foundation Models, on-device, deterministic):

1. **Notes are load-bearing, transcript is corroborating.** The instruction tells the
   model: every user bullet must survive into the output; the transcript is used to
   *expand, correct, and add detail*, not to override the user's intent.
2. **No fabrication, and say so when unsure.** Same guardrail as `ContextSummary.swift`
   /`MeetingSummarizer` ("Do NOT invent anything that isn't in the source"), plus an
   explicit "if a bullet isn't supported by the transcript, keep it but don't elaborate."
3. **Speaker attribution when available.** When the transcript carries `Me:`/`Them:`
   labels (branch), instruct the model to attribute action items to the right party
   ("**You** to send the deck", "**Them** to confirm pricing").
4. **Structured output, parsed not free-chat.** Output markdown with a short
   **Overview**, the user's **Notes (expanded)** as bullets, and **Action items** /
   **Decisions** sections only when present — the same shape `MeetingSummarizer` emits,
   so `MarkdownText` renders it unchanged and the section is drop-in compatible.
5. **Reuse `CleanupEngine.sanitize`-style cleanup** to strip any "Here's the fused
   note:" preamble. (Either call a shared helper or duplicate the small `sanitize`.)

### 4.3 Live action-item suggestions (stretch — phase 3 of this feature)

While recording, after each finalized turn lands in the `TurnLog`, run a *cheap,
debounced* heuristic pass (regex cues already specified for the graph in
`_UNIFICATION.md §1.5`: `\b(I'll|I will|I need to|let me|by (Monday|…|Friday|EOD))\b`)
to surface candidate action items in a side rail of the NotesPane. The user taps one to
drop it into their notes. **No live LLM call during recording** — the model is reserved
for the live mic transcription and a second concurrent generation would contend for the
ANE and could starve the recognizer. Heuristic-only live; LLM only at stop. This keeps
the "model exclusivity" invariant (`_UNIFICATION.md §4.4`).

### 4.4 Why a notes pane and not the system note app

The user must be able to type *inside Talkie during the call* so the notes are
timestamped against the recording and persisted to the partial file for crash safety.
A SwiftUI `TextEditor` bound to `recorder.userNotes` is the minimal correct surface.

---

## 5. New & changed files / types

### New: `NoteFuser.swift` (or add the actor into `Meeting.swift`)

```swift
import Foundation
import FoundationModels

/// Fuses the user's sparse meeting notes with the transcript into a polished note,
/// on-device, without inventing facts. The user's bullets are the spine; the
/// transcript is corroborating evidence. Falls back to plain summarization when the
/// user took no notes.
actor NoteFuser {
    static var isAvailable: Bool { CleanupEngine.isAvailable }

    /// Returns fused markdown (Overview + expanded notes + Action items/Decisions),
    /// or nil if the model is unavailable. `transcript` may carry `Me:`/`Them:` labels.
    func fuse(notes: String, transcript: String, participants: [String]) async -> String?

    // Internal: the system instructions (notes-are-spine, never-invent, attribute to
    // Me/Them when labeled). Greedy, temp 0.2. Caps inputs (notes ~2k, transcript
    // ~8k for MVP; map-reduce via the Summarizer protocol in a later phase, §6/§12).
}
```

### Changed: `Meeting.swift` — `Meeting` struct

Add one field (back-compat the same way `participants`/`source` were added on the
branch):

```swift
struct Meeting: Codable, Identifiable, Hashable {
    // … existing fields …
    /// The user's own notes typed during the meeting, kept verbatim. Empty when none.
    var userNotes: String = ""
    // summary now holds the FUSED note when userNotes is non-empty; otherwise the
    // plain transcript summary (unchanged behavior).
}
```

Extend the custom `init(from:)` (branch `:23-38`) with
`userNotes = try c.decodeIfPresent(String.self, forKey: .userNotes) ?? ""`.

### Changed: `MeetingStore.writeMarkdown`

Insert a `## Notes` section **before** `## Summary`, omitting it when empty:

```swift
let notesSection = m.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    ? ""
    : "\n## Notes\n\n\(m.userNotes)\n"
// frontmatter unchanged (branch adds participants/source); body becomes:
// ---frontmatter--- + notesSection + "## Summary" + summary + "## Transcript" + transcript
```

### Changed: `MeetingRecorder`

```swift
@Published var userNotes: String = ""          // bound to the NotesPane TextEditor
private var notesPartialURL: URL?              // .recording.notes.partial.txt
private let fuser = NoteFuser()                // sibling of `summarizer`

// start(): write empty notes-partial alongside the transcript-partial; reset userNotes.
// tick(): also flush userNotes to notesPartialURL (.atomic), same cadence as transcript.
// stop(): replace the summarize call with:
//     let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
//     let body  = notes.isEmpty
//         ? await summarizer.summarize(clean) ?? ""
//         : await fuser.fuse(notes: notes, transcript: clean, participants: participants)
//                 ?? (await summarizer.summarize(clean) ?? "")   // fusion-failed fallback
//     Meeting(… userNotes: notes, summary: body, …)
//     then clear userNotes + remove notesPartialURL.
// recoverPartialIfNeeded(): also read .recording.notes.partial.txt → Meeting.userNotes.
```

The `isStarting`/`cancelStart` window and the two-stream commit logic on the branch are
untouched — fusion only changes the `stop()` tail and adds a parallel partial file.

### Changed: `MeetingsView`

- A new private `NotesPane` view: an eyebrow ("YOUR NOTES"), a `TextEditor` bound to
  `$recorder.userNotes`, placeholder copy, shown **only while `recorder.isRecording`**,
  laid out beside/under the `recordCard`.
- `MeetingRow`: add a `## Notes`-style disclosure (or always-shown block) rendering
  `meeting.userNotes` when present, distinct from the fused summary.
- (Stretch) a suggestions rail in `NotesPane` driven by `recorder.suggestedActionItems`.

### New (stretch): live-suggestion state on `MeetingRecorder`

```swift
@Published private(set) var suggestedActionItems: [String] = []   // heuristic, debounced
```

---

## 6. Data model & persistence

- **What is stored:**
  - `Meeting.userNotes: String` — the user's verbatim notes (new field).
  - `Meeting.summary: String` — now holds the **fused** note when notes exist, else the
    plain transcript summary (no schema change to this field; behavior change only).
- **Where & format:**
  - JSON index: `~/Library/Application Support/Talkie/meetings.json` (`[Meeting]`),
    via `MeetingStore.save()`. The new field rides along; back-compat by
    `decodeIfPresent` (old notes load with `userNotes = ""`).
  - Durable Markdown: `~/Talkie Meetings/yyyy-MM-dd-HHmm-meeting.md` gains a `## Notes`
    section (omitted when empty). The `.md` files remain the durable copy.
  - Crash-safety partial: `~/Talkie Meetings/.recording.notes.partial.txt`, flushed on
    the 1s `tick()` exactly like `.recording.partial.txt`. Removed on clean stop;
    consumed by `recoverPartialIfNeeded()` on next launch.
- **Migration / back-compat:** none required. Old `meetings.json` and old `.md` files
  load unchanged (`userNotes` defaults to `""`, no `## Notes` section means no notes).
  This matches the house style (`_CURRENT_STATE.md §3/§7`): `.atomic` writes,
  failure-tolerant decode, optional fields.
- **Format choice:** stays JSON + plain Markdown — no new dependency, trivially
  inspectable, consistent with every other store. The Markdown placing **Notes first**
  is deliberate: it is what the user actually wrote, and it's what a downstream tool
  (or feature 10's `NoteDestination`) should surface most prominently.

---

## 7. Unification contract (what 02 exposes / consumes)

Per `_UNIFICATION.md §6 / 02`:

**EXPOSES**

- **The fused note as an `ExportableNote`** (`NoteDestination` protocol, §2.3). When
  feature 10 lands, `MeetingRecorder.stop()` composes an `ExportableNote` with
  `bodyMarkdown` = the three sections (Notes + Summary + Transcript already assembled),
  `frontMatter` = duration/participants/source, `kind = .meeting`, and hands it to the
  injected `NoteDestination` instead of calling `MeetingStore.writeMarkdown` directly.
  Until 10 ships, the default `TalkieFolderDestination` behavior **is** today's
  `writeMarkdown` — so this plan writes the three sections there now, and 10 only
  refactors *where the string is handed off*, not how it's built.
- **Live action-item suggestions → candidate `.commitment` entities** for the graph
  (feature 05). The heuristic suggestions (§4.3) and the fused note's "Action items"
  are exactly the structured commitments `ContextGraphExtractor` wants. 02 does not
  build the graph; it produces the text and the candidate list that 05 consumes.
- **The user's notes as a high-signal source.** `Meeting.userNotes` becomes a
  first-class field other features (05 extraction, 19 search) read.

**CONSUMES**

- **`Summarizer` protocol** (§2.2). `NoteFuser` is written to call *through* the
  `Summarizer` seam (`OnDeviceLLM` by default), not to instantiate
  `LanguageModelSession` directly — so the same fusion works with the opt-in
  `ClaudeBridge` (feature 18) for long meetings and so map-reduce (the 8000-char TODO)
  lives above the protocol as a chained helper. *Concretely:* if the `Summarizer`
  protocol exists when 02 is built, `NoteFuser` takes `any Summarizer` in its init and
  calls `generate(instructions:input:)`; if 02 ships before the protocol refactor,
  `NoteFuser` mirrors `MeetingSummarizer` directly and is conformed later (same cheap
  refactor noted in `_UNIFICATION.md §5`).
- **`NoteDestination` protocol** (§2.3) for writing the fused note (see Exposes).
- **The personal context graph (consume side):** the meeting's `participants` (Person
  entities) and any calendar attendees (feature 04) can be passed into the fusion
  prompt as context so the model uses real names instead of "the other person". The
  graph is *consumed* as a snapshot for naming; the *output* (commitments) flows back
  into it. Both notes and transcript become graph **provenance** (`Provenance(.meeting,
  sourceID: meeting.id)`), per `_UNIFICATION.md §6/02` ("notes and transcript both
  become graph provenance").

**Coherence note (the one thing that keeps 02 in the product):** fusion runs *through*
the `Summarizer` protocol and the fused note travels the *same* `NoteDestination` pipe
as the plain meeting note — so the "Granola-magic" note and the plain note are one
pipeline with one export path, not a parallel system.

---

## 8. UI / UX

**Where:** the existing **Meetings** tab (`MeetingsView.swift`), no new tab/HUD.

**Interaction:**

1. User hits **Start recording** → the `recordCard` flips to the recording state
   (branch copy: "Recording you + the call…") **and a `NotesPane` appears below it**.
2. The `NotesPane` is a `TextEditor` bound to `$recorder.userNotes` with an eyebrow
   "YOUR NOTES" and placeholder "Jot quick bullets — Talkie fills in the rest from the
   call." Notes autosave to the partial file every second.
3. (Stretch) a slim suggestions rail: tappable chips of detected action items the user
   can flick into their notes.
4. On **Stop & summarize** → `isFinishing` state ("Transcribing & summarizing…", reuse
   existing copy or refine to "Fusing your notes…") → the new `MeetingRow` shows the
   fused **Summary** plus a **Notes** block (what they typed) plus the collapsible
   **Transcript**.

**On-brand (cite `DesignSystem.swift` + `BRAND.md`):**

- The `NotesPane` sits in a `.talkieCard()` (`DesignSystem.swift:159`) like every other
  surface; section spacing `Theme.Space.section` (`:103`).
- Eyebrow uses `Font.talkieEyebrow` (11pt caps) per `BRAND.md §4`; titles
  `talkieDisplay`/`talkieHeading`; body `inkSecondary`/`inkTertiary`.
- **One accent per view** (`BRAND.md §10`): the single `Theme.coral` (now blue v2)
  already used by the record card's `mic.circle.fill` and the disclosure label — the
  NotesPane must NOT introduce a second accent. Suggestion chips use `surfaceSunken`
  (neutral), not a feather color (feathers are **data only**, `BRAND.md §3.3/§10`).
- Markdown render via `MarkdownText` (already used at `MeetingsView.swift:181`),
  `bulletColor: Theme.coral`.
- **Honest, second-person copy** (`BRAND.md §9`): "Talkie fills in the rest from the
  call" — a calm fact. The note must never claim a fact the transcript can't back; the
  fused output marks unverified bullets rather than asserting them (§4.2). No invented
  metrics, no "AI magic" billboard.
- Calm spring on the NotesPane appear/disappear (`response 0.28, damping 0.8`,
  `BRAND.md §8`).

---

## 9. Permissions / entitlements / Info.plist

**None new.** Notes are typed text inside the app — no TCC prompt, no entitlement, no
plist key. The recording side's permissions are unchanged (mic on main; mic +
`NSAudioCaptureUsageDescription` on the branch). Sandbox impact: none — writing to
`~/Talkie Meetings/` and `~/Library/Application Support/Talkie/` already works and is
unaffected. This feature does not move the privacy posture at all.

---

## 10. Privacy posture

**Zero-network preserved.** Fusion is one more on-device Foundation-Models call
(`CleanupEngine`/`MeetingSummarizer` pattern) — no `URLSession`, no key, no cost. The
verified invariant (`_CURRENT_STATE.md §0`: no network code anywhere, single
audio-input entitlement) holds unchanged.

The user's notes are the most personal text in the app, so the privacy story is
*strengthened*, not weakened: they are written only to the local `~/Talkie Meetings/`
folder and the local JSON index, and fed only to the on-device model. **No data leaves
the device.** The only future path that could send notes off-device is feature 18's
opt-in `ClaudeBridge` for long-meeting map-reduce — and that is OFF by default, behind
the network wall (`_UNIFICATION.md §4.1`), discloses exactly what is sent, and is
reached only through the `Summarizer` protocol seam (so the default build literally
cannot send notes anywhere).

---

## 11. Open-source genericity

- **No hardcoded personal stack.** Notes are plain Markdown in a plain folder; nothing
  here references Obsidian, a vault, or any third-party app. The zero-config default is
  the existing `~/Talkie Meetings/` writer (`AppPaths.meetingsDirectory()` —
  deliberately not `~/Documents`).
- **Community extension point.** The fused note is composed as `bodyMarkdown` and (once
  feature 10 lands) handed to a `NoteDestination`; the community can ship Obsidian /
  Logseq / Notion destinations that turn the `## Notes` section and the meeting's entity
  `links` into wikilinks/front-matter **without touching core**. The optional
  wikilink/front-matter flags stay off by default (the invariant).
- **Graceful on the widened-hardware path.** When Foundation Models is unavailable
  (Apple Intelligence off, or a future non-AI-Silicon OSS build, feature 20), fusion
  degrades to "store the notes verbatim, skip the fuse" — the user still gets their
  notes + raw transcript in Markdown. The feature never *requires* the model to be
  useful (see §12).

---

## 12. Risks, edge cases, failure modes (and graceful degradation)

| Risk / edge case | Behavior |
|---|---|
| **No notes typed** | Skip fusion; fall back to today's `MeetingSummarizer.summarize`. Identical to current behavior. |
| **Notes but model unavailable** (`CleanupEngine.isAvailable == false`) | Store notes verbatim, no fused summary, raw transcript still saved. UI shows the Notes + Transcript; Summary section reads `_(no summary)_`. Never blocks the save. |
| **Fusion call throws / returns nil** | Fall back to `MeetingSummarizer.summarize` (transcript-only), so the user always gets *a* summary plus their verbatim notes. |
| **Model invents facts** | Mitigated by the strict "notes-are-spine / never-invent / mark-unverified" prompt + greedy low-temp determinism; further guarded because the verbatim **Notes** and raw **Transcript** are both preserved, so the user can always audit the fused **Summary** against the source. |
| **Crash mid-recording** | `.recording.notes.partial.txt` is flushed every 1s; `recoverPartialIfNeeded()` rebuilds the Meeting with the recovered notes (no fusion — recovery has no transcript pairing guarantee). |
| **Very long meeting** (>8k transcript) | MVP truncates like `MeetingSummarizer` does today (`Meeting.swift:36`). Full fix = map-reduce above the `Summarizer` protocol (chained `generate` calls) — explicitly deferred, same TODO the codebase already carries. The **notes** are never truncated (they're the spine and are short). |
| **Empty transcript, only notes** | Fuse with empty transcript = just clean/structure the user's bullets (still useful). Or, if both empty, save nothing (existing `clean.isEmpty` guard). |
| **Notes typed after stop is tapped** | `userNotes` is captured at the top of `stop()`; the TextEditor is dismissed when `isRecording` flips false, so no lost-keystroke race. |
| **Mic-only main (no Me/Them labels)** | Fusion still works; the prompt's attribution clause is a no-op when there are no labels. The feature is strictly better on the branch but correct on main. |
| **Concurrent model use** | Live suggestions are heuristic-only (no LLM during recording); the single fusion call runs at stop, after the recognizer is finished — no ANE contention, honoring model exclusivity (`_UNIFICATION.md §4.4`). |

---

## 13. Testing & verification

There is no test target today (`_CURRENT_STATE.md §8`), so verification is mostly the
`/run` path plus a few pure-function unit tests if a test target is added.

**Pure unit tests (Sendable, model-free):**
- `MeetingStore.writeMarkdown` emits `## Notes` when `userNotes` non-empty, omits it
  when empty, and keeps Notes-before-Summary-before-Transcript order.
- `Meeting` round-trips through Codable with and without `userNotes` (back-compat: a
  pre-02 JSON decodes with `userNotes == ""`).
- The fusion *prompt assembly* (input capping at notes ~2k / transcript ~8k) is a pure
  function and can be asserted without the model.

**Manual / `/run` verification:**
1. Build & launch (`scripts/run.sh` installs the canonical copy so TCC persists).
2. Start recording, type 3 sparse bullets, speak a few sentences (ideally a Zoom/Meet
   call on the branch so Me/Them labels appear), stop.
3. Confirm: the new `MeetingRow` shows the fused Summary, the verbatim Notes block, and
   the collapsible raw Transcript; open the `.md` in `~/Talkie Meetings/` and confirm
   the three sections + frontmatter.
4. Verify fusion fidelity: every typed bullet survives into the Summary; the Summary
   adds only transcript-supported detail; nothing is fabricated.
5. Degradation: turn off Apple Intelligence → record with notes → confirm notes saved
   verbatim, Summary `_(no summary)_`, app doesn't hang.
6. Crash safety: force-quit mid-recording → relaunch → confirm the recovered Meeting
   carries the notes from `.recording.notes.partial.txt`.

**Honest-output check (brand invariant):** spot-check that the fused note never asserts
an action item or decision absent from the transcript when notes alone didn't state it
(the "never invent" guardrail).

---

## 14. Effort & phasing

| Sub-step | Size | Notes |
|---|---|---|
| `Meeting.userNotes` field + Codable back-compat | **S** | One field + one `decodeIfPresent` line. |
| `MeetingStore.writeMarkdown` → `## Notes` section | **S** | String assembly; ordering. |
| `NotesPane` view + `@Published userNotes` binding | **S/M** | `TextEditor`, eyebrow, placeholder, show-while-recording. |
| Notes partial-file flush + recovery | **S** | Mirror the existing transcript-partial logic. |
| `NoteFuser` actor + fusion prompt | **M** | The real design work is the prompt; the plumbing mirrors `MeetingSummarizer`. |
| Wire fusion into `MeetingRecorder.stop()` w/ fallbacks | **S/M** | Replace the summarize line; add the empty-notes / failure fallbacks. |
| `MeetingRow` shows Notes block | **S** | One `MarkdownText`/disclosure. |
| **— MVP slice ends here —** | | Notes pane + persist + fuse + 3-section render + fallbacks. |
| Live heuristic action-item suggestions rail | **M** | Stretch; regex cues + debounced `@Published`. |
| `Summarizer` / `NoteDestination` protocol conformance | **M** | Lands with features 05/10; cheap if done early (see §7). |
| Long-meeting map-reduce above `Summarizer` | **M/L** | Deferred; shared with the existing summarizer TODO. |

**MVP (ship-worthy on its own):** the rows down to "MVP slice ends here" — sparse notes
typed live, fused with the transcript at stop into a three-section Markdown note, with
clean fallbacks when there are no notes or no model. This alone is the Granola feature.

---

## 15. Dependencies & interactions

- **Needs (soft):** **01 far-end → main** — fusion is meaningfully better with
  `Me/Them` labels (action-item attribution); 02 is correct without it but should land
  after 01 per the `_UNIFICATION.md` Tier 0→1 order. **`Summarizer` protocol** — 02
  calls through it; if absent, `NoteFuser` mirrors `MeetingSummarizer` and is conformed
  later (cheap). **`NoteDestination` protocol (feature 10)** — for the export seam; 02
  writes the three sections directly until 10 refactors the hand-off.
- **Enables / feeds:** **05 Context Graph** — the user's notes + the fused action items
  are the richest commitment/entity source, with `Provenance(.meeting)`. **19 Search** —
  `userNotes` becomes a high-signal searchable field. **10 Export** — the fused
  `ExportableNote` is exactly what 10's destinations consume.
- **Overlaps with:** **MeetingSummarizer** (02 adds a sibling, keeps the summarizer as
  the no-notes fallback — they are not redundant). **18 Claude bridge** — the opt-in
  heavy-lift path for long-meeting fusion map-reduce, reached only through the
  `Summarizer` protocol, off by default.
- **Does not touch:** the dictation pipeline, hotkey, audio capture, or any
  entitlement/network surface.
