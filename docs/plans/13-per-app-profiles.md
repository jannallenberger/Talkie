# 13 — Per-app profiles

> Feature plan. Read `_CURRENT_STATE.md` (ground truth) and `_UNIFICATION.md`
> (the spine) first. All paths absolute; `file:line` anchors point at `main`
> (HEAD `5f747fb`) unless marked **[branch]**.

## 1. Summary

Extend today's per-`AppCategory` cleanup-*style* override into a full **per-bundle-id
profile** — vocabulary subset, cleanup level/style, insertion mode, capitalization,
filler-removal, and (later) active macros — with a clean global-default → per-app
override resolution and a Settings list of apps you can override one at a time.

## 2. Why it matters

Dictating a Slack message and dictating into Xcode are different acts. Today Talkie
adapts only the cleanup *personality* and only by coarse category (all chat apps get
"friendly", all editors get "faithful"). A user who wants verbatim insertion +
type-mode in their terminal but polished paste-mode in Mail cannot express that. Real
per-app profiles make Talkie feel like it *knows where you are* — the same instinct
that powers context-awareness and vibe-coding, now applied to behaviour, not just
spelling.

Strategically this is a small but load-bearing tributary to the one thesis: the
profile is the place where the **personal context graph gets filtered per surface**.
A profile says "when I'm in this app, bias toward *these* people/terms" — so
`graph.biasPhrases(near: app)` returns a Slack-flavoured set in Slack and a
codebase-flavoured set in Cursor. Wispr Flow has a global dictionary and one global
style; it cannot key vocabulary, insertion, and (eventually) macros to the app
*and* draw those terms from a shared on-device brain. This is a structural advantage
that compounds with features 05/11/14, not a standalone toggle.

## 3. Current state in the code

What exists today is a **partial, category-level** version of this feature:

- **`AppSettings.appCleanupStyles: [String: String]`** (`AppSettings.swift:118-120`)
  — a dictionary keyed by `AppCategory.rawValue` (8 coarse buckets), value is a
  `CleanupStyle.rawValue`. Seeded with sensible defaults
  (`defaultAppCleanupStyles`, `:193-202`: coding/terminal→faithful, mail→professional,
  chat→friendly, …). Resolution helper `cleanupStyle(for: AppCategory)`
  (`:205-211`) returns user override else default else `.neutral`.
- **`appAdaptiveCleanup: Bool`** (`:114-116`) — the master "Adapt the style to the
  app" switch. When ON, the per-category style path is used; when OFF, a single
  global `cleanupLevel` (`:109-111`) applies everywhere.
- **`AppCategory`** (`AppUsageStore.swift:6-56`) — the 8-bucket enum + a heuristic
  `classify(bundleID:name:)` (`:37-55`) that pattern-matches bundle ids/names. This
  is the ONLY granularity today; there is no per-bundle-id behaviour anywhere.
- **`TargetApp`** (`AppContext.swift:6-12`) — `bundleID: String?`, `name`,
  `category`. Captured per session by `ContextCapture.capture(...)`
  (`AppContext.swift:41-61`) from `NSWorkspace.shared.frontmostApplication`. **The
  exact bundle id is already available** at capture time — it is simply collapsed to
  a category for behaviour decisions.
- **The resolution site** is `AppDelegate.beginDictation()`
  (`AppDelegate.swift:355-358`): it reads `appAdaptive`, computes
  `adaptiveStyle = settings.cleanupStyle(for: captured.target.category)`, and
  `cleanupLevel`, snapshotting all three into `sessionCleanup` so a mid-session
  toggle can't skew accounting. `endDictation()` (`:436-438`) reuses that snapshot.
- **Other behaviours are global only:** `insertionMode` (`:83-85`), `autoCapitalize`
  (`:99-101`), `cleanupFillers` (`:102-104`) are single scalars read at
  `endDictation()` (`AppDelegate.swift:423-425`). They are NOT per-app.
- **Vocabulary** (`DictionaryStore.swift`) is one global set; the bias union in
  `beginDictation()` (`:344-347`) is `vocab ∪ mined phrases ∪ project filenames`,
  capped at 180. No per-app subset.
- **Settings UI:** `CleanupSettings` (`SettingsView.swift:537-570`) → when adaptive
  is on, `AppStylePickers` (`:363-391`) renders one `Picker` per `AppCategory`. The
  Settings index is `SettingsHome` (`:399-476`) with a `SettingsRoute` enum
  (`:393-395`) and `SubPage` scaffold (`:479-497`).

