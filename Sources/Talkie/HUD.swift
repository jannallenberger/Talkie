import AppKit
import SwiftUI

/// Visual state of the dictation HUD. These phases are the *contract* between the
/// dictation pipeline (AppDelegate) and the pill: each one maps to a real stage
/// of capture so the pill always reflects what's actually happening.
///
///   hidden       — nothing going on.
///   arming       — key pressed; mic permission / model load / session warm-up.
///                  Audio is NOT flowing yet (gray dot).
///   listening    — audio is live and being captured (red REC dot + red waveform).
///   transcribing — same as listening for the pill; the recognizer is emitting
///                  partials (which go to the focused app, never into the pill).
///   processing   — key released; polishing + inserting the transcript.
///   inserting    — text delivered to the focused app.
///   copyPrompt   — couldn't paste (no editable field); tap the pill to copy.
///   copied       — brief confirmation after a tap-to-copy.
///   commandPreview — a voice command produced a proposed replacement; the pill
///                  shows it and waits for you to Insert or Undo before anything
///                  touches the focused app.
///   commandReverted — brief "Reverted" confirmation after an Undo.
///   error        — something went wrong; shown briefly then auto-hidden.
enum HUDPhase: Equatable {
    case hidden
    case arming
    case listening
    case transcribing
    case processing
    // Replaced words to show as chips (empty if none), plus whether this was a
    // "Private app" session (I1) — when true the pill shows an eye.slash glyph, a
    // wordless trust moment confirming Talkie kept no history and learned nothing.
    case inserting([String], privateSession: Bool)
    case copyPrompt(String)
    case copied
    // The proposed replacement text, awaiting confirm; `replacing` is non-nil
    // only when the selection came from the implicit "what I just dictated"
    // fallback rather than a real AX selection, so the pill can show what's
    // about to be replaced — the user never selected anything themselves, so
    // they have no other visual anchor for it.
    case commandPreview(text: String, replacing: String?)
    case commandReverted        // brief "Reverted" confirmation (mirrors .copied)
    case learned(String)        // "Added 'X' to dictionary" ping, with an Undo chip
    case saved(String)          // brief "Saved to <destination>" confirmation (mirrors .copied)
    case record(String)         // K3: brief "Personal best — …" chip (mirrors .copied); non-interactive
    // A one-time teaching pill shown when a lone quick tap captured nothing —
    // spells out the gesture ("Hold to talk · tap twice to lock") instead of just
    // vanishing. Non-interactive; auto-hides.
    case gestureHint
    // The first-run Vibe Coding offer (A9): the repo name we discovered, with an
    // "Index" chip (turn the feature on + index this repo) and a "Not now" chip
    // (decline this root forever). Auto-dismisses; ignoring it just means "not now".
    case offerVibe(repo: String)
    // The low-confidence review chip (A12): the recognizer was visibly unsure about
    // 1–2 jargon-like words — surface them with a "Fix" chip that teaches the
    // dictionary for next time. NEVER edits the already-inserted text. Auto-dismisses;
    // ignoring it records nothing.
    case reviewLowConfidence(words: [String])
    // The earned launch-at-login offer (H8): after three consecutive days of real
    // use, offer once — in one tap — to start Talkie at login, so the hotkey stops
    // dying silently after every reboot. An "Enable" chip flips the existing
    // launchAtLogin setting (which registers the SMAppService login item).
    // Auto-dismisses like the other offers; shown at most once ever (a resolved flag
    // persists in UserDefaults), and it loses to every other interactive pill.
    case launchOffer
    // The post-insert "Keep for {App}?" chip (H3): the user cycled the in-pill
    // cleanup switcher DURING this dictation (which changed only that dictation),
    // and the chosen style differs from the app's default — so offer, in one tap,
    // to make it the app's per-app rule. `style` is the chosen style's display name,
    // `app` the target app's name. Auto-dismisses like the other offers; ignoring it
    // discards the change (the switcher was session-scoped, so nothing persisted).
    // It loses to a learned ping and to the copy-prompt (recovery/learning win).
    case keepStyle(style: String, app: String)
    case error(String)
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    /// True while the current capture is locked hands-free (tap-tap). Drives a small
    /// lock glyph in the listening pill so the locked state is unmistakable — you can
    /// let go of the key and it keeps recording until you tap once to stop. Only
    /// meaningful during the capture phases; reset when a session ends.
    @Published var handsFreeLocked: Bool = false
    /// The live transcript's *finalized* portion — segments the recognizer has
    /// committed and won't revise — rendered firmly (higher opacity) as the head of
    /// the capture-pill's one-line tail (C1). Empty renders nothing, i.e. today's
    /// bare pill.
    @Published var text: String = ""
    /// The live transcript's *volatile* tail — the still-changing words — rendered
    /// faintly after `text`, so you can watch words firm up as they finalize (C1).
    @Published var volatileText: String = ""
    /// Rolling history of recent mic levels (newest last) driving the waveform.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: HUDModel.barCount)
    /// Bumped to flash the pill when the key is pressed again mid-processing.
    @Published var busyNudge: Int = 0
    /// Bumped when audio goes live, to fire the one-shot waveform "start" sweep.
    @Published var recordStartID: Int = 0
    /// Text held for the tap-to-copy fallback when a paste couldn't land.
    @Published var copyText: String = ""
    /// Keyboard shortcut to surface in the copy-prompt pill (e.g. "⌥⌘V" to re-paste
    /// the last transcript), or nil to hide the hint.
    @Published var copyShortcut: String?
    /// Invoked when the user taps the pill in the `.copyPrompt` state.
    var onCopyTap: () -> Void = {}
    /// Invoked when the user taps "Insert" on a command preview.
    var onCommandConfirm: () -> Void = {}
    /// Invoked when the user taps "Undo" on a command preview.
    var onCommandUndo: () -> Void = {}
    /// Invoked when the user taps "Undo" on a learned-correction ping.
    var onLearnedUndo: () -> Void = {}
    /// Invoked when the user taps "Index" on the Vibe Coding offer (A9).
    var onVibeAccept: () -> Void = {}
    /// Invoked when the user taps "Not now" on the Vibe Coding offer (A9).
    var onVibeDecline: () -> Void = {}
    /// Invoked with the heard word the user chose to fix from the low-confidence
    /// review chip (A12). The controller opens the correction popover; the hub's
    /// closure teaches the dictionary when the popover commits.
    var onReviewFix: (String) -> Void = { _ in }
    /// Invoked when the user taps "Enable" on the earned launch-at-login offer (H8).
    /// The hub's closure flips `settings.launchAtLogin` on (registering the login
    /// item) and marks the once-ever offer resolved.
    var onLaunchOfferEnable: () -> Void = {}
    /// Invoked when the user taps "Keep" on the post-insert keep-style chip (H3).
    /// The hub's closure upserts the per-app rule (merging into any existing sheet)
    /// so this app defaults to the chosen cleanup style from now on.
    var onKeepStyle: () -> Void = {}
    /// How long the learned-correction ping stays up; the countdown ring depletes
    /// over exactly this window before the pill collapses.
    static let learnedDuration: TimeInterval = 5
    /// Bumped on each learned ping so the countdown ring restarts its animation
    /// from full even if two pings land back to back.
    @Published var learnedTick: Int = 0
    /// Bumped when the earned launch-at-login offer (H8) is shown, so its countdown
    /// ring restarts from full. Separate from `learnedTick` so the two never fight
    /// over the ring's animation identity.
    @Published var launchOfferTick: Int = 0
    /// Bumped when the keep-style chip (H3) is shown, so its countdown ring restarts
    /// from full. Its own tick so it never fights the learned/launch rings over the
    /// ring's animation identity.
    @Published var keepStyleTick: Int = 0

    /// True while a hands-free-locked session (B4) is in its silence auto-stop
    /// countdown (B5). It does NOT change `phase` — the pill stays in `.listening` —
    /// it just overlays the depleting `CountdownRing` and swaps the lock caption for a
    /// "still listening — say something or it'll wrap up" line, so the impending
    /// auto-stop is visible and one word (or a level spike) cancels it. Reset on
    /// cancel and on every session end.
    @Published var silenceCountingDown: Bool = false
    /// Bumped each time the silence countdown (re)starts so the ring restarts from full
    /// even if a cancel→re-arm happens back to back. Its own tick so it never fights the
    /// learned/launch rings over animation identity.
    @Published var silenceCountdownTick: Int = 0
    /// How long the silence countdown ring takes to deplete — set by the watchdog when
    /// it arms (the pure core's `countdownDuration`), so the ring's drain matches the
    /// actual auto-stop deadline rather than a hardcoded guess.
    @Published var silenceCountdownDuration: TimeInterval = 3

