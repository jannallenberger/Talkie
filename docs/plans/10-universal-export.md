# 10 — Universal note export / sync (pluggable, not Obsidian-locked)

> Engineer-ready plan. Grounded in `main` (HEAD `5f747fb`) + the
> `feat/meeting-far-audio` branch. Read `_CURRENT_STATE.md` (ground truth) and
> `_UNIFICATION.md` §2.3 + the feature-10 contract (line ~732) first — this plan
> honors both. All paths absolute.

---

## 1. Summary

A pluggable `NoteDestination` export layer that lets a user send Talkie's notes
(meetings today; dictations + the daily Brief optionally) into **any** folder or
note system — with optional, off-by-default YAML front-matter, `[[wikilinks]]`,
and tags — while keeping the zero-config, no-third-party-app default (`~/Talkie
Meetings/` plain Markdown) exactly as it works now.

---

## 2. Why it matters

Talkie's strategic moat is *one private brain feeding the user's real tools*.
Granola and Wispr Flow both end the value chain at *their* cloud — your notes
live in their app, behind their subscription, on their servers. Talkie's bet is
the opposite: the note is **yours**, on **your** disk, in **your** system, the
instant it's made. This feature is the open seam that delivers that promise
without betraying the OSS-genericity invariant — it must serve the Obsidian user,
the Logseq user, the Notion user, and the "I just want a folder" user equally,
with no personal stack hardcoded. It is also the export side of feature 02 (the
Granola-magic fused note) and the surfacing layer for feature 05's entity graph:
a wikilink-aware destination can cross-link the people/projects the brain
extracted, turning a flat transcript into a navigable knowledge node — something
no separate-cloud competitor can do because they don't have a local graph to link
against.

---

## 3. Current state in the code

What exists today (honest):

- **Meetings already write Markdown.** `MeetingStore.writeMarkdown(_:)`
  (`/Users/jann/Talkie/Sources/Talkie/Meeting.swift:88-109` on main; branch
  version adds `participants`/`source`) composes a fixed string: YAML front-matter
  (`title`, `date`, `duration_min`, `source` — branch adds `participants`) + a
  `## Summary` section + a `## Transcript` section, written `.atomic` to
  `~/Talkie Meetings/<fileName>`. `fileName(for:)` (`Meeting.swift:80-84`) is a
  hardcoded `yyyy-MM-dd-HHmm-meeting.md` scheme. The `.md` is the durable copy;
  `meetings.json` is a lightweight index.
- **The destination root is fixed.** `AppPaths.meetingsDirectory()`
  (`/Users/jann/Talkie/Sources/Talkie/AppPaths.swift:17-22`) hardcodes
  `~/Talkie Meetings/` — deliberately a plain home folder (not TCC-protected
  `~/Documents`) so it's trivial to point Claude at. There is **no setting** to
  change it.
- **No export concept beyond meetings.** Dictations land only in `HistoryStore`
  (`/Users/jann/Talkie/Sources/Talkie/HistoryStore.swift`, JSON, 7-day retention)
  and are copyable as text; they are never written to a note file. The daily Brief
  (`ContextSummary.swift`) is never exported.
- **No protocol, no templating, no front-matter/wikilink/tag options.** Front-matter
  is the single hardcoded block above; there is no toggle, no template, no tags,
  no links.
- **Settings architecture to extend:** `SettingsView.swift` uses
  `SettingsHome` → `NavigationLink(value: SettingsRoute)` → `SubPage` (a serif
  title over a `.grouped` `Form`). `SettingsRoute` (`SettingsView.swift:393-395`)
  is the enum to add a case to. `AppSettings` (`AppSettings.swift`) is the
  UserDefaults-backed `@MainActor ObservableObject` for scalar prefs.

So: **the producer (meeting Markdown) exists and is good; the pluggability,
configurability, and the second producer (dictations) are missing.** This feature
generalizes the existing writer behind a protocol rather than rewriting it.

