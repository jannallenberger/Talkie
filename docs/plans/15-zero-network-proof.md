# 15 — Provable zero-network privacy

> Feature 15 in the unification spine. Read `_CURRENT_STATE.md` (ground truth) and
> `_UNIFICATION.md` §4.1 + the per-feature contract for 15 (§6) first; this plan
> honors both. All paths absolute. `file:line` anchors point at `main` unless
> marked **[branch]** (`feat/meeting-far-audio`).

## 1. Summary

Turn Talkie's verified zero-network fact into a *provable, marketable* feature by
(a) **keeping the Hardened Runtime and deliberately NOT shipping
`com.apple.security.network.client`** as the structural wall (NOT the full App
Sandbox — see §4, which would break paste injection), (b) an in-app **Privacy
proof panel** that lists the app's actual entitlements live from its own code
signature plus a one-tap "verify it yourself" path (Little Snitch / `lsof` /
`nettop`), and (c) a hard **build-flavor split** (`Talkie` default vs.
`Talkie (Connected)`) plus a `requiresNetwork` refusal gate so the opt-in
networked features (18 Claude bridge, 07b connector, 16 Sparkle) can never leak
into the default build.

## 2. Why it matters

The strategic thesis is "your entire voice layer for the Mac… one private brain,
$0, open source. Nothing leaves your machine. **Provably.**" Wispr Flow and
Granola are cloud companies — their audio and your meeting transcripts transit
their servers by design; they *cannot* make this claim. Talkie can, and "provably"
is the word that gets a privacy-tool to the top of Hacker News: a skeptical
audience does not believe marketing copy, it believes (1) an entitlement list it
can read, (2) open source it can grep, and (3) a firewall that never fires. This
feature manufactures all three and packages them so a reviewer can confirm
"Talkie opened zero connections" in 60 seconds. It also builds the *structural*
wall (the entitlement split + `requiresNetwork` refusal) that every later
networked feature (18/07b/16) must respect — per `_UNIFICATION.md` §5 sequencing
decision #3, this wall must exist **before** the first networked module, so the
boundary is enforced by construction, not retrofitted.

## 3. Current state in the code

What exists today (this is the raw material, and it is already strong):

- **Entitlements** — `/Users/jann/Talkie/Resources/talkie.entitlements:7-8`:
  exactly ONE key, `com.apple.security.device.audio-input`. No network, no
  sandbox, no file-access entitlements. This is the verified single-entitlement
  baseline.
- **Zero network code** — verified by `grep -rniE
  "URLSession|NSURLConnection|http://|https://|Network\.|NWConnection|CFStream"
  Sources/` returning nothing on both `main` and `feat/meeting-far-audio`
  (`_CURRENT_STATE.md` lines 9-12). Confirmed again during this plan.
- **Info.plist** — `/Users/jann/Talkie/Resources/Info.plist`: bundle id
  `com.coralate.talkie` (`:6`), `LSMinimumSystemVersion 26.0` (`:26`), three
  usage strings (mic `:33`, speech `:35`, input-monitoring `:37`). **[branch]**
  adds `NSAudioCaptureUsageDescription`.
- **Hardened Runtime + signing** — `/Users/jann/Talkie/scripts/build_app.sh`:
  default ad-hoc signature; `--entitlements Resources/talkie.entitlements`
  (`:83`); Hardened Runtime (`--options runtime --timestamp`) is added only for
  Developer ID builds (`:86-88`). `/Users/jann/Talkie/scripts/notarize.sh:28-31`
  always signs with `--options runtime` + the same entitlements file. So the
  **shipped (notarized) build already runs under the Hardened Runtime** — the
  exact regime where "absence of `network.client`" is a meaningful, signed,
  auditable fact.
- **TCC permissions surfaced** — `/Users/jann/Talkie/Sources/Talkie/Permissions.swift`:
  Accessibility (`AXIsProcessTrusted`, `:18`), Input Monitoring
  (`CGPreflightListenEventAccess`, `:19`), Microphone (`:20`), each with a
  System-Settings deeplink (`:40-50`). Surfaced in `PermissionsSettings`
  (`SettingsView.swift:783-878`).