    /// System accessibility display preferences, mirrored so the SwiftUI pill can
    /// react to them. `highContrast` drives a fuller-opacity, brighter, ringed pill
    /// with slightly larger type; `reduceTransparency` drops the translucent chip
    /// fills for solid ones. Both start from the live `NSWorkspace` values and are
    /// kept current by observing `accessibilityDisplayOptionsDidChangeNotification`
    /// (see `startObservingAccessibilityDisplay()`), so toggling
    /// System Settings ▸ Accessibility ▸ Display updates the pill live.
    @Published var highContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    @Published var reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    /// The active cleanup label to surface in the capture pill (feature 14).
    /// Bumped by the controller so the pill re-reads after a cycle. The hub injects
    /// `cleanupLabel`/`cycleCleanup` so reads/writes go through the live
    /// settings/profile; the defaults keep the pill silent (and inert) when no hub
    /// is wired, which is exactly today's behaviour.
    @Published var cleanupNudge: Int = 0
    /// Returns the short style/level label for the app being dictated into (e.g.
    /// "Neutral", "Faithful · High"), or nil to hide the switcher entirely.
    var cleanupLabel: () -> String? = { nil }
    /// Advances to the next cleanup style/level for the current app and persists it.
    var cycleCleanup: () -> Void = {}

    static let barCount = 14

    /// True while audio is genuinely being captured.
    var isCapturing: Bool { phase == .listening || phase == .transcribing }

    // The observer token is written once (in `init`, on the main actor) and read
    // once (in the nonisolated `deinit`). It's never mutated concurrently, so
    // `nonisolated(unsafe)` is accurate here — it's the documented way to let a
    // MainActor class tear down a NotificationCenter block-observer whose token type
    // (`NSObjectProtocol`) isn't Sendable, without a retain cycle.
    private nonisolated(unsafe) var accessibilityObserver: NSObjectProtocol?

    init() {
        startObservingAccessibilityDisplay()
    }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    /// Watch the system's accessibility display preferences and mirror the two we
    /// render against so the pill updates the instant the user flips a toggle in
    /// System Settings — no relaunch, no re-arm. The notification arrives on the
    /// main queue; `NSWorkspace` is `@MainActor`-safe to read here.
    private func startObservingAccessibilityDisplay() {
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                self.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
    }
}

/// A floating, non-activating pill pinned just under the camera notch (top-center)
/// of the active screen — a Dynamic-Island-style dictation indicator. A solid
/// black capsule with a red dot + a live red waveform makes "recording now"
/// unmistakable.
@MainActor
final class HUDController {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// The low-confidence correction popover (A12) — a small, focusable panel with a
    /// prefilled text field. Unlike the notch pill (a deliberately non-activating
    /// panel that must never steal focus), this one IS key: a text field can only
    /// receive keystrokes in a key window, and it appears solely on an explicit tap
    /// on "Fix", so momentarily taking focus is expected and reversible (Escape).
    private var correctionPanel: NSPanel?

    /// True while an *interactive or lingering* pill occupies the notch — a command
    /// preview, a learned-correction ping, the copy-prompt, another Vibe offer, or an
    /// error. Used by the hub to hold back the A9 Vibe offer so it never overwrites a
    /// pill the user is still reading or acting on (queue phases). The brief,
    /// self-clearing capture/insert states don't count — the offer waits out its own
    /// short delay for those.
    var isPresentingInteractivePill: Bool {
        switch model.phase {
        case .commandPreview, .learned, .copyPrompt, .offerVibe, .reviewLowConfidence,
             .launchOffer, .keepStyle, .error:
            return true
        default:
            return false
        }
    }

    // Compact panel — the transparent canvas the pill floats in. The pill hugs the
    // notch (top-anchored), so the extra height below is transparent headroom: it
    // leaves room for the soft shadow, the drop-in entrance, and the copy-prompt
    // pill expanding downward to a second line (the ⌥⌘V re-paste hint).
    private static let panelSize = NSSize(width: 440, height: 104)

