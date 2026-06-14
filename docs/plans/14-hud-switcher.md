# 14 — HUD style switcher + visible intelligence

> Feature plan. Grounded in `main` (the code as it exists today). Read
> `_CURRENT_STATE.md` (ground-truth map) and `_UNIFICATION.md` (the spine) first;
> this plan honors the per-feature contract written for **14** in
> `_UNIFICATION.md` §6.

## 1. Summary

Surface the *active* cleanup level/style directly in the live dictation HUD pill,
and let the user view and change it in one gesture (a scroll over the pill, plus a
global modifier-cycle hotkey) without ever opening Settings — and route the change
through the same per-app profile path feature 13 owns, so the switch is sticky and
consistent.

## 2. Why it matters

Talkie's whole pitch is that the *intelligence is the product* — the on-device LLM
cleanup is what separates it from a dumb speech-to-text box. Today that
intelligence is **invisible**: the HUD shows only a waveform (`HUD.swift:225-230`),
and the only way to see or change the cleanup style is to dig through
`Settings → Cleanup & style` (`SettingsView.swift:540-552`). The user can't tell,
mid-flight, whether this dictation is going in as a faithful code transcript or a
polished professional email — and can't fix it without breaking the
hold-talk-release loop.

Making the active style visible-and-switchable in the HUD does three strategic
things:

- **Builds trust in the moat.** The disruption (per `_UNIFICATION.md`) is one
  on-device brain routing both voice surfaces. A user only believes the brain is
  working if they can *see* it choosing "Professional for Mail, Faithful for the
  terminal." This is the cheapest, highest-visibility proof that the adaptive
  intelligence is real — exactly the kind of "visible intelligence" Wispr Flow and
  Granola (separate cloud products with no shared, app-aware brain) can't show.
- **Removes the only friction in the core loop.** Dictation is hold → talk →
  release. A Settings round-trip to change tone is a context switch that breaks
  flow. An in-loop switch keeps the user in the gesture.
