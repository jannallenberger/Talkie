# 11 — Voice Macros / Snippets

> Engineer-ready implementation plan. Grounded in `main` (HEAD `5f747fb`) and the
> contracts in `_CURRENT_STATE.md` and `_UNIFICATION.md`. All paths absolute.
> **Floor:** macOS 26, Apple Silicon, Swift 6 strict concurrency (`.v6`).

## 1. Summary

Voice snippets: the user says an explicit trigger phrase (e.g. "insert my
address", "standup template") and Talkie expands it into a stored block of text,
resolving date/time tokens like `{today}` at expansion time. Storage and matching
are 100% on-device; matching uses **explicit invocation** (a leading "insert/expand
<name>" carrier phrase, or whole-phrase trigger match) — never fuzzy substring —
so normal dictation can never accidentally fire a macro.

## 2. Why it matters

Wispr Flow ships "text snippets" and it's one of their most-cited paid features;
Talkie should match it at $0, on-device, open source. For the user it removes the
single most repetitive part of dictation (signatures, addresses, boilerplate,
meeting templates) — say four words, get forty. Strategically it is the smallest,
lowest-risk member of the `CommandIntent` family (`_UNIFICATION.md` §2.4): building
it as a `MacroIntent` proves out the command-routing seam that features 08
(voice commands), 12 (edit-by-voice), and 09 (cross-surface) will all reuse, so the
"voice copilot" story gets a working, shippable first brick. Macros are also
**curated entities adjacent to the context graph** (§7) — they are the
user-authored counterpart to the graph's extracted terms, which keeps the
"one brain" thesis coherent rather than spawning a private island of state.

## 3. Current state in the code

There is **no macro/snippet feature today.** Nothing matches `macro`, `snippet`, or
`expansion` in `Sources/Talkie/`. The relevant existing machinery this plan builds
on:

- **`DictationAssembler`/`endDictation` pipeline** — `AppDelegate.endDictation()`
  (`AppDelegate.swift:401-549`) is the single funnel where a finished transcript is
  post-processed: LLM cleanup (`:465-476`) → `TextProcessor.apply` dictionary +
  fillers + capitalize (`:481-486`) → vibe-coding filename snap (`:492-496`) →
  `TextInjector.insert` (`:527`). Macro expansion must slot into this chain at a
  **precise point** (see §4).
- **`DictionaryStore`** (`DictionaryStore.swift:22-118`) — the exact template for a
  macro store: `@MainActor final class … ObservableObject`, `@Published` arrays, a
  `Codable Payload` written `.atomic` to `AppPaths.supportDirectory()`, failure-
  tolerant `load()`, `seedDefaultsIfEmpty()`, and `…Snapshot()` methods that hand
  Sendable plain values to the off-main pipeline. `Replacement` (`:4-18`) is the
  model template (UUID id, optional fields for back-compat via `learned: Bool?`).
- **`TextProcessor`** (`DictionaryStore.swift:129-238`) — pure `enum`, Sendable,
  runs off the main actor; `applyOne` already does whole-word regex matching
  (`\b…\b`, `:185-198`). The macro matcher is a sibling pure helper in the same
  spirit.
- **`TextInjector`** (`TextInjector.swift:10-154`) — the only injection path
  (`@MainActor enum`); `insert(_:mode:)` handles paste/type, secure-field fallback,
  clipboard restore. Macros inject through this unchanged.
- **`DictionarySettings`** (`SettingsView.swift:634-721`) — the UI template: a
  `ScrollView` of `.talkieCard()` sections, `PageHeader`, `Eyebrow`, `FlowLayout`
  chips, `ReplacementRow` with bound `TextField`s, save driven by view `.onChange`
  (`:703-704`). The macro tab mirrors this exactly.
- **`SettingsTab`** (`SettingsView.swift:4-46`) — the enum that drives the
  `NavigationSplitView` sidebar; adding a tab is a 3-site change (case, `title`,
  `icon`, `tint`) plus a `content` switch arm (`:149-167`) and a `MainView`/
  `MainWindowController` store injection.
- **`AppSettings`** (`AppSettings.swift`) — UserDefaults-backed scalar prefs; the
  one new global toggle (`macrosEnabled`) lands here.

What is **missing:** the entire feature — model, store, matcher, intent, UI tab,
pipeline hook, the `CommandIntent` protocol itself (defined by 08 but stubbed here
if 08 hasn't landed; see §15).

## 4. Design & approach

### 4.1 The matching problem (the crux)

The hard requirement from the brief is **no false positives**. A macro must NEVER
fire because the user happened to dictate words that look like an expansion. Two
explicit-invocation strategies, both opt-in by construction:

1. **Carrier-phrase invocation (primary).** The user speaks a carrier verb +
   the macro's `name`: "**insert** my address", "**expand** standup template",
   "**snippet** signature". The matcher only fires when the transcript (after
   trimming/normalizing) **begins with** a recognized carrier verb followed by a
   string that resolves to exactly one macro `name` (fuzzy *only* over the small,
   closed set of user-authored macro names — diacritic-folded, case-insensitive,
   punctuation-stripped — never over arbitrary text). Carriers: `insert`, `expand`,
   `paste` (configurable list, defaults shipped). This is the recommended default
   because it reads naturally and is unambiguous.

2. **Exact whole-utterance trigger (secondary).** Each macro may define an explicit
   `trigger` string. It fires **only when the entire normalized transcript equals
   the trigger** (not a substring, not a prefix) — e.g. trigger "my signature" fires
   only if the user said exactly "my signature" and nothing else. This is for users
   who want a bare phrase with no carrier verb, accepting that they must speak it
   alone.

Both strategies operate on the **whole final transcript as one unit**: a macro is an
all-or-nothing replacement of the utterance, not an inline substitution mid-sentence.
This is the single most important false-positive defense — we never scan for triggers
*inside* a longer dictation, so "I need to insert my address into the form" (a
genuine sentence) does **not** expand, because it isn't *just* the carrier+name.
(A future enhancement could allow inline expansion behind an explicit setting, but
the MVP is whole-utterance only — documented in §12.)

### 4.2 Where it runs in the pipeline

Macro matching runs **before LLM cleanup**, at the very top of the `endDictation`
`Task` (`AppDelegate.swift:440`), right after `engine.finishSession()` returns
`raw` and the language-detect pass. Rationale:

- If the utterance IS a macro, we **short-circuit the entire cleanup/dictionary/
  vibe chain** — the stored expansion is verbatim user-authored text and must not be
  rewritten by the LLM or have fillers stripped. We resolve tokens, inject, log, and
  return early.
- If it is NOT a macro, `finalRaw` flows through the normal pipeline unchanged —
  zero behavioral change for non-macro dictations.

Flow:

```
raw = finishSession()              (AppDelegate.swift:441)
finalRaw = languageDetect(raw)     (:445-455)
── NEW ──────────────────────────────────────────────
if macrosEnabled,
   let match = MacroMatcher.match(finalRaw, snapshot: macroSnapshot) {
       let expanded = MacroExpander.expand(match.macro, now: Date())
       // log as a dictation entry (appName/category preserved), bump stats,
       // record per-app usage, then:
       TextInjector.insert(expanded, mode: mode)
       hud.showInserting(); return        // SHORT-CIRCUIT
}
── continue normal pipeline if no match ─────────────
cleaned = cleanup(...); processed = TextProcessor.apply(...); vibe(...); inject
```

The macro snapshot (a Sendable value, captured at `beginDictation` time alongside
`vibeSnapshot`/`replacements`) is read off-main; `MacroMatcher`/`MacroExpander` are
pure Sendable `enum`s like `TextProcessor`/`SpokenFileMatcher`.

### 4.3 Token resolution

`MacroExpander.expand` walks the expansion text and substitutes `{token}` runs.
Tokens resolve against `Date()` (and a couple of stateless system values). All are
**honest, real values** — never invented. Token set (extensible):

| Token | Resolves to | Notes |
|---|---|---|
| `{today}` | "June 14, 2026" | `DateFormatter`, medium date, user locale |
| `{date}` | "2026-06-14" | ISO short |
| `{time}` | "3:42 PM" | short time |
| `{datetime}` | "June 14, 2026 at 3:42 PM" | |
| `{day}` | "Saturday" | weekday |
| `{tomorrow}` / `{yesterday}` | offset of `{today}` | |
| `{cursor}` | (stripped) marks caret position | optional MVP+; see §12 |
| `{clipboard}` | current pasteboard string | opt-in per-macro; reads, never writes |
| `{name}` | `settings.userName` | reuses the existing profile field |

Format is `{token}` (single braces, lowercased identifier). Unknown tokens are left
**literally intact** (e.g. `{foobar}` stays `{foobar}`) so a typo never silently
eats text — visible and debuggable. Escaping: `{{` → literal `{`.

## 5. New & changed files/types

### New: `Sources/Talkie/Macros/Macro.swift`

```swift
import Foundation

/// A user-authored voice snippet: speak the name (after a carrier verb) or the
/// exact trigger, get the expansion inserted.
struct Macro: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Spoken name, e.g. "my address". Matched after a carrier verb ("insert …").
    var name: String
    /// Optional exact whole-utterance trigger (fires only if the whole utterance
    /// equals it). Empty = carrier-phrase invocation only.
    var trigger: String = ""
    /// The text inserted, may contain {today}, {name}, … tokens.
    var expansion: String
    /// Reads the current clipboard for {clipboard} (off by default; opt-in).
    var allowsClipboardToken: Bool = false
    var createdAtUnix: Double = Date().timeIntervalSince1970
}

/// Immutable Sendable read model handed to the off-main matcher (mirrors
/// ProjectIndexSnapshot / replacementsSnapshot()).
struct MacroSnapshot: Sendable {
    let macros: [Macro]
    let carriers: [String]      // ["insert","expand","paste"]
    static let empty = MacroSnapshot(macros: [], carriers: [])
}
```

### New: `Sources/Talkie/Macros/MacroStore.swift`

Direct sibling of `DictionaryStore` — same persistence shape.

```swift
@MainActor
final class MacroStore: ObservableObject {
    @Published var macros: [Macro] = []
    private let fileURL = AppPaths.supportDirectory().appendingPathComponent("macros.json")

    init() { load() }

    func load()  // try? Data → decode Payload; else seedDefaultsIfEmpty()
    func save()  // filter blank-name drafts; JSONEncoder; .atomic write
    private func seedDefaultsIfEmpty()   // one illustrative macro (see §6)

    func addMacro()
    func removeMacros(at offsets: IndexSet)

    /// Sendable snapshot for the off-main pipeline.
    func snapshot(carriers: [String]) -> MacroSnapshot

    /// Names + expansions feed the recognizer bias set so "Coralate" inside a macro
    /// is spelled right when the user dictates near it (see §7 — graph biasPhrases).
    func biasPhrasesSnapshot() -> [String]
}
```

### New: `Sources/Talkie/Macros/MacroMatcher.swift` (pure, Sendable)

```swift
enum MacroMatcher {
    struct Match: Sendable { let macro: Macro }

    /// Returns a match ONLY for explicit invocation:
    ///   (a) normalized(utterance) begins with a carrier verb AND the remainder
    ///       resolves to exactly one macro name, OR
    ///   (b) normalized(utterance) equals a macro's exact trigger.
    /// Never matches a trigger/name as a substring of a longer utterance.
    static func match(_ utterance: String, snapshot: MacroSnapshot) -> Match?

    /// lowercased, diacritic-folded, punctuation/whitespace-collapsed.
    static func normalize(_ s: String) -> String
}
```

Matching detail: after `normalize`, split off a leading carrier token; the
**remainder must equal** a macro `name` (normalized) — exact set membership, not
fuzzy contains. If 0 or >1 macro names match the remainder, return `nil` (ambiguous
→ no expansion; the raw utterance flows through normal dictation). Exact-trigger
path: `normalize(utterance) == normalize(macro.trigger)`.

### New: `Sources/Talkie/Macros/MacroExpander.swift` (pure, Sendable)

```swift
enum MacroExpander {
    /// Resolves {today}/{date}/{name}/… against `now`+context. Unknown tokens kept
    /// literal; "{{" → "{". `clipboard` passed in (read on main before calling) so
    /// this stays pure.
    static func expand(_ macro: Macro, now: Date, userName: String, clipboard: String?) -> String
}
```

### New: `Sources/Talkie/Macros/MacroIntent.swift`

A thin `CommandIntent` conformance (the protocol from `_UNIFICATION.md` §2.4 /
feature 08). If 08's protocol exists, adopt it verbatim; if not yet landed, ship the
matcher/expander now and add this file when `CommandIntent` lands — the pipeline
hook in §4.2 works either way (it can call `MacroMatcher` directly as an MVP and be
refactored behind `CommandRouter` later). Sketch:

```swift
struct MacroIntent: CommandIntent {
    let id = "insert-macro"
    let needsSelection = false
    let isMutating = false   // pure insertion, no destructive selection replace
    func run(_ ctx: CommandContext) async -> CommandResult? {
        guard let m = MacroMatcher.match(ctx.spokenCommand, snapshot: snapshot) else { return nil }
        return CommandResult(replacement: MacroExpander.expand(...), preview: false, undoToken: nil)
    }
}
```

### Changed files

- **`AppDelegate.swift`**: add `let macros = MacroStore()` (`:7`-area); capture
  `macroSnapshot` + carriers in `beginDictation` (alongside `currentVibeSnapshot`,
  `:340`); add the short-circuit block at the top of the `endDictation` Task
  (`:440`); feed `macros.biasPhrasesSnapshot()` into the bias union (`:344-347`);
  inject `macros` into `MainWindowController` (`:559-572`).
- **`SettingsView.swift`**: add `.macros` to `SettingsTab` (case + `title`
  "Macros" + `icon` `"text.badge.plus"` or `"command"` + `tint` `Theme.featherGold`
  — but Dictionary already uses Green and History uses Gold; pick an unused feather:
  reuse `Theme.featherPlum` is taken by Meetings, so use a **shared** tint or add a
  hue — recommend reusing `Theme.featherGreen` family by tinting Macros with
  `Theme.coral`-adjacent and keeping Dictionary green; final choice is a 1-line
  design call, see §8); add `MacroSettings` view; wire the `content` switch arm and
  the `MacroStore` through `MainView`/`MainWindowController` init.
- **`AppSettings.swift`**: add `var macrosEnabled: Bool` (default `true`) and
  optionally `var macroCarriers: [String]` (default `["insert","expand","paste"]`),
  following the existing UserDefaults key/default pattern (`:151-211`).

## 6. Data model & persistence

- **File:** `~/Library/Application Support/Talkie/macros.json` via
  `AppPaths.supportDirectory()` — a new file next to `dictionary.json`, **no new
  directory, no new path helper needed.** (The context graph gets its own `graph/`
  subfolder per `_UNIFICATION.md` §1.4; macros do **not** move there — they are
  curated config, like the dictionary, and stay a flat store. See §7.)
- **Format:** `{ "macros": [Macro] }` — a `Codable Payload` struct exactly like
  `DictionaryStore.Payload`. `.atomic` write. `try?`/`decodeIfPresent` decode so a
  missing/garbage file falls back to seed defaults; every optional field
  (`trigger`, `allowsClipboardToken`) defaults so older files load forward.
- **Migration / back-compat:** none needed (new file). First launch with the
  feature seeds **one illustrative macro** so the tab isn't blank, mirroring
  `seedDefaultsIfEmpty()`'s `talkie→Talkie`:
  `Macro(name: "my signature", expansion: "Best,\n{name}")`. If `macros.json`
  already exists (e.g. re-install), it is loaded untouched.
- **Caps:** soft cap macros at a generous limit (e.g. 500) — the matcher is O(n) over
  a tiny set so no perf concern; the cap just guards a pathological JSON.

## 7. Unification contract

Per `_UNIFICATION.md` §6 **feature 11**:

> **Exposes:** a `MacroIntent` (`CommandIntent`); a macro store (trigger → expansion
> with `{today}` tokens).
> **Consumes:** explicit-invocation matching (no fuzzy false positives),
> `TextInjector`, `DictionaryStore` patterns for storage/UI.
> **Note:** on-device only; a Dictionary-tab sibling UI. Triggers are entities-
> adjacent but distinct (curated, not extracted).

This plan honors that exactly:

- **EXPOSES → other features:**
  - `MacroIntent: CommandIntent` for the `CommandRouter` (feature 08). Macros become
    one routed intent so 08/09/12 share entry/safety/injection (`§2.4`).
  - `MacroStore.biasPhrasesSnapshot()` — macro names + expansion vocabulary
    contributed to the recognizer bias union. When feature 05's
    `ContextGraphStore.biasPhrases(near:)` replaces the ad-hoc union in
    `beginDictation` (`_UNIFICATION.md` §1.6), macro phrases should be folded in
    there (macros register as **pinned, curated `.term` entities, `confidence 1.0`**
    — the same channel the dictionary vocab uses). Until 05 lands, macro bias is
    appended in `beginDictation` like dictionary/vibe phrases.
  - To the graph (feature 05): macros are **curated, not extracted** — they are
    surfaced to the graph as pinned `.term` entities with `Provenance(.dictionary)`
    (the existing curated-config provenance source), so recall/search can see "the
    user has a macro named X" without the extractor inventing it. This is the
    "entities-adjacent but distinct" note made concrete: macros never become
    extracted entities; they're authored config that the graph *references*.
- **CONSUMES:**
  - `TextInjector.insert(_:mode:)` — the **only** injection path; never a new paste
    route (matches §2.4's safety rule and the privacy-clean clipboard handling).
  - `DictionaryStore` patterns — store shape, snapshot methods, view-`.onChange`
    save, `FlowLayout`/`talkieCard()` UI.
  - The `CommandIntent`/`CommandRouter` seam from feature 08 (adopt, never fork).
  - Nothing from the graph is *required* to function (degrades fully without 05).

## 8. UI / UX

**A new top-level sidebar tab "Macros"**, sibling to Dictionary (the contract says
"a Dictionary-tab sibling"). Implemented as a new `SettingsTab` case so it gets the
native macOS 26 Liquid Glass sidebar row for free (`SidebarList`,
`SettingsView.swift:176-208`).

- **`MacroSettings`** mirrors `DictionarySettings` (`:634-721`): a `ScrollView` with
  a `PageHeader(title: "Macros", subtitle: "Say a phrase, insert a saved block.")`,
  then `.talkieCard()` sections:
  1. **How to use** (eyebrow + one calm sentence): *"Say 'insert' and the macro's
     name — like 'insert my address'."* Honest, second-person, no hype.
  2. **A global toggle** ("Voice macros — on") bound to `settings.macrosEnabled`.
  3. **Macro list**: one row per macro = a `name` `TextField`, an `expansion`
     multi-line `TextField` (`.lineLimit(1...6)`), an optional `trigger` field
     (disclosure / secondary), a `{token}` helper menu (a small `Menu` that inserts
     `{today}`/`{name}`/… at the cursor), and a delete button — same `ReplacementRow`
     visual grammar. "Add macro" button (`.bordered`, `plus`), empty-state copy.
- **Brand tokens** (`DesignSystem.swift` is source of truth for *values*,
  `BRAND.md` for *philosophy*): `.talkieCard()` (surface fill + whisper shadow, no
  outline), `Eyebrow` (11pt caps), serif `PageHeader` title, **one accent**
  (`Theme.coral` = the v2 macaw blue) on the primary Add button only, `FlowLayout`
  for token chips, squircle controls. Sidebar tint: pick a feather not yet used as a
  *primary* — Dictionary=Green, Meetings=Plum, History=Gold, Dashboard=Coral(red),
  VibeCoding=Blue. Recommend tinting Macros with **`Theme.featherGold`** shared with
  History is acceptable (tints aren't required unique), or introduce no new hue and
  reuse `Theme.featherGreen` to read as "Dictionary's cousin." Final 1-line call at
  build time; calm + on-brand either way. Icon: `"text.badge.plus"`.
- **HUD:** no new HUD state. On a macro hit, reuse the existing
  `hud.showInserting()` → `hud.hide(after:)` (`HUD.swift`), identical to a normal
  insertion — the transcript never shows in the pill (the §4 invariant from
  `_CURRENT_STATE.md` §4.7 holds).

## 9. Permissions / entitlements / Info.plist

**None.** Macros add no TCC prompt, no entitlement, no Info.plist key. They reuse:
mic + Input Monitoring (already needed to dictate the trigger) and Accessibility
(already needed for `TextInjector`'s paste). The `{clipboard}` token reads
`NSPasteboard.general` — no permission required on macOS — and is **opt-in per macro
and never writes** the clipboard for that token. Sandbox impact: zero (the file is
in the existing Application Support directory the app already writes).

## 10. Privacy posture

**Zero-network preserved, no exceptions.** Everything is local:

- `macros.json` lives in `~/Library/Application Support/Talkie/` (same as every
  other store). No data leaves the device.
- Matching/expansion are pure on-device functions; no LLM call, no model needed
  (macros work even when Apple Intelligence / Foundation Models is off — see §12).
- `{clipboard}` only **reads** the local pasteboard and only for macros where the
  user set `allowsClipboardToken = true`; disclose this in the row UI ("reads your
  clipboard").
- No `URLSession`, no telemetry — the verified zero-network invariant
  (`_CURRENT_STATE.md` §intro) is untouched.

## 11. Open-source genericity

- **No hardcoded personal stack.** Macros are pure user-authored content; the
  shipped default is one neutral, universally-useful example
  (`"my signature" → "Best,\n{name}"`) that needs no third-party app. No Obsidian,
  no editor, no folder assumption.
- **Zero-config default:** the feature works the instant the tab is opened — type a
  name + expansion, say "insert <name>". Carriers default to plain English verbs;
  the carrier list is a setting so non-English users can localize ("einfügen",
  "insertar") without code changes.
- **Community extension:** new `{tokens}` are added by extending the `MacroExpander`
  switch (one case each, pure); the token set is the obvious contribution surface.
  Because matching is an `enum`, anyone can add an alternate matching strategy behind
  a setting without touching the store or UI.
- **Wider hardware:** unlike most Talkie features, macros need **no** SpeechAnalyzer
  intelligence or Foundation Models for the expansion step — only the (already-
  required) transcription to hear the trigger. This is one of the few surfaces that
  degrades the least on the widened-hardware path (`_UNIFICATION.md` §4.2).

## 12. Risks, edge cases, failure modes

- **False positive (the headline risk):** mitigated structurally by whole-utterance
  explicit invocation only (§4.1). A macro can fire only if the entire utterance is
  "carrier + exact-name" or "exact-trigger". "I'll insert my address later" → not a
  bare carrier+name → no expansion. **Degradation:** when in doubt (ambiguous or
  multi-macro-name remainder), do nothing and let the text flow as normal dictation
  — never guess.
- **Recognizer mis-hears the name** ("insert my adres"): the normalized remainder
  won't exactly match a macro name → no expansion → the user just sees their spoken
  text (safe failure, nothing destructive). Adding macro names to the bias set (§7)
  reduces this.
- **Macro name collisions / one name is a prefix of another:** matcher requires
  exact set membership of the remainder; if a remainder matches >1 name → ambiguous
  → no-op. Surfacing a gentle "two macros share that name" hint in the UI is a nice-
  to-have (M).
- **Token a typo (`{tody}`)**: left literal, visible — never silently dropped.
- **`{clipboard}` empty / non-text:** resolves to empty string; disclosed.
- **Cursor token (`{cursor}`)**: paste-based injection can't place a caret mid-text;
  MVP **strips** `{cursor}` (documented), a later version could split-paste or use
  the `type` path. Don't over-promise.
- **Very long expansion + `type` mode:** the per-character path (`TextInjector`
  `typeUnicode`, `:141-153`) is slow for huge blocks — same limitation as normal
  dictation; paste mode (default) is unaffected.
- **Secure (password) field focused:** `TextInjector` already falls back to leaving
  the expansion on the clipboard with an explanatory reason — macros inherit this for
  free.
- **Toggle off:** `macrosEnabled == false` skips the whole match block → pure
  no-op, original behavior.

## 13. Testing & verification

No test target exists today (`_CURRENT_STATE.md` §8), so add the **first** one and
keep the pure helpers unit-testable:

- **Unit (add a `Tests/TalkieTests` target, the pure helpers are Sendable & free of
  AppKit):**
  - `MacroMatcher`: "insert my address" → hit; "I need to insert my address" → miss;
    "my signature" exact trigger → hit; "well my signature is nice" → miss; ambiguous
    duplicate names → miss; diacritics/case/punctuation normalization → hit.
  - `MacroExpander`: `{today}`/`{date}`/`{name}` resolve against a fixed injected
    `now`; unknown token kept literal; `{{` → `{`; `{clipboard}` uses the passed
    value.
  - `MacroStore` round-trip: encode → decode → equal; missing-field forward-compat;
    blank-name draft not persisted.
- **Manual / `/run` path** (the project's run skill builds & launches the app):
  1. Open Macros tab, add `coffee → "Grabbing a coffee, back in 10 — {time}."`.
  2. Focus TextEdit, hold the activation key, say "insert coffee", release → the
     expansion (with the real current time) is pasted; the History tab logs it.
  3. Say "I want to insert coffee into my drink" → normal text inserted, NOT expanded
     (the false-positive guard).
  4. Toggle Voice macros off → say "insert coffee" → literal text inserted.
- **`/verify`**: confirm zero new entitlements (diff `Resources/talkie.entitlements`
  + `Info.plist` — must be unchanged) and `grep -rniE "URLSession|https?://"
  Sources/Talkie/Macros/` returns nothing (privacy invariant intact).

## 14. Effort & phasing

| Sub-step | Size | Notes |
|---|---|---|
| `Macro` model + `MacroStore` (clone of DictionaryStore) | **S** | mechanical |
| `MacroMatcher` + `MacroExpander` pure helpers | **S** | core logic, unit-tested |
| `endDictation` short-circuit hook + bias-union feed | **S** | ~20 lines in AppDelegate |
| `MacroSettings` UI tab + `SettingsTab` + injection | **M** | mirror DictionarySettings |
| `macrosEnabled`/carriers in AppSettings | **S** | |
| First test target + unit tests | **S/M** | new `Tests/` + Package.swift target |
| `MacroIntent` conformance (when 08's protocol lands) | **S** | refactor, not rewrite |

**MVP slice (ship first):** model + store + `MacroMatcher` (carrier-phrase only) +
`MacroExpander` (`{today}/{date}/{time}/{name}` only) + the `endDictation` hook + a
basic `MacroSettings` tab (name + expansion fields, the global toggle). That is a
complete, useful feature in ~1–1.5 days.
**Full feature (later):** exact-trigger path, `{clipboard}`/`{tomorrow}`/`{day}`
tokens, token-insert helper menu, duplicate-name hint, `MacroIntent`/`CommandRouter`
integration, graph `.term` registration, the bias-set wiring through
`graph.biasPhrases`.

## 15. Dependencies & interactions

- **Needs (soft):** nothing hard — the MVP works against `main` today. The pipeline
  hook is self-contained in `AppDelegate.endDictation`.
- **Enables / feeds:**
  - **08 (voice commands) & the `CommandIntent`/`CommandRouter` seam** — `MacroIntent`
    is the first, simplest intent; building it proves the router. If 08 lands first,
    adopt its protocol; if macros land first, the matcher is later wrapped as an
    intent (no rewrite of logic).
  - **05 (context graph)** — macros register as pinned curated `.term` entities
    (`Provenance(.dictionary)`); when 05's `biasPhrases(near:)` supersedes the ad-hoc
    bias union, macro phrases route through it.
- **Overlaps / shares with:**
  - **12 (edit-by-voice)** and **09 (cross-surface)** — all `CommandIntent`s; they
    share `TextInjector`, the router, and the preview/undo safety model. Macros are
    non-mutating (`isMutating == false`) so they skip preview; 12/09 will use it.
  - **13 (per-app profiles)** — a per-app profile may scope *which macros are active*
    in a given app (a natural extension: `MacroSnapshot` filtered by bundle id),
    mirroring how 13 filters bias phrases.
  - **`DictionaryStore`** — sibling store; conceptually macros = "phrase →
    block" while the dictionary = "word → word". Worth a cross-link in both tabs'
    copy so users learn the distinction.
- **Does NOT touch:** the meeting recorder, the far-end branch
  (`feat/meeting-far-audio`), transcription engine internals, or any network code.

---

## Biggest open question / risk

The single biggest open question is **the invocation grammar** — specifically
whether whole-utterance-only matching (which guarantees zero false positives) is too
rigid for the natural way people dictate. Users may instinctively say "...and then
insert my address here" expecting expansion mid-sentence, and get literal text
instead. The safe, shippable MVP is whole-utterance only; the risk is it feels
"dumb" versus a fuzzy matcher — but a fuzzy matcher is exactly what corrupts normal
dictation, which is the cardinal sin. The recommended resolution: ship
whole-utterance-only, watch real usage, and only later add an explicit opt-in
"inline expansion" setting (gated, off by default) rather than ever loosening the
default matcher. A secondary open item: the **sidebar feather tint** for the new tab
(all five primary feathers are spoken for) — a trivial design call, but it should be
made deliberately so the nav palette stays coherent rather than reaching for a
sixth hue.
