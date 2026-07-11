import AppKit
import SwiftUI

/// The live meeting pill — a bigger sibling of the dictation HUD pill, pinned under
/// the notch for the whole recording. It reuses the HUD's capsule design language
/// (solid black continuous capsule, hairline, soft shadow) so it reads as the same
/// family, but it's its own persistent surface (lifecycle-tied to the recorder, not
/// the dictation phase machine) and it carries a second line: a live "subtopic".
///
/// The panel is **non-interactive** (`NotchPanel.make(interactive: false)`) so it
/// never blocks clicks to the call window beneath it — it's an indicator, not a
/// control. Stop lives in the Meetings tab.
@MainActor
final class MeetingPillController {
    private var panel: NSPanel?

    private static let panelSize = NSSize(width: 540, height: 104)

    /// Wire the pill to the recorder (timer / capture state) and the subtopic model.
    /// Call once; `show()`/`hide()` then drive visibility.
    func attach(recorder: MeetingRecorder, subtopic: MeetingSubtopicModel) {
        guard panel == nil else { return }
        let panel = NotchPanel.make(size: Self.panelSize, interactive: false)
        panel.contentView = NSHostingView(
            rootView: MeetingPillView(recorder: recorder, subtopic: subtopic)
        )
        self.panel = panel
    }

    func show() {
        guard let panel else { return }
        NotchPanel.reposition(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct MeetingPillView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var subtopic: MeetingSubtopicModel

    var body: some View {
        pill
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
    }

    /// Honest status: names the far-end capture when it's actually happening.
    private var statusLine: String {
        recorder.capturingFarEnd ? "Recording you + the call".loc : "Recording".loc
    }

    private var pill: some View {
        HStack(spacing: 11) {
            RecDot()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(statusLine)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(MeetingTranscriptRenderer.timecode(recorder.elapsed))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                }
                // A live far-end QUESTION takes priority — it's the instant,
                // deterministic signal (no model, no hysteresis) and the highest-value
                // moment on the pill (the interview win). It's ephemeral (auto-clears
                // a few seconds after AppDelegate sets it), so once it lapses we fall
                // back to the topic line exactly as before. The subtopic itself only
                // ever appears once the engine is confident — the pill stays neutral
                // (status + timer) until then, and never shows a guess.
                if let question = subtopic.liveQuestion {
                    HStack(spacing: 5) {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.featherGold.opacity(0.9))
                        Text(question)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    .transition(.blurReplace)
                } else if let topic = subtopic.current {
                    // Prefer the sentence gloss for display (falls back to the short
                    // phrase for the brief moment right after accept, before
                    // `currentGloss` lands, and for any edge case where it's nil) —
                    // gating/chapters still key off `subtopic.current` alone, untouched.
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.coral.opacity(0.9))
                            .padding(.top, 1.5)
                        Text(subtopic.currentGloss ?? topic)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                            // Cap the width so a full sentence actually WRAPS to two
                            // lines instead of the capsule just ballooning wider — the
                            // outer `.fixedSize()` below hugs the tree's ideal size,
                            // and without this cap "ideal" would mean "as wide as
                            // needed to fit on one line" (no wrap, capsule overflows
                            // the 540pt panel). Bounding width here is what makes the
                            // capsule grow VERTICALLY instead of horizontally.
                            .frame(maxWidth: 460, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.blurReplace)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(.black)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.38), radius: 12, x: 0, y: 6)
        // Hug ideal size in both dimensions (unchanged from before): width still hugs
        // tightly for the short neutral/topic-phrase case, and height now correctly
        // reflects up to 2 wrapped lines thanks to the width cap above.
        .fixedSize()
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: subtopic.current)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: subtopic.currentGloss)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: subtopic.liveQuestion)
        .animation(.easeInOut(duration: 0.25), value: recorder.capturingFarEnd)
    }
}

/// A pulsing filled-red REC light — the meeting analogue of the HUD's `StatusDot`
/// (which is private to `HUD.swift`), kept local so the two surfaces stay decoupled.
private struct RecDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Theme.featherRed)
            .frame(width: 9, height: 9)
            .opacity(pulse ? 1.0 : 0.5)
            .scaleEffect(pulse ? 1.0 : 0.78)
            .shadow(color: Theme.featherRed.opacity(pulse ? 0.55 : 0), radius: 4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