    /// The pill's frame within the panel's content view, published by the SwiftUI
    /// layer. The pass-through hosting view consults it so clicks on the large
    /// transparent headroom fall through to the app underneath, while taps on the
    /// pill itself (the cleanup switcher, the Insert/Undo chips) are claimed.
    private let pillFrame = PillFrameBox()

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let hosting = PassthroughHostingView(
            rootView: HUDView(model: model, pillFrame: pillFrame),
            pillFrame: pillFrame
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the SwiftUI pill draws its own shadow
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// Pin the pill top-center, just beneath the camera notch / menu bar.
    private func reposition() {
        guard let panel, let screen = preferredScreen() else { return }
        let full = screen.frame
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // The notch is centered on the display, so center the pill horizontally.
        let x = full.midX - size.width / 2
        // The menu bar (and, on notched Macs, the notch safe area) is the gap
        // between the full frame top and the visible frame top. When the menu bar
        // is auto-hidden or an app is fullscreen that gap collapses to 0 — fall
        // back to the notch / status-bar height so the pill still clears the notch.
        let topChrome = full.maxY - visible.maxY
        let notch = screen.safeAreaInsets.top
        let effectiveChrome = topChrome > 0 ? topChrome : max(notch, NSStatusBar.system.thickness)
        let gap: CGFloat = 4
        let y = (full.maxY - effectiveChrome - gap) - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// The screen the user is working on: prefer the one under the cursor (where
    /// the dictation target and your attention are), then the key screen.
    private func preferredScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func resetLevels() {
        model.levels = Array(repeating: 0, count: HUDModel.barCount)
    }

    /// Speak a HUD state change through VoiceOver. The pill lives in a
    /// `.nonactivatingPanel` that VoiceOver's cursor may never land on (activating
    /// it would steal focus from the app you're dictating into — the whole point of
    /// the pill), so for the states that carry a decision or an outcome we post an
    /// announcement instead of relying on the user navigating to the element. High
    /// priority so it isn't dropped mid-speech; announcements are the accessibility
    /// floor for the pill even where direct navigation isn't reachable.
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Key pressed — acknowledge immediately while the mic/engine warm up. Audio
    /// is not flowing yet, so the dot is gray (not recording).
    func showArming() {
        cancelHide()
        resetLevels()
        model.handsFreeLocked = false   // fresh session starts un-locked
        model.silenceCountingDown = false   // and never inherits a stale auto-stop countdown
        model.phase = .arming
        model.text = ""
        model.volatileText = ""
        let panel = ensurePanel()
        // Accept mouse events so the cleanup switcher is tappable while you talk.
        // The pass-through hosting view only claims clicks over the pill itself, so
        // the transparent headroom still falls through to the app underneath.
        panel.ignoresMouseEvents = false
        reposition()
        panel.orderFrontRegardless()
    }

    /// Audio is now genuinely flowing into the recognizer — flip to the live
    /// recording state (red dot + reactive waveform).
    func showListening() {
        cancelHide()
        let panel = ensurePanel()
        // Re-pin in case the active display changed during the arming→live gap.
        reposition()
        panel.ignoresMouseEvents = false   // keep the switcher tappable while live
        model.phase = .listening
        model.recordStartID &+= 1   // fire the one-shot waveform sweep
        panel.orderFrontRegardless()
    }

    /// Push a fresh mic level into the rolling waveform history.
    func updateLevel(_ level: Float) {
        // Ignore stray levels once we've left the capture phases.
        guard model.phase == .arming || model.isCapturing else { return }
        var l = model.levels
        l.removeFirst()
        l.append(CGFloat(max(0, min(1, level))))
        model.levels = l
    }

    /// Push a fresh partial into the capture pill (C1). The handoff carries STRUCTURE
    /// — the committed `finalized` head and the still-changing `volatile` tail — so
    /// the pill can render the volatile words fainter and let them firm up as they
    /// finalize. Display only: the transcript still goes to the focused app; this
    /// merely mirrors the tail so there's no "is it even hearing me?" dead air.
    func updateTranscribing(finalized: String, volatile: String) {
        // Only meaningful while still capturing — a late partial must never
        // resurrect the pill out of processing/inserting/hidden.
        switch model.phase {
        case .arming, .listening, .transcribing: break
        default: return
        }
        cancelHide()
        if model.phase != .transcribing { model.phase = .transcribing }
        model.text = finalized
        model.volatileText = volatile
    }

    func showProcessing() {
        cancelHide()
        // Recording's over — the switcher is gone, so stop claiming clicks again.
        panel?.ignoresMouseEvents = true
        model.phase = .processing
    }

    /// Key pressed again while still processing — flash the pill so the press is
    /// acknowledged, without starting a second (overlapping) session.
    func nudgeBusy() {
        guard model.phase == .processing else { return }
        model.busyNudge &+= 1
    }

    /// `privateSession` (I1) is true when the app dictated into was marked "Private":
    /// the pill then shows an eye.slash glyph next to "Inserted" as a wordless
    /// confirmation that Talkie kept no history and learned nothing from it.
    func showInserting(replacedWords: [String] = [], privateSession: Bool = false) {
        cancelHide()
        model.phase = .inserting(replacedWords, privateSession: privateSession)
    }

    /// A paste couldn't land — show a tappable alert; tapping copies the text to
    /// the clipboard. The text is already on the clipboard as a safety net, so an
    /// auto-hide without a tap won't lose it.
    func showCopyPrompt(text: String, message: String, shortcut: String? = nil) {
        cancelHide()
        model.copyText = text
        model.copyShortcut = shortcut
        model.onCopyTap = { [weak self] in self?.handleCopyTap() }
        let panel = ensurePanel()
        panel.ignoresMouseEvents = false   // let the user tap to copy
        model.phase = .copyPrompt(message)
        reposition()
        panel.orderFrontRegardless()
        // Announce it: this state needs an action (there's no editable field to
        // paste into), and a VoiceOver user must hear that even if the pill's panel
        // never takes focus. `message` is already a localized, human-facing string
        // supplied by the hub; append the shortcut hint via a localized format.
        if let shortcut {
            announce(String(format: "%@ Press %@ to paste your last transcript.".loc, message, shortcut))
        } else {
            announce(message)
        }
        hide(after: 6)
    }

    private func handleCopyTap() {
        cancelHide()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(model.copyText, forType: .string)
        Feedback.done()
        panel?.ignoresMouseEvents = true
        model.phase = .copied
        hide(after: 0.9)
    }

    // MARK: - Voice command preview / undo

    /// A voice command produced a proposed replacement. Show it in the pill and
    /// wait — nothing is inserted until you tap "Insert". Mouse events are enabled
    /// (like `.copyPrompt`) so both chips are tappable. There's no auto-hide: a
    /// preview is a decision, so the pill stays until you act (or the hub dismisses
    /// it). `onConfirm`/`onUndo` are the hub's closures (inject the replacement via
    /// `TextInjector`, or restore the prior selection from the undo token).
    /// `replacing`, when non-nil, is the implicit-fallback source text (see
    /// `ImplicitSelectionGate`) so the pill can show what's about to be
    /// replaced — required, not decorative: it's the only thing that makes an
    /// implicit-fallback Insert an informed choice instead of a blind one.
    func showCommandPreview(_ text: String,
                            replacing original: String? = nil,
                            onConfirm: @escaping () -> Void,
                            onUndo: @escaping () -> Void) {
        cancelHide()
        let panel = ensurePanel()
        model.onCommandConfirm = { [weak self] in
            self?.panel?.ignoresMouseEvents = true
            onConfirm()
        }
        model.onCommandUndo = onUndo
        panel.ignoresMouseEvents = false   // let the user tap Insert / Undo
        model.phase = .commandPreview(text: text, replacing: original)
        reposition()
        panel.orderFrontRegardless()
        // A preview is a decision with no auto-hide — the VoiceOver user has to hear
        // both the proposal and that Insert/Undo are waiting, since the panel may
        // never take focus. Name the implicit-fallback source too when there is one.
        if let original {
            announce(String(format: "Voice command wants to replace \u{201c}%@\u{201d} with \u{201c}%@\u{201d}. Activate Insert to apply, or Undo to keep what you had.".loc, String(original.prefix(60)), text))
        } else {
            announce(String(format: "Voice command suggestion: \u{201c}%@\u{201d}. Activate Insert to apply, or Undo to dismiss.".loc, text))
        }
    }

    /// Talkie auto-added a learned correction — ping the user with the term and an
    /// Undo chip (WhisperFlow-style). Mouse events are enabled so Undo is tappable;
    /// auto-dismisses after a few seconds since doing nothing means "keep it".
    func showLearned(_ message: String, onUndo: @escaping () -> Void) {
        cancelHide()
        let panel = ensurePanel()
        model.onLearnedUndo = { [weak self] in
            self?.panel?.ignoresMouseEvents = true
            onUndo()
        }
        Feedback.learned()                 // chime so the ping is noticed
        model.learnedTick &+= 1            // restart the countdown ring
        panel.ignoresMouseEvents = false   // let the user tap Undo
        model.phase = .learned(message)
        reposition()
        panel.orderFrontRegardless()
        // The ping auto-dismisses, so announce the learned term (and that Undo is
        // there) for a VoiceOver user who can't see the transient pill.
        announce(String(format: "%@ Activate Undo to remove it.".loc, message))
        hide(after: HUDModel.learnedDuration)
    }

    /// How long the Vibe Coding offer stays up. A touch longer than a learned ping
    /// because it's a question, not a passive confirmation — but still bounded, since
    /// ignoring it means "not now" (and we never re-offer more than once a day).
    static let vibeOfferDuration: TimeInterval = 8

    /// The first-run Vibe Coding offer (A9): we discovered a real git repo behind
    /// the editor/terminal you just dictated into, so offer one tap to index its
    /// filenames. Mouse events are enabled so both chips are tappable; auto-dismisses
    /// (ignoring it just means "not now"). `onAccept`/`onDecline` are the hub's
    /// closures — accept flips on vibe coding + indexes the repo; decline remembers
    /// this root so it's never offered again. Modeled on `showLearned`.
    func showVibeOffer(repo: String,
                       onAccept: @escaping () -> Void,
                       onDecline: @escaping () -> Void) {
        cancelHide()
        let panel = ensurePanel()
        model.onVibeAccept = { [weak self] in
            self?.panel?.ignoresMouseEvents = true
            onAccept()
        }
        model.onVibeDecline = { [weak self] in
            self?.panel?.ignoresMouseEvents = true
            onDecline()
        }
        panel.ignoresMouseEvents = false   // let the user tap Index / Not now
        model.phase = .offerVibe(repo: repo)
        reposition()
        panel.orderFrontRegardless()
        // The offer auto-dismisses, so spell it out for a VoiceOver user who can't
        // see the transient pill.
        announce(String(format: "Talkie found the project %@. Activate Index to snap spoken filenames to its real files, or Not now to dismiss.".loc, repo))
        hide(after: HUDController.vibeOfferDuration)
    }

    /// How long the earned launch-at-login offer (H8) stays up. Matches the Vibe
    /// offer's window — it's a question, not a passive confirmation, so it lingers a
    /// touch longer than a learned ping, but stays bounded because a timeout means
    /// "not now" (and here also "resolved" — it's offered at most once, ever).
    static let launchOfferDuration: TimeInterval = 8

    /// The earned launch-at-login offer (H8): after a 3-day streak of real use, offer
    /// one tap to start Talkie at login so the hotkey stops dying silently after every
    /// reboot. One "Enable" chip; auto-dismisses. Modeled on `showVibeOffer`. `onEnable`
    /// is the hub's closure (flip `settings.launchAtLogin` on → registers the login
    /// item). `onResolve` runs when the offer leaves the screen for ANY reason (tap OR
    /// timeout OR a superseding pill) so the once-ever resolved flag is set either way;
    /// it must be idempotent. The hub only calls this when no other interactive pill is
    /// up and the streak/settings gates pass, so it never stacks or nags.
    func showLaunchOffer(onEnable: @escaping () -> Void, onResolve: @escaping () -> Void) {
        cancelHide()
        let panel = ensurePanel()
        model.onLaunchOfferEnable = { [weak self] in
            self?.panel?.ignoresMouseEvents = true
            // The tap itself resolves the offer; the enable closure flips the setting
            // and marks it resolved, so the timeout-driven resolve below is a no-op.
            onEnable()
        }
        model.launchOfferTick &+= 1        // restart the countdown ring from full
        panel.ignoresMouseEvents = false   // let the user tap Enable
        model.phase = .launchOffer
        reposition()
        panel.orderFrontRegardless()
        // The offer auto-dismisses and its panel may never take focus, so spell it out
        // for a VoiceOver user who can't see the transient pill.
        announce("Three days of dictation in a row. Activate Enable to start Talkie at login so your hotkey always works.".loc)
        // Resolve exactly once, whichever ends the offer first — the tap or this
        // timeout. `onResolve` is idempotent, so a tap that already resolved makes this
        // a harmless no-op.
        hideLaunchOffer(after: HUDController.launchOfferDuration, onResolve: onResolve)
    }

    /// Auto-hide for the launch offer that also fires `onResolve` when the timeout
    /// elapses (unless the pill was already replaced by another state). Mirrors
    /// `hide(after:)` but threads the once-ever resolve through, so an ignored offer is
    /// still marked resolved and never shown again.
    private func hideLaunchOffer(after delay: TimeInterval, onResolve: @escaping () -> Void) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // Only resolve-by-timeout if the offer is still the thing on screen; if a
            // superseding pill took over, THAT transition already resolved it (the hub
            // resolves before showing anything that would preempt the offer).
            if case .launchOffer = self.model.phase {
                onResolve()
                self.panel?.ignoresMouseEvents = true
                self.model.handsFreeLocked = false
                self.model.phase = .hidden
                self.panel?.orderOut(nil)
            }
            self.hideTask = nil
        }
    }

