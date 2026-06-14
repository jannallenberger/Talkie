# 04 — Calendar awareness (EventKit, on-device)

> Per-feature plan. Built against `_CURRENT_STATE.md` (ground truth) and
> `_UNIFICATION.md` (the spine). Floor: macOS 26, Apple Silicon, Swift 6 `.v6`.
> All paths absolute. `file:line` anchors are `main` HEAD unless marked **[branch]**
> (= `feat/meeting-far-audio`), read via `git show feat/meeting-far-audio:<path>`.

## 1. Summary

Use EventKit (local, read-only) to make a meeting recording *smart*: title the note
from the calendar event the recording overlaps, extract attendee names, and pre-load
those names into the recognizer's `contextualStrings` on **both** the mic ("Me") and
far-end ("Them") engines so names are spelled right from the first word — and feed the
same names into the personal context graph (feature 05) as `Person` entities with
`Provenance(.calendar)`.

## 2. Why it matters

Granola's headline trick is that your meeting note shows up already titled and
attributed ("Sync with Sarah Chen — design review") instead of `meeting-1437.md`.
Today Talkie titles every note `Meeting · Jun 14, 2026 at 2:37 PM`
(`MeetingRecorder.makeTitle`, **[branch]**) and never knows who is in the room. This
feature closes that gap with zero cloud — Granola reads your calendar through a Google
OAuth scope on their servers; Talkie reads it through EventKit, on-device, read-only.

Strategically it is a small feature with outsized leverage on the thesis:

- **Accuracy where it's most visible.** Names are the words a transcriber gets wrong
  most often and the words a reader most wants right. Biasing the recognizer with the
  actual attendee list ("Aoife", "Nguyen", "Praveen", "Coralate") fixes them *before*
  cleanup, on both speaker streams.
- **It is a tributary to the one brain.** Attendees become `Person` entities. The
  *next* meeting with the same people, the daily Brief, recall ("who is Aoife?"), and
  the cross-surface demo ("email the team the action items") all get richer because the
  calendar fed the graph once. Neither Wispr nor Granola can do this — they are
  separate cloud products with no shared local graph.
- **It is provably private** (EventKit is local; nothing leaves the Mac), which is the
  brand's whole pitch.

## 3. Current state in the code

**Nothing calendar-related exists.** `grep -rn "EventKit|EKEventStore"
Sources/` returns nothing. EventKit is not imported, not entitled, not prompted.

What exists and what this feature plugs into:

- **Meeting capture (the consumer).** `MeetingRecorder` **[branch]** (rewired in
  `feat/meeting-far-audio`) runs two streams: mic → shared `engine` tagged `.me`;
  far-end → a per-recording `farEngine` tagged `.them`. Crucially, **both engines are
  currently primed with an EMPTY bias set**: `await engine.setContextualStrings([])`
  before the mic `beginSession`, and `await far.setContextualStrings([])` before the
  far `beginSession`. These are the two exact call sites this feature fills.
- **Note titling.** `MeetingRecorder.makeTitle(start:)` **[branch]** returns the
  timestamp-only string used for `Meeting.title`. `participants` is set from *capture
  state* (`["Me","Them"]` / `["Me"]`), not from real names.
- **The `Meeting` model.** `Meeting` **[branch]** already carries
  `participants: [String]` and `source: String` with a back-compat `init(from:)`
  (`decodeIfPresent`). `writeMarkdown` emits `participants: [...]` into YAML
  frontmatter. We extend, not invent.
- **Contextual-string plumbing (the mechanism).** `TranscriptionEngine`
  (`/Users/jann/Talkie/Sources/Talkie/TranscriptionEngine.swift`) stores
  `contextualStrings` (`:46`), exposes `setContextualStrings(_:)` (`:76-78`), and
  applies them per session through `AnalysisContext().contextualStrings = [.general:
  …]` in `beginSession` (`:236-240`). This is the same mechanism dictation already
  uses; meetings just pass `[]` today.
- **The dictation bias precedent.** `AppDelegate.beginDictation` builds the dictation
  bias union (custom vocab ∪ mined names ∪ project filenames, deduped, capped 180) at
  `/Users/jann/Talkie/Sources/Talkie/AppDelegate.swift:344-347`. Calendar names should
  flow through the *same* shape — and, post-05, through `graph.biasPhrases`.