**Honest gap statement:** the *style*-by-*category* slice is built and shipping.
**Everything else is missing** — there is no per-bundle-id keying, no profile object,
no per-app insertion/capitalization/fillers/vocabulary/level, and no app-list UI. The
data is there (we capture `bundleID`); the model and UI to act on it are not.

## 4. Design & approach

### 4.1 Shape: a resolved profile, computed by inheritance

Introduce an **`AppProfile`** value type (the per-app *override sheet* — every field
optional, `nil` = "inherit") and a **`ResolvedProfile`** (every field concrete, the
thing the pipeline actually consumes). A new `@MainActor` store,
**`AppProfileStore`**, owns the override sheets keyed by bundle id and resolves
against the global `AppSettings` defaults.

Resolution is a pure two-level merge (global default → per-app override), matching
the exact shape today's `cleanupStyle(for:)` already uses, just widened to all
behaviour fields and keyed by bundle id instead of category:

```
ResolvedProfile.field = appProfile.field ?? globalDefault.field
```

There is a deliberate **third, implicit tier** for cleanup style: if an app has no
explicit per-bundle override but `appAdaptiveCleanup` is on, fall back to the
**category** default (`appCleanupStyles[category]`). So the precedence for cleanup
is: per-app override → (if adaptive) per-category style → global cleanup level. This
keeps every existing user's behaviour byte-for-byte identical after migration
(§6) while letting a power user pin one specific app.

### 4.2 Where resolution happens

`AppDelegate.beginDictation()` already captures `TargetApp` (with `bundleID`) and
already snapshots cleanup config into `sessionCleanup` at session start
(`AppDelegate.swift:355-358`). We extend that snapshot to a full `ResolvedProfile`:

```
let captured = ContextCapture.capture(...)               // unchanged
let profile  = profiles.resolve(for: captured.target, settings: settings)
sessionProfile = profile                                  // replaces sessionCleanup tuple
```

`endDictation()` reads `sessionProfile` for cleanup style/level (replacing the tuple
at `:436-438`), **insertion mode** (replacing `settings.insertionMode` at `:425`),
**autoCapitalize** (replacing `:423`), and **removeFillers** (replacing `:424`). The
existing "snapshot at start so a mid-session toggle can't skew accounting" invariant
is preserved — we just snapshot more fields into one object instead of three locals.

This is a **surgical change**: the begin/end pipeline keeps its exact control flow,
generation tokens, and ordering; only the *source* of four config values moves from
`settings.*` / `cleanupStyle(for:category)` to `sessionProfile.*`.

### 4.3 Per-app vocabulary subset & graph filtering

A profile may carry `vocabularyTagFilter: [String]?` (nil = all). MVP keeps it
simple: a profile can name a subset of the **global** dictionary vocabulary to bias
toward in that app (so terminal dictation isn't biased toward your contacts' names).
The bias union in `beginDictation()` (`:344-347`) becomes:

```
var bias = profiles.biasVocabulary(for: target, dictionary: dictionary)   // filtered subset
bias.append(contentsOf: captured.phrases)
if vibeCoding { bias.append(contentsOf: snapshot.biasPhrases) }
```

Per the Unification contract (§7), once feature 05 lands, `biasVocabulary` is
replaced by `graph.biasPhrases(near: target)` — the profile becomes a *filter
parameter* on the graph query rather than a second vocabulary store. We design the
`AppProfileStore` API so this is a one-line swap (§5).

### 4.4 App identity & detection

`ContextCapture.capture` already returns the live `bundleID` from
`NSWorkspace.shared.frontmostApplication.bundleIdentifier` (`AppContext.swift:43-47`).
No new detection code is needed for resolution. For the **UI** (listing apps to add
an override for), we need a way to pick a running/installed app:

- **Running apps:** `NSWorkspace.shared.runningApplications` filtered to
  `.activationPolicy == .regular` → `(bundleID, localizedName, icon)`.
- **Installed apps (optional, M):** an `NSOpenPanel` pointed at `/Applications`
  returning a `.app` bundle → read `Bundle(url:).bundleIdentifier` + name + icon.
