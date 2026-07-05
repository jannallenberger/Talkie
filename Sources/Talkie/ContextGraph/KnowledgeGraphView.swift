import SwiftUI

/// The interactive, force-directed **knowledge graph** of your on-device context
/// graph (WS-M) — the Obsidian-style map of the people, projects, and terms you
/// talk about, connected wherever the same dictation or meeting mentioned two of
/// them. 100% local: it reads only the `ContextGraphStore` snapshot, never a
/// network.
///
/// This is the tab/subpage entry point: it owns the live store, re-derives the
/// pure `KnowledgeGraphModel.KnowledgeGraph` whenever the store's entities change,
/// and hands it to the `Canvas`-drawing `GraphCanvas`. A tapped node opens an
/// inspector panel (name, kind, mentions, first/last seen, recent provenance) that
/// re-fetches the full `Entity` from the store so it always shows current sources.
struct KnowledgeGraphView: View {
    @ObservedObject var contextGraph: ContextGraphStore

    /// The derived graph. Rebuilt from the snapshot on appear and whenever entities
    /// change — cheap (a few hundred nodes) and keeps node identity stable so the
    /// layout doesn't jump when an unrelated entity updates.
    @State private var graph: KnowledgeGraphModel.KnowledgeGraph = .empty
    /// The currently selected node's id, driving the inspector.
    @State private var selectedID: EntityID?
    /// The live Obsidian-style customization values (display multipliers + the four
    /// headline force constants). One struct so "Reset" restores everything at once.
    @State private var render = GraphRenderSettings.defaults
    /// Whether the collapsible controls panel is open. Closed by default so the graph
    /// opens clean; the sliders button in the corner reveals it.
    @State private var controlsOpen = false

    /// When true, the surrounding chrome (legend, cap notice, controls) is hidden —
    /// set by the Memory-page embedding, where the graph is a background layer that
    /// the search bar + history slide over, so those overlays would collide with the
    /// scroll content. The standalone use leaves it false and keeps the full chrome.
    var chromeHidden = false