- **Name extraction helper to reuse.** `PhraseMiner.mine`
  (`/Users/jann/Talkie/Sources/Talkie/AppContext.swift:99-151`) already extracts
  proper nouns; we reuse its philosophy (and the graph reuses it per `_UNIFICATION.md`
  §1.5) but attendee names come *structured* from EventKit, so we mostly just need to
  split display names into spell-worthy tokens.
- **Permissions surface.** `PermissionsModel`
  (`/Users/jann/Talkie/Sources/Talkie/Permissions.swift`) reflects/requests the three
  TCC permissions with System-Settings deeplinks. Calendar is a *new, optional* TCC
  domain — it does **not** belong in the required three (`allGranted` must not start
  gating on it), but it gets a parallel opt-in surface.
- **Store/DI convention.** Stores are created in `AppDelegate` (`:6-15`) and threaded
  through `MainWindowController` → `MainView` → the per-tab views
  (`/Users/jann/Talkie/Sources/Talkie/SettingsView.swift:60-167`).

Honest status: **fully greenfield.** The only thing already done is the *receiving
sockets* — the two `setContextualStrings` call sites **[branch]**, the
`participants`/`title`/`source` fields **[branch]**, and the `NSAudioCapture` plist key
**[branch]**. This plan assumes feature 01 (the far-end branch) is rebased to `main`
first, per `_UNIFICATION.md` §5 Tier 0.

## 4. Design & approach

**Framework:** `EventKit` (`EKEventStore`, `EKEvent`, `EKParticipant`,
`EKAuthorizationStatus`). macOS 14+ for the API; macOS 26 floor is fine. Read-only:
we never create/modify/delete events.

### 4.1 Authorization model (macOS 14+ / Sequoia+ semantics)

EventKit on modern macOS distinguishes:

- `EKAuthorizationStatus`: `.notDetermined`, `.restricted`, `.denied`, `.fullAccess`,
  `.writeOnly`.
- Request API: `EKEventStore().requestFullAccessToEvents()` (async throwing) — we need
  **read** of events + attendees, which requires **full access** (there is no
  "read-only events" tier; `.writeOnly` is calendar-write-only and useless to us).

We request **full access** but use it strictly read-only; the Info.plist string says
exactly that, and the privacy panel (feature 15) lists EventKit as read-only. We never
call any write API, so the "full" grant is benign.

### 4.2 The matching algorithm — recording ↔ event

When a recording starts (or stops — see trade-off below), find the calendar event
whose time window best contains the recording start.

```
input: now = recording start instant
window = events in [now - 90 min, now + 90 min] across all calendars the user enabled
candidates = events where:
    not all-day
    has a real title (non-empty)
    status != .canceled
    overlaps the recording: event.startDate - graceBefore <= now <= event.endDate + graceAfter
        graceBefore = 5 min   (you hit record a few minutes early)
        graceAfter  = 10 min  (you joined late / it ran over)
pick = candidate minimizing |now - event.startDate|; tie-break by shortest duration
       (a 30-min standup beats an all-day "Focus" block that slipped through)
result = MeetingEventContext(title, attendeeNames, eventID) OR nil
```

- `EKEventStore.predicateForEvents(withStart:end:calendars:)` + `events(matching:)`
  fetches the window cheaply.
- "Now" is the **recording start**, captured in `MeetingRecorder.start()`.
- **No event found → graceful fallback** to the existing timestamp title and
  capture-derived participants (Phase-1 behavior, unchanged). The feature is purely
  additive: it can only *improve* a note, never break one.

**Decision — match at START, snapshot, reconcile at STOP.** We resolve the event at
`start()` so names can be biased into the recognizers *before* the first word (the
whole point — biasing post-hoc is useless). We re-resolve once at `stop()` and prefer
the longer-overlapping event if the recording drifted past one event into the next
(back-to-back calls). The start-time match is what feeds bias; the stop-time match only
refines the title/attendees written to disk.

### 4.3 Attendee → name → token flow