- **Apps you've already dictated into:** `AppUsageStore.apps` is keyed by bundle id
  with display names (`AppUsageStore.swift:83`) — the *best* seed list, because it's
  exactly the apps the user actually uses. The "Add app" picker shows these first.

App icons come from `NSWorkspace.shared.icon(forFile:)` /
`NSRunningApplication.icon` — purely cosmetic, lazy, never required.

## 5. New & changed files/types

### New: `Sources/Talkie/AppProfile.swift`

```swift
import Foundation

/// A per-app *override sheet*. Every field is optional: nil = inherit the global
/// default (or, for cleanup style, the per-category default). Keyed by bundle id.
struct AppProfile: Codable, Identifiable, Sendable, Hashable {
    var bundleID: String                 // the key, e.g. "com.tinyspeck.slackmacgap"
    var displayName: String              // freshest known name, for the UI
    var id: String { bundleID }

    // Behaviour overrides (nil = inherit)
    var cleanupStyle: CleanupStyle?      // overrides the adaptive/category path
    var cleanupLevel: CleanupLevel?      // used when adaptive is off
    var insertionMode: InsertionMode?
    var autoCapitalize: Bool?
    var removeFillers: Bool?

    /// Subset of global vocabulary terms to bias toward in this app (nil = all).
    /// Post-feature-05 this becomes a tag/entity filter on the graph.
    var vocabularyFilter: [String]?

    /// Macro ids active in this app (feature 11; nil/[] = all). Parked field — the
    /// model carries it now so 11 needs no migration later.
    var activeMacroIDs: [String]?

    /// Convenience: does this profile actually override anything?
    var isEmpty: Bool {
        cleanupStyle == nil && cleanupLevel == nil && insertionMode == nil
        && autoCapitalize == nil && removeFillers == nil
        && (vocabularyFilter?.isEmpty ?? true) && (activeMacroIDs?.isEmpty ?? true)
    }
}

/// The fully-resolved, concrete config the dictation pipeline consumes. No
/// optionals — every field decided by global-default → category → per-app merge.
struct ResolvedProfile: Sendable {
    var appAdaptiveCleanup: Bool
    var cleanupStyle: CleanupStyle       // meaningful when appAdaptiveCleanup
    var cleanupLevel: CleanupLevel       // meaningful when !appAdaptiveCleanup
    var insertionMode: InsertionMode
    var autoCapitalize: Bool
    var removeFillers: Bool
    var bundleID: String?
    var category: AppCategory
}
```

### New: `Sources/Talkie/AppProfileStore.swift`

```swift
import Foundation

/// Owns the per-app override sheets and resolves them against AppSettings.
/// House style: @MainActor ObservableObject, atomic JSON, failure-tolerant decode.
@MainActor
final class AppProfileStore: ObservableObject {
    @Published private(set) var profiles: [String: AppProfile] = [:]   // keyed by bundleID
    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("app_profiles.json")
        load()
    }

    // --- The resolution surface the pipeline calls (keep stable) ---

    /// Two-level (three-tier for cleanup) merge: per-app → per-category → global.
    func resolve(for app: TargetApp, settings: AppSettings) -> ResolvedProfile {
        let p = app.bundleID.flatMap { profiles[$0] }
        let categoryStyle = settings.cleanupStyle(for: app.category)   // existing helper
        return ResolvedProfile(
            appAdaptiveCleanup: settings.appAdaptiveCleanup,
            cleanupStyle: p?.cleanupStyle ?? categoryStyle,
            cleanupLevel: p?.cleanupLevel ?? settings.cleanupLevel,
            insertionMode: p?.insertionMode ?? settings.insertionMode,
            autoCapitalize: p?.autoCapitalize ?? settings.autoCapitalize,
            removeFillers: p?.removeFillers ?? settings.cleanupFillers,
            bundleID: app.bundleID,
            category: app.category
        )
    }

    /// Bias vocabulary for an app: the filtered subset, else all global vocab.
    /// (Post-05: forwards to graph.biasPhrases(near:) — see §7.)
    func biasVocabulary(for app: TargetApp, dictionary: DictionaryStore) -> [String] {
        let all = dictionary.contextualPhrasesSnapshot()
        guard let filter = app.bundleID.flatMap({ profiles[$0]?.vocabularyFilter }),
              !filter.isEmpty else { return all }
        let set = Set(filter.map { $0.lowercased() })
        return all.filter { set.contains($0.lowercased()) }
    }

    // --- Mutations (UI) ---
    func upsert(_ profile: AppProfile)             // delete the row if profile.isEmpty
    func remove(bundleID: String)
    func profile(for bundleID: String) -> AppProfile?

    // --- persistence ---
    private func load() { /* try? decode [String:AppProfile]; tolerate failure */ }
    private func save() { /* .atomic write */ }
}
```

