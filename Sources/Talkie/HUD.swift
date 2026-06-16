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
    case inserting([String])   // replaced words to show as chips; empty if none
    case copyPrompt(String)
    case copied
    case commandPreview(String) // the proposed replacement text, awaiting confirm
    case commandReverted        // brief "Reverted" confirmation (mirrors .copied)
    case error(String)
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    @Published var text: String = ""
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

    /// Key pressed — acknowledge immediately while the mic/engine warm up. Audio
    /// is not flowing yet, so the dot is gray (not recording).
    func showArming() {
        cancelHide()
        resetLevels()
        model.phase = .arming
        model.text = ""
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

    func updateTranscribing(_ text: String) {
        // Only meaningful while still capturing — a late partial must never
        // resurrect the pill out of processing/inserting/hidden.
        switch model.phase {
        case .arming, .listening, .transcribing: break
        default: return
        }
        cancelHide()
        if model.phase != .transcribing { model.phase = .transcribing }
        model.text = text
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

    func showInserting(replacedWords: [String] = []) {
        cancelHide()
        model.phase = .inserting(replacedWords)
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
    func showCommandPreview(_ text: String,
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
        model.phase = .commandPreview(text)
        reposition()
        panel.orderFrontRegardless()
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

    func showError(_ message: String) {
        cancelHide()
        let panel = ensurePanel()
        panel.ignoresMouseEvents = true   // nothing to tap here
        model.phase = .error(message)
        reposition()
        panel.orderFrontRegardless()
        hide(after: 2.6)
    }

    func hide(after delay: TimeInterval = 0.25) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.panel?.ignoresMouseEvents = true
            self.model.phase = .hidden
            self.panel?.orderOut(nil)
            self.hideTask = nil
        }
    }
}

// MARK: - SwiftUI HUD content

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    let pillFrame: PillFrameBox

    private static let hudSpace = "talkieHUD"

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
            .background(
                // Publish the panel-content height so the pass-through hosting
                // view can flip AppKit's bottom-left hit-test point into the
                // pill's top-left frame without touching any @MainActor state.
                GeometryReader { geo in
                    Color.clear.onAppear { pillFrame.viewHeight = geo.size.height }
                }
            )
    }

    @ViewBuilder
    private var pill: some View {
        // Solid pure-black capsule — floats above whatever app you're in. A faint
        // hairline keeps the edge legible even against a dark backdrop.
        inner
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.black)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                    )
            )
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
            let tint = recording ? Theme.featherRed : Color.white.opacity(0.55)
            HStack(spacing: 8) {
                StatusDot(color: tint, filled: recording)
                    .animation(.easeInOut(duration: 0.25), value: recording)
                // A red waveform: equal-width bars whose heights move with your
                // voice. A one-shot wave of opacity sweeps across it the instant
                // recording starts, then it settles to steady red.
                Waveform(levels: model.levels, tint: tint, sweepTrigger: model.recordStartID)
                // Feature 14: the active cleanup style/level, tappable to cycle —
                // change how Talkie polishes this dictation without leaving the
                // record. Hidden entirely when no switcher is wired (today's pill).
                CleanupSwitcher(model: model)
            }
            .transition(.blurReplace)
        case .processing:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Polishing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .modifier(BusyShake(trigger: model.busyNudge))
            .transition(.blurReplace)
        case .inserting(let words):
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.positive)
                Text("Inserted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                if !words.isEmpty {
                    Text("·")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.22))
                    ForEach(Array(words.prefix(3).enumerated()), id: \.offset) { _, word in
                        Text(word)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.13)))
                    }
                    if words.count > 3 {
                        Text("+\(words.count - 3)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .transition(.blurReplace)
        case .copyPrompt(let message):
            // Expands downward into a second line when the re-paste shortcut is on,
            // spelling out how to use it rather than relying on a bare keycap.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                if let shortcut = model.copyShortcut {
                    HStack(spacing: 6) {
                        Text("Press")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        KeycapHint(text: shortcut)
                        Text("to paste into a text field")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .transition(.blurReplace)
        case .copied:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.positive)
                Text("Copied")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .transition(.blurReplace)
        case .commandPreview(let text):
            // A voice command's proposed replacement — nothing's been inserted yet.
            // The pill widens to show it, with two chips: Insert (apply it) and Undo
            // (drop it, keep what was there). Reuses the `.inserting` chip styling.
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.coral)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                CommandChip(title: "Insert", prominent: true) { model.onCommandConfirm() }
                CommandChip(title: "Undo", prominent: false) { model.onCommandUndo() }
            }
            .transition(.blurReplace)
        case .commandReverted:
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Reverted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .transition(.blurReplace)
        case .error(let message):
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .frame(maxWidth: 300, alignment: .leading)
            }
            .transition(.blurReplace)
        case .hidden:
            EmptyView()
        }
    }
}

