# 03 — Meeting auto-detect & consent banner

> Feature owner contract (from `_UNIFICATION.md` §6 / 01): **Exposes**
> `MeetingContextProvider.detectActiveMeeting() → MeetingSignal`. **Consumes** a
> Core Audio process-list scan + a meeting-app allowlist + debounce + the brand
> HUD/banner pattern. **Note:** NEVER silently record — always the consent banner.
> Music/video can't trigger (output, not input). Confidence = mic-hot + allowlisted
> app.
>
> Grounded against `main` (HEAD `5f747fb`) and the unmerged
> `feat/meeting-far-audio` branch (the Phase-2 far-end recorder this feature drives).
> Researched 2026-06-14: Core Audio process-property selectors verified against the
> installed CoreAudio SDK headers; meeting-app bundle IDs verified against installed
> apps where present.

---

## 1. Summary

Add a lightweight always-on detector that notices when **another** process is
actively capturing the microphone (a meeting), raises confidence with a known-app
bundle-id allowlist, and shows a calm, dismissible "Meeting detected — record?"
banner — Talkie offers to record but **never** records silently. It is wired as the
first `MeetingContextProvider` implementation so the calendar feature (04) and the
recorder (01) consume it through one seam.

---

## 2. Why it matters

Granola's whole onboarding magic is "it just knew I was in a call." Today Talkie
recording is **fully manual** — a button in the Meetings tab, no global hotkey, no
menu item (`_CURRENT_STATE.md` §2.3). A user who installs Talkie for dictation will
forget it can record meetings until they happen to open the tab mid-call, by which
point the first ten minutes are gone. Auto-detect closes that gap: it converts a
feature people *own* into a feature people *use*, with zero ongoing effort.

For the strategic thesis, this is the feed valve for the personal context graph
(feature 05). The graph's richest input is meeting transcripts (Me/Them turns →
Person/Commitment entities). Auto-detect is what makes those transcripts *actually
get captured* — every call you'd otherwise forget to record becomes graph fuel. And
it does it the way neither incumbent can credibly claim: the detection signal
(mic-hot + bundle id) is read **locally** off Core Audio and never leaves the
machine, and the banner makes the trust posture explicit rather than burying
auto-record in a EULA. "It notices your meetings, offers to record, and proves
nothing left your Mac" is a line Granola (a cloud company) cannot say.

---

## 3. Current state in the code

**Nothing of this feature exists yet.** Confirmed: no Core Audio process scan, no
allowlist, no banner (`_CURRENT_STATE.md` §2.3, Phase 5 "NOT built"). What *does*
exist and what this feature builds on:

- **`SystemAudioCapture.swift`** *[branch `feat/meeting-far-audio`]* — already proves
  out the exact Core Audio object/property pattern this detector reuses:
  - `audioObject(forPID:)` translates a PID → `AudioObjectID` via
    `kAudioHardwarePropertyTranslatePIDToProcessObject` (branch lines ~165-186).
  - It already uses `AudioObjectGetPropertyData` with an `AudioObjectPropertyAddress`
    (the same call this detector uses to read the process list and `IsRunningInput`).
  - It already excludes Talkie's own process object from the tap — the detector must
    do the analogous "exclude self" by **PID** when scanning.
  This is the canonical reference; the detector is a *read-only* sibling of it.
- **`MeetingRecorder.swift`** — `@MainActor ObservableObject`; the thing the banner's
  "Record" button drives. On `main` it is mic-only; the branch version captures
  far-end too and exposes `capturingFarEnd`, `isRecording`, `isFinishing`,
  `isStarting` (`MeetingRecorder.swift` branch). The detector must read
  `isRecording`/`isStarting`/`isFinishing` to suppress the banner while a recording
  (or dictation, via the shared engine) is in flight.
- **`AppDelegate.swift`** — the composition root that owns every store + the
  recorder (`:15-23`, `:61-63`). The detector is created and started here, and the
  banner is shown here (it already owns `HUDController` at `:20` and routes engine →
  HUD via a `@MainActor` static, `:223-237`). `appBecameActive`/`permissions.refresh`
  (`:100-105`) is the model for "re-check on focus."
- **`HUD.swift`** — the brand HUD pattern (`HUDController` + a borderless
  non-activating floating `NSPanel`, real macOS-26 `.glassEffect`, top-center under
  the notch, `:46-185`). The consent banner reuses this exact panel pattern but is a
  **separate, interactive** panel (the dictation HUD ignores mouse events at `:72`;
  the banner needs buttons).
