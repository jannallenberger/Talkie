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
    /// Invoked when the user taps the pill in the `.copyPrompt` state.
    var onCopyTap: () -> Void = {}

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

    // Compact panel — the transparent canvas the pill floats in. Kept small so the
    // pill hugs the notch; the extra height below leaves room for the soft shadow
    // and the drop-in entrance.
    private static let panelSize = NSSize(width: 440, height: 72)

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: HUDView(model: model))
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
        panel.ignoresMouseEvents = true
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
    func showCopyPrompt(text: String, message: String) {
        cancelHide()
        model.copyText = text
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

    func showError(_ message: String) {
        cancelHide()
        let panel = ensurePanel()
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
            HStack(spacing: 7) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
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