    /// How long the post-insert keep-style chip (H3) stays up. Matches the learned
    /// ping's window (a coral countdown ring drains over it) — long enough to catch,
    /// short enough that ignoring it discards the change without lingering.
    static let keepStyleDuration: TimeInterval = HUDModel.learnedDuration

    /// The post-insert "Keep for {App}?" chip (H3): the user cycled the in-pill
    /// cleanup switcher during this dictation (which changed only that dictation), and
    /// the chosen `style` differs from `app`'s default — so offer, in one tap, to make
    /// it `app`'s per-app rule. Modeled on `showLearned`: mouse events on so "Keep" is
    /// tappable, a coral countdown ring drains over `keepStyleDuration`, and a timeout
    /// discards silently (the switcher was session-scoped, so nothing persisted). `onKeep`
    /// is the hub's closure — it upserts the per-app rule. The hub only calls this when
    /// no learned/copy/command pill is up, so it never stacks (learned/recovery win).
    func showKeepStyle(style: String, app: String, onKeep: @escaping () -> Void) {
        cancelHide()
        let panel = ensurePanel()
        model.onKeepStyle = { [weak self] in
            self?.panel?.ignoresMouseEvents = true
            onKeep()
        }
        model.keepStyleTick &+= 1          // restart the countdown ring from full
        panel.ignoresMouseEvents = false   // let the user tap Keep
        model.phase = .keepStyle(style: style, app: app)
        reposition()
        panel.orderFrontRegardless()
        // The chip auto-dismisses and its panel may never take focus, so spell it out
        // for a VoiceOver user: which style, which app, and that Keep persists it.
        announce(String(format: "Keep the %@ cleanup style for %@? Activate Keep to make it this app's default.".loc, style, app))
        hide(after: HUDController.keepStyleDuration)
    }

    /// How long the low-confidence review chip stays up before auto-dismissing.
    /// A little longer than a learned ping because it's an invitation to act (tap
    /// to fix), but still bounded — ignoring it must record nothing and get out of
    /// the way, since a chip the user didn't want is pure interruption.
    static let reviewDuration: TimeInterval = 4

    /// The low-confidence review chip (A12): the recognizer was visibly unsure about
    /// `words` (1–2 jargon-like terms). Surface them with a "Fix" chip that, on tap,
    /// opens a tiny correction popover teaching the dictionary for NEXT time — it
    /// NEVER edits the text already inserted. Mouse events are enabled so "Fix" is
    /// tappable; auto-dismisses after `reviewDuration` and records nothing if ignored.
    /// Single-phase queue: the hub only calls this when no learned/copy/command pill
    /// is showing, so it never stacks. `onFix` is the hub's closure (opens the
    /// popover + teaches the dictionary on commit).
    func showReviewChip(words: [String], onFix: @escaping (String) -> Void) {
        guard !words.isEmpty else { return }
        cancelHide()
        let panel = ensurePanel()
        model.onReviewFix = onFix
        panel.ignoresMouseEvents = false   // let the user tap Fix
        model.phase = .reviewLowConfidence(words: Array(words.prefix(2)))
        reposition()
        panel.orderFrontRegardless()
        // The chip auto-dismisses and its panel may never take focus, so spell it out
        // for a VoiceOver user: which words were unsure and that Fix teaches them.
        let list = words.prefix(2).joined(separator: ", ")
        announce(String(format: "Not sure about %@. Activate Fix to correct the spelling for next time.".loc, list))
        hide(after: HUDController.reviewDuration)
    }

    /// Brief "Reverted" confirmation after an Undo — mirrors `.copied`.
    func showReverted() {
        cancelHide()
        let panel = ensurePanel()
        panel.ignoresMouseEvents = true
        model.phase = .commandReverted
        reposition()
        panel.orderFrontRegardless()
        hide(after: 0.9)
    }

    /// A note was written to the export destination (a "note this …" dictation) —
    /// a brief, non-interactive confirmation that mirrors `.copied`. `message` is
    /// the full localized line
    /// ("Saved to Talkie Meetings folder") the caller composed, so this method
    /// stays destination-agnostic. Nothing to tap; auto-hides.
    func showSaved(_ message: String) {
        cancelHide()
        let panel = ensurePanel()
        panel.ignoresMouseEvents = true   // nothing to tap here
        model.phase = .saved(message)
        reposition()
        panel.orderFrontRegardless()
        // Announce it: the pill is transient and non-focusable, so a VoiceOver user
        // would otherwise never hear that (and where) their note was saved.
        announce(message)
        hide(after: 1.8)
    }

    /// K3: a personal record just broke — show a brief, non-interactive "personal
    /// best" chip (e.g. "Personal best — 168 WPM"). Mirrors `.copied`/`.saved`:
    /// nothing to tap, auto-hides after 3 s. No sound — K2 owns audio cues, and a
    /// record is a quiet celebration, not an event that demands the ear. `message`
    /// is the full localized line the hub composed. Detection lives in the stores;
    /// the HUD only displays what it's told.
    func showRecord(_ message: String) {
        cancelHide()
        let panel = ensurePanel()
        panel.ignoresMouseEvents = true   // nothing to tap here
        model.phase = .record(message)
        reposition()
        panel.orderFrontRegardless()
        // Announce it: the pill is transient and non-focusable, so a VoiceOver user
        // would otherwise never hear their personal best.
        announce(message)
        hide(after: 3)
    }

    // MARK: - Cleanup-style switcher (feature 14)