    var body: some View {
        Group {
            if graph.isEmpty {
                emptyState
            } else {
                GraphCanvas(graph: graph, selectedID: $selectedID,
                            parameters: render.layoutParameters,
                            nodeSizeMultiplier: render.nodeSize,
                            linkThicknessMultiplier: render.linkThickness,
                            labelThreshold: Int(render.labelThreshold.rounded()))
                    .overlay(alignment: .topLeading) { if !chromeHidden { legend } }
                    .overlay(alignment: .topTrailing) { inspector }
                    .overlay(alignment: .bottomLeading) { if !chromeHidden { capNotice } }
                    .overlay(alignment: .bottomTrailing) { controls }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .navigationTitle("Knowledge graph".loc)
        .onAppear(perform: rebuild)
        .onReceive(contextGraph.$entities.map { _ in () }) { _ in rebuild() }
    }

    // MARK: Controls (Obsidian-style, collapsible)

    private var controls: some View {
        GraphControlsPanel(settings: $render, isOpen: $controlsOpen)
            .padding(16)
    }

    private func rebuild() {
        graph = KnowledgeGraphModel.build(from: Array(contextGraph.entities.values))
        // Drop a stale selection if its node no longer exists.
        if let selectedID, !graph.nodes.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.inkTertiary)
            Text("Your knowledge graph".loc)
                .font(.talkieDisplay(22))
                .foregroundStyle(Theme.ink)
            Text("Dictate and take meetings — the people, projects, and terms you mention connect up here.".loc)
                .font(.talkieHeading(14, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Legend (kind → colour key)

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(.person)
            legendDot(.project)
            legendDot(.term)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(16)
    }

    private func legendDot(_ kind: EntityKind) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(GraphStyle.color(for: kind))
                .frame(width: 9, height: 9)
            Text(LocalizedStringKey(GraphStyle.label(for: kind)))
                .font(.talkieEyebrow)
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    // MARK: Cap notice — honest "top N of M" when the graph was trimmed.

    @ViewBuilder
    private var capNotice: some View {
        if graph.wasCapped {
            Text(String(format: "Showing the %1$@ most-mentioned of %2$@".loc,
                        graph.nodes.count.formatted(), graph.totalEligible.formatted()))
                .font(.talkieEyebrow)
                .foregroundStyle(Theme.inkTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(16)
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let selectedID, let entity = contextGraph.entities[selectedID] {
            NodeInspector(entity: entity) { self.selectedID = nil }
                .padding(16)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

// MARK: - Node inspector panel

/// The detail card shown when a node is tapped: name, kind, mention count, first /
/// last seen, and the few most-recent provenance snippets (which dictation or
/// meeting mentioned it). Reuses the `Entity` straight from the store, so provenance
/// is always current.
private struct NodeInspector: View {
    let entity: Entity
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: GraphStyle.icon(for: entity.kind))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(GraphStyle.color(for: entity.kind))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.displayName)
                        .font(.talkieHeading(15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                    Text(LocalizedStringKey(GraphStyle.label(for: entity.kind)))
                        .font(.talkieEyebrow)
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help("Close".loc)
            }

            Divider().overlay(Theme.hairline)

            VStack(alignment: .leading, spacing: 6) {
                InspectorRow(icon: "quote.bubble",
                             text: String(format: "Mentioned %@".loc, mentionsText))
                InspectorRow(icon: "clock.arrow.circlepath",
                             text: String(format: "First seen %@".loc, Self.relative.localizedString(for: Date(timeIntervalSince1970: entity.firstSeenUnix), relativeTo: Date())))
                InspectorRow(icon: "clock",
                             text: String(format: "Last seen %@".loc, Self.relative.localizedString(for: entity.lastSeen, relativeTo: Date())))
            }

            if !recentProvenance.isEmpty {
                Divider().overlay(Theme.hairline)
                Text("Recent sources".loc)
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkSecondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(recentProvenance.enumerated()), id: \.offset) { _, p in
                        InspectorProvenance(provenance: p)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
    }

    private var mentionsText: String {
        entity.mentions == 1 ? "once".loc : String(format: "%@ times".loc, entity.mentions.formatted())
    }

    /// The three most-recent provenance entries (the store keeps them oldest-first).
    private var recentProvenance: [Provenance] {
        Array(entity.provenance.reversed().prefix(3))
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

private struct InspectorRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 15)
            Text(text)
                .font(.talkieHeading(12.5, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 0)
        }
    }
}

/// One provenance line in the inspector: source label + a short quote if present.
private struct InspectorProvenance: View {
    let provenance: Provenance
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: sourceIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(sourceLabel))
                    .font(.talkieHeading(11.5, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                if let snippet = provenance.snippet, !snippet.isEmpty {
                    Text("“\(snippet)”")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sourceIcon: String {
        switch provenance.source {
        case .dictation:  return "text.bubble"
        case .meeting:    return "person.2"
        case .dictionary: return "character.book.closed"
        case .calendar:   return "calendar"
        case .appContext: return "app.badge"
        }
    }

    private var sourceLabel: String {
        switch provenance.source {
        case .dictation:  return "Dictation"
        case .meeting:    return "Meeting"
        case .dictionary: return "Dictionary"
        case .calendar:   return "Calendar"
        case .appContext: return "On-screen context"
        }
    }
}

// MARK: - Graph styling (kind → colour / icon / label)

/// Shared visual mapping from `EntityKind` to the on-brand feather palette, so the
/// canvas nodes, the legend, and the inspector all agree. Three distinct hues from
/// `Theme` — matching the Memory tab's per-kind tints:
///   • person  → plum   • project → blue   • term → green
enum GraphStyle {
    static func color(for kind: EntityKind) -> Color {
        switch kind {
        case .person:     return Theme.featherPlum
        case .project:    return Theme.featherBlue
        case .term:       return Theme.featherGreen
        case .commitment: return Theme.featherGold // excluded from the graph, but total.
        }
    }

    static func label(for kind: EntityKind) -> String {
        switch kind {
        case .person:     return "People"
        case .project:    return "Projects"
        case .term:       return "Terms"
        case .commitment: return "Commitments"
        }
    }

    static func icon(for kind: EntityKind) -> String {
        switch kind {
        case .person:     return "person.fill"
        case .project:    return "folder.fill"
        case .term:       return "textformat"
        case .commitment: return "checklist"
        }
    }
}