- **The APIs the privacy wall must not break** (each assessed in §4):
  - Global hotkey: a **listen-only `CGEventTap`** (`HotKeyMonitor.swift:70-79`,
    `.listenOnly`) — needs Input Monitoring.
  - Paste injection: **`CGEvent.post`** of ⌘V (`TextInjector.swift:135-136`) and
    a per-character Unicode fallback (`:149-150`) — needs Accessibility / PostEvent.
  - Mic: `AVAudioEngine` + `AVCaptureDevice` (`AudioCapture.swift:49,55-59`).
  - Speech: `SpeechAnalyzer`/`SpeechTranscriber` actor (`TranscriptionEngine.swift`).
  - On-device LLM: Foundation Models `SystemLanguageModel.default` (`CleanupEngine.swift`).
  - Far-end capture **[branch]**: Core Audio global process tap
    (`SystemAudioCapture.swift`, `AudioHardwareCreateProcessTap` +
    `AudioHardwareCreateAggregateDevice`).
  - Secure-input probe: `IsSecureEventInputEnabled` (`TextInjector.swift:31,81`).
  - File access: `~/Library/Application Support/Talkie/` and **`~/Talkie Meetings/`**
    (`AppPaths.swift:7-22`) — the latter deliberately a plain home folder, not
    `~/Documents`, to stay out of TCC.

**Honest gap:** none of the *proof surface* exists yet. There is no privacy
panel, no live entitlement readout, no build-flavor split, no `requiresNetwork`
gate (the `TranscriptionBackend`/`Summarizer` protocols that carry that flag are
themselves not yet built — they are Tier-0 work in `_UNIFICATION.md` §2). What
exists is the *fact* (zero network, one entitlement, Hardened Runtime); this
feature builds the *evidence and the structural lock*.

## 4. Design & approach — the load-bearing correction to the brief

**The brief proposes "adopt the App Sandbox with NO network entitlement so the OS
itself forbids any outbound connection." Research says: do NOT adopt the full App
Sandbox. It would break Talkie's core feature.** Here is the precise, per-API
verdict, because this is the heart of the feature.

### 4.1 Why the full App Sandbox is the wrong tool

The App Sandbox **blocks `CGEventPost` / `CGEvent.post`** — synthesizing keystrokes
into other apps is exactly the kind of cross-app control the sandbox exists to
prevent. Apple DTS and multiple Mac-App-Store rejections confirm sandboxed apps
cannot post synthetic events for general use, and `kTCCServicePostEvent`
(Accessibility-to-post) is rejected for non-accessibility purposes. Talkie's
**entire dictation output path** is `TextInjector.postCommandV()` (⌘V,
`TextInjector.swift:135-136`) and the `typeUnicode` fallback (`:149-150`). Under
the App Sandbox these become no-ops: **dictation would transcribe and then fail to
type anything into the focused app.** That is the product. So the App Sandbox is
disqualified for the *primary* distribution build.

Per-API sandbox verdict (for completeness, and to justify the decision):

| API (file) | Under full App Sandbox |
|---|---|
| `CGEventTap` listen-only hotkey (`HotKeyMonitor.swift`) | **OK** — works via Input Monitoring (`CGPreflightListenEventAccess`), allowed even on MAS. |
| `CGEvent.post` paste / type (`TextInjector.swift`) | **BLOCKED** — synthetic event posting is denied; the core injection dies. **Disqualifying.** |
| `IsSecureEventInputEnabled` (`TextInjector.swift`) | OK (read-only query). |
| Mic `AVAudioEngine`/`AVCaptureDevice` | OK with `com.apple.security.device.audio-input` (already held) + mic TCC. |
| `SpeechAnalyzer`/`SpeechTranscriber` | OK (on-device, no extra entitlement; model assets download is system-mediated — but a download IS network at the OS layer; see §10). |
| Foundation Models (`CleanupEngine`) | OK on-device. |
| Core Audio process tap **[branch]** (`SystemAudioCapture.swift`) | **Uncertain/likely BLOCKED** — `AudioHardwareCreateAggregateDevice` and global process taps historically need privileges a sandbox withholds; needs empirical test. Another reason the full sandbox is risky. |
| Accessibility `AXIsProcessTrusted` (`Permissions.swift`, `LearningEngine`, `AppContext`) | Sandbox "generally blocks Accessibility APIs"; AX *reads* for context-mining/learning would degrade or die. |
| `~/Talkie Meetings/` write (`AppPaths.swift:17-22`) | **BLOCKED** — outside the container. Would require `com.apple.security.files.user-selected.read-write` + a user folder pick + security-scoped bookmarks, defeating the "plain folder you can point Claude at" design. |