    /// Wire the capture pill's cleanup switcher to the live settings/profile. The
    /// hub passes a `label` that resolves the active style/level for the current
    /// target app, and a `cycle` that advances + persists it. Called once at setup;
    /// safe to call again to re-wire.
    func bindCleanupSwitcher(label: @escaping () -> String?,
                             cycle: @escaping () -> Void) {
        model.cleanupLabel = label
        model.cycleCleanup = { [weak self] in
            cycle()
            // Nudge so the pill re-reads the (now-changed) label, and give a small
            // tactile confirmation that the tap landed (no sound — you're mid-record).
            self?.model.cleanupNudge &+= 1
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Flip the listening pill's hands-free lock glyph on/off. Called when a tap-tap
    /// locks (on) and when the session ends (off). Purely presentational — the pill
    /// must already be in a capture phase for the glyph to be visible.
    func setHandsFreeLocked(_ locked: Bool) {
        model.handsFreeLocked = locked
    }

    /// B5: begin the visible, cancelable auto-stop countdown on the LISTENING pill
    /// (the coral ring drains over `remaining`, and the tail swaps to "still listening
    /// — say something or it'll wrap up"). Called by the hub's `SilenceWatchdogDriver`
    /// only for a hands-free-locked session that's gone quiet. It does NOT change the
    /// phase — the pill is still `.listening` — so a cancel just clears the flag and the
    /// plain locked pill returns. Bumps the ring's tick so a re-arm restarts it full.
    func showSilenceCountdown(remaining: TimeInterval) {
        model.silenceCountdownDuration = remaining
        model.silenceCountdownTick &+= 1
        model.silenceCountingDown = true
        // Announce it: a hands-free VoiceOver user who can't see the ring must still
        // hear that recording is about to stop and that a word keeps it going.
        announce("Still listening — it's quiet, so recording will stop soon. Say something to keep going.".loc)
    }

    /// B5: the user spoke again (level spike or new partial) during the countdown —
    /// abandon it and restore the plain locked pill. Purely presentational; the hub's
    /// watchdog owns the timing.
    func cancelSilenceCountdown() {
        model.silenceCountingDown = false
    }

    /// Show the one-time gesture-teaching pill (after a lone quick tap that captured
    /// nothing). Non-interactive; announces itself and auto-hides. The caller gates
    /// how often this appears (see `GestureHint`).
    func showGestureHint() {
        cancelHide()
        let panel = ensurePanel()
        panel.ignoresMouseEvents = true   // nothing to tap here
        model.phase = .gestureHint
        reposition()
        panel.orderFrontRegardless()
        // Non-focusable transient pill — announce the gesture so a VoiceOver user who
        // just tapped-and-got-nothing still learns hold vs tap-tap.
        announce("Hold your key to talk; keep holding it to lock hands-free recording.".loc)
        hide(after: 2.6)
    }

    func showError(_ message: String) {
        cancelHide()
        let panel = ensurePanel()
        panel.ignoresMouseEvents = true   // nothing to tap here
        model.phase = .error(message)
        reposition()
        panel.orderFrontRegardless()
        // Errors auto-hide quickly and there's nothing to tap, so a VoiceOver user
        // would otherwise miss them entirely — announce so the failure is heard.
        announce(String(format: "Talkie error: %@".loc, message))
        hide(after: 2.6)
    }

    /// Present the A12 correction popover for one heard word: a tiny focusable panel
    /// with a text field prefilled with `heardWord`. On commit it calls `onCommit`
    /// with the corrected spelling; the hub then teaches the dictionary + records the
    /// niche confirmation. The popover NEVER touches the already-inserted text — it's
    /// purely "fix it for next time." Dismissing (Escape / Cancel / clicking away)
    /// records nothing. Pins just under the notch, like the pill, so the correction
    /// happens where the user's attention already is.
    func presentCorrectionPopover(heardWord: String, onCommit: @escaping (String) -> Void) {
        // Dismiss the chip immediately — the popover supersedes it.
        cancelHide()
        model.phase = .hidden
        panel?.orderOut(nil)

        // Tear down any prior popover so a rapid second Fix can't leak a window.
        correctionPanel?.orderOut(nil)
        correctionPanel = nil

        let dismiss: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.correctionPanel?.orderOut(nil)
            self.correctionPanel = nil
        }
        let view = CorrectionPopover(
            heardWord: heardWord,
            onSave: { corrected in
                let fixed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                dismiss()
                // Only teach when the user actually changed the spelling to something
                // non-empty — saving the heard word unchanged is a no-op, not a rule.
                if !fixed.isEmpty, fixed.lowercased() != heardWord.lowercased() {
                    onCommit(fixed)
                }
            },
            onCancel: { dismiss() }
        )

        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: 320, height: 96)
        // A titled panel (NOT non-activating): the text field can only take
        // keystrokes in a key window, so this one is allowed to activate — the whole
        // point, and expected because it only appears on an explicit "Fix" tap.
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        self.correctionPanel = panel

        // Pin under the notch, centered — same anchor as the pill.
        if let screen = preferredScreen() {
            let full = screen.frame
            let visible = screen.visibleFrame
            let x = full.midX - size.width / 2
            let topChrome = full.maxY - visible.maxY
            let notch = screen.safeAreaInsets.top
            let chrome = topChrome > 0 ? topChrome : max(notch, NSStatusBar.system.thickness)
            let y = (full.maxY - chrome - 8) - size.height
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        // Bring the app forward so the field can take keys, then focus the panel.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide(after delay: TimeInterval = 0.25) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.panel?.ignoresMouseEvents = true
            self.model.handsFreeLocked = false   // never carry a lock glyph into the next session
            self.model.silenceCountingDown = false   // nor a stale auto-stop countdown
            self.model.phase = .hidden
            self.panel?.orderOut(nil)
            self.hideTask = nil
        }
    }
}

/// The A12 correction popover body: a compact card with a prefilled text field and
/// Save / Cancel. Committing on Return or Save hands the corrected spelling up; the
/// copy makes the promise explicit — this fixes it for NEXT time, it does not touch
/// the text already inserted. Honest, second-person, no invented metrics.
private struct CorrectionPopover: View {
    let heardWord: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var fieldFocused: Bool

    init(heardWord: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.heardWord = heardWord
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: heardWord)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "Heard \u{201c}%@\u{201d} — fix it for next time".loc, heardWord))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Correct spelling".loc, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit { onSave(text) }
                Button("Cancel".loc) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save".loc) { onSave(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        )
        .frame(width: 320)
        .onAppear { fieldFocused = true }
        // The whole popover is a labeled correction affordance for VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: "Fix the spelling of %@ for next time.".loc, heardWord))
    }
}

// MARK: - Gesture-hint gating

/// Gates the one-time "Hold to talk · tap twice to lock" teaching pill so it can't
/// nag. A lone quick tap that captures nothing is a strong signal the user tapped
/// instead of holding (or doesn't yet know tap-tap locks), so we teach the gesture
/// in the pill — but only the first few such taps ever, tracked by a plain counter
/// in `UserDefaults`. There is no setting and no other state: once the cap is hit,
/// the hint is silent forever.
enum GestureHint {
    /// How many times a lone empty tap will surface the hint before we stay quiet.
    static let maxShows = 3
    private static let countKey = "gestureHintEmptyTapShows"

    /// Whether to show the hint for this empty lone-tap, incrementing the persisted
    /// counter when it says yes. Returns false once the cap is reached. Main-actor
    /// (called from the dictation pipeline); `UserDefaults` access stays on the main
    /// thread, so no synchronization is needed.
    @MainActor
    static func shouldShowEmptyTapHint(defaults: UserDefaults = .standard) -> Bool {
        let shown = defaults.integer(forKey: countKey)
        guard shown < maxShows else { return false }
        defaults.set(shown + 1, forKey: countKey)
        return true
    }
}

