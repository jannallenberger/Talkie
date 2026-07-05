import SwiftUI

/// The live, user-adjustable settings for the knowledge graph — the Obsidian-style
/// customization surface, in Talkie's own visual language (dark `Theme` surfaces +
/// the brand accent, never Obsidian's purple).
///
/// Two groups, matching the panel:
///   • **Display** — pure render-time scalars (node size, link thickness, and the
///     degree/mentions cutoff above which a node shows its label). Changing these
///     repaints instantly; the simulation is untouched.
///   • **Forces** — the four headline physics constants, forwarded into
///     `ForceDirectedLayout.Parameters`. Changing these retunes the *running* sim and
///     re-heats it, so the layout eases toward the new shape.
///
/// Held as one `@State` in `KnowledgeGraphView` so a single "reset to defaults" swaps
/// every value back at once.
struct GraphRenderSettings: Equatable {
    // Display.
    var nodeSize: CGFloat = 1
    var linkThickness: CGFloat = 1
    var labelThreshold: Double = 4

    // Forces (map 1:1 onto ForceDirectedLayout.Parameters).
    var gravity: Double = ForceDirectedLayout.Parameters.default.gravity
    var charge: Double = ForceDirectedLayout.Parameters.default.charge
    var stiffness: Double = ForceDirectedLayout.Parameters.default.stiffness
    var restLength: Double = ForceDirectedLayout.Parameters.default.restLength

    static let defaults = GraphRenderSettings()

    /// The force fields projected onto a fresh `Parameters` (the non-tuned fields —
    /// softening, speed clamp, hub gravity, seed radius — keep their defaults).
    var layoutParameters: ForceDirectedLayout.Parameters {
        var p = ForceDirectedLayout.Parameters.default
        p.gravity = gravity
        p.charge = charge
        p.stiffness = stiffness
        p.restLength = restLength
        return p
    }
}

/// The collapsible controls overlay pinned to a corner of the graph. A small sliders
/// button toggles it; open, it's a compact card of grouped sliders that never covers
/// more than its own corner. Every slider is a live binding into the parent's
/// `GraphRenderSettings`, so edits take effect as the thumb moves (the canvas re-heats
/// on the Forces ones). A "Reset" pill restores all defaults.
struct GraphControlsPanel: View {
    @Binding var settings: GraphRenderSettings
    @Binding var isOpen: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            toggleButton
            if isOpen { panel }
        }
    }

    private var toggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isOpen.toggle() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOpen ? Theme.coral : Theme.inkSecondary)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(isOpen ? Theme.coral.opacity(0.5) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide graph controls".loc : "Show graph controls".loc)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Customize".loc)
                    .font(.talkieHeading(13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { settings = .defaults }
                } label: {
                    Text("Reset".loc)
                        .font(.talkieEyebrow)
                        .foregroundStyle(Theme.coral)
                }
                .buttonStyle(.plain)
                .disabled(settings == .defaults)
                .opacity(settings == .defaults ? 0.4 : 1)
                .help("Reset all graph controls to their defaults".loc)
            }

            group("Display") {
                slider("Node size", value: $settings.nodeSize, in: 0.5...2.2)
                slider("Link thickness", value: $settings.linkThickness, in: 0.4...3)
                slider("Text fade", value: $settings.labelThreshold, in: 1...12)
            }

            group("Forces") {
                slider("Center force", value: $settings.gravity, in: 0.002...0.06)
                slider("Repel force", value: $settings.charge, in: 1_500...14_000)
                slider("Link force", value: $settings.stiffness, in: 0.004...0.08)
                slider("Link distance", value: $settings.restLength, in: 40...200)
            }
        }
        .padding(16)
        .frame(width: 236, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Building blocks

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Eyebrow(text: title)
            content()
        }
    }

    /// One labelled slider. Generic over any `BinaryFloatingPoint` so the same row
    /// drives both the `CGFloat` display multipliers and the `Double` force fields;
    /// `.tint(Theme.coral)` gives the track the brand accent.
    private func slider<V: BinaryFloatingPoint>(_ label: String, value: Binding<V>,
                                                in range: ClosedRange<V>) -> some View
        where V.Stride: BinaryFloatingPoint {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(label))
                .font(.talkieHeading(12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Slider(value: value, in: range)
                .controlSize(.small)
                .tint(Theme.coral)
        }
    }
}