/// A tappable capsule chip used in the command-preview pill (Insert / Undo).
/// Reuses the `.inserting` chip treatment — a `.white.opacity(0.13)` capsule — so
/// it sits in the same visual family as the replaced-word chips. The primary
/// action carries a coral tint to read as the affirmative choice.
private struct CommandChip: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Theme.coral : .white.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(prominent ? 0.18 : 0.13))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.coral.opacity(prominent ? 0.5 : 0), lineWidth: 1)
            )
            .opacity(hovering ? 0.85 : 1)
            .contentShape(Capsule(style: .continuous))
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
    }
}

/// A small keycap-styled hint shown in the copy-prompt pill — e.g. "⌥⌘V" — telling
/// you the shortcut to re-paste the last transcript once you've focused a field.
private struct KeycapHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                    )
            )
            .help("Focus a text field and press \(text) to paste your last transcript")
    }
}

/// Feature 14 — the in-pill cleanup-style switcher. While you're talking it shows
/// the active style/level for the app you're dictating into; tap it to cycle to
/// the next one (persisted through the injected settings/profile). It renders
/// nothing at all when the hub hasn't wired a label, so the bare pill is unchanged.
private struct CleanupSwitcher: View {
    @ObservedObject var model: HUDModel
    @State private var hovering = false

    var body: some View {
        // `cleanupNudge` is read so the label re-resolves after each cycle.
        let _ = model.cleanupNudge
        if let label = model.cleanupLabel() {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(hovering ? 0.18 : 0.13))
            )
            .contentShape(Capsule(style: .continuous))
            .onTapGesture { model.cycleCleanup() }
            .onHover { hovering = $0 }
            .help("Cleanup style — tap to change how Talkie polishes this dictation")
            .transition(.blurReplace)
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
    /// is the safe default (clicks pass straight through). In SwiftUI top-left
    /// coordinates relative to the panel-content root (the `hudSpace` space).
    var rect: CGRect = .null
    /// The panel-content height, published from SwiftUI layout. The pass-through
    /// hit-test needs it to flip AppKit's bottom-left point into `rect`'s
    /// top-left space — cached here so the (nonisolated) override never has to
    /// read `bounds` off the main-actor-isolated view.
    var viewHeight: CGFloat = 0
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

    /// Called on the main thread by AppKit (mouse routing) and by the macOS
    /// accessibility runtime (hit-testing the element under a screen point).
    ///
    /// Deliberately `nonisolated`: a `@MainActor` `@objc` override makes the Swift 6
    /// runtime inject a main-actor executor precondition (`swift_task_isCurrentExecutor`)
    /// at the top of the ObjC thunk, and that check faults when the accessibility
    /// MIG path (`accessibilityHitTest:` → `hitTest:`) calls in — the cause of the
    /// 2026-06-16 SIGSEGV crash. Staying nonisolated means no check is emitted; we
    /// read only the precomputed, Sendable geometry and never touch `bounds`,
    /// `convert`, `super`, or `MainActor.assumeIsolated` (which would re-enter the
    /// same faulting primitive).
    nonisolated override func hitTest(_ point: NSPoint) -> NSView? {
        let box = pillFrame
        let rect = box.rect
        guard !rect.isNull, box.viewHeight > 0 else { return nil }
        // `point` is in this content view's superview coordinates. The panel is
        // borderless and this hosting view fills it at origin (0, 0), so that maps
        // 1:1 to view coordinates; flip AppKit's bottom-left y into the pill's
        // top-left frame, with a small slop so the edge stays comfortably tappable.
        let probe = CGPoint(x: point.x, y: box.viewHeight - point.y)
        guard rect.insetBy(dx: -4, dy: -4).contains(probe) else { return nil }
        // Returning the hosting view itself (rather than descending via
        // `super.hitTest`) is enough: every interactive control in the pill is a
        // SwiftUI `.onTapGesture`, which SwiftUI routes from the hosting view.
        return self
    }
}