// MARK: - SwiftUI HUD content

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    let pillFrame: PillFrameBox
    /// Whether the live transcript renders as flowing text below the waveform (growing
    /// the pill downward). Read live from the same UserDefaults the settings toggle
    /// writes — `AppSettings` persists to `.standard`.
    @AppStorage("showLivePillText") private var showLivePillText = true

    private static let hudSpace = "talkieHUD"

    // MARK: Accessibility-aware styling helpers
    //
    // The pill's text and glyphs are white-on-black at a range of opacities tuned
    // for a calm look. Under the system's Increase Contrast setting we lift every
    // opacity toward solid white so nothing sits at a low-contrast wash; the
    // capture-phase colors (waveform, cleanup label) brighten the same way. These
    // funnel every `.white.opacity(...)` through one place so the contrast bump is
    // consistent and reversible.

    /// White text/glyph color, lifted toward solid in high-contrast mode.
    private func ink(_ opacity: Double) -> Color {
        .white.opacity(model.highContrast ? max(opacity, 0.95) : opacity)
    }

    /// Fill for the translucent in-pill chips (cleanup switcher, Insert/Undo). In
    /// Reduce Transparency mode the frosted `.white.opacity` look reads as muddy, so
    /// we swap to a solid, high-contrast fill; high-contrast alone just strengthens
    /// it. Returns a `Color` so call sites stay a one-liner.
    private func chipFill(_ opacity: Double) -> Color {
        if model.reduceTransparency { return .white.opacity(0.22) }
        return .white.opacity(model.highContrast ? min(opacity + 0.06, 1) : opacity)
    }

    /// C1 (redesigned) — the live tail as a WRAPPING block below the waveform. A fixed
    /// width forces it to wrap (so the pill grows downward, not sideways); a line cap
    /// stops it past a few lines; head-truncation keeps the newest words visible once
    /// it's full. Empty text renders nothing.
    @ViewBuilder
    private var liveTailBlock: some View {
        Text(liveTailString)
            .font(.system(size: model.highContrast ? 12 : 11, weight: .medium))
            .multilineTextAlignment(.leading)
            .lineLimit(5)
            .truncationMode(.head)
            .frame(width: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }

    /// The two-tone attributed tail: a firm finalized head + a dimmer volatile tail,
    /// as ONE `AttributedString` so the `Text` truncates as a single line (SwiftUI
    /// can't head-truncate a `Text` built from `+`-concatenated runs). A single space
    /// joins head and tail only when both are present, so the seam reads as normal
    /// word spacing. Colors flow through `ink(_:)` so high-contrast lifts them too.
    private var liveTailString: AttributedString {
        var attributed = AttributedString(model.text)
        attributed.foregroundColor = ink(model.highContrast ? 0.95 : 0.85)
        let volatile = model.volatileText
        if !volatile.isEmpty {
            let joiner = model.text.isEmpty ? "" : " "
            var tail = AttributedString(joiner + volatile)
            tail.foregroundColor = ink(model.highContrast ? 0.7 : 0.5)
            attributed.append(tail)
        }
        return attributed
    }

    var body: some View {
        // Top-anchored within the (larger, transparent) panel so the pill hugs
        // the notch; the headroom holds the shadow and the drop-in slide.
        pill
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
            // A quick, springy entrance so it's obvious the pill just appeared:
            // it pops up in scale and drops down from behind the notch.
            .scaleEffect(model.phase == .hidden ? 0.5 : 1, anchor: .top)
            .offset(y: model.phase == .hidden ? -8 : 0)
            .opacity(model.phase == .hidden ? 0 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.6), value: model.phase)
            .coordinateSpace(name: Self.hudSpace)
    }

    @ViewBuilder
    private var pill: some View {
        // Solid pure-black capsule — floats above whatever app you're in. A faint
        // hairline keeps the edge legible even against a dark backdrop. In the
        // system's Increase Contrast mode the edge becomes a full white ring so the
        // pill has a hard, high-contrast boundary against any backdrop.
        inner
            .padding(.horizontal, model.highContrast ? 13 : 12)
            .padding(.vertical, model.highContrast ? 8 : 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.black)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                .white.opacity(model.highContrast ? 0.9 : 0.10),
                                lineWidth: model.highContrast ? 1.5 : 0.5
                            )
                    )
            )
            // Learned-correction ping: a coral ring that traces the pill and
            // visibly drains over the dismiss window — a wordless countdown. Keyed
            // by `learnedTick` so it restarts from full on each new ping.
            .overlay {
                if case .learned = model.phase {
                    CountdownRing(duration: HUDModel.learnedDuration)
                        .id(model.learnedTick)
                } else if case .launchOffer = model.phase {
                    // H8: the earned launch-at-login offer drains the same coral ring
                    // over its (longer) window — a wordless "this dismisses itself".
                    CountdownRing(duration: HUDController.launchOfferDuration)
                        .id(model.launchOfferTick)
                } else if case .keepStyle = model.phase {
                    // H3: the post-insert keep-style chip drains the same coral ring
                    // over its window — a wordless "ignore this and the change is
                    // dropped". Keyed by `keepStyleTick` so it restarts from full.
                    CountdownRing(duration: HUDController.keepStyleDuration)
                        .id(model.keepStyleTick)
                }
                // The silence auto-stop no longer draws a draining ring — the "closing
                // in" countdown read as stressful. A quiet latched session instead shows
                // only the calm "still listening — say something…" text in the row above,
                // and the whole auto-stop is opt-out (Settings ▸ Stop hands-free when I go
                // quiet).
            }
            .shadow(color: .black.opacity(0.38), radius: 12, x: 0, y: 6)
            .fixedSize()
            .contentShape(Capsule(style: .continuous))
            .background(
                // Publish the pill's frame (SwiftUI top-left coords) so the panel's
                // hosting view only claims clicks here — the transparent headroom
                // keeps passing through to the app underneath.
                GeometryReader { geo in
                    Color.clear
                        .onAppear { pillFrame.rect = geo.frame(in: .named(Self.hudSpace)) }
                        .onChange(of: model.phase) { pillFrame.rect = geo.frame(in: .named(Self.hudSpace)) }
                        // C1: the live tail widens the capture pill as you speak, so
                        // republish the clickable rect on each text change too — the
                        // click pass-through region must track the wider pill or the
                        // CleanupSwitcher (and the transparent headroom's fall-through)
                        // would go stale. Cheap: it just re-reads the frame.
                        .onChange(of: model.text) { pillFrame.rect = geo.frame(in: .named(Self.hudSpace)) }
                        .onChange(of: model.volatileText) { pillFrame.rect = geo.frame(in: .named(Self.hudSpace)) }
                }
            )
            .onTapGesture {
                if case .copyPrompt = model.phase { model.onCopyTap() }
            }
    }

    // The pill shows the recording indicator + waveform while active — the
    // transcript goes to the focused app and the History log, never into the pill.
    @ViewBuilder
    private var inner: some View {
        switch model.phase {
        case .arming, .listening, .transcribing:
            // One persistent dot across the whole capture phase, so the pulse
            // keeps running and the gray→red change crossfades the moment audio
            // goes live. The shape also changes (hollow ring → filled) so the
            // recording state never relies on color alone.
            let recording = model.phase != .arming
            // The idle/arming gray lifts to near-white in high-contrast so the
            // "not yet recording" ring stays legible; the live red is already a
            // saturated feather color, left as-is.
            let tint = recording ? Theme.featherRed : ink(model.highContrast ? 0.9 : 0.55)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    StatusDot(color: tint, filled: recording)
                        .animation(.easeInOut(duration: 0.25), value: recording)
                    // A red waveform: equal-width bars whose heights move with your
                    // voice. A one-shot wave of opacity sweeps across it the instant
                    // recording starts, then it settles to steady red.
                    Waveform(levels: model.levels, tint: tint, sweepTrigger: model.recordStartID)
                        .accessibilityHidden(true)
                    // Hands-free lock: a small lock glyph so it's obvious you can release
                    // the key and it keeps recording until you tap to stop. Only while
                    // genuinely locked; it slides in without disturbing the dot/waveform.
                    // Coral so it reads as an active state, not an error. Accessibility is
                    // folded into the group label below.
                    if model.handsFreeLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.coral)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                    // Feature 14: the active cleanup style/level, tappable to cycle —
                    // change how the dictation is polished without leaving the record.
                    // Hidden entirely when no switcher is wired (today's pill).
                    CleanupSwitcher(model: model, chipFill: chipFill(0.13), ink: ink(0.82))
                    if model.silenceCountingDown {
                        // B5: while the hands-free auto-stop countdown runs, the row says
                        // so in plain words — a gentle nudge that one word (or reaching the
                        // key) keeps it going. It takes the tail slot so the pill doesn't
                        // also carry the transcript during the wrap-up moment.
                        Text("still listening — say something or it'll wrap up")
                            .font(.system(size: model.highContrast ? 12 : 11, weight: .medium))
                            .foregroundStyle(ink(0.72))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .transition(.blurReplace)
                    }
                }
                // C1 (redesigned): the live tail of what's being heard flows BELOW the
                // waveform as wrapping text, so the pill grows DOWNWARD (to a capped
                // height) as you speak rather than stretching sideways. Gated by the
                // Settings toggle; hidden during the silence countdown (which owns the row
                // above) and when there's nothing yet — so the bare pill is exactly today's.
                if showLivePillText, !model.silenceCountingDown,
                   !model.text.isEmpty || !model.volatileText.isEmpty {
                    liveTailBlock
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: model.handsFreeLocked)
            .animation(.easeInOut(duration: 0.2), value: model.silenceCountingDown)
            .transition(.blurReplace)
            // The dot + waveform are one status glyph to VoiceOver: state it plainly
            // rather than exposing a decorative waveform. The cleanup switcher stays
            // a separate, labeled control (its own element inside this group). When
            // locked, say so — a hands-free VoiceOver user must hear that releasing
            // the key won't stop it (a single tap will). During the auto-stop countdown
            // say THAT — a hands-free user must hear it's about to wrap up and that a
            // word keeps it going.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                model.silenceCountingDown
                    ? "Still listening — it's quiet, so recording will stop soon. Say something to keep going.".loc
                    : (model.handsFreeLocked
                        ? "Listening, hands-free. Recording is locked — tap your key once to stop.".loc
                        : (recording ? "Listening. Talkie is recording your voice.".loc
                                     : "Getting ready to listen.".loc))
            )
        case .processing:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .accessibilityHidden(true)
                Text("Polishing…")
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.8))
            }
            .modifier(BusyShake(trigger: model.busyNudge))
            .transition(.blurReplace)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Polishing your dictation.".loc)
        case .inserting(let words, let privateSession):
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.positive)
                Text("Inserted")
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.8))
                // Private-app trust moment (I1): an eye.slash confirms, wordlessly,
                // that Talkie inserted the text but kept no history and learned
                // nothing from it. Folded into the group's accessibility label below.
                if privateSession {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ink(0.6))
                        .accessibilityHidden(true)
                }
                if !words.isEmpty {
                    Text("·")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ink(0.22))
                    ForEach(Array(words.prefix(3).enumerated()), id: \.offset) { _, word in
                        Text(word)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ink(0.72))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(chipFill(0.13)))
                    }
                    if words.count > 3 {
                        Text("+\(words.count - 3)")
                            .font(.system(size: 11))
                            .foregroundStyle(ink(0.4))
                    }
                }
            }
            .transition(.blurReplace)
            // Read as one confirmation; name the corrected words so a VoiceOver user
            // hears what Talkie fixed, not just "inserted". For a Private app, say so —
            // the eye.slash is silent to VoiceOver, so the trust moment is spoken here.
            .accessibilityElement(children: .combine)
            .accessibilityLabel({
                let base = words.isEmpty
                    ? "Inserted your dictation.".loc
                    : String(format: "Inserted your dictation. Corrected: %@".loc,
                             words.prefix(3).joined(separator: ", "))
                return privateSession
                    ? base + " " + "Private app — kept no history, learned nothing.".loc
                    : base
            }())
        case .copyPrompt(let message):
            // Expands downward into a second line when the re-paste shortcut is on,
            // spelling out how to use it rather than relying on a bare keycap.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink(0.9))
                    Text(message)
                        .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                        .foregroundStyle(ink(0.9))
                        .lineLimit(1)
                }
                if let shortcut = model.copyShortcut {
                    HStack(spacing: 6) {
                        Text("Press")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(ink(0.7))
                        KeycapHint(text: shortcut, fill: chipFill(0.16), ink: ink(0.92))
                        Text("to paste into a text field")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(ink(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .transition(.blurReplace)
            // The whole pill is the tap target in this phase (the outer tap gesture
            // fires only here). Expose it as a button with a clear action so a
            // VoiceOver user can activate it to copy the transcript again. The tap
            // gesture lives on the ancestor `pill`, which VO activation may not
            // bubble to, so wire the copy action directly here too — activation then
            // copies regardless of gesture propagation.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
            .accessibilityHint("Activate to copy your transcript to the clipboard.".loc)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.onCopyTap() }
        case .copied:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.positive)
                Text("Copied")
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.85))
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Copied to the clipboard.".loc)
        case .commandPreview(let text, let replacing):
            // A voice command's proposed replacement — nothing's been inserted yet.
            // The pill widens to show it, with two chips: Insert (apply it) and Undo
            // (drop it, keep what was there). Reuses the `.inserting` chip styling.
            VStack(alignment: .leading, spacing: 4) {
                if let replacing {
                    // Implicit-fallback path only: the user never selected anything
                    // themselves, so this is their only visual anchor for what
                    // "Insert" is about to replace. Required, not decorative.
                    Text("Replacing your last dictation: \u{201c}\(replacing.prefix(60))\u{201d}")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ink(0.55))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.coral)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                        .foregroundStyle(ink(0.92))
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        // Name the proposal so it isn't read as a bare, unlabeled
                        // string; the chips that follow are the actions.
                        .accessibilityLabel(
                            replacing == nil
                                ? String(format: "Voice command suggestion: %@".loc, text)
                                : String(format: "Replace \u{201c}%@\u{201d} with: %@".loc,
                                         String(replacing!.prefix(60)), text)
                        )
                    CommandChip(title: "Insert", prominent: true,
                                fill: chipFill(0.18), ink: ink(0.72),
                                hint: "Applies the suggested text.".loc) { model.onCommandConfirm() }
                    CommandChip(title: "Undo", prominent: false,
                                fill: chipFill(0.13), ink: ink(0.72),
                                hint: "Dismisses the suggestion and keeps your text.".loc) { model.onCommandUndo() }
                }
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .contain)
        case .commandReverted:
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ink(0.85))
                Text("Reverted")
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.85))
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reverted.".loc)
        case .saved(let message):
            // A note reached the export destination — a brief, non-interactive
            // confirmation (mirrors `.copied`). A checkmark + the "Saved to …" line
            // the hub composed, so the pill stays destination-agnostic. The message
            // is the full sentence, shown verbatim.
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.positive)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        case .record(let message):
            // K3: a personal best just broke — a brief, non-interactive celebration
            // (mirrors `.saved`). A gold trophy + the "Personal best — …" line the
            // hub composed, shown verbatim so the pill stays record-agnostic.
            HStack(spacing: 6) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.featherGold)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message)
        case .learned(let message):
            // Talkie auto-added a dictionary correction — a brief, tappable ping.
            // One chip: Undo (remove the rule). Auto-dismisses; ignoring it keeps it.
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.92))
                    .lineLimit(1)
                    .frame(maxWidth: 300, alignment: .leading)
                    .accessibilityLabel(message)
                CommandChip(title: "Undo", prominent: false,
                            fill: chipFill(0.13), ink: ink(0.72),
                            hint: "Removes this learned correction.".loc) { model.onLearnedUndo() }
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .contain)
        case .offerVibe(let repo):
            // First-run Vibe Coding offer (A9): we found a real git repo behind the
            // editor/terminal. One tap to index it. Two chips: Index (turn it on +
            // index this repo) and Not now (decline this root forever). Same visual
            // family as the learned/command pills.
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                    .accessibilityHidden(true)
                Text(String(format: "Index %@ filenames?".loc, repo))
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.92))
                    .lineLimit(1)
                    .frame(maxWidth: 300, alignment: .leading)
                    .accessibilityLabel(
                        String(format: "Index the project %@ so spoken filenames snap to its real files?".loc, repo))
                CommandChip(title: "Index", prominent: true,
                            fill: chipFill(0.18), ink: ink(0.72),
                            hint: "Turns on Vibe Coding and indexes this project's filenames.".loc) { model.onVibeAccept() }
                CommandChip(title: "Not now", prominent: false,
                            fill: chipFill(0.13), ink: ink(0.72),
                            hint: "Dismisses the offer for this project.".loc) { model.onVibeDecline() }
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .contain)
        case .reviewLowConfidence(let words):
            // Low-confidence review chip (A12): the recognizer was visibly unsure
            // about `words` (1–2 jargon-like terms). Same visual family as the
            // learned/command pills — a question-mark glyph, the unsure term(s), and
            // one "Fix" chip that opens the correction popover. It NEVER edits the
            // text already inserted; the copy is about NEXT time. `onReviewFix` gets
            // the first (primary) unsure word to prefill the popover.
            let primary = words.first ?? ""
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                    .accessibilityHidden(true)
                Text(words.count > 1
                     ? String(format: "Not sure about %@".loc, words.prefix(2).joined(separator: ", "))
                     : String(format: "Not sure about \u{201c}%@\u{201d}".loc, primary))
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.92))
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
                CommandChip(title: "Fix", prominent: true,
                            fill: chipFill(0.18), ink: ink(0.72),
                            hint: "Opens a small box to correct the spelling for next time.".loc) {
                    model.onReviewFix(primary)
                }
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .contain)
        case .launchOffer:
            // Earned launch-at-login offer (H8): a 3-day streak of real use has been
            // reached, so offer one tap to start Talkie at login — the hotkey stops
            // dying silently after every reboot. Same visual family as the vibe/learned
            // pills: a power glyph, the honest line, and one "Enable" chip. A coral
            // countdown ring (above) drains over the window; a timeout means "not now"
            // (and resolves it — offered once, ever).
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                    .accessibilityHidden(true)
                Text("3-day streak — start Talkie at login so dictation always works?")
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.92))
                    .lineLimit(2)
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                CommandChip(title: "Enable", prominent: true,
                            fill: chipFill(0.18), ink: ink(0.72),
                            hint: "Starts Talkie automatically at login so your hotkey is always ready.".loc) {
                    model.onLaunchOfferEnable()
                }
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .contain)
        case .keepStyle(let style, let app):
            // Post-insert keep-style chip (H3): the user cycled the in-pill cleanup
            // switcher this dictation — which changed only this dictation — and the
            // chosen style differs from the app's default. Offer one tap to make it
            // the app's rule. Same visual family as the vibe/launch offers: a wand
            // glyph, the honest "Keep {Style} for {App}?" line, and one "Keep" chip.
            // A coral countdown ring (above) drains over the window; a timeout drops
            // the change (the switcher was session-scoped — nothing persisted).
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                    .accessibilityHidden(true)
                Text(String(format: "Keep %@ for %@?".loc, style, app))
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.92))
                    .lineLimit(1)
                    .frame(maxWidth: 300, alignment: .leading)
                    .accessibilityLabel(
                        String(format: "Keep the %@ cleanup style as the default for %@?".loc, style, app))
                CommandChip(title: "Keep", prominent: true,
                            fill: chipFill(0.18), ink: ink(0.72),
                            hint: "Makes this cleanup style the default for this app.".loc) {
                    model.onKeepStyle()
                }
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .contain)
        case .gestureHint:
            // Teaching pill after a lone tap that captured nothing: a keyboard glyph
            // and the one-line gesture summary. Non-interactive; auto-hides.
            HStack(spacing: 7) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink(0.85))
                    .accessibilityHidden(true)
                Text("Hold to talk · keep holding to lock")
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .medium))
                    .foregroundStyle(ink(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Hold your key to talk; keep holding it to lock hands-free recording.".loc)
        case .error(let message):
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: model.highContrast ? 14 : 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: model.highContrast ? 13 : 12, weight: .regular))
                    .foregroundStyle(ink(0.92))
                    .lineLimit(2)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            .transition(.blurReplace)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(format: "Error: %@".loc, message))
        case .hidden:
            EmptyView()
        }
    }
}