```
EKEvent.attendees: [EKParticipant]?
  → name = participant.name (a display name like "Sarah Chen"); skip nil/empty
  → also include event.organizer.name
  → drop the current user (participant.isCurrentUser == true) — that's "Me"
  → dedupe, cap (≤ 25 attendees; large invites get truncated, logged)
displayNames: ["Sarah Chen", "Aoife Ní Bhraonáin", "Praveen Kumar"]

biasTokens = for each name:
    the full name  ("Sarah Chen")
    each whitespace-split part length ≥ 2 that contains a letter ("Sarah", "Chen")
  → this lets the recognizer lock onto first OR last name in fast speech
  → dedupe; merged with the meeting's other bias (vocab/graph) at the call site
```

Tokenizing on top of the full name matters: people say "Sarah said…" far more than
"Sarah Chen said…", and the recognizer biases per-phrase.

### 4.4 Flow at record time (with feature 01's two engines)

```
MeetingRecorder.start():
  start = Date()
  ctx = await calendar.eventContext(at: start)        // nil if no event / no permission
  bias = (graph.biasPhrases(...) ?? dictionary vocab)  // existing meeting bias source
        ∪ ctx.biasTokens                               // NEW
        capped at 180 (the existing cap)

  // mic engine ("Me")
  await engine.setContextualStrings(bias)               // was: setContextualStrings([])
  engine.beginSession(...)

  // far engine ("Them")  — names matter MOST here (other people talking)
  await far.setContextualStrings(bias)                  // was: setContextualStrings([])
  far.beginSession(...)

  // remember ctx for stop() so the title/participants/provenance use it
  self.pendingEventContext = ctx

MeetingRecorder.stop():
  ctx = self.pendingEventContext, optionally refined by eventContext(at: stop)
  title = ctx?.title ?? makeTitle(start:)                // smart title, else timestamp
  realNames = ctx?.attendeeNames ?? []
  // participants = capture-derived ["Me","Them"]/["Me"] UNION real names (deduped),
  // keeping "Me"/"Them" as the speaker labels the transcript actually uses.
  meeting = Meeting(..., title:, participants:, source: source + (ctx != nil ? "; calendar" : ""))
  store.add(meeting)
  → enqueue graph extraction: ctx.attendeeNames → Person entities w/ Provenance(.calendar)
```

### 4.5 Why a protocol, not inline EventKit

Per `_UNIFICATION.md` §2.5, calendar is one implementation of
`MeetingContextProvider`. Feature 03 (auto-detect) implements `detectActiveMeeting()`;
feature 04 implements `eventContext(at:)`. `MeetingRecorder` consumes the *protocol*,
so it doesn't care whether names came from the calendar, a future allowlist, or a
stub. This keeps `MeetingRecorder` from growing an EventKit dependency and lets feature
15's sandboxed-default build inject a no-op provider if calendar is compiled out.

## 5. New & changed files/types

### New: `/Users/jann/Talkie/Sources/Talkie/Protocols/MeetingContextProvider.swift`