- **`AppContext.swift`** — `TargetApp` (`bundleID`, `name`, `category`) and
  `AppCategory.classify(bundleID:name:)` (`:6-11, 45-47`). The allowlist maps a
  detected bundle id → a friendly app name for the banner copy; reuse `TargetApp`
  for the signal's app identity.
- **`AppSettings.swift`** — the UserDefaults-backed settings pattern + the
  `.talkieSettingsChanged` notification (`:147-149`). The new "auto-detect meetings"
  toggle and the per-app allowlist additions live here.
- **`Permissions.swift`** — the TCC model. Far-end capture's audio-capture consent
  (`NSAudioCaptureUsageDescription`, already in the branch's `Info.plist`) is the
  only TCC surface, and it is triggered by the **recorder**, not the detector (§9).
- **`Meeting.swift`** *[branch]* — `Meeting` already carries `participants`/`source`
  with back-compat decode; `MeetingRecorder` already sets a timestamp title via
  `makeTitle(start:)`. Feature 04 will replace that title with the calendar event
  name via the same `MeetingContextProvider`; 03 only needs to *trigger* the start.

**Honest gap statement:** the detector, the `MeetingContextProvider` protocol, the
allowlist, the consent banner, the settings, and the wiring are **all new**. The
Core Audio read primitives are not new — they are a strict subset of what
`SystemAudioCapture.swift` already does on the branch.

---

## 4. Design & approach

### 4.1 The detection signal (verified APIs)

**Trigger = a process *other than Talkie* is actively capturing the mic.** Read
purely off Core Audio's hardware object — no AVCaptureSession, no tap, no audio
actually captured by the detector.

Selectors confirmed present in the installed CoreAudio SDK
(`MacOSX.sdk/.../CoreAudio.framework/Headers/AudioHardware.h`), with their FourCC
codes, all available **macOS 14.4+** (we floor at 26, so always available):

| Selector | FourCC | Type | Use |
|---|---|---|---|
| `kAudioHardwarePropertyProcessObjectList` | `'prs#'` | `[AudioObjectID]` | enumerate every audio process |
| `kAudioProcessPropertyPID` | `'ppid'` | `pid_t` | exclude self; identify the process |
| `kAudioProcessPropertyBundleID` | `'pbid'` | `CFString` | allowlist match + friendly name |
| `kAudioProcessPropertyIsRunningInput` | `'piri'` | `UInt32` (0/1) | **the trigger**: is this process recording the mic *now* |
| `kAudioProcessPropertyIsRunning` | `'pir?'` | `UInt32` | (optional) liveness |

**Algorithm (polled every 1.5 s on a background actor):**

```
1. Read kAudioHardwarePropertyProcessObjectList on kAudioObjectSystemObject
   → [AudioObjectID]  (the audio processes the system knows about)
2. For each object:
     a. read kAudioProcessPropertyPID; skip if == getpid()  (exclude self)
     b. read kAudioProcessPropertyIsRunningInput; skip if 0  (not capturing mic)
     c. read kAudioProcessPropertyBundleID  (may be nil for some procs)
   → the set of (pid, bundleID?) currently capturing the mic, minus Talkie.
3. If that set is empty → "no meeting". Else:
     confidence = bundleID ∈ allowlist ? .high(app) : .low
4. Emit a MeetingSignal (or nil) through the provider.
```

**Why polling, not the change-listener:** the brief and the design doc both flag
the `IsRunning*` listeners as documented-flaky; research confirms it — Apple's own
forums report `kAudioProcessPropertyIsRunningOutput` listeners "never trigger"
(thread/770348). So the detector **polls** at 1.5 s (the design doc's 1–2 s window),
which is cheap (a handful of `AudioObjectGetPropertyData` calls) and reliable.
Listener registration is explicitly out of scope.

**Why music/video never trigger:** Spotify/YouTube/Netflix are *output*
(`IsRunningOutput`), not *input*. Step 2b reads `IsRunningInput` only, so they
structurally cannot match. This is stated as a guarantee in the brief and is correct.

### 4.2 Confidence model

- **Low (`mic-hot only`):** some non-Talkie process is recording the mic, but its
  bundle id is unknown or not on the allowlist. *Default behavior: do **not** raise
  the banner* — too noisy (a generic AVCapture app, a screen recorder, another
  dictation tool would all trip it). Low-confidence signals are still returned by
  the provider (04/05 may want them) but the banner only fires on high confidence by
  default. A setting can opt into "offer for any mic-hot app" (§8).
- **High (`mic-hot + allowlisted app`):** a known meeting app is on the mic →
  raise the banner with the app's friendly name ("Zoom is in a call — record it?").

Optional confidence *boosters* (deferred, not MVP, listed for completeness): a hot
camera via CoreMediaIO, a held display-sleep assertion, or Zoom's `CptHost` child
process. None are needed for a good first release; the allowlist alone is the
high-signal discriminator.

### 4.3 The allowlist (verified bundle IDs)

Seed list (those marked ✓ verified against an installed copy on this machine; the
rest are the well-known stable ids from the design doc / brief):

| App | Bundle id | Note |
|---|---|---|
| Zoom | `us.zoom.xos` | also child `us.zoom.xos` / `ZoomPhone`; main app id is stable |
| Microsoft Teams (new) | `com.microsoft.teams2` | new Teams; old was `com.microsoft.teams` |
| Webex | `com.cisco.webexmeetingsapp` | Meetings app |
| FaceTime | `com.apple.FaceTime` | ✓ verified |
| Slack | `com.tinyspeck.slackmacgap` | huddles |
| Discord | `com.hnc.Discord` | ✓ verified |
| Google Meet (Chrome) | `com.google.Chrome` | ✓ verified — browser, see note |
| Safari (web meetings) | `com.apple.Safari` | ✓ verified — browser, see note |
| Arc / Edge / Brave / Firefox | `company.thebrowser.Browser` / `com.microsoft.edgemac` / `com.brave.Browser` / `org.mozilla.firefox` | browsers |

**Browser caveat (important):** a browser being mic-hot is a *weaker* signal than a
dedicated meeting app — the user could be on a voice-note site, a speech-to-text
demo, etc. Treat browsers as **medium** confidence: raise the banner, but with
softer copy ("A call may have started in Chrome — record it?") and remember
per-app dismissals more aggressively (a user who dismisses "Chrome" three times
gets it muted for that app). The allowlist entry carries a `tier` (meetingApp |
browser) to drive this.

The allowlist ships as a **built-in default** plus a **user-editable** set in
Settings (genericity, §11) — add/remove bundle ids, toggle the whole feature off.

### 4.4 Lifecycle & debounce

- **Start scanning** when: the app has launched, the feature is enabled, and the OS
  is supported (always, on 26). Scanning is *passive metadata reading* and needs no
  TCC prompt (§9), so it can run from launch.
- **Meeting start** = high/medium-confidence signal sustained for **2 consecutive
  polls (~3 s)** — avoids a one-frame blip when an app briefly probes the mic.
- **Banner shown** once per detected meeting (a meeting "session" keyed by
  `bundleID + first-seen time`). If dismissed, **do not** re-show for the same
  session.
- **Meeting end** = the trigger flips to false, **debounced 20 s** (the design doc's
  15–30 s window) so a mute/hold/screen-share-swap doesn't end the session. After
  the debounce, the session resets so a genuinely new call later re-offers.
- **Suppression** — never raise the banner when: the feature is off; a meeting
  recording is already live or starting (`recorder.isRecording || isStarting ||
  isFinishing`); a dictation is live (`isDictating`, shared engine); the user already
  dismissed this session; or the app that's mic-hot **is Talkie itself** (excluded by
  PID in step 2a, but double-checked by bundle id).

### 4.5 The banner → recorder handoff

The banner has exactly two affordances: **Record** and **Dismiss** (plus an
implicit auto-hide). "Record" calls `meetingRecorder.start()` (the branch's
two-stream start; it already degrades to mic-only). On success the banner closes and
the in-window recording pill / menu-bar indicator take over (the persistent
"Recording" indicator is the recorder's job, partially built — `_CURRENT_STATE.md`
§2.3). "Dismiss" records the session as dismissed and closes. The banner never
auto-records.

---

## 5. New & changed files/types

### New: `Sources/Talkie/Protocols/MeetingContextProvider.swift`

The shared seam (verbatim shape from `_UNIFICATION.md` §2.5 — adopt, do not fork):

```swift
protocol MeetingContextProvider: Sendable {
    /// Auto-detect: is a meeting likely in progress right now? (feature 03)
    func detectActiveMeeting() async -> MeetingSignal?
    /// Naming/attendees from the calendar for a given time window. (feature 04)
    func eventContext(at date: Date) async -> MeetingEventContext?
}

struct MeetingSignal: Sendable {
    var confidence: Double          // 0.4 browser · 0.6 mic-hot+camera · 0.85 allowlisted app
    var appBundleID: String?        // us.zoom.xos, com.microsoft.teams2, …
    var appName: String?            // friendly name for banner copy ("Zoom")
    var startedAtUnix: Double
}

struct MeetingEventContext: Sendable {   // owned/implemented by feature 04
    var title: String?
    var attendeeNames: [String]
    var eventID: String?
}
```

03 ships `detectActiveMeeting()`; `eventContext(at:)` returns `nil` until 04 lands
(a single `CompositeMeetingContextProvider` can merge the two later, or 03's impl
just stubs `eventContext`).

### New: `Sources/Talkie/Meetings/AudioProcessScanner.swift`

The Core Audio read layer. `@unchecked Sendable` value-ish helper (no live state to
guard; the scan is a pure read each call). Pattern mirrors
`SystemAudioCapture`'s static Core Audio helpers.

```swift
struct ActiveInputProcess: Sendable, Hashable {
    let pid: pid_t
    let bundleID: String?
}

enum AudioProcessScanner {
    /// All processes currently capturing mic input, excluding Talkie's own PID.
    /// Pure read of Core Audio hardware objects — no tap, no TCC prompt.
    static func processesCapturingInput(excludingPID selfPID: pid_t) -> [ActiveInputProcess]

    // private helpers, all AudioObjectGetPropertyData wrappers:
    private static func processObjectList() -> [AudioObjectID]            // 'prs#'
    private static func pid(of obj: AudioObjectID) -> pid_t?              // 'ppid'
    private static func bundleID(of obj: AudioObjectID) -> String?       // 'pbid'
    private static func isRunningInput(_ obj: AudioObjectID) -> Bool     // 'piri'
}
```

### New: `Sources/Talkie/Meetings/MeetingDetector.swift`

The polling engine + provider impl + debounce/session state. An `actor` (owns the
mutable scan state and the poll loop; mirrors the engine/extractor convention).

```swift
actor MeetingDetector: MeetingContextProvider {
    struct Config: Sendable {
        var enabled: Bool
        var allowlist: [MeetingApp]      // bundleID + displayName + tier
        var offerForAnyMicApp: Bool      // low-confidence opt-in (default false)
        var pollInterval: Duration = .seconds(1.5)
        var startConfirmPolls: Int = 2   // ~3 s sustained before "started"
        var endDebounce: Duration = .seconds(20)
    }

    init(config: Config, selfPID: pid_t)

    /// Begins the poll loop. Calls `onDetect` on the MainActor when a NEW meeting
    /// crosses the start threshold (suppression handled by the caller via `shouldOffer`).
    func start(onDetect: @escaping @Sendable (MeetingSignal) -> Void) async
    func stop() async
    func updateConfig(_ config: Config) async      // settings changed → re-bind live
    func markSessionDismissed(_ bundleID: String?) async   // don't re-offer this session

    // MeetingContextProvider
    func detectActiveMeeting() async -> MeetingSignal?   // one-shot probe (no loop)
    func eventContext(at date: Date) async -> MeetingEventContext? { nil } // 04 fills in
}

struct MeetingApp: Codable, Sendable, Hashable {
    var bundleID: String
    var displayName: String
    enum Tier: String, Codable, Sendable { case meetingApp, browser }
    var tier: Tier
}
```

The detector emits through a `@Sendable` closure to the MainActor exactly like the
engine→HUD route in `AppDelegate` (`:225-231`). It must **not** import or own UI.

### New: `Sources/Talkie/Meetings/MeetingConsentBanner.swift`

A `@MainActor final class MeetingConsentBannerController` + a SwiftUI `BannerView`,
modeled on `HUDController`/`HUDView` but **interactive** (`ignoresMouseEvents =
false`, `.nonactivatingPanel` so it doesn't steal focus from the call). Two buttons.

```swift
@MainActor
final class MeetingConsentBannerController {
    func show(appName: String?,
              onRecord: @escaping () -> Void,
              onDismiss: @escaping () -> Void)
    func hide()
}
```

### Changed: `AppDelegate.swift`

- Own `private var meetingDetector: MeetingDetector?` and
  `private let consentBanner = MeetingConsentBannerController()`.
- In `applicationDidFinishLaunching`, after the recorder is built (`:63`), build the
  detector from settings and `start` it with an `onDetect` that runs the
  **suppression check** (`shouldOffer(for:)`) and then shows the banner. The banner's
  `onRecord` calls `await meetingRecorder.start()`; `onDismiss` calls
  `await meetingDetector?.markSessionDismissed(signal.appBundleID)`.
- Extend `observeSettings` (`:269-290`) to call `meetingDetector?.updateConfig(...)`
  when `.talkieSettingsChanged` fires (toggle on/off, allowlist edits).
- Inject `selfPID: getpid()` so the detector excludes Talkie.

### Changed: `AppSettings.swift`

New keys (UserDefaults, same pattern as `:213-231`):
`autoDetectMeetings: Bool` (default **true**, but the *banner* still requires explicit
"Record" — auto-*detect* on, auto-*record* never), `offerMeetingForAnyMicApp: Bool`
(default false), `meetingAllowlist: [MeetingApp]` (default = built-in seed; stored as
JSON-encoded data under one key, decoded failure-tolerantly), and a transient
`mutedMeetingApps: [String]` (bundle ids the user muted via repeated dismissals).

### Changed: `SettingsView.swift`

A new "Meetings" sub-page (or a section in an existing pane) with: the master toggle,
the "offer for any mic app" toggle, and an editable allowlist (FlowLayout chips, same
control as the dictionary vocab chips, `SettingsView.swift:634-721`).

---

## 6. Data model & persistence

This feature is **almost stateless on disk** — by design, the detection signal is
ephemeral and read live from Core Audio every poll. What persists:

- **Settings** (UserDefaults, via `AppSettings`): `autoDetectMeetings`,
  `offerMeetingForAnyMicApp`, the user-edited `meetingAllowlist` (JSON-encoded under
  one key — there is no array-of-Codable UserDefaults convenience, so encode to
  `Data` like a small store; decode with `try?` + fall back to the built-in seed),
  and `mutedMeetingApps`. No new file in `~/Library/Application Support/Talkie/`.
- **No new file format, no migration.** The recordings the banner produces are just
  normal `Meeting`s written by the existing `MeetingStore` (Markdown +
  `meetings.json`), already back-compat (branch `Meeting.init(from:)` decodes missing
  `participants`/`source`). Nothing this feature adds touches that schema.
- **Session state** (which meeting is "current," dismissed, debouncing) lives **only
  in the `MeetingDetector` actor's memory** — it is intentionally not persisted; a
  relaunch mid-call simply re-detects and may re-offer, which is acceptable and
  honest.

Back-compat: the only durable change is new UserDefaults keys with safe defaults, so
older installs upgrade transparently and a downgrade just ignores the keys.

---

## 7. Unification contract

Read against `_UNIFICATION.md` §2.5 and §6/03. This feature is the **first
implementer of `MeetingContextProvider`** — the protocol is the anti-divergence
layer, so 03 must define/adopt it, not invent a private detector API.

**EXPOSES (what other features consume):**
- `MeetingContextProvider.detectActiveMeeting() → MeetingSignal?` — the live
  "is a meeting happening, and in what app" signal. Consumed by:
  - **01 (far-end recorder)** — the banner's "Record" drives `MeetingRecorder.start()`;
    the `MeetingSignal.appBundleID`/`appName` can title the note ("Zoom call") until
    04 supplies a calendar title.
  - **05 (context graph)** — when a meeting is recorded *because* it was detected, the
    detected `appBundleID` is a candidate `Provenance.appName` for the resulting
    meeting's entities (the source app the call ran in).
- The **`MeetingSignal`** value type (confidence + bundle id + app name + start time)
  and the editable **allowlist** as a reusable list of known meeting apps.

**CONSUMES (what this depends on):**
- The **Personal Context Graph is NOT a hard dependency** for 03 — auto-detect works
  with the graph absent. (03 is a *producer-trigger*, not a graph consumer.) The one
  soft tie: when 04/05 exist, the same `MeetingContextProvider` instance also answers
  `eventContext(at:)`, so the recorder gets a calendar title + attendee bias on the
  recording 03 kicked off. 03 leaves `eventContext` returning `nil` until 04 fills it.
- `MeetingRecorder` (01/branch) — reads `isRecording`/`isStarting`/`isFinishing` for
  suppression; calls `start()` on consent.
- The **brand HUD/banner pattern** (`HUDController` panel mechanics) — reused, not
  reinvented (§4.5, §8).
- `AppContext.AppCategory`/`TargetApp` for friendly app naming.

**Honoring the contract's "Note":** NEVER silently record (banner is mandatory);
music/video can't trigger (input-only read); confidence = mic-hot + allowlisted app.
All three are structural in §4, not optional.

---

## 8. UI / UX

**Surface:** a new **consent banner** — a sibling of the dictation HUD, same
borderless non-activating floating `NSPanel` + real macOS-26 `.glassEffect`
(`HUD.swift:55-77, 206-211`), pinned top-center under the notch like the HUD, but:
- **interactive** (`ignoresMouseEvents = false`; the HUD sets it `true` at `:72`),
- `.nonactivatingPanel` kept so clicking "Record" doesn't yank focus from the call,
- slightly larger to fit two buttons, with the same calm spring entrance
  (`.spring(response: 0.28, dampingFraction: 0.8)`, `HUD.swift:200`).

**Content (on-brand, `DesignSystem.swift` tokens verified):**
- A small mic/`person.2.wave.2` glyph in `Theme.coral` (the blue accent under the
  legacy name) — one accent per view (BRAND.md).
- Title (`Theme.ink`, `.talkieHeading(14, weight:.semibold)`): "Meeting detected"
  or, with a known app, "Zoom is in a call."
- Subtitle (`Theme.inkSecondary`, 12.5pt): "Record it on-device? Audio stays on your
  Mac." — honest second-person copy, states the privacy fact (BRAND.md voice).
- Browser tier softens it: "A call may have started in Chrome."
- Two controls: a primary **Record** button and a quiet **Dismiss** (`.buttonStyle`
  matching the Meetings tab's controls). One-tap dismiss is the brief's requirement.
- Auto-hide after ~12 s if untouched (treated as a soft dismiss — does NOT mute the
  app, just this session), so a stale banner never lingers.

**Why a banner, not a notification:** an in-app floating panel keeps the trust story
visible and immediate, matches the existing HUD vocabulary, and needs no Notifications
TCC entitlement (which would be a new permission). It also sits above full-screen
meeting windows (`.canJoinAllSpaces, .fullScreenAuxiliary`, `HUD.swift:73`).

**Repeated-dismissal mute:** after N dismissals of the same bundle id (browser tier:
2; meeting app: never auto-mute, since a Zoom call is almost always recordable), add
it to `mutedMeetingApps` and surface a tiny "muted — re-enable in Settings" affordance
once. Honest, non-nagging.

**Brand tokens to use (confirmed in `DesignSystem.swift`):** `Theme.coral`,
`Theme.ink/.inkSecondary/.inkTertiary`, `Theme.positive` (✓ on record success),
`Theme.Radius.card (22)`, `Theme.Space.section (24)`, `.talkieCard()` /
`.glassEffect`, `.talkieHeading`. No new tokens needed.

---

## 9. Permissions / entitlements / Info.plist

**The detector itself needs NO new permission and triggers NO TCC prompt.**
Reading `kAudioHardwarePropertyProcessObjectList` and the per-process
`IsRunningInput`/`PID`/`BundleID` is **metadata reading** of the Core Audio hardware
object — it does not capture audio and does not require `NSAudioCaptureUsage
Description`. Research confirms the consent prompt is tied to **creating a tap /
capturing**, not to enumerating processes (insidegui/AudioCap; Apple's
"Capturing system audio with Core Audio taps"). This is the key reason the detector
can run from launch without nagging the user.

**The recording the banner starts** uses the existing surfaces, no *new* keys beyond
what the branch already adds:
- `NSAudioCaptureUsageDescription` — **already in the branch `Info.plist`** (for
  far-end capture). The TCC consent prompt fires the first time `MeetingRecorder`
  creates the system-audio tap (i.e., when the user taps "Record"), which is the
  correct, expected moment. Main's `Info.plist` lacks this key; it lands with the
  far-end branch merge (01), which is a prerequisite for the *far-end* path. 03 works
  on plain main too (mic-only recording needs only the existing
  `NSMicrophoneUsageDescription`).
- `NSMicrophoneUsageDescription` — already present (`Info.plist`).

**Entitlements:** unchanged. No network, no new sandbox/file entitlements. The single
`com.apple.security.device.audio-input` entitlement already covers mic recording.

**Sandbox impact:** if/when feature 15 sandboxes the app, validate that
`kAudioHardwarePropertyProcessObjectList` enumeration works under the App Sandbox
without a network entitlement (it should — it is local hardware introspection — but
15's note explicitly calls out validating the Core Audio tap under sandbox; fold the
process-list read into that validation).

---

## 10. Privacy posture

**Zero-network is fully preserved.** This feature adds **no** network code. The
detection signal (which app is mic-hot) is read from local Core Audio and:
- never leaves the machine,
- is never written to disk (ephemeral in-actor state only, §6),
- only ever results in an *offer* (the banner), never a silent action.

The trust posture is the feature's selling point and is made explicit in three ways:
1. **Consent banner, never silent record** — the user affirmatively taps "Record."
2. **Honest copy** stating "Audio stays on your Mac" right in the banner (§8).
3. **Off-switch + allowlist editing** in Settings, and per-app mute — the user has
   full control over when Talkie even *looks*.

One subtle privacy nuance to document for the user: the detector can *see which apps
are using the mic* (that's how it works). That observation is local, transient, and
never logged — but feature 15's privacy/proof panel should mention it honestly
("Talkie notices when another app is recording your mic, locally, to offer to record
meetings — it never stores this").

---

## 11. Open-source genericity

- **No hardcoded personal stack.** The allowlist is generic, well-known meeting/
  browser apps — nothing about Jann's setup. It ships as a **built-in default seed**
  (zero config: works out of the box for Zoom/Teams/Meet/etc.) and is fully
  **user-editable** in Settings (add your niche conferencing app by bundle id, remove
  ones you don't want).
- **Zero-config default:** auto-detect on, banner offers for the seed allowlist, no
  third-party app or setup required.
- **Community extension path:** the allowlist is plain data (`[MeetingApp]` JSON), so
  adding apps is a one-line PR or a user setting — no code. The detector itself is a
  generic "another process is on the mic" primitive, useful beyond meetings.
- The **`MeetingContextProvider` protocol** is the formal extension seam: a community
  contributor could ship an alternative provider (e.g., one that reads a calendar API
  or a different signal) without touching the recorder.

---

## 12. Risks, edge cases, failure modes

| Risk / edge case | Behavior / mitigation |
|---|---|
| **`IsRunningInput` listener flakiness** | Avoided entirely — we **poll** at 1.5 s (verified-flaky listeners not used). |
| **Bluetooth mic under-reporting** | Apple-acknowledged bug: some Bluetooth mics report inactive (`IsRunningSomewhere`). `IsRunningInput` per-process is more reliable but may still miss exotic BT setups → graceful: no false *positive*, just a possible missed offer; the manual record button always works. |
| **`BundleID` nil for a mic-hot process** | Treated as low-confidence "unknown app" → no banner by default (avoids noise); covered by `offerForAnyMicApp` opt-in. |
| **False positive: a non-meeting app on the mic** (another dictation tool, a voice memo app, an AVCapture demo) | Allowlist gate means only known apps fire by default. Talkie's *own* dictation is excluded by PID. |
| **Self-trigger** | Excluded by PID (`getpid()`) in the scan, double-checked by bundle id. |
| **Music / video** | Structurally impossible — input-only read (`IsRunningInput`, not Output). |
| **Banner during a live dictation or recording** | Suppressed (`isDictating`, `recorder.isRecording/isStarting/isFinishing`). |
| **Mute / hold / screen-share swap mid-call** | 20 s end-debounce keeps the session alive; the banner already showed once and won't re-nag. |
| **User dismissed, then call genuinely continues** | Not re-shown for that session (keyed by bundle id + first-seen); a *new* call later re-offers. |
| **Browser false alarms** | Browser tier = softer copy + auto-mute after 2 dismissals per app. |
| **Polling overhead** | A few `AudioObjectGetPropertyData` reads every 1.5 s on a background actor — negligible CPU; no audio I/O. |
| **OS < 14.4 (future widened floor, feature 20)** | `isSupported` gate returns false → detector no-ops, manual recording unaffected (graceful degradation). |
| **Core Audio returns a transiently empty process list** | One empty poll ≠ "ended"; the 2-poll start + 20 s end debounce absorb transients. |
| **Feature disabled** | Poll loop not started (or `stop()`ed live via settings) — no scanning at all. |

**Graceful-degradation summary:** every failure mode degrades to "no automatic
offer," never to a wrong recording or a crash. Manual recording (the Meetings tab
button) is always the floor.

---

## 13. Testing & verification

**Unit-testable pure logic** (the repo has no test target yet — this is a good first
candidate; add a SwiftPM test target):
- **Confidence mapping**: `(bundleID, tier) → confidence/banner-decision` table.
- **Allowlist matching**: bundle-id membership, browser-tier vs meeting-app tier.
- **Debounce/session state machine**: feed a synthetic sequence of scan results
  (start blip, sustained, mute gap, end, new call) into `MeetingDetector`'s decision
  function (extract the pure decision logic from the Core Audio I/O so it's testable
  without hardware) and assert: offered-once, not-re-offered-after-dismiss,
  end-after-debounce, re-offer-on-new-session.
- **Self-exclusion**: a scan containing Talkie's PID never yields a signal.

**Manual verification (the `/run` path):**
1. Build & run; ensure auto-detect is on.
2. Start a Zoom/FaceTime/Meet call (or join a test meeting). Within ~3 s the banner
   should appear naming the app. → confirms scan + allowlist + start-debounce.
3. Tap **Dismiss** → banner closes, does not re-appear for that call. → suppression.
4. End the call → after ~20 s the session resets. Start another → banner re-offers.
   → end-debounce + new-session.
5. Tap **Record** on a fresh call → `MeetingRecorder.start()` runs, the recording
   pill/menu-bar indicator appear, banner closes. Stop → a `Meeting` is saved to
   `~/Talkie Meetings/`. → full handoff.
6. Play music/YouTube → **no banner** (input-only proof).
7. Start a dictation while a call is detected → no banner during dictation
   (suppression).
8. Toggle the feature off in Settings → scanning stops (verify via no banner on a
   new call). Toggle on → resumes.
9. Edit the allowlist (remove Zoom) → no banner for Zoom; add a custom bundle id →
   banner for it.

**Instrumentation for the manual pass:** an `NSLog` per state transition (started /
offered / dismissed / ended), gated behind a debug flag, mirroring the existing
`NSLog("Talkie: …")` breadcrumbs in `AppDelegate`.

---

## 14. Effort & phasing

| Sub-step | Size | Notes |
|---|---|---|
| `AudioProcessScanner` (Core Audio reads) | **S** | Strict subset of `SystemAudioCapture`'s proven helpers; selectors verified. |
| `MeetingContextProvider` protocol + `MeetingSignal`/`MeetingApp` types | **S** | Verbatim from §2.5; trivial. |
| `MeetingDetector` actor (poll loop + debounce/session state) | **M** | The state machine is the substance; keep the decision logic pure for tests. |
| `MeetingConsentBanner` (panel + SwiftUI view) | **M** | Mostly a fork of `HUDController`/`HUDView`, made interactive. |
| `AppDelegate` wiring (own, start, suppress, handoff, settings re-bind) | **S** | Follows existing store/HUD wiring. |
| `AppSettings` keys + JSON allowlist encode/decode | **S** | One new pattern (Codable→Data in UserDefaults). |
| `SettingsView` Meetings sub-page (toggle + allowlist chips) | **M** | Reuse the dictionary-chip FlowLayout UI. |
| Unit tests (decision logic) + first test target | **M** | Bootstraps testing for the repo. |

**MVP slice (ship first, ~S+M):** `AudioProcessScanner` + `MeetingDetector` (high-
confidence allowlist only, fixed built-in list, 2-poll start / 20 s end) + a minimal
two-button banner + `AppDelegate` wiring + a single Settings on/off toggle. This
already delivers "Zoom starts → banner → Record." Defer: user-editable allowlist UI,
browser-tier softening, per-app mute, the `offerForAnyMicApp` opt-in, and the camera/
assertion confidence boosters.

**Full feature:** the MVP plus the editable allowlist + tiering + mute + opt-in +
tests, and the `eventContext` stub ready for 04 to fill.

---

## 15. Dependencies & interactions

**Needs (soft / hard):**
- **Hard at runtime: `MeetingRecorder`** — the thing "Record" starts. Works against
  *either* main's mic-only recorder or the branch's far-end recorder. The far-end
  branch (01) is the *better* target (richer transcripts) but **not a blocker** —
  03 can land on main and immediately improve when 01 merges. The branch also brings
  `NSAudioCaptureUsageDescription` (needed only for far-end capture).
- **Soft: `MeetingContextProvider` (the protocol)** — 03 introduces it; if the
  protocol file is being added by the Tier-0 protocol pass, coordinate so it's
  defined once.

**Enables:**
- **04 (calendar)** — shares the *same* `MeetingContextProvider` instance: 03 owns
  `detectActiveMeeting()`, 04 fills `eventContext(at:)`. Together they give the
  recorder both "a meeting started" *and* "it's the 2pm standup with Sarah & Dave."
- **05 (context graph)** — auto-detected → auto-recorded meetings are the graph's
  richest feed; 03 is the valve that makes those meetings get captured at all. The
  detected app bundle id is a candidate provenance field.
- **01 (far-end)** — auto-detect is what turns the far-end recorder from "a button
  you forget" into "it offers every call."

**Overlaps / coordinate with:**
- **HUD (`HUD.swift`)** — the banner is a deliberate parallel of `HUDController`.
  Decide whether to extract a shared `FloatingPanelController` base (clean) or fork
  (fast). Recommend a small shared base to avoid two copies of the
  panel/reposition/notch logic. The dictation HUD and the consent banner can both be
  visible (different concerns) but should be vertically offset so they don't overlap
  under the notch.
- **15 (sandbox/zero-net proof)** — fold the process-list read into 15's
  under-sandbox validation; surface the "Talkie notices mic-hot apps locally" fact in
  the privacy panel.
- **13 (per-app profiles)** — the allowlist is bundle-id keyed, same space as per-app
  profiles; keep them separate stores but consistent in shape.

---

## Sequencing note

03 sits in `_UNIFICATION.md`'s Tier-1 "product surfaces." It depends only lightly on
Tier 0 (it introduces, rather than consumes, `MeetingContextProvider`, and it does
not need the context graph). Recommended order: land the **MVP slice against main's
recorder** to prove the detection + banner UX early, then upgrade automatically when
01 (far-end) and 04 (calendar) arrive through the shared provider seam.