### 4.2 The right wall: Hardened Runtime + *absent* `network.client` + structural separation

The honest, accurate mechanism for "provably zero network" that does **not** break
the app:

1. **Keep the Hardened Runtime** (already on for notarized builds). This is the
   signed, tamper-evident envelope. The entitlements are baked into the code
   signature; a skeptic can dump them with `codesign -d --entitlements - Talkie.app`
   and see exactly one capability (`device.audio-input`) and **no
   `com.apple.security.network.client`**.

2. **Be precise about what "no network.client" guarantees, and don't overclaim.**
   Research finding (Apple DTS / sandbox docs): the `network.client` entitlement
   is *enforced by the kernel only when the App Sandbox is enabled*. For a
   **non-sandboxed** Hardened-Runtime app, the absence of `network.client` is
   **documentary, not a kernel-enforced block** — the Hardened Runtime does not
   itself firewall outbound traffic. So the truthful claim for the default build
   is: *"Talkie ships with no network entitlement and contains no network code
   (open source, grep it); verify with your own firewall."* The proof is
   **source + signature + a live firewall test**, not a kernel guarantee. This
   distinction is exactly the kind of honesty `_UNIFICATION.md` §4.3 demands ("never
   invent… cite provenance"); overclaiming "the OS forbids it" would be false for
   the non-sandboxed build and would get torn apart on HN.

3. **Manufacture the kernel-enforced proof anyway, without breaking the app, via a
   sandboxed audit artifact** (the credible upgrade over pure documentation):
   - **Option A (recommended, ships):** a tiny **App-Sandboxed XPC helper /
     companion target** that does the *non-injecting* heavy work — or, more
     simply, ship a **sandboxed "audit build"** of the same source compiled with
     `com.apple.security.app-sandbox = true` and no `network.client`, used purely
     to *demonstrate* the kernel block in CI/screencast (it will fail to paste,
     which is fine — its only job is to prove that with the sandbox on and no
     network entitlement, an attempted connection is killed by the kernel). This
     gives the marketable "the OS itself refuses" claim, attached to an artifact,
     without shipping it as the daily driver.
   - **Option B:** factor the model/LLM work into a sandboxed XPC service (which
     *can* be fully sandboxed because it never posts events or writes the meetings
     folder), so the part of Talkie that touches your speech runs in a
     kernel-enforced no-network jail, while the thin UI/injection shell stays
     Hardened-Runtime-only. Higher effort; defer to a later phase.

4. **Structural network wall (the part that actually matters long-term):** enforce
   the boundary in the *build system and the type system*, per `_UNIFICATION.md`
   §3 module boundaries:
   - The default `Talkie` target links **no** network-capable module
     (`TalkieBridge`/`TalkieMCP` are separate targets, `_UNIFICATION.md:497-505`).
   - A compile-time flag `TALKIE_CONNECTED` selects the flavor. The default build
     defines it nowhere; entitlements file has no `network.client`.
   - A runtime **`requiresNetwork` refusal gate** (§5): any `Summarizer` /
     `TranscriptionBackend` whose `requiresNetwork == true` (e.g. `ClaudeBridge`)
     **fatally refuses to instantiate** in the default flavor. This is the
     `_UNIFICATION.md` §2.1/§2.2 contract made real — the seam exists so 18 is a
     drop-in, and the gate guarantees it can't drop in to the wrong build.

### 4.3 The proof panel (the user-facing half)

A read-only **Privacy** sub-page that renders *live* facts, not hardcoded copy:

- **Entitlements, read from our own signature at runtime** via the Security
  framework (`SecCodeCopySelfSigningInformation` →
  `kSecCodeInfoEntitlementsDict`) so the list is literally what the OS sees, not a
  string we typed. Render each as a row: ✓ Microphone (`device.audio-input`);
  then the *absence* assertions: "✓ No outgoing-network entitlement", "✓ No
  file-system entitlement beyond your two folders". If we ever ship the Connected
  flavor, the panel turns the network row red/honest automatically (it reads the
  real signature).
- **Network-code statement:** "Talkie's source contains zero networking code.
  This is open source — verify it: `grep -rn URLSession Sources/`." With a
  copy-button for the command and a link to the repo.
- **A skeptic's checklist (the headline):** three one-tap "Verify it yourself"
  rows that copy a command to the clipboard and open Terminal / the relevant app:
  - `nettop -p $(pgrep Talkie)` — live, no third-party tool, shows zero bytes.
  - `lsof -i -a -p $(pgrep Talkie)` — no open sockets.
  - "Use Little Snitch / LuLu and watch Talkie never appear." (Little Snitch is
    the gold-standard outbound-firewall reviewers already trust.)
- **What leaves your Mac, by feature:** a table that is honest about the *only*
  network-adjacent operations: (a) **one-time speech-model + Foundation-Models
  asset downloads**, performed by **macOS itself** (not Talkie code) through
  `AssetInventory`/system services on first use of a locale — disclosed as "macOS
  downloads the on-device model once; Talkie sends nothing"; (b) in the Connected
  flavor only, the bridge/connector, off by default. Provenance-honest, per
  `_UNIFICATION.md` §1.3 spirit.

## 5. New & changed files/types

New, under `Sources/Talkie/Privacy/` (a new folder, organizational only — still
one default target, per `_UNIFICATION.md` §3):

```swift
// Privacy/EntitlementInspector.swift
/// Reads THIS running binary's signed entitlements via the Security framework so
/// the privacy panel shows ground truth, not hand-typed claims.
enum EntitlementInspector {
    struct Capability: Identifiable, Sendable {
        let id: String          // entitlement key, e.g. "com.apple.security.device.audio-input"
        let humanName: String   // "Microphone"
        let present: Bool
        let benign: Bool        // true = expected/safe; false = network/escalation
    }
    /// The full list (present + notable-absent assertions) for the panel.
    static func capabilities() -> [Capability]
    /// True iff com.apple.security.network.client is ABSENT from our signature.
    static func hasNoNetworkEntitlement() -> Bool
    /// True iff com.apple.security.app-sandbox is present (audit/Connected detection).
    static func isSandboxed() -> Bool
}

// Privacy/NetworkPosture.swift
/// The single source of truth for which build flavor is running and what the
/// honest disclosure copy is. Pure, Sendable.
enum NetworkPosture: Sendable {
    case localOnly          // default Talkie: no network module compiled, no entitlement
    case connected          // Talkie (Connected): TalkieBridge linked, opt-in features available

    static var current: NetworkPosture {
        #if TALKIE_CONNECTED
        return .connected
        #else
        return .localOnly
        #endif
    }
    var headline: String
    var detail: String
}

// Privacy/PrivacyProof.swift
/// The "verify it yourself" command catalog (nettop/lsof) + the network-code
/// grep statement. Pure data + clipboard helpers; no shell execution by us.
enum PrivacyProof {
    struct Check: Identifiable, Sendable {
        let id: String
        let title: String
        let explanation: String
        let command: String     // copied to clipboard; we never run it for them
        let opensApp: String?   // "Terminal", or nil
    }
    static func checks() -> [Check]
    static let grepStatement = "grep -rn \"URLSession\\|http\" Sources/   # → nothing"
}

// Privacy/RequiresNetworkGate.swift
/// The structural refusal gate. Called at the composition root before any
/// networked organ is instantiated. In .localOnly it traps; in .connected it
/// requires the explicit user opt-in flag.
enum RequiresNetworkGate {
    /// Returns the backend only if the current posture + consent allow it; else nil.
    static func authorize<T>(_ make: () -> T, requiresNetwork: Bool, userOptedIn: Bool) -> T?
}
```

New UI: `Privacy/PrivacyView.swift` — a `SubPage`-styled pane (reuse
`SettingsView.swift:479` `SubPage` scaffold + `talkieCard`) showing the three
blocks from §4.3.

Changed:

- **`SettingsView.swift`** — add a `SettingsRoute.privacy` case and a `row(...)`
  in `SettingsHome` (`:410-427`) titled "Privacy" with `lock.shield.fill` /
  `featherGreen`, subtitle "Nothing leaves your Mac" (or the honest Connected
  string). Wire `subpage(.privacy)` → `PrivacyView`.
- **Protocols (Tier-0, may be built alongside)** — `TranscriptionBackend`,
  `Summarizer` already carry `var requiresNetwork: Bool` per `_UNIFICATION.md`
  §2.1-2.2. This feature **consumes** that flag at the composition root via
  `RequiresNetworkGate`; it does not define the protocols.
- **`AppDelegate.swift`** — at the composition root, route any future networked
  organ through `RequiresNetworkGate.authorize`. In the default build this is a
  no-op (nothing networked is even compiled in); the gate is the belt to the
  build-separation suspenders.
- **`Package.swift`** — keep the single default target. Add the Connected flavor
  as a **separate executable target / product** (or an `unsafeFlags` define
  `-D TALKIE_CONNECTED` selected by an env var in the build script) that links
  `TalkieBridge`. The default product never references it.
- **`scripts/build_app.sh`** — add a `--flavor connected` path that signs with a
  *second* entitlements file `Resources/talkie.connected.entitlements` (adds
  `com.apple.security.network.client`). The default path is unchanged and uses
  the existing `talkie.entitlements` (no network).
- **New `Resources/talkie.connected.entitlements`** — `device.audio-input` +
  `com.apple.security.network.client`. Used ONLY by the connected flavor.
- **(Optional, audit artifact) `Resources/talkie.audit-sandbox.entitlements`** —
  `device.audio-input` + `com.apple.security.app-sandbox = true`, no network. A CI
  target that proves the kernel block; not shipped to users.

## 6. Data model & persistence

Almost none — this feature is largely read-only over facts the OS already holds.

- **Entitlements:** read live from the code signature at view time. Not persisted.
- **One UserDefaults scalar (Connected flavor only):** `networkFeaturesOptedIn:
  Bool` (default `false`), added to `AppSettings.swift` alongside the existing
  keys (`:151-211`), following the same `@MainActor ObservableObject` +
  `UserDefaults` convention. In `.localOnly` it is irrelevant (never read).
- **No new files in `~/Library/Application Support/Talkie/`.** No migration:
  pre-existing installs gain a read-only panel; nothing they stored changes. The
  default flavor's on-disk footprint is byte-identical to today.
- Back-compat: opening an older meeting/history is unaffected; the panel only
  reports current signature + posture.

## 7. Unification contract

Per `_UNIFICATION.md` §6 / feature 15:

**This feature EXPOSES:**
- **The two build flavors** — `Talkie` (sandbox-free Hardened-Runtime default,
  **no** `network.client`) and `Talkie (Connected)` (adds `network.client`, links
  `TalkieBridge`) — and the `NetworkPosture.current` discriminator every feature
  can read.
- **The `requiresNetwork` enforcement point** (`RequiresNetworkGate.authorize`) —
  the runtime refusal that backs up the build separation. 18/07b/20's networked
  organs MUST route through it. This realizes the `_UNIFICATION.md` §2.1 promise
  ("the sandbox/consent layer refuses to instantiate any backend whose
  `requiresNetwork == true` unless the user has flipped the explicit opt-in").
- **The in-app privacy/proof panel** + the `EntitlementInspector` API (other
  features, e.g. a future "what would this expose?" consent dialog in 18, can
  reuse the live-entitlement readout).
- **The structural network wall** (module/target separation) that every networked
  feature respects.

**This feature CONSUMES:**
- **Nothing it can't already verify locally.** It reads its own code signature
  (Security framework) and the build flavor. It does **not** read the personal
  context graph (05) — but it is the feature that makes 05's "the graph never
  leaves the machine" claim *true and provable*. Per the §6 note,
  **provenance (05 §1.3) is the honest "here's exactly what's on your Mac" data**
  that a richer version of the panel can later surface ("here is every entity, and
  none of it has ever been sent anywhere"). For the MVP, the panel cites entitlements
  + source, not the graph; a Phase-3 enhancement links to the graph for the full
  "audit your own brain" story.
- The `TranscriptionBackend` / `Summarizer` protocols' `requiresNetwork` flag
  (Tier-0; built alongside per `_UNIFICATION.md` §5).

**The §6 sequencing obligation:** "lock this BEFORE 18/07b exist so the wall is
built-in, not bolted-on." Concretely: ship the build-flavor split + the
`RequiresNetworkGate` *before* any code in `TalkieBridge`/`TalkieMCP` can call
out, so 18/07b are physically unable to compile into the default product.

## 8. UI / UX

- **Where:** a new **Privacy** row in the Settings index (`SettingsHome`,
  `SettingsView.swift:410-427`), pushing a `PrivacyView` `SubPage`
  (`SettingsView.swift:479-497`). Not a new top-level tab — it belongs with the
  other trust/permission surfaces and keeps the sidebar (`SettingsTab`,
  `SettingsView.swift:4-46`) unchanged. (Consider a small green "lock.shield"
  affordance in `OnboardingView`'s permissions step linking here, so the privacy
  story is part of first-run.)
- **Brand tokens** (`DesignSystem.swift` is the value source of truth per
  `_CURRENT_STATE.md` §5):
  - Cards via `.talkieCard()` (surface fill, two whisper shadows, no outline,
    squircle `Radius.card 22`).
  - One accent per view: `Theme.coral` (now blue) for the single emphasis (the
    headline "Nothing leaves your Mac"); the feather palette only for the
    *data-like* entitlement rows (green ✓ = `featherGreen`, a single
    `Theme.warning`/`danger` for any network row in the Connected flavor).
  - Serif (`Font.talkieDisplay`) for the page hero line; `talkieHeading` for body;
    `Eyebrow` for section labels.
  - `MarkdownText` for any rich copy; `FlowLayout` if entitlement chips are used.
  - Copy-to-clipboard buttons reuse the existing pasteboard pattern
    (`SettingsView.swift:293`).
- **Voice/tone** (`BRAND.md` philosophy + `_UNIFICATION.md` §4.3): warm, honest,
  second person. The hero is **"Nothing leaves your Mac."** with a one-line honest
  qualifier — for the default build, "No network entitlement. No network code. You
  can check." For Connected, the panel says exactly what's enabled and that it's
  off until you turn it on. **Never** the false-precision claim "the OS makes it
  impossible" for the non-sandboxed build (§4.2 #2) — that's the honesty invariant.

## 9. Permissions / entitlements / Info.plist

- **Default flavor:** **no new entitlements, no new Info.plist keys, no new TCC
  prompts.** The entire MVP panel is read-only over the existing signature. This
  is the point — the default build's permission surface is *unchanged* and remains
  the single `device.audio-input` capability (plus the **[branch]**
  `NSAudioCaptureUsageDescription` Info.plist string for far-end, which is a usage
  string, not an entitlement).
- **Connected flavor:** new `Resources/talkie.connected.entitlements` adding
  `com.apple.security.network.client`. This flavor is a separate, clearly-labeled
  build; it does not affect the default.
- **Audit artifact (optional):** `talkie.audit-sandbox.entitlements` with
  `com.apple.security.app-sandbox = true`. Used only to demonstrate the
  kernel-enforced block in CI/marketing; not distributed.
- **Hardened Runtime:** already applied to notarized builds
  (`build_app.sh:86-88`, `notarize.sh:29`); no change.
- **Sandbox impact:** intentionally **NOT adopting** the full App Sandbox for the
  shipping build (§4.1 — it breaks `CGEvent.post` paste, likely breaks the Core
  Audio tap, breaks `~/Talkie Meetings/`, and degrades AX context-mining).

## 10. Privacy posture

- **Default build preserves zero-network** exactly as today: no network code, no
  `network.client`, Hardened Runtime, single audio-input entitlement. The feature
  *adds evidence*, not behavior.
- **The one honest asterisk to disclose in the panel:** first-time use of a speech
  locale or Apple Intelligence triggers a **system-mediated, on-device model
  download performed by macOS itself** (`AssetInventory` for SpeechTranscriber;
  Foundation Models asset provisioning) — `TranscriptionEngine.ensureModelInstalled`
  (`:98-108`) *requests* the install but the network transfer is the OS's, not
  Talkie's. The panel must state this plainly: "macOS downloads the on-device
  speech model once; after that, and for everything else, Talkie makes no
  connections — and Talkie itself never opens one." Hiding it would be the kind of
  dishonesty the thesis forbids; disclosing it is actually *stronger* (it shows we
  audited even the system's behavior).
- **Networked features stay off by default, opt-in, disclosed, separated**
  (`_UNIFICATION.md` §4.1): 18/07b/16 live in `TalkieBridge`/`TalkieMCP`, compiled
  only into the Connected flavor, gated by `networkFeaturesOptedIn` and
  `RequiresNetworkGate`. The panel discloses, per feature, exactly what would be
  sent and when.

## 11. Open-source genericity

- **No hardcoded personal stack.** The "verify it yourself" checks use
  **first-party, universally-available tools** (`nettop`, `lsof` ship with macOS)
  as the zero-config default; Little Snitch / LuLu are mentioned as *optional*
  third-party verifiers, never required. No Obsidian, no specific editor, no
  Claude-anything in the default panel.
- **The proof is the source.** Because Talkie is open source, the strongest claim
  ("grep it yourself") is free and reproducible by anyone — the panel surfaces the
  exact command. The community can extend the panel's check catalog (`PrivacyProof.checks()`
  is a plain array) with their preferred verifier without touching core.
- **Floor honesty:** the panel notes macOS 26 + Apple Silicon is required for the
  on-device models (per the global invariant), so the privacy guarantee is
  scoped to the platform the app actually runs on; feature 20's wider-hardware
  backends keep the same `requiresNetwork == false` posture.

## 12. Risks, edge cases, failure modes

- **Overclaiming.** The single biggest risk: asserting "the OS forbids any
  connection" for the **non-sandboxed default build**. That is false (Hardened
  Runtime ≠ kernel network jail without the sandbox). Mitigation: the panel's copy
  is reviewed against §4.2 #2; the kernel-enforced claim is only ever attached to
  the **sandboxed audit artifact**, clearly labeled as such. Graceful behavior:
  err toward the weaker, true claim.
- **`EntitlementInspector` failure.** `SecCodeCopySelfSigningInformation` can fail
  (ad-hoc/unsigned dev builds). Degrade: show "Could not read signature (unsigned
  dev build) — `codesign -d --entitlements -` to inspect" rather than a fake list.
- **Ad-hoc signature churn.** Dev builds re-sign each rebuild (`build_app.sh:30-33`)
  → TCC re-prompts; irrelevant to the network claim but the panel should not imply
  the ad-hoc build is the notarized one.
- **Sandbox audit build can't paste / can't write meetings** — *expected*; that
  artifact's only job is the kernel-block demo. Document it so no one ships it by
  mistake (guard with a loud build-time warning).
- **Connected flavor mislabeled.** If the network entitlement ever leaks into the
  default entitlements file, the panel (reading the live signature) would *show it*
  — which is the self-checking property we want, but CI must also fail. Mitigation:
  a CI assertion (`codesign -d --entitlements` | assert no `network.client`) on the
  default product (§13).
- **Foundation Models / Speech model download** mistaken for Talkie phoning home by
  a firewall watcher (they'll see `nsurlsessiond`/system daemons, not Talkie).
  Mitigation: the panel pre-empts this in the disclosure table (§10).
- **Core Audio tap under any future sandbox push** — if Option B (sandboxed XPC for
  the model) is pursued, the far-end tap must stay in the unsandboxed shell;
  factor accordingly.

## 13. Testing & verification

- **CI entitlement assertion (the regression that protects the thesis):**
  `codesign -d --entitlements - Talkie.app 2>&1 | grep -q network.client && exit 1`
  on the **default** product → build fails if a network entitlement ever appears.
  Symmetrically assert the Connected product *does* carry it.
- **Source grep gate in CI:** `grep -rniE
  "URLSession|NSURLConnection|NWConnection|CFStream|Network\\.framework|http://|https://"
  Sources/Talkie/` (the default target's sources) → must be empty. (TalkieBridge
  is allowed to match.)
- **Live no-traffic test (manual + scriptable):** run the notarized default build,
  exercise dictation + a meeting + the dashboard Brief, while `nettop -p
  $(pgrep Talkie)` and `lsof -i -a -p $(pgrep Talkie)` run → assert zero
  Talkie-owned sockets/bytes (system model-download daemons excluded and
  explained). This is the exact demo the panel tells a skeptic to run — dogfood it.
- **Little Snitch screencast** for the launch: install Talkie behind Little Snitch
  in "alert" mode, use every feature, show it never produces an alert. This is the
  HN-ready artifact.
- **Sandboxed audit-build test:** compile with
  `talkie.audit-sandbox.entitlements`, attempt an outbound connection from a test
  hook → assert the kernel kills it (sandbox violation in Console). Proves the
  "with sandbox on + no network entitlement, the OS itself refuses" claim that
  backs the marketing, attached to the right artifact.
- **Panel unit tests:** `EntitlementInspector.hasNoNetworkEntitlement()` returns
  true for the default fixture, false for the connected fixture;
  `NetworkPosture.current` matches the compile flag. (No test target exists yet —
  `_CURRENT_STATE.md` §8 — so this also seeds the first test target.)
- **`/verify` path:** build the app (`scripts/build_app.sh`), open Settings →
  Privacy, confirm the three blocks render with live entitlements; click each
  "verify yourself" row and confirm the command lands on the clipboard and the app
  opens.

## 14. Effort & phasing

- **MVP slice (S–M):** the **read-only Privacy panel** + `EntitlementInspector` +
  `NetworkPosture` (default `.localOnly` only) + `PrivacyProof` checks, wired into
  Settings. No build-flavor split needed yet (nothing networked exists). This
  alone delivers the marketable surface and is shippable now. **S** for the
  inspector/posture/checks, **S** for the SwiftUI pane, **S** for the Settings
  wiring → small-to-medium overall.
- **Phase 2 — the structural wall (M):** `RequiresNetworkGate`, the
  `talkie.connected.entitlements` file, the `build_app.sh --flavor connected`
  path, the `Package.swift` target/flag split, the CI entitlement + grep
  assertions. Build this **before** 18/07b write any network code
  (`_UNIFICATION.md` §5).
- **Phase 3 — the kernel-proof artifact + graph-aware panel (M–L):** the
  sandboxed audit build/target + its CI test (the "OS itself refuses" demo); and
  the richer panel that, with 05 present, surfaces provenance ("every entity, none
  ever sent"). The optional sandboxed-XPC-for-the-model (Option B) is **L** and
  can be deferred indefinitely — it is a credibility upgrade, not a requirement.

Recommended: ship MVP + Phase 2 together as one "privacy" milestone, since Phase 2
is what makes the wall *structural*; Phase 3 is a fast-follow marketing asset.

## 15. Dependencies & interactions

- **Enables / gates (must precede):** 18 Claude bridge, 07b remote connector, 16
  Sparkle auto-update — all networked, all must compile only into the Connected
  flavor and route through `RequiresNetworkGate`. Per `_UNIFICATION.md` §5 decision
  #3, 15's wall lands before these.
- **Depends on (loosely, Tier-0):** the `TranscriptionBackend` / `Summarizer`
  protocols (for their `requiresNetwork` flag). The MVP panel needs neither —
  it's pure OS-fact introspection — so 15's MVP can ship independently; the gate
  (Phase 2) wants the protocols defined.
- **Reinforces:** 05 Context Graph (makes "the graph never leaves your machine"
  provable; the panel can later read 05's provenance), 06 MCP (the local
  stdio/no-network server is consistent with and demonstrated by the panel), 10
  export (the `~/Talkie Meetings/` plain-folder default is part of the "your data,
  your disk" story the panel tells).
- **Touches:** `SettingsView.swift` (new route + row), `AppDelegate.swift`
  (gate at composition root), `Package.swift` + `scripts/build_app.sh` +
  `Resources/*.entitlements` (flavor split). No change to the dictation pipeline,
  meetings, or the shipped default's behavior/footprint.
```

---

### Sources

Sandbox vs. APIs (the load-bearing research):
- [Apple DevForums — sandbox & CGEventTap / Input Monitoring vs Accessibility](https://developer.apple.com/forums/thread/789896)
- [Apple DevForums — Mac App Store rejection for CGEvent.post (synthetic keystrokes blocked in sandbox)](https://developer.apple.com/forums/thread/820594)
- [Apple DevForums — Accessibility/PostEvent rejected for non-accessibility use](https://developer.apple.com/forums/thread/756130)
- [Apple — Capturing system audio with Core Audio taps (macOS 14.4+)](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [Apple — Enabling App Sandbox (network.client governs URLSession outbound)](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
- [Apple DevForums — network entitlement enforced under sandbox (Quinn/DTS)](https://developer.apple.com/forums/thread/689000)
- [Apple — App Sandbox user-selected.read-write + security-scoped bookmarks](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
- [lapcatsoftware — Hardened Runtime and Sandboxing (independent technologies)](https://lapcatsoftware.com/articles/hardened-runtime-sandboxing.html)
- [Little Snitch — outbound firewall (the skeptic's verifier)](https://www.obdev.at/products/littlesnitch/index.html)
