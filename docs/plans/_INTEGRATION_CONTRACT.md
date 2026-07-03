# Talkie — Integration Contract (the binding wiring spec)

Status: BINDING. Every wiring agent follows this verbatim. The repo at
`/Users/jann/talkie-mvp` (branch `feat/mvp-ramp`) builds green: the live app plus
13 committed-but-unwired cores. This pass wires the cores into the running app so
the features work, matching the CURRENT premium UX exactly.

Non-negotiables (read once, obey everywhere):
- **No new gesture.** Commands are entered by a *parsed leading imperative* on the
  existing dictation hotkey path — never a second key. The hub owns that parse.
- **100% on-device.** No network. Default `Summarizer` is `OnDeviceLLM()`.
- **Honest voice + design parity.** New UI is indistinguishable from the current
  app: same `Theme` tokens, same `talkieCard`/`SettingsCard`/`PageHeader`
  components, same second-person copy ("you", never "the user").
- **File ownership is disjoint.** No two agents edit the same file (see §5).
- **Never guess a public API.** The signatures pinned below were read from source;
  if a core's API differs from what you remember, the source wins — re-read it.

---

## 1. COMPOSITION ROOT (AppDelegate.swift — owned by the HUB agent)

All new stores are instantiated as `let` stored properties on `AppDelegate`
alongside the existing ones (`settings`, `dictionary`, `history`, `stats`,
`meetingStore`, `contextSummary`, …). Add EXACTLY these, with these names/types:

```swift
// --- new cores (integration pass) ---
let contextGraph = ContextGraphStore()                 // @MainActor ObservableObject
let macros       = MacroStore()                         // @MainActor ObservableObject
let profiles     = AppProfileStore()                    // @MainActor ObservableObject
let searchEngine = SearchEngine()                       // @MainActor ObservableObject
// CommandRouter is NOT an ObservableObject; it is plain @MainActor. Build it after
// `macros` exists. Default summarizer is OnDeviceLLM (on-device).
private(set) lazy var commandRouter = CommandRouter(macros: macros)
```

Notes the wiring agents MUST respect:
- `ContextGraphStore()`, `MacroStore()`, `AppProfileStore()`, `SearchEngine()` are
  all zero-arg inits that load their own JSON from `AppPaths.supportDirectory()`.
- `CommandRouter(macros:summarizer:)` — `summarizer` defaults to `OnDeviceLLM()`.
  Do not pass a network backend.
- `OnDeviceLLM` is a `struct` (value type, `Sendable`); construct freely.
- `ContextGraphSnapshot`, `MeetingSnapshot`, `CommandContext`, `CommandResult`,
  `SearchHit`, `ResolvedProfile`, `TargetApp` are all `Sendable` value types — they
  are what crosses the actor boundary into the post-processing `Task`.

### 1a. Launch wiring (in `applicationDidFinishLaunching`, HUB agent)

After the stores are created and `meetingRecorder` is built, add (in this order):

```swift
// Seed the graph from already-stored data so recall/Brief/search are useful on
// first launch (idempotent enough for the MVP; backfill only writes the graph).
contextGraph.backfill(dictations: history.entries, meetings: meetingStore.meetings)

// Build the search index off the same three sources. Cheap for a few thousand rows.
searchEngine.rebuild(dictations: history.entries,
                     meetings: meetingStore.meetings,
                     graph: contextGraph.snapshot())
```

### 1b. Injection into views (HUB agent, in `openSettings` / `MainWindowController`)

`MainWindowController.init` and `MainView` gain four new `@ObservedObject`
parameters, threaded the SAME way the existing stores are (explicit init params,
NOT `environmentObject` — the app uses constructor injection throughout):

```
contextGraph: ContextGraphStore,
macros:       MacroStore,
profiles:     AppProfileStore,
searchEngine: SearchEngine,
```

`commandRouter` is NOT injected into the window — it lives only in `AppDelegate`
(the dictation/command path is in the hub). The SEARCH agent's `SearchView`
receives `searchEngine` via its own init (see §3).