### Changed files

- **`AppDelegate.swift`**
  - Add `let profiles = AppProfileStore()` next to the other stores (`:1-15`).
  - `beginDictation()`: replace the three cleanup locals + `sessionCleanup` tuple
    (`:355-358`) with `let profile = profiles.resolve(for: captured.target,
    settings: settings); sessionProfile = profile`. Replace the bias-vocab line
    (`:344`) with `profiles.biasVocabulary(for: captured.target, dictionary:
    dictionary)`.
  - `endDictation()`: read `insertionMode`/`autoCapitalize`/`removeFillers` and
    cleanup style/level from `sessionProfile` instead of `settings.*` /
    `cleanupStyle(for:)` (`:423-438`).
  - Replace the `sessionCleanup` property (`:47`) with
    `private var sessionProfile: ResolvedProfile?`.
  - Pass `profiles` into `MainWindowController` (add a parameter).
- **`SettingsView.swift`**
  - Add a `SettingsRoute.appProfiles` case (`:393-395`); add a row in `SettingsHome`
    (`:410-428`) and a `subpage` branch (`:464-475`).
  - New views: `AppProfilesSettings` (the app list + "Add app"),
    `AppProfileRow` (one app row → pushes), `AppProfileDetail` (the per-app
    override form: cleanup style/level, insertion, capitalize, fillers, vocab
    subset chips). Reuse `SubPage`, `FlowLayout`, `talkieCard`, the existing
    `Picker` patterns from `CleanupSettings`/`ActivationSettings`.
  - Thread `AppProfileStore` through `MainView`/`MainWindowController` init
    (`:60-88`) the way `dictionary` already is.
- **`AppSettings.swift`** — no schema change required (profiles live in their own
  store). Optionally add a computed `globalDefaultsProfile` for the detail view's
  "inherit (showing global)" placeholder text.

### New (optional, M): `Sources/Talkie/AppPicker.swift`
A small `@MainActor enum` returning `[(bundleID, name, NSImage?)]` from
`NSWorkspace.runningApplications` + `AppUsageStore.apps`, plus an `NSOpenPanel`
helper for installed apps.

## 6. Data model & persistence

- **File:** `~/Library/Application Support/Talkie/app_profiles.json` (via
  `AppPaths.supportDirectory()`, matching every other store —
  `_CURRENT_STATE.md` §3). `.atomic` write; failure-tolerant `try?` decode;
  optional fields throughout for forward/back-compat (house style,
  `_CURRENT_STATE.md` §7).