/// A coral capsule outline that traces the learned-correction pill and visibly
/// drains away over `duration` — a wordless timer for how long the ping stays
/// before it auto-collapses. A faint static track sits underneath so the
/// depleting arc reads as a countdown, and a soft coral glow makes it a "ring of
/// light" rather than a hard stroke. Created fresh per ping (keyed by
/// `learnedTick`), so `onAppear` restarts the drain from full every time.
private struct CountdownRing: View {
    let duration: TimeInterval
    @State private var depleted = false

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 2)
            Capsule(style: .continuous)
                .trim(from: 0, to: depleted ? 0 : 1)
                .stroke(Theme.coral, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .shadow(color: Theme.coral.opacity(0.6), radius: 4)
        }
        .animation(.linear(duration: duration), value: depleted)
        .onAppear { depleted = true }
    }
}

/// A tappable capsule chip used in the command-preview pill (Insert / Undo).
/// Reuses the `.inserting` chip treatment — a `.white.opacity(0.13)` capsule — so
/// it sits in the same visual family as the replaced-word chips. The primary
/// action carries a coral tint to read as the affirmative choice. `fill`/`ink` come
/// from the parent's accessibility-aware helpers so the chip honors Increase
/// Contrast / Reduce Transparency; `hint` is the VoiceOver hint for the action.
private struct CommandChip: View {
    let title: LocalizedStringKey
    let prominent: Bool
    let fill: Color
    let ink: Color
    let hint: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Theme.coral : ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.coral.opacity(prominent ? 0.5 : 0), lineWidth: 1)
            )
            .opacity(hovering ? 0.85 : 1)
            .contentShape(Capsule(style: .continuous))
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            // A real, activatable control for VoiceOver: the title is the label, the
            // caller-supplied `hint` explains the outcome, and the button trait tells
            // the user it can be activated.
            .accessibilityLabel(Text(title))
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
    }
}