---

## 2. PER-SURFACE WIRING SPEC

### HUB  (AppDelegate.swift + HotKeyMonitor.swift) — owns dictation, commands, graph ingest, profiles, search refresh

1. **Recognizer bias → graph.** In `beginDictation()`, the existing union
   (`dictionary.contextualPhrasesSnapshot()` + `captured.phrases` + vibe) gains the
   graph's phrases. Build a snapshot once and union it:
   ```swift
   let graphSnapshot = contextGraph.snapshot()
   bias.append(contentsOf: graphSnapshot.biasPhrases(limit: 60))
   ```
   Keep the existing `Array(Set(bias)).prefix(180)` cap. Capture
   `graphSnapshot` into the session so the end path reuses it (don't re-snapshot).

2. **Per-app profile resolution.** Replace the ad-hoc per-category cleanup capture
   with the three-tier resolver. At session start:
   ```swift
   let resolved = profiles.resolve(for: captured.target, settings: settings)
   ```
   Store `resolved` in place of `sessionCleanup`; in `endDictation()` read
   `resolved.appAdaptiveCleanup / .cleanupStyle / .cleanupLevel / .insertionMode /
   .autoCapitalize / .removeFillers` instead of the loose `settings.*` reads. This
   is byte-for-byte identical for a user with no profiles (resolver falls back to
   `settings.cleanupStyle(for:)` etc.), so the existing accounting can't drift.
   Also use `profiles.biasVocabulary(for:dictionary:)` as the dictionary slice of
   the bias union (it returns all global vocab when no profile narrows it).

3. **Command mode (parsed leading imperative — no new gesture).** In
   `endDictation()`, AFTER the raw transcript is finalized but BEFORE the normal
   cleanup/insert pipeline, ask the router whether this utterance is a command:
   ```swift
   if let intent = commandRouter.intent(for: finalRaw) {
       // It's a macro or an imperative rewrite — route it instead of dictating.
       let selection = intent.needsSelection ? AXSelection.read() : nil
       let result = await commandRouter.run(
           spoken: finalRaw, selection: selection,
           target: currentTarget, graph: graphSnapshot)
       if let result { await applyCommandResult(result) ; return }
   }
   ```
   - The hub adds a tiny `AXSelection.read() -> String?` helper (new private file
     `Sources/Talkie/Commands/AXSelection.swift` is HUB-owned) that reads
     `kAXSelectedTextAttribute` from the focused element — mirror the AX pattern in
     `ContextCapture.focusedText()` / `TextInjector.hasEditableFocus()`.
   - The hub also constructs `CrossSurfaceIntent(meetings:)` and
     `ReplaceSelectionIntent` paths only if/when it routes them; `CommandRouter`
     itself only resolves macro + imperative-rewrite (per its source). For the MVP
     the hub routes what `commandRouter.intent(for:)` returns; cross-surface is
     reachable by the hub calling the intent directly with
     `MeetingSnapshot(meetings: meetingStore.meetings)` when the parse matches —
     keep this additive and behind the same imperative-leading guard.

4. **The preview/undo flow (`applyCommandResult`).** HUB-owned helper:
   - `result.preview == true` → show the HUD preview (`hud.showCommandPreview(...)`,
     see §HUD) and inject only on confirm; on undo, restore `result.undoToken` via
     `TextInjector`. `result.preview == false` (macro) → inject immediately via
     `TextInjector.insert(result.replacement, mode: resolved.insertionMode)`.
   - Mutating intents always carry `undoToken` (the prior selection); the hub keeps
     it so the HUD's "Undo" can re-inject it.

5. **Graph + search ingest on dictation end.** After a normal (non-command)
   dictation inserts, fold the transcript into the graph and refresh search:
   ```swift
   let candidates = ContextGraphExtractor.candidates(from: finalText)
   contextGraph.ingest(candidates, provenance: Provenance(
       source: .dictation, sourceID: <history entry id>.uuidString,
       dateUnix: Date().timeIntervalSince1970, snippet: String(finalText.prefix(120))))
   searchEngine.rebuild(dictations: history.entries,
                        meetings: meetingStore.meetings, graph: contextGraph.snapshot())
   ```
   (`ContextGraphExtractor.candidates(from:)` is pure/Sendable — fine to compute in
   the Task; `ingest` + `rebuild` hop back to `@MainActor`.)

6. **Dictionary → graph pin.** When the hub already calls
   `dictionary.addLearnedReplacement(...)` (learn-from-edits), ALSO call
   `contextGraph.pinTerm(<the target spelling>)` so curated terms always bias.
   (Additive; no behavior removed.)

7. **HotKeyMonitor.swift** needs NO API change for command mode (commands ride the
   same press/release edges). The only hub edit here, if any, is comments — keep
   the `Config`/`onActivate`/`onDeactivate` contract intact.

### MEETINGS  (MeetingRecorder.swift + MeetingsView.swift) — owns calendar context, notes fusion, graph ingest of meetings

1. **Calendar context provider.** `MeetingRecorder` gains an injected provider:
   ```swift
   var contextProvider: (any MeetingContextProvider)?   // set by AppDelegate? NO — see below
   ```
   OWNERSHIP NOTE: `MeetingRecorder` is meetings-owned, so the meetings agent adds
   the property AND defaults it to `CalendarMeetingContext()` inside the recorder
   (do not require the hub to inject it — that would force a cross-file edit). At
   `start()`, after `startedAt` is set, call
   `await contextProvider?.eventContext(at: start)`; if non-nil:
   - title the meeting `eventContext.title` instead of the timestamp title;
   - union `eventContext.biasTokens` into BOTH engines' `setContextualStrings([...])`
     (currently `[]`) so attendee names spell right;
   - record attendee names as participants/people (carried into the saved `Meeting`).
   Guard everything: nil provider / nil context / unauthorized → today's exact
   timestamp-title, `[]`-bias behavior. Calendar access is requested only by a
   deliberate user tap in Settings (§SETTINGS), never at launch.

2. **Notes fusion (the Granola moment).** `MeetingsView` gains a live-notes
   `TextEditor` in the record card (only while `isRecording`), bound to
   `@State private var liveNotes`. On stop, the recorder fuses notes + transcript:
   ```swift
   let fusion = MeetingNotesFusion()
   if let result = await fusion.fuse(notes: liveNotes, transcript: clean,
                                     using: OnDeviceLLM(temperature: 0.3)) {
       // result.bodyMarkdown is "## Notes\n…\n## Summary\n…"; store it as the
       // meeting summary path (append "## Transcript" via the existing writer).
   }
   ```
   Thread `liveNotes` from the view to `recorder.stop(notes:)` — the meetings agent
   adds a `notes: String = ""` param to `stop()` (back-compat default keeps every
   other call site valid). Fall back to today's `MeetingSummarizer` summary when
   fusion returns nil. Keep the honest copy: notes pane placeholder is
   "Jot rough notes — Talkie fleshes them out from the transcript, never invents."

3. **Graph ingest of meetings.** In `MeetingRecorder.stop()`, after `store.add(meeting)`,
   ingest the meeting into the graph (meetings agent does this; it owns the file):
   ```swift
   AppDelegate.shared?.contextGraph.ingest(
       ContextGraphExtractor.candidates(from: clean)
         + meeting.participants.filter { $0 != "Me" && $0 != "Them" }
             .map { .init(kind: .person, displayName: $0) },
       provenance: Provenance(source: .meeting, sourceID: meeting.id.uuidString,
                              dateUnix: meeting.startUnix, snippet: nil))
   ```
   `AppDelegate.shared` is the existing static accessor; the graph store is public.
   (If the meetings agent prefers, it can take a `var onSaved: (Meeting) -> Void`
   callback the hub sets — but the static is already there and is the lighter touch.)

### HUD  (HUD.swift) — owns the command preview/undo pill states

Add new `HUDPhase` cases + controller methods that match the EXISTING pill visual
language (solid black capsule, `Theme.featherRed` accents, `.blurReplace`
transitions, `StatusDot`, spring entrance). Do NOT restyle existing phases.

```swift
// new cases on HUDPhase:
case commandPreview(String)   // the proposed replacement text, awaiting confirm
case commandReverted          // brief "Reverted" confirmation (mirror .copied)
```

Controller surface (mirror `showCopyPrompt` — it already toggles
`ignoresMouseEvents` and wires a tap callback):

```swift
var onCommandConfirm: () -> Void
var onCommandUndo:    () -> Void
func showCommandPreview(_ text: String, onConfirm: @escaping () -> Void,
                                          onUndo: @escaping () -> Void)
func showReverted()   // hide(after: 0.9)
```

Visual spec for `commandPreview`: the black pill widens to show the preview text
(`lineLimit(2)`, `maxWidth: 320`) with a small `sparkles` glyph in
`Theme.coral`, plus two inline affordances: a primary "Insert" and a subtle
"Undo" — rendered as tappable capsule chips reusing the `.inserting` chip styling
(`.white.opacity(0.13)` fill). Tapping Insert calls `onCommandConfirm`; Undo calls
`onCommandUndo`. Keep mouse events enabled only in this phase (like `.copyPrompt`).
Honest copy, no em-dash drama.

### SETTINGS  (SettingsView.swift + new files under Sources/Talkie/Settings/) — owns macro mgmt, per-app profiles, calendar opt-in, feature toggles

1. **New sidebar-adjacent surfaces are SETTINGS subpages**, not new top-level tabs
   (the top-level nav is the hub's call — see §3). Add to the existing
   `SettingsRoute` enum and `categoryRows`:
   - `.voiceCommands` → "Voice commands" (macros list + how-to). Icon
     `"IconWand"` (reuse) or system `"mic.badge.plus"`. Subtitle:
     `"\(macros.macros.count) macros"`.
   - `.appProfiles` → "Per-app rules". Subtitle:
     `profiles.customizedCount == 0 ? "Same everywhere" : "\(profiles.customizedCount) apps customized"`.
   - `.calendar` → "Calendar". Subtitle: authorized → "Connected", else "Off".
2. **New panes live in `Sources/Talkie/Settings/`** (settings-owned new files):
   - `VoiceCommandsSettings.swift` — a `SubPage` hosting a `SettingsCard` list of
     `Macro` rows (trigger → expansion) with add/delete via `MacroStore.add` /
     `.delete`; reuse `SettingsRow` / `SettingsCard` / `SubPage` exactly. Explain
     the parsed-leading-imperative model in the footer (honest: "Start a dictation
     with a verb like 'make', 'fix', 'translate' to run a command on your selection;
     say a macro's trigger by itself to expand it.").
   - `AppProfilesSettings.swift` — list of `AppProfile`s with an editor sheet
     (cleanup style/level, insertion, auto-cap, fillers, vocabulary filter) writing
     through `AppProfileStore.upsert` / `.remove`. Reuse `SettingsToggleRow` +
     `SettingsRow` pickers; match `CleanupSettings` patterns.
   - `CalendarSettings.swift` — an "Enable calendar context" `SubPage` with a single
     prominent button calling `await CalendarMeetingContext().requestAccess()` and
     showing `CalendarMeetingContext.isAuthorized`. Honest copy: read-only, names
     your meetings and biases attendee spelling, never edits your calendar.
   - These panes receive their stores via init params (`macros:`, `profiles:`),
     threaded from `MainView` → `SettingsHome`. The settings agent adds those
     params to `SettingsHome` and `subpage(_:)` (SettingsView is settings-owned).
3. **Feature toggles.** If a feature needs a master switch (e.g. voice commands on/
   off, semantic search visibility), the settings agent adds an `@Published` flag to
   `AppSettings.swift` — BUT `AppSettings.swift` is NOT in any agent's ownership
   list. RESOLUTION: the hub owns the cross-cutting composition, so **any new
   `AppSettings` flag is added by the HUB agent** on request; settings agent reads
   it. For the MVP, prefer NOT adding flags — commands and graph are always-on and
   on-device; search is a nav route, not a toggle.

### SEARCH  (new Sources/Talkie/Search/SearchView.swift) — owns the recall UI

`SearchView` is a new view; it does not edit any existing file. Its init:

```swift
struct SearchView: View {
    @ObservedObject var engine: SearchEngine
    let history: HistoryStore       // to resolve a hit id back to its dictation
    let meetingStore: MeetingStore  // to resolve a hit id back to its meeting
    init(engine: SearchEngine, history: HistoryStore, meetingStore: MeetingStore)
}
```

Behavior: a serif `PageHeader(title: "Search", subtitle: "Find anything you've
said — on-device.")`, a search field bound to `@State query`, results from
`engine.search(query)` rendered as `talkieCard`-style rows. Each `SearchHit`
shows `snippet`, a kind glyph (dictation/meeting/entity) tinted by the feather
palette (dictation→`featherGold`, meeting→`featherPlum`, entity→`featherGreen`),
and a relative date from `dateUnix`. Tapping a hit reveals the source (jump to the
History/Meetings tab via the `router` the hub passes, or expand inline). Empty
query → a calm prompt; zero hits → honest "Nothing matches yet." Reuse
`Theme`, `talkieCard`, `Eyebrow`. The hub passes `engine: searchEngine` plus the
two stores when it adds the route (§3).

### BRIEF  (ContextSummary.swift) — owns enriching the daily brief with the graph

`ContextSummaryStore.refresh(from:)` currently summarizes only `history.entries`.
Enrich it to fold in graph commitments/people so the Brief reflects the whole
context graph, not just today's dictations. Add an overload that accepts a snapshot
WITHOUT breaking the existing call site (DashboardView calls `refresh(from:)`):

```swift
func refresh(from history: HistoryStore,
             graph: ContextGraphSnapshot = .empty) async
```

Inside, pass the snapshot's `commitments()` (rendered as plain lines) and top
people/projects into the engine prompt as additional, clearly-labeled context
("Open commitments from your context graph: …"), keeping the engine's existing
"do NOT invent" guardrail. The DashboardView call site is owned by the dashboard,
not this agent — so the default `.empty` keeps it compiling; the HUB (which has the
graph) may later pass `contextGraph.snapshot()` from where it triggers a refresh.
This agent only edits `ContextSummary.swift`. Do not touch DashboardView.

---

## 3. CROSS-SURFACE CONTRACTS (exact signatures one surface exposes to another)

1. **New top-level nav route (`SettingsTab`)** — the HUB owns adding it (it owns the
   window/tab composition through `openSettings`/`MainWindowController`, even though
   the enum text lives in SettingsView). Coordinate: the SEARCH agent ships
   `SearchView`; the HUB adds the tab case and the `content` switch arm. Add:
   ```swift
   case search   // in SettingsTab, between .meetings and .dictionary
   // title "Search"; icon "magnifyingglass"; tint Theme.featherBlue
   ```
   and in `MainView.content`:
   ```swift
   case .search:
       SearchView(engine: searchEngine, history: history, meetingStore: meetingStore)
   ```
   ⚠️ FILE-OWNERSHIP EXCEPTION: this requires touching `SettingsView.swift`
   (settings-owned) for the enum case AND the `content` switch. To keep ownership
   disjoint, the **SETTINGS agent adds the `SettingsTab.search` enum case + its
   `title`/`icon`/`tint`** (it owns SettingsView), and the **HUB agent provides the
   `MainView.content` arm + the `MainWindowController`/`MainView` init params** —
   BUT both live in SettingsView.swift. RESOLUTION (binding): **the SETTINGS agent
   makes ALL edits inside `SettingsView.swift`** (enum case, init params, `content`
   arm, `SettingsHome` new subpage routes), consuming the `searchEngine`/`macros`/
   `profiles`/`contextGraph` objects the HUB threads into `MainWindowController`.
   The HUB edits only `MainWindowController`'s *call site* in `AppDelegate.swift`
   (passing the four new stores). This keeps SettingsView single-owner.

2. **`SearchView(engine:history:meetingStore:)`** — pinned in §2 SEARCH. The
   SETTINGS agent calls it from `MainView.content`; the SEARCH agent ships it.

3. **Command mode entry** — `CommandRouter.intent(for: String) -> (any CommandIntent)?`
   and `CommandRouter.run(spoken:selection:target:graph:) async -> CommandResult?`.
   HUB-only consumer. The parse that gates it is the imperative-leading check inside
   `CommandRouter.intent` (already implemented) — the hub does NOT reimplement it.

4. **Preview/undo between CommandRouter and HUD** — `CommandResult(replacement,
   preview, undoToken)` flows hub → `hud.showCommandPreview(text:onConfirm:onUndo:)`.
   Confirm → `TextInjector.insert(replacement, mode: resolved.insertionMode)`. Undo →
   `TextInjector.insert(undoToken!, mode: resolved.insertionMode)` then
   `hud.showReverted()`. HUB owns the closures; HUD owns the pill.

5. **`MeetingRecorder.stop(notes: String = "")`** — MEETINGS adds the param;
   MeetingsView is the only caller and is meetings-owned, so this is intra-agent.

6. **`ContextSummaryStore.refresh(from:graph:)`** — BRIEF adds the `graph:`
   overload with a default, so the dashboard's existing `refresh(from:)` call is
   unaffected.

7. **Graph ingest seam** — `ContextGraphExtractor.candidates(from: String)
   -> [Candidate]` (pure) + `ContextGraphStore.ingest(_:provenance:)` +
   `Provenance(source:sourceID:dateUnix:snippet:)`. HUB ingests dictations;
   MEETINGS ingests meetings (via `AppDelegate.shared?.contextGraph`).

8. **`SearchEngine.rebuild(dictations:meetings:graph:)`** — HUB calls it at launch
   and after each dictation/meeting save; `SearchView` only reads via `search`.

---

## 4. DESIGN-MATCH RULES (the exact tokens/components new UI reuses)

- **Colors:** `Theme.canvas` (page bg), `Theme.surface` (cards), `Theme.ink` /
  `inkSecondary` / `inkTertiary` (text), `Theme.hairline` (dividers only),
  `Theme.coral` (= brand blue: primary action/selection/focus). Categorical/feather
  tints `featherCoral`/`featherGold`/`featherBlue`/`featherGreen`/`featherPlum` for
  per-item glyphs and nav tints. `Theme.featherRed` for the recording/live accent.
- **Type:** `Font.talkieDisplay(_:)` (serif) for page titles + hero numbers;
  `Font.talkieHeading(_:weight:)` (SF Pro) for functional headings;
  `Font.talkieEyebrow` + the `Eyebrow` view for all-caps section labels. Never
  hardcode a font family.
- **Surfaces:** `.talkieCard(padding:)` / `.talkieSurface()` for cards;
  `RoundedRectangle(cornerRadius: Theme.Radius.card/.control/.chip, style:
  .continuous)` (squircle) for any custom rounding. Borderless — lift with the
  built-in whisper shadows, never an outline.
- **Spacing:** `Theme.Space.card` / `.gridGap` / `.section`.
- **Settings panes:** reuse `SubPage`, `SettingsCard(header:footer:)`,
  `SettingsRow`, `SettingsToggleRow`, `SettingsRowView`, `PageHeader` verbatim.
  Do not invent a new row/card style.
- **HUD:** new phases reuse the black capsule, `StatusDot`, the `.inserting` chip
  treatment (`.white.opacity(0.13)` capsule), `.blurReplace` transitions, and the
  spring entrance. White text at the established opacities (0.8/0.72/0.4).
- **Sidebar rows:** `Label(title, systemImage: icon).listItemTint(tint)` — match
  the `SettingsTab` pattern for the new `.search` tab.
- **Voice:** second person, honest, concrete. No "the user", no fabricated claims,
  no AI-slop ("seamlessly", "effortlessly", em-dash drama). Mirror existing copy.

---

## 5. FILE OWNERSHIP (disjoint — enforced)

| Agent     | Files it may edit / create                                                                 |
|-----------|--------------------------------------------------------------------------------------------|
| **hub**   | `AppDelegate.swift`, `HotKeyMonitor.swift`, **new** `Sources/Talkie/Commands/AXSelection.swift` |
| **meetings** | `MeetingRecorder.swift`, `MeetingsView.swift`                                            |
| **hud**   | `HUD.swift`                                                                                 |
| **settings** | `SettingsView.swift`, **new** files under `Sources/Talkie/Settings/`                     |
| **search**| **new** `Sources/Talkie/Search/SearchView.swift` (only)                                     |
| **brief** | `ContextSummary.swift`                                                                      |

Hard rules:
- The HUB edits `AppDelegate.swift` ONLY for: new store properties, launch
  backfill/rebuild, `beginDictation`/`endDictation` wiring, `applyCommandResult`,
  the `MainWindowController(...)` call site (passing the 4 new stores), and the new
  `AppSettings` flag IF one is requested.
- The SETTINGS agent is the SOLE editor of `SettingsView.swift` — including the new
  `SettingsTab.search` case, its `title`/`icon`/`tint`, the `MainView`/
  `MainWindowController` init params for the 4 new stores, the `content` switch
  `.search` arm calling `SearchView(...)`, and the new settings subpages/routes.
  (This is why the search tab edit is assigned here, not to the hub: SettingsView
  has one owner.)
- The SEARCH agent creates ONLY `SearchView.swift`; it must not edit SettingsView.
- The BRIEF agent edits ONLY `ContextSummary.swift`; it must not touch DashboardView
  (the default `graph: .empty` keeps the dashboard call site compiling untouched).
- `AppSettings.swift`, `DashboardView.swift`, `Meeting.swift`, the cores themselves,
  and `DesignSystem.swift` are READ-ONLY for all agents this pass.

> **Correction (2026-07-03, D2):** the `Meeting.swift` READ-ONLY line above is a
> stale earlier-pass artifact. The current implementation pipeline's file-conflict
> matrix defines an explicit `Meeting.swift` EDIT order (F1→D2→A8→F3→…) — the
> back-compat custom decoder exists precisely so packages can add optional fields.
> D2 added `Meeting.segments: [MeetingSegment]?` (decoded with `decodeIfPresent`);
> old JSON loads unchanged and older builds ignore the new key. `AppSettings.swift`
> is likewise edited by A2/I2 per their specs. `DesignSystem.swift` remains
> genuinely read-only.

---

## 6. RISKIEST COUPLING (call it out, mitigate it)

**The command-mode interception in `endDictation` (hub) ↔ the HUD preview/undo
(hud) ↔ `TextInjector`/AX selection.** A spoken utterance now has two fates —
normal dictation vs. a routed command — decided by `CommandRouter.intent(for:)` on
the *finalized raw transcript*. If the imperative parse fires on ordinary dictation
("make sure you call her"), the user's words vanish into a rewrite preview instead
of being inserted. Mitigations baked into this contract: (a) the parse is the
core's own conservative leading-verb / whole-utterance-macro check — the hub does
NOT widen it; (b) mutating commands ALWAYS preview (never auto-apply), so a
misfire is one tap to dismiss and the original text is recoverable via the
`undoToken`; (c) command routing happens only when `intent != nil`, otherwise the
exact existing pipeline runs unchanged; (d) `needsSelection` intents that find no
selection return nil → fall through to normal dictation. Wire it so a nil/empty
command result, or a preview the user dismisses, leaves the original transcript
insertable rather than lost.