- **Format:** `[String: AppProfile]` keyed by bundle id (mirrors
  `appusage.json`'s shape). Every override field optional so the file is sparse —
  an app with only an insertion override stores only that.
- **Migration / back-compat (critical, zero behaviour change):**
  - `appCleanupStyles` (per-category, in `UserDefaults`) is **left untouched**.
    `resolve(...)` still consults it via the existing `settings.cleanupStyle(for:)`
    as the middle tier. So an existing user with category styles gets *identical*
    behaviour — the new per-bundle layer is purely additive and starts empty.
  - First launch: `app_profiles.json` absent → `profiles == [:]` → `resolve`
    returns exactly today's resolution for every app. No seeding, no prompts.
  - `AppProfile` decode tolerates missing fields (`activeMacroIDs`,
    `vocabularyFilter` were added "later" by construction). New fields added in
    future features (macros) decode as nil on old files.
- **Pruning:** profiles are user-curated, kept indefinitely (like the dictionary).
  Offer a "Reset this app to defaults" (delete the row) in the detail view;
  `upsert` auto-deletes a row that becomes `isEmpty`.

## 7. Unification contract

Per `_UNIFICATION.md` §6, contract **13 — Per-app profiles**:

> **Exposes:** a resolved profile (dictionary subset, cleanup level/style, insertion
> mode, capitalization, active macros) keyed by bundle id.
> **Consumes:** `AppContext` (active app), `AppSettings` (global default → per-app
> override resolution), `DictionaryStore`, `CleanupEngine`/`CleanupStyle`.
> **Note:** extends today's per-`AppCategory` `appCleanupStyles` to per-bundle-id
> full profiles, same inheritance shape. Profile selection of bias terms should
> filter the Graph's `biasPhrases` for that app.

This plan honors it exactly:

- **EXPOSES — `ResolvedProfile` keyed by bundle id**, via
  `AppProfileStore.resolve(for:settings:)`. The fields are precisely the contracted
  set (cleanup level/style, insertion mode, capitalization, vocab subset, + a
  parked `activeMacroIDs` for macros). This is the single object features 14
  (HUD style switcher — "shows the resolved per-app profile") and 11 (macros —
  "which voice-macros are active") read. **14's note** ("the switch writes through
  the same settings/profile path (13)") is satisfied: the HUD switcher will call
  `AppProfileStore.upsert` for the current app's `cleanupStyle`, not a separate
  path.
- **CONSUMES:** `AppContext` (`TargetApp.bundleID`), `AppSettings` (the global
  defaults forming the inheritance root — uses the *existing*
  `settings.cleanupStyle(for:)` as the middle tier so the contract's "same
  inheritance shape" is literal), `DictionaryStore` (vocab subset),
  `CleanupEngine`/`CleanupStyle` (the resolved style/level fed unchanged into the
  existing cleanup call at `AppDelegate.swift:466-470`).
- **The Graph hook (§1, §1.6 of the spine — the keystone):** the contract's
  "Profile selection of bias terms should filter the Graph's `biasPhrases` for that
  app" is the single most important integration. `biasVocabulary(for:dictionary:)`
  is designed as the *seam*: when feature **05** lands, its body becomes
  `graph.biasPhrases(limit:, near: app)` and the profile's `vocabularyFilter`
  becomes a parameter narrowing that query (e.g. only `.term`/`.person` entities the
  profile whitelists). The pipeline call site in `beginDictation` does not change —
  this feature *replaces the ad-hoc bias union* (`AppDelegate.swift:344-347`) that
  the spine (§1.6) explicitly calls out for replacement, doing it through one
  injected object instead of inline set math. We do **not** build a second
  vocabulary store; the profile is a filter, the graph/dictionary is the source.
- **No protocol fork:** this feature adopts no `_UNIFICATION.md` §2 protocol of its
  own — it is a *consumer/configurator* of the pipeline, sitting beside
  `AppSettings`. It must not reimplement `CleanupStyle` resolution; it extends the
  existing one.

## 8. UI / UX

A new Settings subpage, reached from the `SettingsHome` index
(`SettingsView.swift:399-476`):

- **Index row:** under "Cleanup & style", add "Per-app profiles" with subtitle
  "N apps customized" (or "Same everywhere" when empty). Icon `app.badge`,
  `Theme.featherPlum` tint (matching the cleanup row's family —
  `DesignSystem.swift:65`). Route `SettingsRoute.appProfiles`.
- **List page (`AppProfilesSettings`):** a `SubPage` (serif `PageHeader`,
  `DesignSystem.swift:122` `talkieDisplay`) listing each overridden app as a
  `talkieCard` row (`DesignSystem.swift:159`) — icon, name, and a one-line summary
  of what's overridden ("Faithful · Type · no caps"). A prominent "Add app…" button
  opens a picker seeded from `AppUsageStore` (apps you actually use) then running
  apps then "Choose from /Applications…". An `Eyebrow` (`DesignSystem.swift:173`)
  reading "PER-APP OVERRIDES". Empty state: a calm line "Talkie behaves the same
  everywhere until you add an app." (honest, second-person — `BRAND.md` voice).
- **Detail page (`AppProfileDetail`):** a grouped `Form` (like `CleanupSettings`,
  `:537-570`) with each control offering an explicit **"Inherit (Global: …)"**
  option so the user always sees what they'd fall back to — no hidden state. Pickers
  for cleanup style/level, insertion mode (reuse `InsertionMode.allCases`),
  toggles-with-inherit for capitalize/fillers, and a `FlowLayout`
  (`DesignSystem.swift:228`) chip set to pick the vocabulary subset from the global
  dictionary. A "Reset to defaults" button (deletes the row). One accent
  (`Theme.coral`/blue) per view (`BRAND.md`); feather tints only on the per-control
  icons; squircle cards + whisper shadow via `talkieCard`. No new visual language.
- **Honesty:** every control labels its inherited value; nothing invents a setting
  the app doesn't actually use. Calm springs, sentence case, second person.

## 9. Permissions / entitlements / Info.plist

**None.** Bundle id, name, and icon of the frontmost/running/installed apps come
from `NSWorkspace` / `NSRunningApplication` / `Bundle`, which need no entitlement and
no TCC prompt. The `NSOpenPanel` "choose from /Applications" path is a standard,
user-initiated file dialog (no `com.apple.security.files.user-selected` entitlement
is needed because the current build is **not** sandboxed —
`Resources/talkie.entitlements` carries only audio-input, `_CURRENT_STATE.md` §6;
under the future sandboxed flavour from feature 15, the open-panel grant is the
standard user-selected-read exception, which the App Sandbox grants implicitly for
panel-chosen files). No new Info.plist keys. Reads stay read-only.

## 10. Privacy posture

**Zero-network preserved, trivially.** Everything is local: one JSON file in
Application Support, `NSWorkspace` reads, the existing on-device cleanup. No network
code is added (the verified invariant — `_CURRENT_STATE.md` §0 — holds). The profile
file lists bundle ids and the user's chosen behaviours; it never leaves the machine.
This feature *strengthens* the privacy story: per-app vocabulary scoping means
sensitive terms can be confined to the apps where they belong, and (post-05) the
profile is exactly the lever that lets a user say "don't bias this app with my
people/commitments at all." It introduces no new sensitive read — `bundleID` was
already captured for the usage dashboard.

## 11. Open-source genericity

- **No hardcoded personal stack.** The model is generic: any bundle id, any of the
  existing styles/levels/modes. No app is special-cased; the seed list is *the
  user's own* `AppUsageStore`, not a curated favourites list.
- **Zero-config default is "no profiles."** An empty `app_profiles.json` (the
  default) reproduces today's exact behaviour. The feature is invisible until a user
  opts into a single override — nothing to configure to get a working app.
- **The `AppCategory` heuristic stays the sane fallback** for apps with no override,
  so the community benefits from per-category defaults without any setup.
- **Extension point:** because resolution is one pure function over a `[String:
  AppProfile]` plus `AppSettings`, a contributor adding a new behaviour field (e.g.
  per-app language, per-app macros for 11) adds one optional field to `AppProfile`
  and one line to `resolve` — no UI or pipeline surgery. The `vocabularyFilter`
  → graph-query swap (§7) is the documented hook for feature 05.

## 12. Risks, edge cases, failure modes

- **Apps with no bundle id** (`TargetApp.bundleID == nil` — rare, e.g. some helper
  processes). `resolve` falls through to the category/global tiers (the `flatMap`
  yields nil → no per-app override). Graceful: behaves exactly as today. The UI
  cannot create a profile for a nil-bundle app (keyed by bundle id), which is
  correct.
- **Renamed/relocated apps:** profiles key on bundle id (stable across renames), and
  `displayName` is refreshed on every capture/upsert, so a moved or renamed app
  keeps its profile. An uninstalled app's profile lingers harmlessly (shown greyed;
  "Reset" removes it).
- **Conflicting tiers / surprise:** the detail page's explicit "Inherit (Global: …)"
  labels make precedence visible, mitigating the classic "why is this app behaving
  oddly" confusion. The summary string on each row states the *effective*
  overrides.
- **Mid-session change:** unchanged invariant — the resolved profile is snapshotted
  at `beginDictation` into `sessionProfile`; a toggle mid-session can't skew the
  in-flight session's accounting (the reason the `sessionCleanup` snapshot exists
  today, `AppDelegate.swift:45-47`).