- **It is the visible face of feature 13 (per-app profiles).** The HUD switcher is
  where the resolved per-app profile becomes legible and editable; the two features
  share one resolution+persistence path (`_UNIFICATION.md` §6/14: "the switch
  writes through the same settings/profile path (13)").

## 3. Current state in the code

What exists today, honestly:

- **The HUD is waveform-only.** `HUDController` drives a borderless non-activating
  `NSPanel` pinned under the notch; the SwiftUI pill (`HUD.swift:189-264`) renders
  per `HUDPhase` (`HUD.swift:17-25`) and shows **only** a `StatusDot` + `Waveform`
  while `.listening`/`.transcribing` (`HUD.swift:225-230`). The phase model
  (`HUDModel`, `HUD.swift:27-40`) carries `phase`, `text`, `levels`, `busyNudge` —
  **no style/level field, no interactivity.** The panel is explicitly
  `ignoresMouseEvents = true` (`HUD.swift:72`) so it currently can't receive a
  scroll or click.
- **Cleanup is fully modeled but only mutable via Settings.** `CleanupLevel`
  (none/light/medium/high, `CleanupEngine.swift:5-80`) and `CleanupStyle`
  (off/faithful/neutral/friendly/professional/concise, `CleanupEngine.swift:85-189`)
  each carry `displayName` + `detail` strings already — ready-made HUD labels. The
  actor `CleanupEngine` (`CleanupEngine.swift:194`) runs them.
- **The active config is computed once, at session start.** In
  `beginDictation()` Talkie resolves `appAdaptive` / `adaptiveStyle` /
  `cleanupLevel` and freezes them into `sessionCleanup`
  (`AppDelegate.swift:355-358`) — deliberately, so a mid-session toggle can't skew
  end-of-session accounting (re-read at `endDictation()`,
  `AppDelegate.swift:434-438`). **This is the value we must surface in the HUD.**
- **Resolution lives in `AppSettings`.** `appAdaptiveCleanup` (the master toggle),
  `cleanupLevel` (fixed path), and `appCleanupStyles: [String: String]` keyed by
  `AppCategory.rawValue` with `cleanupStyle(for:)` doing override→default lookup
  (`AppSettings.swift:114-211`). The target app's category comes from
  `captured.target.category` (`AppContext.swift:46`, `AppUsageStore.swift:37-55`).
- **HUD↔pipeline plumbing already exists.** `AppDelegate.sharedHUD` (a
  `@MainActor static weak`, `AppDelegate.swift:237`) routes engine/level callbacks
  to the pill; `showArming()`/`showListening()`/`updateLevel()` are the existing
  push points (`AppDelegate.swift:331,385,391`).
- **The hotkey funnel is a single ordered `AsyncStream`** (`AppDelegate.swift:244-266`)
  — the model for adding a "cycle style" edge.

**Missing (everything this feature builds):** any style/level display in the pill;
any interaction on the panel; a global "cycle cleanup" gesture; a write-back path
that updates the live session's resolved style; and per-app **profiles** (13) —
today there are only per-*category* styles, no per-bundle-id overrides.

## 4. Design & approach

### 4.1 The model: one resolved value, surfaced and mutable

Introduce a single Sendable value, `ActiveCleanup`, that captures the *resolved*
cleanup the current dictation is using — already computed in `beginDictation()`,
just not currently exposed:

- mode: adaptive (per-app) vs. fixed (global level)
- the concrete `CleanupStyle` (adaptive) **or** `CleanupLevel` (fixed)
- the resolving `AppCategory` + app display name (so the pill can say
  "Professional · Mail")
- whether it came from a per-app **profile** override, a category default, or the
  global level (for the on-brand subtitle and the write-back target)

The HUD shows this; the two switch gestures cycle it; cycling writes back through
the **profile resolver** (§4.4) so it sticks for this app next time.

### 4.2 Surfacing it in the pill (the calm, default state)

Extend `HUDModel` with `@Published var activeCleanup: ActiveCleanup?` and push it
from `beginDictation()` right after `sessionCleanup` is set
(`AppDelegate.swift:358`), via a new `hud.showCleanup(_:)`. The
`.listening`/`.transcribing` branch (`HUD.swift:225-230`) gains a compact,
**non-intrusive** style chip *to the right of the waveform*:

```
●  ▁▂▅▇▅▂  Professional
```

The chip is a `Capsule` in `Theme.coralWash` with `Theme.coral` text, an SF Symbol
per style (`wand.and.stars` family), 11pt. It must not grow the pill enough to
cover content — `fixedSize()` already lets the pill hug its content
(`HUD.swift:211`). Default state = glanceable only; the *interaction* is opt-in.

### 4.3 Interaction model (two affordances, no Settings trip)

Two complementary gestures, because the HUD panel and a global key serve different
moments:

**(A) Scroll-over-pill to cycle (discoverable, in-the-moment).** Flip the panel to
accept scroll while capturing. The panel is `ignoresMouseEvents = true`
(`HUD.swift:72`) — change to `false` **only during `.listening`/`.transcribing`**
and restore it on `showProcessing()`/`hide()` so the pill never eats clicks when
idle. Because the panel is `.nonactivatingPanel` (`HUD.swift:62`), a scroll won't
steal focus from the app you're dictating into — critical, the focused field must
stay focused for injection. A `scrollWheel`-handling `NSView` (or SwiftUI
`.onScroll`-equivalent via an `NSViewRepresentable` wrapper) on the chip cycles
through the ordered list (adaptive: the `CleanupStyle.allCases` minus `.off`;
fixed: `CleanupLevel.allCases`). Each tick: haptic-free spring bump on the chip,
update label, write back (§4.4). A **tap** on the chip toggles to `.off`/`.none`
and back (the "just give me verbatim, now" escape).

**(B) Global modifier-cycle hotkey (hands-on-keyboard).** A second hotkey edge —
e.g. **double-tap the activation key**, or a dedicated chord — cycles the style
*for the current/next session*. Route it through the SAME ordered `AsyncStream`
the press/release edges use (`AppDelegate.swift:244-266`) by adding a
`case cycleCleanup` to `DictationEvent`, so ordering vs. begin/end is guaranteed
on the MainActor. Reuse `HotKeyMonitor`'s existing left/right-modifier flag
decoding; the exact gesture is **feature 13/08's call** to keep the gesture
vocabulary coherent — this plan ships (A) as the MVP and exposes the hook for (B).

Mid-session change is allowed and *live*: cycling updates `sessionCleanup` in
place so `endDictation()` cleans with the new choice. The existing "freeze config
at start so accounting can't skew" rule (`AppDelegate.swift:350-358`) is preserved
by recording the **final** resolved choice at stop (the chip is the source of
truth at stop), not by forbidding the change.

### 4.4 The write-back path = feature 13's profile resolver

This is the unification seam. Cycling must persist so the user isn't re-cycling
every time they return to Mail. Two layers:

- **Today (category-level):** write the chosen `CleanupStyle` into
  `AppSettings.appCleanupStyles[category.rawValue]` (adaptive mode) or set
  `AppSettings.cleanupLevel` (fixed mode). This already persists and is read by
  `cleanupStyle(for:)` (`AppSettings.swift:204-211`). Ships in the MVP with **zero
  new persistence**.
- **With feature 13 (per-bundle-id profiles):** the write-back target becomes the
  resolved `AppProfile` for `target.bundleID`, falling back to category, falling
  back to global — the inheritance shape 13 defines (`_UNIFICATION.md` §6/13). The
  HUD calls one resolver/mutator that 13 owns; the HUD does **not** invent its own
  storage. Until 13 lands, the resolver is a thin shim over `appCleanupStyles`.

### 4.5 Flow summary

```
beginDictation()  ─► resolve ActiveCleanup (already done at :355-358)
                  ─► hud.showCleanup(active)        [NEW push point]
HUD pill          ─► shows  ●  ~~~  <Style chip>
user scrolls/taps chip (A)  ─►  cycle ActiveCleanup
   or global cycle key (B)  ─►  DictationEvent.cycleCleanup ─► cycle
cycle  ─► update sessionCleanup in place (live)
       ─► ProfileResolver.set(style, for: target)   [13 path; shim today]
endDictation()    ─► clean with the chip's current choice; account against it
```

## 5. New & changed files/types

**New — `Sources/Talkie/HUDCleanup.swift`** (or fold into `HUD.swift`):

```swift
/// The resolved cleanup the current dictation is using — the value the HUD shows
/// and the switcher mutates. Sendable so it crosses into the pipeline cleanly.
struct ActiveCleanup: Sendable, Equatable {
    enum Mode: Sendable, Equatable { case adaptive(CleanupStyle), fixed(CleanupLevel) }
    var mode: Mode
    var appName: String          // "Mail"
    var category: AppCategory    // for category-level write-back + the icon
    var source: Source           // .profile | .categoryDefault | .globalLevel

    enum Source: Sendable, Equatable { case profile, categoryDefault, globalLevel }

    /// "Professional", "Light" — pulled from the existing displayName.
    var label: String
    /// "Polished, like a work email." — the existing `detail`, for a subtitle.
    var detail: String
    /// SF Symbol per style/level (wand.and.stars family).
    var symbol: String

    /// The ordered choices the switcher cycles through, and the next one.
    func cycled(forward: Bool = true) -> ActiveCleanup
}
```

**Changed — `HUD.swift`:**
- `HUDModel`: add `@Published var activeCleanup: ActiveCleanup?`.
- `HUDController`: add `showCleanup(_:)`, `cycleCleanup(forward:)` (returns the new
  value so AppDelegate can write it back), and an `onCycle: ((ActiveCleanup) -> Void)?`
  callback. Toggle `panel.ignoresMouseEvents` with phase (false only while
  capturing).
- `HUDView`: add the style chip to the `.listening`/`.transcribing` branch
  (`HUD.swift:225-230`); a small `CleanupChip` subview + an
  `NSViewRepresentable` `ScrollCatcher` that forwards `scrollWheel`.

**Changed — `AppDelegate.swift`:**
- After `sessionCleanup = …` (`:358`): build `ActiveCleanup` and call
  `hud.showCleanup(active)`.
- Wire `hud.onCycle = { [weak self] new in self?.applyCleanupCycle(new) }`.
- `applyCleanupCycle(_:)` (new): update `sessionCleanup` in place + call the
  profile resolver/shim to persist.
- `DictationEvent`: add `case cycleCleanup`; handle it in the stream loop
  (`:250-256`) for the global-key path (B).

**New (or 13-owned) — `ProfileResolver`** (thin today): `resolve(for: TargetApp)
-> ActiveCleanup` and `set(_ style:/level:, for: TargetApp)`. Today it reads/writes
`AppSettings.appCleanupStyles` + `cleanupLevel`; feature 13 replaces the body with
per-bundle-id profiles, same signatures.

## 6. Data model & persistence

- **No new file in the MVP.** The switcher writes through existing
  `UserDefaults`-backed `AppSettings` keys: `appCleanupStyles` (per-category
  dictionary, `AppSettings.swift:118-120`) and `cleanupLevel`
  (`AppSettings.swift:109-111`). `register(defaults:)` already seeds them
  (`AppSettings.swift:151-202`); back-compat is automatic.
- **With feature 13:** the per-bundle-id profile store (13's
  `profiles.json` in `~/Library/Application Support/Talkie/`, `.atomic`,
  failure-tolerant decode per the house style in `_CURRENT_STATE.md` §3/§7) becomes
  the write target. Migration is additive — absent a profile, resolution falls
  through to `appCleanupStyles` then the global level, so existing users see no
  change until they cycle.
- `ActiveCleanup` itself is **ephemeral** (per-session, recomputed each
  `beginDictation`) — never persisted; only the resolved style/level is stored.

## 7. Unification contract

Per `_UNIFICATION.md` §6 (feature **14**):

**EXPOSES:**
- An in-HUD affordance to *view and cycle* the active cleanup style/level
  (the chip + the two gestures). Other surfaces (08 voice commands, a future
  menu-bar quick-switch) can call `HUDController.cycleCleanup`/`showCleanup` or the
  shared `ProfileResolver` to reflect/drive the same state.

**CONSUMES:**
- The existing **`glassEffect` HUD** (`HUD.swift` — reuse the panel, pill, spring,
  `Waveform`; do not invent a new window).
- **`CleanupEngine` levels/styles** (`CleanupLevel`/`CleanupStyle`, including their
  `displayName`/`detail` strings as labels).
- **`AppSettings`** (`appAdaptiveCleanup`, `cleanupLevel`, `appCleanupStyles`,
  `cleanupStyle(for:)`).
- **Feature 13 (per-app profiles)** — the switch resolves and writes through 13's
  profile path (per-bundle-id → category → global). This is the binding contract:
  *the HUD switcher does not own cleanup persistence; 13 does.* Until 13 ships, a
  shim over `appCleanupStyles` stands in, with identical resolver signatures so 13
  is a drop-in.

**Relationship to the Personal Context Graph (05):** feature 14 is a *control
surface*, not a graph consumer — it does not read or write `ContextGraphStore`.
The one indirect tie: when feature 13 later lets a per-app profile *filter*
`graph.biasPhrases(near:)` (`_UNIFICATION.md` §6/13), the HUD switch that changes
the active profile will, transitively, change which graph-biased terms the
recognizer gets next session. The HUD itself stays graph-agnostic — correct
separation of concerns.

## 8. UI / UX

- **Where:** the existing HUD pill (`HUD.swift`), in the `.listening`/
  `.transcribing` branch only. Nothing new in the main window.
- **Default (calm):** waveform + a small style chip to its right
  (`●  ▁▂▅▇  Professional`). Glanceable, not loud.
- **Interaction:** scroll over the pill to cycle; tap the chip to toggle
  off/verbatim; (B) optional global cycle key. On change: a brief spring bump
  (reuse the `BusyPulse`-style animation, `HUD.swift:291-303`) + the new label, and
  a one-line `detail` subtitle that fades after ~1.2s so it teaches once then gets
  out of the way.
- **On-brand tokens** (BRAND.md = philosophy, `DesignSystem.swift` = values):
  - One accent per view — the chip uses `Theme.coral` text on `Theme.coralWash`
    fill (`DesignSystem.swift:48,52`); the waveform keeps `Theme.coral`
    (`HUD.swift:229`). No second accent.
  - Squircle: `Capsule(style: .continuous)` matching the pill (`HUD.swift:209`),
    chip corner ~`Theme.Radius.chip` (9, `DesignSystem.swift:97`).
  - Calm spring: reuse `.spring(response: 0.28, dampingFraction: 0.8)`
    (`HUD.swift:200`).
  - Honest, second-person, sentence-case copy: the subtitle is the style's own
    `detail` ("Polished, like a work email.") — no invented claims, matching the
    "honest" pillar (BRAND.md §1) and `_UNIFICATION.md` §4.3.
  - Type: 11pt SF Pro for the chip (functional UI; serif is for titles/metrics
    only, `DesignSystem.swift:130-134`).
- **Accessibility:** the chip carries an `accessibilityLabel`
  ("Cleanup style: Professional. Scroll to change."); the global cycle key is the
  keyboard-only path.

## 9. Permissions / entitlements / Info.plist

**None.** No new TCC prompt, no entitlement, no Info.plist key. The panel is the
existing in-process `NSPanel`; making it accept scroll while capturing is a window
property change, not a new capability. (Note: a *global scroll* anywhere would need
Input Monitoring — but the scroll target here is Talkie's own panel, so it needs
nothing. The global *cycle key* (B) reuses the already-granted Input Monitoring
hotkey path.) Zero impact on the single `audio-input` entitlement.

## 10. Privacy posture

**Preserves zero-network completely.** This is a local UI control over a local
setting feeding a local on-device model (`CleanupEngine` is Foundation Models,
on-device — `CleanupEngine.swift:194,229`). Nothing is sent, logged remotely, or
phoned home. No data leaves the device; the invariant in `_CURRENT_STATE.md` §0 /
`_UNIFICATION.md` §4.1 holds unchanged.

## 11. Open-source genericity

- **No hardcoded personal stack.** The switcher cycles the generic, built-in
  `CleanupStyle`/`CleanupLevel` enums and writes to generic per-category/per-app
  settings — no Obsidian, no editor, no folder assumptions.
- **Zero-config default:** out of the box the chip just *shows* the resolved style
  (adaptive defaults from `AppSettings.defaultAppCleanupStyles`,
  `AppSettings.swift:193-202`); the user never has to configure anything to benefit.
- **Community extension:** because the switcher cycles `CleanupStyle.allCases`,
  anyone who adds a new style to the enum (`CleanupEngine.swift:85`) gets it in the
  HUD switcher for free — the chip, label, icon, and cycle order all derive from
  the enum. No HUD code to touch when extending the cleanup vocabulary.

## 12. Risks, edge cases, failure modes

- **Mid-session change vs. accounting integrity.** The "freeze at start" rule
  (`AppDelegate.swift:350-358`) exists so stats don't lie. *Mitigation:* allow the
  change but treat the **chip's value at stop** as the source of truth for both the
  actual cleanup and the accounting in `endDictation()`
  (`AppDelegate.swift:434-438`) — they always agree because both read the same
  final `sessionCleanup`.
- **Scroll stealing focus / breaking injection.** Injection needs the target field
  to stay focused. *Mitigation:* the panel is `.nonactivatingPanel`
  (`HUD.swift:62`) + `canJoinAllSpaces`/`stationary` (`HUD.swift:73`); a scroll on
  a non-activating panel does not change key focus. Verify explicitly (it's the
  riskiest interaction).
- **Pill eats clicks when idle.** *Mitigation:* set `ignoresMouseEvents = false`
  *only* during capture; restore `true` on `showProcessing()`/`showInserting()`/
  `hide()`.
- **Pill grows and covers content.** Long labels ("Professional") + waveform could
  widen the pill near the notch. *Mitigation:* `fixedSize()` keeps it content-sized
  and centered; cap the label, and on a narrow screen drop to the icon-only chip.
- **Cleanup unavailable (Apple Intelligence off).** `CleanupEngine.isAvailable`
  can be false (`CleanupEngine.swift:196-213`). *Graceful degradation:* the chip
  shows the would-be style but dimmed with a short note from
  `CleanupEngine.unavailableMessage`; cycling still updates the preference (so it
  takes effect once AI is enabled) but the session inserts raw — consistent with
  today's behavior (`AppDelegate.swift:465`).
- **`.off`/`.none` toggle confusion.** Tapping to verbatim must read unmistakably
  ("Verbatim" / a distinct icon), so the user knows the AI is off this session.
- **Per-category write-back surprises sibling apps.** In MVP, cycling for Mail
  changes the style for *all* mail apps (it's category-keyed). *Mitigation:* note
  this honestly in copy until feature 13's per-bundle-id profiles make it
  app-specific; that's the explicit upgrade path.

## 13. Testing & verification

- **No test target exists** (`_CURRENT_STATE.md` §8) — pure helpers should still be
  unit-testable if a target is added. Make `ActiveCleanup.cycled(forward:)` a pure
  function and (when added) unit-test the cycle order, off/none toggle, and
  source-resolution precedence (profile → category → global).
- **Manual / `/run`:** build via `scripts/build_app.sh` (use a stable
  `TALKIE_SIGN_ID` so TCC persists — `_CURRENT_STATE.md` §6), launch, then for each
  app category: hold the key in Mail vs. a code editor and confirm the chip shows
  "Professional" vs. "Faithful"; scroll to cycle and confirm the label changes and
  the inserted text reflects the new style; release and re-hold to confirm the
  choice **stuck** for that app; toggle Apple Intelligence off and confirm the
  dimmed/raw degradation.
- **Focus regression (critical):** dictate into a text field, scroll the chip, and
  confirm the field stays focused and injection still lands.
- **`/verify`:** confirm the chip appears only while capturing, the panel ignores
  mouse when idle, and zero network (grep stays clean per `_CURRENT_STATE.md` §0).

## 14. Effort & phasing

- **MVP slice (S–M):** `ActiveCleanup` + chip display in the pill +
  `hud.showCleanup` push from `beginDictation` + **scroll-to-cycle (A)** writing to
  the existing `appCleanupStyles`/`cleanupLevel`. Visible-and-switchable, zero new
  persistence, zero new permissions. **This alone satisfies the brief.**
  - Display + push point: **S**.
  - Scroll-catcher + `ignoresMouseEvents` phasing + write-back: **M**.
- **Full feature (M–L):**
  - Global modifier-cycle key (B) through the event stream: **M** (coordinate the
    gesture with 08/13).
  - Per-bundle-id write-back via feature 13's `ProfileResolver`: **M**, but gated on
    13 landing.
  - Polish: degraded state, off/verbatim toggle, fade-out subtitle, accessibility,
    narrow-screen icon-only fallback: **S–M**.

## 15. Dependencies & interactions

- **Needs (soft):** **feature 13 (per-app profiles)** for the *sticky-per-app*
  write-back — the contract binds 14 to 13's resolver. 14 ships a working
  category-level shim without 13, so it's not hard-blocked. **`CleanupEngine`**
  (existing) and **`AppSettings`** (existing) are hard dependencies, both present
  today.
- **Enables / complements:** **08 voice commands** — once a command layer exists,
  "switch to professional" becomes another way to drive the same
  `cycleCleanup`/resolver; the HUD chip is the visible feedback for it.
- **Overlaps (coordinate):** the **gesture vocabulary** (double-tap activation key,
  chords) is shared with 08/13/12 — pick the cycle gesture (B) jointly so Talkie
  doesn't accumulate conflicting modifier meanings. The **HUD real estate** is
  shared with any future in-HUD affordance (e.g. 02's meeting status, 03's
  consent) — keep the chip compact and phase-gated so the pill stays calm.
- **No interaction with:** 05 graph (control surface only — see §7), meetings
  pipeline, or any networked module.
