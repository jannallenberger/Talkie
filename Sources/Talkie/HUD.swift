import AppKit
import SwiftUI

/// Visual state of the dictation HUD.
enum HUDPhase: Equatable {
    case hidden
    case listening
    case transcribing
    case inserting
    case error(String)
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    @Published var text: String = ""
}

/// A floating, non-activating panel that shows the live transcript near the
/// bottom of the active screen — like Wispr Flow's dictation pill.
@MainActor
final class HUDController {
    private let model = HUDModel()
    private var panel: NSPanel?

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: HUDView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
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
        panel.hasShadow = true
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
        let y = frame.minY + 120
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showListening() {
        model.phase = .listening
        model.text = ""
        let panel = ensurePanel()
        reposition()
        panel.orderFrontRegardless()
    }

    func updateTranscribing(_ text: String) {
        if model.phase != .transcribing { model.phase = .transcribing }
        model.text = text
    }

    func showInserting() {
        model.phase = .inserting
    }

    func showError(_ message: String) {
        let panel = ensurePanel()
        model.phase = .error(message)
        reposition()
        panel.orderFrontRegardless()
        hide(after: 2.6)
    }

    func hide(after delay: TimeInterval = 0.25) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            self.model.phase = .hidden
            self.panel?.orderOut(nil)
        }
    }
}

// MARK: - SwiftUI HUD content

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            indicator
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(6)
        .opacity(model.phase == .hidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.18), value: model.phase)
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.phase {
        case .listening, .transcribing:
            PulsingDot()
        case .inserting:
            Image(systemName: "text.cursor")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            Text("Listening…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        case .transcribing:
            Text(model.text.isEmpty ? "…" : model.text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.head)
        case .inserting:
            Text("Inserting…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        case .error(let message):
            Text(message)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(2)
        case .hidden:
            EmptyView()
        }
    }
}

private struct PulsingDot: View {
    @State private var animating = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 12, height: 12)
            .scaleEffect(animating ? 1.0 : 0.6)
            .opacity(animating ? 1.0 : 0.5)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: animating)
            .onAppear { animating = true }
    }
}