- **Verbatim/faithful + type-mode in terminals:** a real per-app combo this enables;
  must verify type-mode injection (`TextInjector` per-character path) still respects
  the secure-field fallback (`_CURRENT_STATE.md` §1.6) — it does, the fallback is in
  `TextInjector`, upstream of the mode choice.
- **Vocabulary filter pointing at deleted terms:** `biasVocabulary` intersects with
  the *current* global vocab, so stale filter entries are silently ignored (no
  crash, just no bias). The chip UI shows only terms that still exist.
- **Empty profile rows:** `upsert` deletes any profile that becomes `isEmpty`, so the
  list never accumulates no-op rows.

## 13. Testing & verification

- **Unit (pure, add a test target — none exists today, `_CURRENT_STATE.md` §8):**
  `resolve` precedence — per-app over category over global; cleanup three-tier order;
  `biasVocabulary` filtering + stale-term tolerance; `AppProfile.isEmpty`;
  encode/decode round-trip with missing optional fields (back-compat).
- **Manual (the `/run` path):**
  1. Fresh state (delete `app_profiles.json`) → dictate into several apps → confirm
     behaviour identical to pre-feature (migration safety).
  2. Add a profile for Terminal: faithful + type + no-caps + no-fillers. Dictate into
     Terminal → verify verbatim, character-typed, lowercased, fillers kept. Dictate
     into Mail → verify global/category behaviour unchanged.
  3. Add an insertion-only override for one app → confirm only insertion changes,
     everything else inherits (check "Inherit (Global: …)" labels).
  4. Set a vocab subset for one app → confirm the recognizer biases only those terms
     there (inspect via a deliberately ambiguous term).
  5. Reset an app → row disappears, behaviour reverts.