Relevant brand tokens for the UI section: `Theme.coral` (brand blue accent),
`Theme.featherGreen` (success), `Theme.surface`/`talkieCard()`, `Eyebrow`,
`FlowLayout` (chips), `PageHeader`/`SubPage` scaffolds, `Font.talkieDisplay` —
all in `/Users/jann/Talkie/Sources/Talkie/DesignSystem.swift` and
`SettingsView.swift`.

---

## 4. Design & approach

### 4.1 The neutral note shape + the destination seam

Adopt **`_UNIFICATION.md` §2.3 exactly** — do not fork it. Producers (meetings,
optionally dictations, the Brief) fill in an `ExportableNote` value; a
`NoteDestination` decides *where* and *how* it lands. Templating, front-matter,
wikilinks, and tags are applied **by the destination**, never baked into the
producer. This is the anti-divergence rule: feature 02's fused note and a plain
note travel the same pipe.

### 4.2 The default destination (zero config, no third-party app)

`TalkieFolderDestination` is the refactor of today's `MeetingStore.writeMarkdown`.
It writes plain Markdown to a user-chosen folder (default `~/Talkie Meetings/`,
i.e. `AppPaths.meetingsDirectory()` unchanged). Out of the box it behaves
**byte-for-(near)-byte like today**: YAML front-matter ON (it's already on for
meetings), wikilinks OFF, extra tags OFF. The only behavioral default change is
that the same destination can now also receive dictations and the Brief if the
user opts in — meetings are unchanged.

### 4.3 The templating engine

A tiny, dependency-free token substitution engine (`NoteTemplate`) — **not** a
general template language (keeps "zero dependencies" true and the attack surface
nil). It supports:

- **Filename templates** — e.g. `{date}-{title}-meeting` →
  `2026-06-14-1432-standup-meeting.md`. Tokens: `{date}` (`yyyy-MM-dd`),
  `{datetime}` (`yyyy-MM-dd-HHmm`), `{time}` (`HHmm`), `{title}` (slugified),
  `{kind}` (`meeting`/`dictation`/`brief`), `{app}` (the dictation's target app,
  slugified, dictations only), `{n}` (a uniquifying counter only if a collision
  occurs). Every token is run through a filesystem-safe sanitizer; the result is
  length-capped (≤ 120 chars before the extension) and de-collided.
- **Body composition** is the producer's job (it hands over `bodyMarkdown` already
  containing Summary/Transcript or the dictation text). The destination only wraps
  it: optional front-matter block on top, optional trailing tag line / links block.

Front-matter rendering: emit a YAML block from `ExportableNote.frontMatter`
(deterministic key order via a fixed precedence list, then alphabetical for the
rest) only when the destination's `emitFrontMatter` flag is on. Values are YAML-
escaped; arrays (`participants`, `tags`) render as `[a, b]`.

### 4.4 The flow (where a note gets exported)

```
Producer (MeetingRecorder.stop / endDictation / Brief regen)
   │  builds ExportableNote (title, date, bodyMarkdown, frontMatter, tags, links, suggestedFileName)
   ▼
ExportCoordinator.export(note)            ← @MainActor, owns the enabled destinations
   │  for each enabled NoteDestination where isConfigured:
   │      try await dest.write(note)      ← off-main file I/O via the destination
   │      collect URL or error
   ▼
result surfaced (meeting row "Saved to …", or silent for dictations) +
   failures logged, never thrown to the user mid-dictation
```

- **Meetings** call `ExportCoordinator.export` from `MeetingRecorder.stop()`
  *instead of* `MeetingStore.add` doing the markdown write inline. (Keep
  `MeetingStore` as the JSON index + the in-memory list; move the *file write* into
  `TalkieFolderDestination`. The default destination still writes to
  `~/Talkie Meetings/`, so `MeetingStore.folderURL` and "Reveal in Finder" still
  work.) The `Meeting.fileName` stored in the index becomes "the filename the
  default destination produced" so reveal/delete still resolve.