/// A small keycap-styled hint shown in the copy-prompt pill — e.g. "⌥⌘V" — telling
/// you the shortcut to re-paste the last transcript once you've focused a field.
/// `fill`/`ink` come from the parent's accessibility-aware helpers so the keycap
/// honors Increase Contrast / Reduce Transparency.
private struct KeycapHint: View {
    let text: String
    var fill: Color = .white.opacity(0.16)
    var ink: Color = .white.opacity(0.92)

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    )
            )
            .help("Focus a text field and press \(text) to paste your last transcript")
            // The surrounding copy-prompt element already reads the shortcut in its
            // combined label, so keep this decorative keycap out of the VoiceOver
            // tree to avoid a duplicate, contextless "⌥⌘V".
            .accessibilityHidden(true)
    }
}

/// Feature 14 — the in-pill cleanup-style switcher. While you're talking it shows
/// the active style/level for the app you're dictating into; tap it to cycle to
/// the next one (persisted through the injected settings/profile). It renders
/// nothing at all when the hub hasn't wired a label, so the bare pill is unchanged.
private struct CleanupSwitcher: View {
    @ObservedObject var model: HUDModel
    /// Accessibility-aware fill + text color resolved by the parent HUDView.
    var chipFill: Color = .white.opacity(0.13)
    var ink: Color = .white.opacity(0.82)
    @State private var hovering = false

    var body: some View {
        // `cleanupNudge` is read so the label re-resolves after each cycle.
        let _ = model.cleanupNudge
        if let label = model.cleanupLabel() {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.7))
                    .accessibilityHidden(true)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(hovering ? chipFill.opacity(0.9) : chipFill)
            )
            .contentShape(Capsule(style: .continuous))
            .onTapGesture { model.cycleCleanup() }
            .onHover { hovering = $0 }
            .help("Cleanup style — tap to change how Talkie polishes this dictation")
            .transition(.blurReplace)
            // A labeled, activatable control for VoiceOver: state the current style
            // and that double-tapping cycles it (matches the spec's example wording).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: "Cleanup style: %@.".loc, label))
            .accessibilityHint("Double-tap to cycle to the next cleanup style.".loc)
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// The recording-state indicator: a hollow gray ring while arming (not yet
/// capturing) and a filled red dot while recording. It pulses so it reads as a
/// live "REC" light at full opacity, and the ring→filled shape change means the
/// recording state is legible without relying on the gray→red color alone.
private struct StatusDot: View {
    let color: Color
    var filled: Bool = true
    var pulsing: Bool = true
    @State private var pulse = false

    var body: some View {
        shape
            .frame(width: 9, height: 9)
            .opacity(pulse ? 1.0 : 0.5)
            .scaleEffect(pulse ? 1.0 : 0.78)
            .shadow(color: color.opacity(pulse && filled ? 0.55 : 0), radius: 4)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }

    @ViewBuilder
    private var shape: some View {
        if filled {
            Circle().fill(color)
        } else {
            Circle().stroke(color, lineWidth: 1.8)
        }
    }
}

/// A quick left-right shake fired when the key is pressed again mid-processing —
/// a self-explanatory "still finishing, can't start yet" cue, so the press is
/// clearly acknowledged even though a new session can't begin.
private struct BusyShake: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.phaseAnimator([0.0, -5.0, 5.0, -3.5, 3.5, 0.0], trigger: trigger) { view, dx in
            view.offset(x: dx)
        } animation: { _ in .easeInOut(duration: 0.07) }
    }
}

/// A red audio waveform: equal-width bars whose heights follow the live mic
/// levels (newest on the right) so the row moves with your voice. The instant
/// recording starts, a single fast wave of opacity flows left→right across the
/// bars — a one-shot "recording now" flourish — then they settle to steady red.
/// While arming the bars sit calm, dim and gray.
private struct Waveform: View {
    let levels: [CGFloat]          // 0…1, newest last
    var tint: Color
    var sweepTrigger: Int          // bumped once when audio goes live

    @State private var opacities = Array(repeating: 0.5, count: HUDModel.barCount)

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3
    private let maxHeight: CGFloat = 22
    private let floor: CGFloat = 4

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { idx, level in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: barWidth, height: floor + level * (maxHeight - floor))
                    .opacity(idx < opacities.count ? opacities[idx] : 1)
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.09), value: levels)
        .onChange(of: sweepTrigger) { playSweep() }
    }

    /// One fast wave of opacity flowing left→right, settling at full red. Runs
    /// once per recording start (driven by `sweepTrigger`).
    private func playSweep() {
        let n = opacities.count
        for i in 0..<n { opacities[i] = 0.2 }
        for i in 0..<n {
            withAnimation(.easeOut(duration: 0.2).delay(Double(i) * 0.022)) {
                opacities[i] = 1
            }
        }
    }
}

// MARK: - Pass-through hit-testing

/// A tiny reference box the SwiftUI pill writes its current frame into (in SwiftUI
/// top-left coordinates within the panel) so the hosting view knows where the only
/// clickable region is. Only ever touched on the main thread (SwiftUI layout +
/// AppKit hit-testing both run there), so `@unchecked Sendable` is accurate.
private final class PillFrameBox: @unchecked Sendable {
    /// `.null` until the pill has laid out — until then nothing is claimed, which
    /// is the safe default (clicks pass straight through).
    var rect: CGRect = .null
}

/// An `NSHostingView` that only claims clicks landing on the pill itself. The HUD
/// panel is much larger than the pill (it holds the shadow and the drop-in
/// headroom), so when mouse events are enabled — needed for the cleanup switcher
/// and the command-preview chips — we must NOT swallow clicks on the transparent
/// area, or we'd block the app the user is working in. Everything outside the
/// published pill rect returns `nil`, letting those clicks fall through.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    private let pillFrame: PillFrameBox

    @MainActor init(rootView: Content, pillFrame: PillFrameBox) {
        self.pillFrame = pillFrame
        super.init(rootView: rootView)
    }

    @MainActor required init(rootView: Content) {
        self.pillFrame = PillFrameBox()
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let rect = pillFrame.rect
        guard !rect.isNull else { return nil }
        // `point` is in this view's superview coordinates (the content view), which
        // is flipped vs. SwiftUI's top-left frame. Convert into top-left space, with
        // a small slop so the pill's edge is comfortably tappable.
        let local = convert(point, from: superview)
        let topLeftY = bounds.height - local.y
        let probe = CGPoint(x: local.x, y: topLeftY)
        guard rect.insetBy(dx: -4, dy: -4).contains(probe) else { return nil }
        return super.hitTest(point)
    }
}
