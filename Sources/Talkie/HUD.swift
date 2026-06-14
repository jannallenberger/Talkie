import AppKit
import SwiftUI

/// Visual state of the dictation HUD.
enum HUDPhase: Equatable {
    case hidden
    case listening
    case transcribing
    case processing
    case inserting
    case error(String)
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    @Published var text: String = ""
    /// Rolling history of recent mic levels (newest last) driving the waveform.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: HUDModel.barCount)

    static let barCount = 28
}

/// A floating, non-activating pill near the bottom of the active screen — like
/// Wispr Flow's dictation pill. The waveform reacts live to your voice.
@MainActor
final class HUDController {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private static let panelSize = NSSize(width: 540, height: 80)

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

    private func reposition() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func resetLevels() {
        model.levels = Array(repeating: 0, count: HUDModel.barCount)
    }

    func showListening() {
        cancelHide()
        resetLevels()
        model.phase = .listening
        model.text = ""
        let panel = ensurePanel()
        reposition()
        panel.orderFrontRegardless()
    }

    /// Push a fresh mic level into the rolling waveform history.
    func updateLevel(_ level: Float) {
        var l = model.levels
        l.removeFirst()
        l.append(CGFloat(max(0, min(1, level))))
        model.levels = l
    }

    func updateTranscribing(_ text: String) {
        cancelHide()
        if model.phase != .transcribing { model.phase = .transcribing }
        model.text = text
    }

    func showProcessing() {
        cancelHide()
        model.phase = .processing
    }

    func showInserting() {
        cancelHide()
        model.phase = .inserting
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
        // Centered compact pill within the (larger, transparent) panel.
        pill
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(model.phase == .hidden ? 0.85 : 1)
            .opacity(model.phase == .hidden ? 0 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.phase)
    }

    @ViewBuilder
    private var pill: some View {
        inner
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 8)
            .fixedSize()
    }

    // The pill shows ONLY the waveform while active — the transcript goes to the
    // focused app and the History log, never into the pill.
    @ViewBuilder
    private var inner: some View {
        switch model.phase {
        case .listening, .transcribing:
            Waveform(levels: model.levels)
                .frame(width: 124, height: 30)
        case .processing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Polishing…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .inserting:
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.green)
                Text("Inserted")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        case .hidden:
            EmptyView()
        }
    }
}

/// A live, reactive waveform: a row of capsule bars whose heights follow the
/// rolling mic-level history (newest on the right), so it "moves" with your voice.
private struct Waveform: View {
    let levels: [CGFloat]
    var tint: Color = .red

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 2.5
            let barWidth = max(2, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.55 + 0.45 * level))
                        .frame(width: barWidth, height: barHeight(level, in: geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .animation(.easeOut(duration: 0.11), value: levels)
    }

    private func barHeight(_ level: CGFloat, in maxHeight: CGFloat) -> CGFloat {
        let floor: CGFloat = 3
        return floor + level * (maxHeight - floor)
    }
}