- **Verify hooks:** the HUD already surfaces the active phase; feature 14 will show
  the resolved style — until then, confirm via the History tab `appName`/`appCategory`
  and the inserted text. Confirm `grep -rniE "URLSession|http"` over `Sources/` still
  returns nothing (privacy regression guard).

## 14. Effort & phasing

| Sub-step | Size | Notes |
|---|---|---|
| `AppProfile`/`ResolvedProfile` types + `AppProfileStore` (resolve, persistence) | **S** | Pure value types + one store; mirrors `AppUsageStore`. |
| Wire `resolve` into begin/end pipeline (replace 3 locals + tuple) | **S** | Surgical; preserves the snapshot invariant. |
| `biasVocabulary` + replace the bias union | **S** | One call-site swap; graph seam documented. |
| Settings: index row + list page + detail form | **M** | New SwiftUI views; reuse `SubPage`/`Form`/`FlowLayout`/`talkieCard`. |
| App picker (running + usage seed) | **S** | `NSWorkspace`. |
| App picker (installed via `NSOpenPanel`) | **S** | Optional polish. |
| Unit test target + tests | **M** | First tests in the repo; resolution + back-compat. |
| Macro field wiring (`activeMacroIDs`) | **deferred to 11** | Field parked now; UI later. |

**MVP slice (S+S+M):** the model+store, pipeline wiring for cleanup style/level +
insertion + capitalize + fillers, and a minimal list/detail UI seeded from
`AppUsageStore`. Ship this; it's the whole user-facing win.
**Full feature:** + vocabulary subset (graph-aware after 05), installed-app picker,
macro activation (with 11), and the HUD switcher write-back (with 14).

## 15. Dependencies & interactions

- **Builds on (already shipped):** `AppContext`/`TargetApp` (bundle id capture),
  `AppSettings` (`appCleanupStyles`, the inheritance root), `AppCategory`
  (`classify`), `CleanupEngine`/`CleanupStyle`/`CleanupLevel`, `DictionaryStore`,
  `AppUsageStore` (the seed list), `TextInjector` (insertion modes). No
  dependency on the unmerged far-end branch.
- **Enabled-by / strengthened-by:**
  - **05 Context Graph (keystone, build-first):** turns `biasVocabulary` into a
    per-app filter on `graph.biasPhrases(near:)`; this feature's `vocabularyFilter`
    is the parameter. Plan the seam now, swap the body when 05 lands.
- **Enables / is consumed by:**
  - **14 HUD style switcher:** reads the `ResolvedProfile` to display the active
    style and writes back through `AppProfileStore.upsert` (same path — no fork).
  - **11 Voice macros:** the parked `activeMacroIDs` field is the per-app macro
    activation surface; 11 fills in the UI and the `MacroIntent` reads it.
- **Overlaps to avoid divergence:** must NOT reimplement `CleanupStyle` resolution
  (extend `settings.cleanupStyle(for:)`); must NOT add a second vocabulary store
  (filter the dictionary/graph). Insertion/capitalize/fillers move from global
  scalars to *resolved* values — every reader must go through `sessionProfile`, not
  re-read `settings.*`, to stay consistent.