The shared protocol from `_UNIFICATION.md` §2.5 (04 + 03 co-own it; 04 lands the file
since it's Tier 1 and 03 is later). Verbatim shape from the spine:

```swift
protocol MeetingContextProvider: Sendable {
    /// Auto-detect: is a meeting likely in progress now? (feature 03 implements; 04 returns nil.)
    func detectActiveMeeting() async -> MeetingSignal?
    /// Naming/attendees from the calendar for a given instant. (feature 04 implements.)
    func eventContext(at date: Date) async -> MeetingEventContext?
}

struct MeetingSignal: Sendable {
    var confidence: Double
    var appBundleID: String?
    var startedAtUnix: Double
}

struct MeetingEventContext: Sendable {
    var title: String?              // → meeting note title
    var attendeeNames: [String]    // → Person entities (05) AND recognizer bias (04)
    var eventID: String?           // → Provenance(.calendar)

    /// Spell-worthy tokens (full names + name parts) for setContextualStrings.
    var biasTokens: [String] {
        var seen = Set<String>(); var out: [String] = []
        for name in attendeeNames {
            for tok in ([name] + name.split(whereSeparator: \.isWhitespace).map(String.init))
            where tok.count >= 2 && tok.contains(where: \.isLetter) {
                if seen.insert(tok.lowercased()).inserted { out.append(tok) }
            }
        }
        return out
    }
}
```

### New: `/Users/jann/Talkie/Sources/Talkie/Meetings/CalendarContextProvider.swift`

The EventKit implementation. An `actor` (owns an `EKEventStore`, matches the
engine/extractor convention; EventKit objects are not `Sendable`, so confining them to
one actor keeps Swift 6 happy and never crosses `EKEvent` between actors — we extract
plain `String`s before returning).

```swift
import EventKit

actor CalendarContextProvider: MeetingContextProvider {
    private let store = EKEventStore()
    private let lookBack: TimeInterval  = 90 * 60
    private let lookAhead: TimeInterval = 90 * 60

    /// Reflects EKEventStore.authorizationStatus(for: .event). Read-only.
    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Request full access (used read-only). Returns granted.
    @discardableResult
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func detectActiveMeeting() async -> MeetingSignal? { nil }   // feature 03 owns this

    func eventContext(at date: Date) async -> MeetingEventContext? {
        guard Self.authorizationStatus == .fullAccess else { return nil }
        let cals = enabledEventCalendars()                       // see §11 (settings)
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-lookBack),
            end: date.addingTimeInterval(lookAhead),
            calendars: cals.isEmpty ? nil : cals)
        let events = store.events(matching: predicate)
        guard let event = bestMatch(events, around: date) else { return nil }
        let names = attendeeNames(of: event)
        return MeetingEventContext(
            title: event.title?.trimmingCharacters(in: .whitespaces),
            attendeeNames: names,
            eventID: event.eventIdentifier)
    }

    // bestMatch(_:around:)  → the §4.2 scoring (overlap + grace, nearest start, shortest)
    // attendeeNames(of:)    → §4.3 (organizer + attendees, drop isCurrentUser, cap 25)
    // enabledEventCalendars → maps the user's calendar-id allowlist setting to [EKCalendar]
}
```

### Changed: `MeetingRecorder.swift` **[branch]**

- Add `var meetingContext: MeetingContextProvider?` (injected by `AppDelegate`,
  optional so a build without calendar still compiles/runs).
- Add `var meetingBias: (() -> [String])?` injected by `AppDelegate` — returns the
  non-calendar meeting bias (post-05: `graph.biasPhrases(limit:180)`; pre-05: the
  dictionary vocab snapshot). Keeps `MeetingRecorder` out of the store-union business.
- Add private `pendingEventContext: MeetingEventContext?` (set in `start()`, read in
  `stop()`, cleared on both teardown paths alongside `turnLog`/`startedAt`).
- In `start()`: after computing `start`, `let ctx = await meetingContext?.eventContext(
  at: start)` (re-check `cancelStart` after this `await`, per the existing
  generation-token pattern); build the merged bias and pass it to **both**
  `engine.setContextualStrings(_)` and `far.setContextualStrings(_)` (replacing the two
  `[]` calls); stash `pendingEventContext = ctx`.
- In `stop()`: compute `title`/`participants`/`source` from `pendingEventContext`
  (optionally refined by a stop-time `eventContext`), pass them into the `Meeting`
  initializer.
- Expose what 05 needs: include `eventContext` (names + eventID) on the meeting-added
  notification or via a small `lastMeetingEventContext` the extractor reads (see §7).

### Changed: `AppDelegate.swift`

- `let calendar = CalendarContextProvider()` alongside the other engines.
- `meetingRecorder.meetingContext = calendar`;
  `meetingRecorder.meetingBias = { [weak self] in self?.graph.biasPhrases(limit: 180)
  ?? self?.dictionary.contextualPhrasesSnapshot() ?? [] }` (graph fallback to dictionary
  until 05 lands; pre-05 just use the dictionary snapshot).
- Pass `calendar` (its auth state) into `MainWindowController`/`MainView` so the
  Permissions pane and a Meetings-tab hint can show/request calendar access.

### Changed: `Permissions.swift`

Add **optional** calendar reflection — kept separate from the required three so
`allGranted` is unaffected:

```swift
@Published var calendar: EKAuthorizationStatus = .notDetermined
func refreshCalendar() { calendar = EKEventStore.authorizationStatus(for: .event) }
// request goes through CalendarContextProvider.requestAccess() (owns the store)
func openCalendarSettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
}
```

### Changed: `Resources/Info.plist`

Add `NSCalendarsFullAccessUsageDescription` (see §9).

### Changed: `MeetingsView.swift` **[branch]** (small)

A one-line opt-in row in the record card area: *"Connect your calendar so meetings get
named and attendees spelled right — read-only, stays on your Mac."* with an "Enable
calendar" button when status is `.notDetermined`/`.denied`. Hidden when `.fullAccess`.

## 6. Data model & persistence

**No new store.** Calendar data is *transient context*, not a persisted store — it is
read live at record time and projected into existing durable artifacts:

- **The meeting note** (`~/Talkie Meetings/<file>.md`, the durable copy): title becomes
  the event title; YAML `participants:` becomes the union of speaker labels + real
  attendee names; `source:` appends `"; calendar"` when an event matched. All three
  fields already exist on `Meeting` **[branch]** with back-compat `decodeIfPresent`, so
  **no migration is needed** — old notes simply lack the calendar-derived richness.
- **The graph** (feature 05, `~/Library/Application Support/Talkie/graph/entities.json`):
  attendee names become `Person` entities with `Provenance(.calendar)` (source
  `calendar`, `sourceID` = `eventID`, `snippet` = event title). This is the one *new*
  persistence, and it is owned by 05's store/extractor, not by this feature.

One setting is persisted (UserDefaults, matching `AppSettings`): an optional
**enabled-calendars allowlist** (`[String]` of `EKCalendar.calendarIdentifier`) so a
user can exclude a noisy shared/holiday calendar. Empty/absent = all calendars
(zero-config default). Back-compat: absent key → all calendars.

## 7. Unification contract (per `_UNIFICATION.md` §2.5, §6/04)

**EXPOSES**

- `MeetingContextProvider.eventContext(at:) -> MeetingEventContext?` — the spine's
  exact protocol/shape (§2.5). `title` + `attendeeNames` + `eventID`. Consumed by 01
  (`MeetingRecorder` titling + dual-engine bias), 02 (notes fusion can show attendees),
  05 (Person entities + provenance).
- `MeetingEventContext.attendeeNames` as the canonical attendee list → feature 05
  ingests these as `Person` entities, each with `Provenance(source: .calendar, sourceID:
  eventID, unix: meetingStart, snippet: eventTitle)`. This is the contract's "attendees
  as Person entities with `Provenance(.calendar)`."
- The recognizer-bias tokens (`biasTokens`) folded into the meeting bias on **both**
  transcription backends — satisfying "feeds `attendeeNames` into BOTH transcription
  backends' `setContextualStrings` (mic + far-end)."

**CONSUMES**

- **The Graph (write).** Attendee names → `Person` entities. We do **not** write the
  graph JSON directly (the spine forbids consumers reading/writing graph files); we hand
  `MeetingEventContext` to the graph extractor's meeting-extraction trigger
  (`_UNIFICATION.md` §1.5 trigger (b): after `MeetingRecorder.stop()` adds a `Meeting`).
  Concretely: `MeetingRecorder.stop()` already enqueues graph extraction for the new
  meeting; we attach the `eventContext` to that enqueue so the extractor reads attendees
  from structured calendar data (high confidence, `pinned`-adjacent) rather than mining
  them from prose.
- **The Graph (read), post-05.** Meeting bias comes from `graph.biasPhrases(limit:180)`
  — we add calendar tokens to that set, not a parallel union. Pre-05 fallback:
  `dictionary.contextualPhrasesSnapshot()` (`DictionaryStore`).
- **Both transcription backends.** Via `MeetingRecorder`'s `setContextualStrings` on
  `engine` and `farEngine`. After 01 conforms to `TranscriptionBackend` (§2.1), this is
  `backend.setContextualStrings(_)` on each; the call site is identical.
- **`MeetingRecorder`** (01) — consumes `eventContext` to title the note instead of
  `makeTitle(start:)`'s timestamp.

**NOTE (the coherence rule, verbatim from §6/04):** *on-device, read-only. No event →
graceful fallback to timestamp title.* Honored exactly: `eventContext` returns nil when
there's no permission or no matching event, and every consumer treats nil as "use the
existing behavior."

**Sequencing:** depends on **01 merged** (the dual-engine `setContextualStrings` call
sites and the `participants`/`title` fields live there) and benefits from **05** (graph
bias + Person entities). It can ship a **useful slice before 05** (smart titles +
dual-engine bias + richer `participants`) and wire the graph in when 05 lands — the
`MeetingEventContext` shape doesn't change.

## 8. UI / UX

Two small surfaces, both on-brand (`DesignSystem.swift` v2 tokens; `BRAND.md`
philosophy — warm, honest, one accent, calm).

1. **Meetings tab opt-in row** (`MeetingsView.swift` **[branch]**). When calendar
   status is not `.fullAccess`, show a single quiet row under the record card:
   `Image(systemName: "calendar")` (tinted `Theme.coral` — the one accent), copy
   *"Name meetings & spell attendees right — connect your calendar. Read-only, stays on
   your Mac."*, and a `Button("Enable")`. Tapping calls
   `calendar.requestAccess()` then `permissions.refreshCalendar()`. When `.fullAccess`,
   the row disappears (no nagging). Honest copy, second person, no invented benefit —
   exactly the brand voice. Reuse `.talkieCard()`/`Theme.inkSecondary`/`Theme.coral`;
   invent no new component.

2. **Permissions pane** (`SettingsView.swift` `PermissionsSettings`). Add calendar as a
   **fourth, clearly-optional** row beneath the required three, visually subordinate
   (an "Optional" eyebrow via the existing `Eyebrow`), with a `Re-check` and an
   open-Settings deeplink (`openCalendarSettings`). It must **not** join the
   `allGranted` gate or the red sidebar badge — calendar being off is a valid, fully
   functional state.

3. **The payoff is in the saved note**, not a new screen: the meeting row title in
   `MeetingsView` shows the real event title, and the `.md` frontmatter lists real
   attendees — visible immediately, no extra UI. Optionally a small
   `Image(systemName: "calendar")` glyph next to a calendar-titled meeting row
   (subordinate tint) so the user sees *why* it's named that.

No HUD changes (the dictation HUD is untouched; calendar bias only affects meetings).

## 9. Permissions / entitlements / Info.plist

- **New Info.plist key:** `NSCalendarsFullAccessUsageDescription` — e.g.
  *"Talkie reads your calendar (read-only, on your Mac) to title meeting notes and spell
  attendee names correctly. Talkie never edits your calendar and nothing leaves your
  Mac."* Required or the request crashes/silently fails on macOS 14+. (Add the legacy
  `NSCalendarsUsageDescription` too for belt-and-suspenders on the access prompt.)