- **Dictations** (opt-in, default OFF): after `history.add(...)` in
  `AppDelegate.endDictation` (`/Users/jann/Talkie/Sources/Talkie/AppDelegate.swift:511`),
  if `settings.exportDictations`, fire-and-forget `ExportCoordinator.export(.init(kind:
  .dictation, …))`. **Must not** block the injection path or add latency — dispatch
  it after the HUD outcome, at `.utility`.
- **The Brief** (opt-in, default OFF): when `ContextSummaryStore` regenerates,
  optionally export a single rolling `brief.md` (overwrite, not append) so the
  user's note system always has today's brain dump.

### 4.5 Concurrency

`NoteDestination` is `Sendable`; `write` is `async throws` and does its file I/O
off the main actor (it's pure `FileManager`/`Data.write` — already safe). The
`ExportCoordinator` is `@MainActor` (it reads `AppSettings` + holds the destination
list) but awaits each `write` so the actual disk work doesn't run on the main
thread. This matches the house pattern (stores `@MainActor`, heavy work awaited/
detached, `.atomic` writes). No new locks needed.

---

## 5. New & changed files/types

New folder `Sources/Talkie/Export/` (per `_UNIFICATION.md` §3 layout) — keeps the
single executable target, just organizes files.

### New: `Sources/Talkie/Protocols/NoteDestination.swift`

Verbatim from the spine (§2.3), so 02 and the community share it:

```swift
protocol NoteDestination: Sendable {
    var id: String { get }            // "talkie-folder", "obsidian", "logseq", …
    var displayName: String { get }
    var isConfigured: Bool { get }    // folder picked & accessible
    func write(_ note: ExportableNote) async throws -> URL
}

struct ExportableNote: Sendable {
    var kind: NoteKind                 // .meeting | .dictation | .brief
    var title: String
    var date: Date
    var bodyMarkdown: String           // Summary / Transcript / dictation body already composed
    var frontMatter: [String: String]  // duration, participants, source, app, …
    var tags: [String] = []
    var links: [String] = []           // entity displayNames → optional [[wikilinks]] by destination
    var suggestedFileName: String      // template-rendered base name (no extension)
}

enum NoteKind: String, Sendable, Codable { case meeting, dictation, brief }
```

### New: `Sources/Talkie/Export/NoteTemplate.swift`

```swift
/// Dependency-free token substitution for filenames + (optional) front-matter.
enum NoteTemplate {
    /// Render a filename base (no extension) from a template + a note.
    /// Sanitizes every substituted value; caps length; never throws.
    static func fileName(_ template: String, for note: ExportableNote,
                         existing: Set<String>) -> String

    /// Render a YAML front-matter block from ordered keys (deterministic).
    static func frontMatterBlock(_ pairs: [String: String], priority: [String]) -> String

    /// Filesystem-safe slug (lowercased, ascii-folded, `[^a-z0-9-]`→`-`, collapsed).
    static func slug(_ s: String, max: Int = 60) -> String

    /// YAML-escape a scalar value.
    static func yamlValue(_ s: String) -> String
}
```

### New: `Sources/Talkie/Export/TalkieFolderDestination.swift`

```swift
/// The zero-config default: plain Markdown into a chosen folder (default
/// ~/Talkie Meetings/). Optional front-matter / wikilinks / tags, all honoring
/// the user's flags. Refactor of MeetingStore.writeMarkdown.
struct TalkieFolderDestination: NoteDestination {
    let id = "talkie-folder"
    let displayName = "Talkie folder"

    var folderURL: URL                  // resolves via security-scoped bookmark if non-default
    var fileNameTemplate: String        // default "{datetime}-{kind}"
    var emitFrontMatter: Bool           // default true (matches today)
    var emitWikilinks: Bool             // default false
    var emitTags: Bool                  // default false

    var isConfigured: Bool { /* folder exists & writable */ }

    func write(_ note: ExportableNote) async throws -> URL {
        // 1. base = NoteTemplate.fileName(fileNameTemplate, for: note, existing: …)
        // 2. body = [optional front-matter] + note.bodyMarkdown
        //           + [optional "\n\n#tag #tag" line] + [optional links block]
        // 3. links → "[[Name]]" only if emitWikilinks, else plain "Name" or omitted
        // 4. FileManager write .atomic to folderURL/base.md ; return URL
    }
}
```

`Obsidian` / `Logseq` / `Notion` impls are **not** in core (per the contract).
The plan ships only `TalkieFolderDestination`; the protocol + the
front-matter/wikilink/tag flags are exactly what a community destination overrides
(e.g. an Obsidian impl that always-on wikilinks + writes into a vault subfolder, or
a Notion impl whose `write` posts via the user's own integration token in the
*networked* module — see §10). A short doc comment in the protocol file points
contributors at the seam.

### New: `Sources/Talkie/Export/ExportCoordinator.swift`

```swift
@MainActor
final class ExportCoordinator: ObservableObject {
    @Published private(set) var lastError: String?
    private let settings: AppSettings
    // Future: a registry [NoteDestination]; v1 holds the single TalkieFolderDestination
    // built from settings.

    init(settings: AppSettings) { … }

    /// Build the active destination(s) from settings and write the note to each.
    /// Best-effort: collects per-destination failures, never throws to the caller.
    @discardableResult
    func export(_ note: ExportableNote) async -> [Result<URL, Error>]

    /// The default destination's folder, for "Reveal in Finder".
    var primaryFolderURL: URL
}
```

### New: `Sources/Talkie/Export/ExportSettingsView.swift`

The settings subpage (§8). Folder picker, filename-template field with live
preview, the three toggles, dictation-export toggle, Brief-export toggle.

### Changed files

- **`Meeting.swift`** — `MeetingStore` keeps the JSON index + list; its
  `writeMarkdown` is **removed** and the file write delegated to the coordinator.
  Add `Meeting.exportableNote()` that composes today's body (`## Summary` + `##
  Transcript`) into an `ExportableNote` with the same front-matter keys
  (`title/date/duration_min/participants/source`). `MeetingStore.add` is split:
  `add(_:)` (index/list, synchronous, as today) + the recorder calls the
  coordinator for the file. `folderURL` proxies `ExportCoordinator.primaryFolderURL`.
- **`MeetingRecorder.swift`** (branch version) — `stop()` builds the
  `ExportableNote`, awaits `ExportCoordinator.export`, sets `Meeting.fileName` from
  the produced URL, then `store.add(meeting)`. Injected `exportCoordinator` like
  the other deps. `recoverPartialIfNeeded` exports the recovered note too.
- **`AppDelegate.swift`** — `let exportCoordinator = ExportCoordinator(settings:
  settings)`; inject into `MeetingRecorder` and `MainWindowController`; in
  `endDictation` (after `history.add`, `:511`) optionally export the dictation
  (off-main, fire-and-forget).
- **`AppSettings.swift`** — new keys (§6).
- **`SettingsView.swift`** — add `SettingsRoute.export`, a `SettingsHome` row
  ("Export & sync"), and route to `ExportSettingsView`. Add the
  `ExportCoordinator`/`AppSettings` plumbing to `MainView`/`MainWindowController`
  init so the subpage can read/write it.
- **`AppPaths.swift`** — add `bookmarkData` helpers if a non-default folder is
  chosen outside the app's reach (only needed if/when the app is sandboxed —
  feature 15; see §9). Today (unsandboxed) a plain path works.

---

## 6. Data model & persistence

- **Note files**: Markdown under the chosen folder (default
  `~/Talkie Meetings/`). Same format as today by default; richer (front-matter +
  optional tags/links) when enabled. `.atomic` writes (house style).
- **The meetings index** (`meetings.json`) and `HistoryStore`'s `history.json`
  are unchanged. The `.md` files remain the durable copy of meetings; dictation
  `.md` exports are *additive* (history JSON is still the source of truth for the
  History tab).
- **New settings** in `UserDefaults` (via `AppSettings`, matching `:151-211`):
  - `exportFolderPath: String` (empty ⇒ default `~/Talkie Meetings/`).
  - `exportFolderBookmark: Data?` (security-scoped bookmark; nil unless a non-
    default folder is chosen and sandboxing is on — see §9).
  - `exportFileNameTemplate: String` (default `"{datetime}-{kind}"`; meetings keep
    the legacy `-meeting` suffix via `{kind}` ⇒ `meeting`).
  - `exportFrontMatter: Bool` (default **true** — matches current meeting output).
  - `exportWikilinks: Bool` (default **false**).
  - `exportTags: Bool` (default **false**).
  - `exportTagList: [String]` (extra tags appended to every note, e.g. `["talkie"]`;
    default empty).
  - `exportDictations: Bool` (default **false**).
  - `exportBrief: Bool` (default **false**).
- **Migration / back-compat**: existing meeting `.md` files and the index are
  untouched; the default flag values reproduce today's behavior, so an upgrading
  user sees **no change** unless they open Export settings. Failure-tolerant decode
  + `register(defaults:)` keeps old installs valid. `Meeting.fileName` semantics
  preserved (still resolves for Reveal/Delete). If a user changes the folder, old
  meetings stay where they were (their stored `fileName`/folder is honored on
  delete via the historical path; new ones go to the new folder) — document this in
  the UI ("changes apply to new notes").

---

## 7. Unification contract

Per `_UNIFICATION.md` §2.3 and the **feature-10 contract** (line ~732):

**EXPOSES** (what other features consume):
- The `NoteDestination` protocol + the `ExportableNote` value shape — the single
  pipe every note producer writes through. Feature **02** (notes×transcript
  fusion) hands its fused `bodyMarkdown` to the *same* `ExportCoordinator`, so the
  Granola-magic note and a plain note travel one path.
- The settings UX + the `NoteTemplate` engine + the off-by-default
  front-matter/wikilink/tag flags — the community extension surface.
- `ExportCoordinator.export(_:)` as the in-process entry every producer calls.

**CONSUMES**:
- `ExportableNote`s from **meetings** (and the branch's `participants`/`source`)
  and, opt-in, **dictations** (`DictationEntry` → app name, text) and the **Brief**.
- The **Personal Context Graph** (feature 05, `ContextGraphSnapshot`) for the
  `links` field: when `ContextGraphStore` exists, populate
  `ExportableNote.links` from `graph.entities(fromMeeting:)` (people/projects in
  that meeting) so a wikilink-aware destination cross-links them
  (`[[Sarah Chen]]`, `[[Coralate]]`). **Graceful absence**: feature 05 is Tier 0
  and may not be built yet — `links` is simply empty until then, and even with the
  graph, wikilinks are OFF by default, so this is purely additive. Export must
  **not** hard-depend on the graph (build/ship without it).

**Coherence note (the one thing that keeps it one product)**: the default
`TalkieFolderDestination` must stay useful with **zero config and no third-party
app**. The protocol is the only thing core exposes for Obsidian/Logseq/Notion;
those impls live outside core (and any networked one, e.g. Notion's API, lives in
the `TalkieBridge`-style networked module behind feature 15's wall — see §10).

---

## 8. UI / UX

A new **"Export & sync"** subpage under the **Settings** tab, reached from
`SettingsHome` exactly like the other rows (`SettingsView.swift:411-427` pattern):
a `NavigationLink(value: SettingsRoute.export)` row with an SF Symbol
(`square.and.arrow.up.on.square.fill`), a feather tint (`Theme.featherGreen` —
"things leaving correctly" reads as the green success hue), title "Export & sync",
subtitle showing the resolved state (e.g. "~/Talkie Meetings/" or the chosen
folder name).

The subpage uses the existing `SubPage` scaffold (serif `PageHeader` over a
`.grouped` `Form`), so it's on-brand for free:

- **Section "Destination folder"**: a row showing the current folder + a
  "Choose…" button (`NSOpenPanel`, `canChooseDirectories`). Footer:
  "Your notes are written here as Markdown. The default needs no other app —
  point Claude, Obsidian, Logseq, or anything that reads files at it." Honest,
  second-person (BRAND.md voice).
- **Section "Filename"**: a `TextField` bound to the template + a **live preview**
  line ("Example: `2026-06-14-1432-meeting.md`") rendered through `NoteTemplate`
  on a sample note. A small token legend (`{date} {datetime} {title} {kind} {app}`)
  as `.caption` `Theme.inkTertiary`.
- **Section "Format (optional)"**: three `Toggle`s — "YAML front-matter"
  (default on), "Wiki-style [[links]] for people & projects" (off; footer notes it
  needs the context graph and a tool that understands wikilinks), "Add tags" (off)
  with a `FlowLayout` of tag chips (reuse the `VocabChip`/`FlowLayout` pattern from
  `DictionarySettings`) when on.
- **Section "What to export"**: "Meetings" (read-only, always on, "Meetings are
  always saved"), "Dictations" (`exportDictations`, off, footer: "Also save each
  dictation as a note — off by default to keep your folder tidy"), "Daily Brief"
  (`exportBrief`, off).
- **Privacy line** at the bottom (caption, `Theme.inkTertiary`): "Everything is
  written to your disk. Nothing is uploaded." (Matches the existing CleanupSettings
  privacy footer voice.)

The **Meetings tab** copy (`MeetingsView.swift:92`) updates from a fixed
"~/Talkie Meetings/" string to read `store.folderURL.lastPathComponent` so it
reflects a custom folder; "Reveal in Finder" already uses `store.folderURL`.

One accent per view (brand blue for the active buttons/preview), feather green
only as the nav tint + success states, squircle cards, whisper shadow — no new
visual primitives.

---

## 9. Permissions / entitlements / Info.plist

- **Today (unsandboxed, the current build):** writing to a user-chosen folder via
  `NSOpenPanel` needs **no new entitlement** — the panel grants access and the
  process is not sandboxed (`talkie.entitlements` has only audio-input). No new
  TCC prompt, no Info.plist key. The default `~/Talkie Meetings/` is already in
  use.
- **Under the App Sandbox (feature 15's connected/sandboxed flavor):** a
  non-default folder requires the **user-selected read-write file-access**
  entitlement (`com.apple.security.files.user-selected.read-write`) plus a
  **security-scoped bookmark** persisted in `exportFolderBookmark` and resolved
  with `startAccessingSecurityScopedResource()` around each write. This is the
  *only* sandbox interaction; the default folder still works because the app
  created it. Plan for it now (the `exportFolderBookmark` key + bookmark resolve
  path), but it's inert until 15 turns on the sandbox.
- **No network**, no microphone change, no new usage strings for the core default
  and for any local-folder destination.

---

## 10. Privacy posture

- **Preserves zero-network for the default and every core destination.**
  `TalkieFolderDestination` is pure local disk I/O — no `URLSession`, nothing
  leaves the Mac. The privacy invariant (verified: no network code, single
  audio-input entitlement) is untouched by this feature's shipped code.
- **The one place network could enter** is a community **cloud** destination
  (e.g. a Notion API impl). Per `_UNIFICATION.md` §4.1 + §3 boundary rules, such a
  destination **must not** live in core (`Talkie`); it belongs in the separate
  networked module (`TalkieBridge`-style target), is OFF by default, requires a
  deliberate enable + per-destination disclosure of exactly what is sent and when,
  and refuses to load in the sandboxed-default flavor (mirrors the
  `requiresNetwork` gate on backends/summarizers). The core protocol stays
  network-agnostic; the wall is enforced by target separation, not by trust.
- **Provenance honesty**: wikilinks/front-matter only ever surface what's already
  in the note + the local graph; nothing is invented (the graph's entities carry
  provenance, feature 05 §1.3). The UI states plainly that export writes to disk
  and uploads nothing.

---

## 11. Open-source genericity

- **No hardcoded personal stack.** Obsidian, Logseq, Notion, a specific vault, an
  editor — none appear in core. The only shipped destination is the neutral
  `TalkieFolderDestination` (a plain folder + Markdown).
- **Useful zero-config default with no third-party app**: out of the box, meetings
  keep saving to `~/Talkie Meetings/` exactly as today; the user can change the
  folder and turn on optional front-matter/wikilinks/tags, but doesn't have to
  install anything.
- **Community extension path**: ship a destination by conforming `NoteDestination`
  (`id`, `displayName`, `isConfigured`, `write`). The `ExportableNote` carries
  everything an Obsidian/Logseq impl needs (front-matter map, tags, entity links)
  to apply its own conventions (vault subfolders, always-on wikilinks, callouts).
  A doc comment + a one-page `docs/EXPORT.md` (contributor guide) explains the seam.
  A future `destinationRegistry` makes multiple enabled destinations a list; v1
  ships the single default + the protocol so the API is locked before contributors
  build against it.

---

## 12. Risks, edge cases, failure modes

- **Filename collisions** (two meetings same minute; a custom template that drops
  the time): `NoteTemplate.fileName` appends `-{n}` only on a real on-disk
  collision; never silently overwrites a different note.
- **Illegal/odd characters in title** (slashes, emoji, RTL): `slug` ascii-folds +
  strips to `[a-z0-9-]`, caps length; empty result falls back to `{datetime}`.
- **Folder gone / unwritable / external drive ejected**: `write` throws;
  `ExportCoordinator` catches per-destination, sets `lastError`, and **falls back
  to the default `~/Talkie Meetings/`** for that note so a meeting is never lost.
  Surface a non-blocking warning in the meeting row / Export settings; never crash
  or block a dictation.
- **Dictation export must never add latency**: it runs fire-and-forget at
  `.utility` after the insertion outcome; a slow disk can't stall the paste.
- **Front-matter breaking a tool's parser** (e.g. a colon in a title): YAML-escape
  values; quote when needed. Wikilink/tag chars in titles are slugged.
- **Custom folder + sandbox** (future): if the security-scoped bookmark fails to
  resolve (folder moved/renamed), degrade to the default folder and prompt the user
  to re-pick.
- **Changing the folder doesn't migrate old notes**: by design (don't move the
  user's files); the UI says "applies to new notes" and Reveal still resolves old
  ones via their stored path.
- **Large transcript bodies**: no extra cap beyond what producers already apply
  (meetings are already whole-file; this just writes them).

Graceful-degradation principle throughout: **a failed export never loses a note
and never blocks the voice path** — worst case it lands in the default folder with
a logged warning.

---

## 13. Testing & verification

No test target exists today (`_CURRENT_STATE.md` §8). Add a small one for the pure
logic (the spine wants this kind of thing testable):

- **Unit (pure, no model/audio)** — add a `TalkieTests` target:
  - `NoteTemplate.fileName`: tokens substitute; slug strips illegals; length cap;
    collision `-{n}`; empty-title fallback.
  - `NoteTemplate.frontMatterBlock`: deterministic key order; YAML escaping;
    array rendering; off ⇒ no block.
  - `TalkieFolderDestination.write` into a temp dir: default flags reproduce the
    exact legacy meeting Markdown (golden-file compare against today's
    `writeMarkdown` output for a fixed `Meeting`); wikilinks/tags appear only when
    flagged; collision handling on disk.
  - `Meeting.exportableNote()`: front-matter keys match the legacy set.
- **Manual / `/run`**:
  1. Record a meeting → confirm the `.md` in `~/Talkie Meetings/` is identical in
     shape to before (regression).
  2. Change the folder to a test dir → record → confirm the note lands there and
     "Reveal in Finder" opens it.
  3. Turn on front-matter off→on, wikilinks, tags → inspect the rendered file.
  4. Turn on "Export dictations" → dictate → confirm a dictation `.md` appears and
     the dictation latency is unchanged (HUD timing identical).
  5. Eject/`chmod -w` the folder mid-session → confirm fallback to default + a
     warning, no lost note, no crash.
- **`/verify`** path: drive the app, exercise steps 1–4, screenshot the Export
  settings subpage to confirm it's on-brand (serif title, grouped form, blue
  accent, green nav tint).

---

## 14. Effort & phasing

**MVP slice (S–M, ships the contract + parity):**
1. (S) `NoteDestination` + `ExportableNote` in `Protocols/`.
2. (S) `NoteTemplate` (filename + front-matter) + unit tests.
3. (M) `TalkieFolderDestination` (refactor `writeMarkdown`) + `ExportCoordinator`;
   rewire `MeetingRecorder.stop` and `MeetingStore` to use them. **Goal: byte-
   parity with today's meeting output, no UI yet.**
4. (S) Folder + filename-template settings (`AppSettings` keys + a minimal
   `ExportSettingsView` with folder picker + template field + front-matter toggle).

**Full feature (M–L):**
5. (M) Optional wikilinks/tags + the format section UI + the tag-chip FlowLayout;
   wire `links` from feature 05's graph when present.
6. (M) Opt-in dictation export (the off-main hook in `endDictation`) + Brief
   export.
7. (S) `docs/EXPORT.md` contributor guide + the destination-registry scaffold for
   community impls (no extra core destinations).
8. (S, deferred to feature 15) sandbox security-scoped bookmark path for non-
   default folders.

The MVP alone satisfies the contract: the protocol is exposed, the default is
zero-config and useful, and meetings are unchanged. Wikilinks/dictations are the
differentiators layered on top.

---

## 15. Dependencies & interactions

- **Needs (soft):** feature **05 Context Graph** for `ExportableNote.links`
  (people/projects cross-linking). Soft because export ships and works with empty
  `links`; the wikilink value lights up once 05 exists. **Hard-depends on nothing**
  beyond the existing meeting/dictation producers.
- **Enables / shares with:** feature **02 (notes×transcript fusion)** — its fused
  note becomes an `ExportableNote` through the *same* coordinator (the most
  important reuse; do not let 02 fork a second write path). Also the surfacing arm
  of **05** (the graph's entities become wikilinks).
- **Overlaps with:** feature **15 (sandbox/zero-net proof)** — the only feature
  that adds an entitlement here (user-selected file access + bookmarks for a custom
  folder under the sandbox) and that polices any future networked (cloud)
  destination. Coordinate the `requiresNetwork`-style wall for cloud destinations
  with 15.
- **Adjacent:** feature **06 (local MCP server)** reads the same `~/Talkie
  Meetings/` Markdown read-mostly; keeping the default folder + Markdown shape
  stable keeps the MCP server's `list_meetings`/`get_meeting` trivial. A custom
  export folder is an app concern, not the MCP's — the MCP keeps reading the
  canonical meetings dir (the index records the actual path).

---

### Biggest open question / risk

**Where does the canonical meeting `.md` live once the folder is user-configurable
— and does that break feature 06's "just read `~/Talkie Meetings/`" assumption?**
The MCP server (06), the privacy proof (15), and "point Claude at the folder" all
lean on a *stable, known* meetings directory. If a user retargets export to, say,
an Obsidian vault, the meeting notes leave `~/Talkie Meetings/`, and the MCP server
(which runs out-of-process, possibly while the app is closed) no longer knows where
to look. The cleanest resolution is to treat the user's folder as an **additional**
destination while *always* keeping the canonical copy in `~/Talkie Meetings/` (the
index/MCP truth), i.e. export is *fan-out*, not *move* — but that doubles writes and
may surprise a user who expected one location. The alternative — make the folder
fully relocatable and have the index/MCP read the recorded path — is more honest to
the user's intent but couples 06/15 to a setting. **This single decision (fan-out
vs. relocate) should be settled with the 06 and 15 planners before step 3 of the
MVP**, because it determines whether `AppPaths.meetingsDirectory()` stays the
source of truth or becomes just the default.