- **New TCC prompt:** Calendar (Full Access). First triggered by the explicit "Enable"
  button — **never** at launch (no surprise prompts; matches the brand's calm,
  opt-in posture and the privacy invariant's "deliberate user action").
- **Entitlements:** the **default (non-sandboxed) build needs no new entitlement** —
  EventKit works under Hardened Runtime with the usage string. **If/when feature 15
  ships the App-Sandbox build**, EventKit requires
  `com.apple.security.personal-information.calendars` in `talkie.entitlements`. Feature
  15 owns the sandboxed flavor; this feature documents the requirement so 15 includes
  it. (Flag for 15 to validate EventKit under the sandbox, per its contract.)
- **No network entitlement.** EventKit is local IPC to `calaccessd`; it does not touch
  the network. The zero-network invariant is preserved.

## 10. Privacy posture

**Zero-network preserved.** EventKit is an on-device framework (local XPC to the
calendar daemon); it adds no `URLSession`, no host, no outbound connection. The verified
"no network code, single audio-input entitlement" fact stays true for the default build.

What is read and when, stated plainly (the honest-disclosure the brand promises):

- **Read:** event titles, start/end times, attendee/organizer *display names*, and
  calendar identifiers — **only** within a ±90-minute window around a recording start,
  and **only** while a recording is happening (and on an explicit "Enable" tap). No
  background polling, no full-calendar scrape, no event bodies/notes/locations beyond
  the title. Read-only: no write API is ever called.
- **Stored:** the matched event's title and attendee names land in the meeting `.md`
  (which already lives in `~/Talkie Meetings/` by design) and as `Person` entities +
  `Provenance(.calendar)` in the local graph. Both are user-inspectable plain
  files/JSON — the provenance chain (`_UNIFICATION.md` §1.3) lets the user see exactly
  which event a name came from.
- **Leaves the Mac:** nothing. The only path off-device for any of this would be the
  opt-in Claude bridge (18) / connector (07) behind feature 15's wall, with per-call
  consent — and provenance makes the calendar-sourced data auditable before any such
  export.

The Info.plist string and the privacy panel (15) both state "read-only" explicitly.

## 11. Open-source genericity

- **No hardcoded personal stack.** EventKit is the OS calendar database — it surfaces
  *whatever* the user has (iCloud, Google via macOS Internet Accounts, Exchange, local
  `.ics`) with zero per-provider code. No Google API, no Granola-style OAuth, no
  account assumptions.
- **Zero-config default:** all calendars, ±90-min window, 5/10-min grace. Works the
  instant access is granted, no setup.
- **Pluggable / extendable:** calendar is one `MeetingContextProvider`. The community
  can add other providers (e.g. an `.ics`-file provider, a meeting-app deep-link
  provider) behind the same protocol without touching `MeetingRecorder`. The
  enabled-calendars allowlist is the one user-facing knob, and it's optional.
- **Degrades, never breaks:** if EventKit is denied/unavailable (or compiled out in a
  hypothetical minimal build), `eventContext` returns nil and meetings behave exactly as
  Phase-1 — preserving the "widen, don't break" principle (`_UNIFICATION.md` §4.2).

## 12. Risks, edge cases, failure modes

| Case | Behavior |
|---|---|
| No calendar permission | `eventContext` → nil; timestamp title, capture-derived participants. Opt-in row shown. |
| Permission granted, no event near now | nil; same graceful fallback. (Most ad-hoc calls.) |
| Back-to-back meetings (recording spans two events) | Start-time match biases names of event A; stop-time re-match prefers the longer-overlapping event for the *title*. Document as best-effort. |
| All-day "Focus"/"OOO"/holiday event overlaps | Excluded (`isAllDay` filter + shortest-duration tie-break) so a 24h block can't shadow the real 30-min call. |
| Recurring event | EventKit returns the concrete occurrence in the window; `eventIdentifier` may be shared across occurrences — provenance also stamps the meeting start `unix`, so occurrences stay distinguishable in the graph. |
| Huge invite (200 attendees) | Cap at 25 names (logged); biasing 200 names would blow the 180 cap and dilute. Title still correct. |
| Attendee has no display name (email only) | Skip (no spell-worthy token). Don't bias raw emails. |
| `isCurrentUser` attendee | Dropped — that's "Me", already labeled. |
| Declined/canceled event | `status == .canceled` filtered out. (Optionally also skip events the user declined.) |
| Two engines (01) — bias both | Same merged set to mic + far; far-end is where names matter most. If far-end fell back to mic-only, mic still gets the names. |
| `cancelStart` during the `eventContext` await | Re-check `cancelStart`/generation token after the await (existing `MeetingRecorder` pattern) and abort cleanly. |
| EventKit returns events off the main actor | `CalendarContextProvider` is an `actor`; `EKEvent` never crosses out — we extract `String`s inside the actor and return a `Sendable` `MeetingEventContext`. |
| Permission revoked mid-app | `authorizationStatus` re-checked on every `eventContext` call; nil on revoke. |

**Graceful-degradation principle:** every failure mode collapses to *exactly* today's
Phase-1/Phase-2 behavior. Calendar can only add value.

## 13. Testing & verification

No test target exists today (`_CURRENT_STATE.md` §8). Add the first unit tests for the
**pure, EventKit-free** logic, plus manual verification for the framework-bound parts.

- **Unit (pure, no EventKit):** factor `bestMatch(events:around:)` scoring and
  `MeetingEventContext.biasTokens` over a plain `Sendable` value (`struct CandidateEvent
  { title; start; end; isAllDay; durationSec }`) so they're testable without
  `EKEventStore`. Cases: overlap+grace boundaries (4/6/11 min early/late), all-day
  exclusion, shortest-duration tie-break, back-to-back nearest-start pick, empty window
  → nil. `biasTokens`: "Sarah Chen" → {"Sarah Chen","Sarah","Chen"}; diacritics
  ("Aoife Ní Bhraonáin") preserved; email-only attendee dropped; dedupe.
- **Manual (`/run` path):** add a real event to Calendar.app (`now`, titled "Design
  review", attendees Sarah Chen + Praveen Kumar) → start a meeting recording → confirm:
  (1) TCC prompt only on the explicit Enable tap, (2) the saved `.md` title = "Design
  review", (3) frontmatter `participants:` includes the real names, (4) the recognizer
  spells "Praveen" right in the first far-end turn (read a script containing it).
  Negative: remove the event → record → title falls back to the timestamp, no names.
- **Privacy verification (`/verify`):** `grep -rniE "URLSession|http://|https://"
  Sources/` still returns nothing after this feature lands. Confirm `talkie.entitlements`
  is unchanged in the default build (no new entitlement) and only the plist usage string
  was added.
- **Build:** `scripts/build_app.sh` (Swift 6 strict — verify the `actor` confinement of
  `EKEventStore` compiles clean with no `Sendable` warnings).

## 14. Effort & phasing

| Sub-step | Size | Notes |
|---|---|---|
| `MeetingContextProvider.swift` protocol + `MeetingEventContext`/`biasTokens` | **S** | Verbatim from the spine; the file 03 also uses. |
| `CalendarContextProvider` (EventKit, `actor`, auth + window fetch + `bestMatch` + attendee extraction) | **M** | The core. Pure scoring factored out for tests. |
| Wire `MeetingRecorder` **[branch]**: inject provider + bias closure, fill the two `setContextualStrings` sites, title/participants/source at stop | **M** | Depends on 01 being on main; respect `cancelStart`/generation tokens. |
| Info.plist key + Permissions calendar reflection + open-Settings deeplink | **S** | |
| Meetings-tab opt-in row + optional Permissions pane row | **S** | On-brand, reuse existing components. |
| Graph hand-off (attendees → Person + `Provenance(.calendar)`) | **S** (post-05) | Attach `eventContext` to the existing stop-time extraction enqueue. |
| Unit tests for `bestMatch` + `biasTokens` | **S** | First tests in the repo. |

**MVP slice (ship first, pre-05):** protocol + `CalendarContextProvider.eventContext` +
`MeetingRecorder` titling and **dual-engine bias** + Info.plist + the Enable row. This
alone delivers the Granola-class "named meeting, names spelled right" win.

**Full feature:** + the graph hand-off (Person entities + provenance), the
enabled-calendars allowlist setting, the stop-time title refinement, and the Permissions
pane row.

## 15. Dependencies & interactions

- **Needs 01 (far-end → main)** — provides the two `setContextualStrings` call sites,
  the `farEngine`, and the `participants`/`title`/`source` fields this feature fills.
  Per `_UNIFICATION.md` §5, 01 is rebased to main in Tier 0 before this. (Pre-01, a
  degraded single-engine version is possible but pointless to ship separately.)
- **Enables / feeds 05 (Context Graph)** — attendees become the cleanest `Person`
  entities in the graph (structured, high-confidence, with calendar provenance), making
  recall and the Brief sharper. Best built after 05's store exists; ships a useful slice
  before it.
- **Implements the shared `MeetingContextProvider` (§2.5)** — co-owned with **03
  (auto-detect)**, which adds `detectActiveMeeting()`. Landing the protocol here unblocks
  03.
- **Feeds 02 (notes fusion)** — the fused note can show real attendees in its header.
- **Improves 09 (cross-surface)** — "email *Sarah* the action items from my last
  meeting" resolves "Sarah" against a real calendar-sourced `Person` entity.
- **Touches 15 (sandbox)** — flags the `com.apple.security.personal-information.calendars`
  entitlement requirement for the future sandboxed build; 15 must validate EventKit under
  the sandbox.
- **Conforms via 20/01 `TranscriptionBackend`** — once mic/far-end are
  `TranscriptionBackend`s, the bias call is `backend.setContextualStrings(_)`; on a
  backend with `supportsContextualStrings == false` (whisper.cpp, feature 20), calendar
  bias is silently skipped (still get the smart title) — the matching degrade.
