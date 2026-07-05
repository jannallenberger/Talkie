import SwiftUI

/// The drawing + interaction surface for the knowledge graph. Owns the live
/// `ForceDirectedLayout`, steps it on a `TimelineView` animation clock until it
/// settles (then stops, to spare the CPU), and paints edges + nodes into a
/// `Canvas`. Handles pan, zoom, node-drag, and tap-to-select itself.
///
/// Coordinate spaces:
///   • **world** — the layout's origin-centred abstract space (`layout.positions`).
///   • **screen** — the canvas' points. `worldToScreen` composes centre + pan + zoom.
/// Hit-testing converts a tap back through `screenToWorld` and picks the nearest node
/// within a zoom-aware radius.
struct GraphCanvas: View {
    let graph: KnowledgeGraphModel.KnowledgeGraph
    @Binding var selectedID: EntityID?

    /// Live physics parameters from the controls panel. A change to these re-seeds
    /// the running sim's forces and re-heats it (see `.onChange` below) so the layout
    /// visibly responds as the user drags a Forces slider.
    var parameters: ForceDirectedLayout.Parameters = .default
    /// Display multipliers from the controls panel — pure render-time scalars, so
    /// changing them repaints instantly without touching the simulation.
    ///   • `nodeSizeMultiplier`      scales every node's drawn radius.
    ///   • `linkThicknessMultiplier` scales every edge's stroke width.
    ///   • `labelThreshold`          the degree/mentions cutoff above which a node is
    ///     labelled at rest (lower = more labels shown).
    var nodeSizeMultiplier: CGFloat = 1
    var linkThicknessMultiplier: CGFloat = 1
    var labelThreshold: Int = 4

    /// The simulation. Rebuilt when the graph's node/edge identity changes.
    @State private var layout: ForceDirectedLayout
    /// Drives the `TimelineView` clock: true while the graph is on screen so the sim
    /// runs CONTINUOUSLY (a grab always responds; it never freezes a couple of seconds
    /// after opening). Flipped false only in `.onDisappear` so it doesn't burn CPU
    /// off-screen.
    @State private var isSettling = true

    // Viewport transform.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    // Gesture accumulators (committed to `zoom`/`pan` on gesture end).
    @GestureState private var pinch: CGFloat = 1
    @State private var lastPan: CGSize = .zero

    // Active node drag.
    @State private var draggingNode: Int?
    /// Set true on the first `onChanged` of a drag so the pan-vs-node-drag decision is
    /// made once per gesture and can't flip partway through; reset on `onEnded`.
    @State private var dragDecided = false

    private static let zoomRange: ClosedRange<CGFloat> = 0.3...3
    /// A brief warm-up so the graph opens already partly spread rather than as a ring.
    private static let warmupSteps = 60

    init(graph: KnowledgeGraphModel.KnowledgeGraph, selectedID: Binding<EntityID?>,
         parameters: ForceDirectedLayout.Parameters = .default,
         nodeSizeMultiplier: CGFloat = 1,
         linkThicknessMultiplier: CGFloat = 1,
         labelThreshold: Int = 4) {
        self.graph = graph
        self._selectedID = selectedID
        self.parameters = parameters
        self.nodeSizeMultiplier = nodeSizeMultiplier
        self.linkThicknessMultiplier = linkThicknessMultiplier
        self.labelThreshold = labelThreshold
        var initial = ForceDirectedLayout(nodes: graph.nodes, edges: graph.edges, parameters: parameters)
        initial.settle(steps: Self.warmupSteps)
        self._layout = State(initialValue: initial)
    }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let effectiveZoom = clampedZoom(zoom * pinch)

            TimelineView(.animation(paused: !isSettling)) { timeline in
                // Step the sim on the timeline's date change — outside the Canvas draw
                // closure, so we never mutate state during rendering. While unpaused the
                // `.animation` schedule re-runs this closure each display frame; each run
                // advances one step and the Canvas below repaints the new positions.
                Canvas { context, size in
                    draw(in: &context, size: size, center: center, zoom: effectiveZoom)
                }
                .task(id: timeline.date) { advance(at: timeline.date) }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(center: center, zoom: effectiveZoom))
            .gesture(magnifyGesture())
            .onTapGesture { location in
                handleTap(at: location, center: center, zoom: effectiveZoom)
            }
        }
        .onChange(of: graph.nodeSignature) { _, _ in reheat() }
        // A Forces slider changed: push the new constants into the live sim and
        // re-heat so the layout eases toward the new equilibrium. `Parameters` is
        // Equatable-by-fields via this signature (a struct of Doubles), so this only
        // fires on an actual value change, not every re-render.
        .onChange(of: parameters.forceSignature) { _, _ in
            layout.updateParameters(parameters)
            isSettling = true
        }
        .onAppear { isSettling = true }
        .onDisappear { isSettling = false }
    }

    // MARK: Simulation clock

    /// The last timeline date we stepped on — guards against stepping twice for one
    /// frame (SwiftUI may evaluate the timeline body more than once per tick).
    @State private var lastStepDate: Date = .distantPast

    /// Advance the sim one step for a new timeline `date`. A no-op once settled or if
    /// this date was already processed. The `.animation` timeline re-renders every
    /// frame while unpaused, so stepping here and repainting the Canvas is enough — no
    /// extra tick counter needed.
    private func advance(at date: Date) {
        guard isSettling, date != lastStepDate else { return }
        lastStepDate = date
        // Keep stepping the whole time the graph is on screen — the sim never "finishes"
        // (Obsidian-style live layout), so a grab always responds and it stays alive
        // instead of freezing shortly after opening. At equilibrium the bounded forces +
        // damping mean it barely moves, so the per-frame cost is negligible; `.onDisappear`
        // pauses the clock when you leave the page.
        _ = layout.step()
    }

    /// Re-heat the sim (resume stepping) — after a drag, or when the graph changes.
    private func reheat() {
        // Rebuild the layout if the node set changed; otherwise just resume stepping.
        if layout.nodeCount != graph.nodes.count {
            var fresh = ForceDirectedLayout(nodes: graph.nodes, edges: graph.edges)
            fresh.settle(steps: Self.warmupSteps)
            layout = fresh
        }
        isSettling = true
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize,
                      center: CGPoint, zoom: CGFloat) {
        let positions = layout.positions
        guard positions.count == graph.nodes.count else { return }
        let indexByID = graph.indexByID

        // Selection focus (Obsidian-style): when a node is selected, its NEIGHBOURHOOD —
        // itself + directly-linked nodes and the edges between them — stays bright while
        // everything else dims, so you can see exactly how one term/person/project is
        // interlinked. Nothing selected → the whole graph draws, with orphan (link-less)
        // nodes faded so the connected core reads.
        let selectedIndex: Int? = selectedID.flatMap { indexByID[$0] }
        let hasSelection = selectedIndex != nil
        var focusSet = Set<Int>()
        if let si = selectedIndex {
            focusSet.insert(si)
            for edge in graph.edges {
                guard let ai = indexByID[edge.a], let bi = indexByID[edge.b] else { continue }
                if ai == si { focusSet.insert(bi) }
                if bi == si { focusSet.insert(ai) }
            }
        }

        // Edges first.
        var maxWeight = 1
        for e in graph.edges { maxWeight = max(maxWeight, e.weight) }
        for edge in graph.edges {
            guard let ai = indexByID[edge.a], let bi = indexByID[edge.b] else { continue }
            let p1 = worldToScreen(positions[ai], center: center, zoom: zoom)
            let p2 = worldToScreen(positions[bi], center: center, zoom: zoom)
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            let strength = Double(edge.weight) / Double(maxWeight)
            let touchesSelection = hasSelection && (ai == selectedIndex || bi == selectedIndex)
            let color: Color
            let opacity: Double
            let width: CGFloat
            if hasSelection {
                // Selected node's edges glow coral; every other edge nearly vanishes.
                color = touchesSelection ? Theme.coral : Theme.inkTertiary
                opacity = touchesSelection ? 0.85 : 0.04
                width = touchesSelection
                    ? (1.2 + 1.6 * strength) * min(1.6, max(0.6, zoom)) * linkThicknessMultiplier
                    : 0.6 * linkThicknessMultiplier
            } else {
                // At rest: more visible than before so the interconnectivity reads.
                color = Theme.inkTertiary
                opacity = 0.15 + 0.18 * strength // ~0.15–0.33
                width = (0.7 + 1.5 * strength) * min(1.5, max(0.5, zoom)) * linkThicknessMultiplier
            }
            context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: width)
        }

        // Nodes on top.
        for (i, node) in graph.nodes.enumerated() {
            let p = worldToScreen(positions[i], center: center, zoom: zoom)
            let r = nodeRadius(node) * zoom
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let base = GraphStyle.color(for: node.kind)
            let isSelected = node.id == selectedID
            let nodeOpacity: Double = hasSelection
                ? (focusSet.contains(i) ? 1.0 : 0.16)          // dim non-neighbourhood
                : (node.degree == 0 ? 0.42 : 1.0)              // fade orphans at rest

            context.fill(Circle().path(in: rect), with: .color(base.opacity(nodeOpacity)))
            // Subtle outline; the selected node gets a brighter ring.
            context.stroke(Circle().path(in: rect),
                           with: .color(isSelected ? Theme.ink : .black.opacity(0.25 * nodeOpacity)),
                           lineWidth: isSelected ? 2 : 0.75)

            // Label the selected node + its neighbours always; otherwise the hubs (the
            // controls panel's live text-fade threshold). Non-focus labels fade with the
            // selection so the neighbourhood's names stand out.
            let showLabel = isSelected
                || (hasSelection && focusSet.contains(i))
                || (!hasSelection && (node.degree >= labelThreshold || node.mentions >= labelThreshold))
            if showLabel {
                let dimLabel = hasSelection && !focusSet.contains(i)
                let text = Text(node.displayName)
                    .font(.system(size: max(9, min(13, 8 + r * 0.35)), weight: isSelected ? .semibold : .medium))
                    .foregroundStyle((isSelected ? Theme.ink : Theme.inkSecondary).opacity(dimLabel ? 0.3 : 1))
                context.draw(text, at: CGPoint(x: p.x, y: p.y + r + 8), anchor: .top)
            }
        }
    }

    /// Node radius from mentions + degree, ~4–16 pt in world units (before zoom),
    /// scaled by the controls panel's live node-size multiplier.
    private func nodeRadius(_ node: KnowledgeGraphModel.Node) -> CGFloat {
        // Smaller dots (Jann's taste + so the links between nodes read): most nodes sit
        // ~2–4 pt, hubs grow to ~10, scaled by the controls' live node-size multiplier.
        let base = 2.2 + 1.0 * (Double(node.mentions).squareRoot()) + 0.5 * Double(node.degree).squareRoot()
        return CGFloat(min(10, max(2.2, base))) * nodeSizeMultiplier
    }

    // MARK: Coordinate transforms

    private func worldToScreen(_ p: CGPoint, center: CGPoint, zoom: CGFloat) -> CGPoint {
        CGPoint(x: center.x + pan.width + p.x * zoom,
                y: center.y + pan.height + p.y * zoom)
    }

    private func screenToWorld(_ p: CGPoint, center: CGPoint, zoom: CGFloat) -> CGPoint {
        CGPoint(x: (p.x - center.x - pan.width) / zoom,
                y: (p.y - center.y - pan.height) / zoom)
    }

    private func clampedZoom(_ z: CGFloat) -> CGFloat {
        min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, z))
    }

    // MARK: Gestures

    /// Drag: on an empty spot pans the whole graph; grabbing a node moves that node
    /// (pinned while dragging, so the sim doesn't fight the pointer) and re-heats the
    /// sim so neighbours settle around it.
    private func dragGesture(center: CGPoint, zoom: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                // Decide the mode ONCE, on the first change of this gesture: if the
                // press started on a node, drag that node; otherwise pan the canvas.
                // `dragDecided` gates this so the choice can't flip mid-drag.
                if !dragDecided {
                    dragDecided = true
                    if let hit = nearestNode(to: value.startLocation, center: center, zoom: zoom) {
                        draggingNode = hit
                        layout.setPinned(hit)
                        isSettling = true
                    }
                }
                if let node = draggingNode {
                    let world = screenToWorld(value.location, center: center, zoom: zoom)
                    layout.setPosition(world, at: node)
                } else {
                    pan = CGSize(width: lastPan.width + value.translation.width,
                                 height: lastPan.height + value.translation.height)
                }
            }
            .onEnded { value in
                if let node = draggingNode {
                    let world = screenToWorld(value.location, center: center, zoom: zoom)
                    layout.setPosition(world, at: node)
                    layout.setPinned(nil)
                    draggingNode = nil
                    isSettling = true // brief re-heat so the graph re-relaxes.
                } else {
                    lastPan = pan
                }
                dragDecided = false
            }
    }

    private func magnifyGesture() -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                zoom = clampedZoom(zoom * value.magnification)
            }
    }

    // MARK: Hit-testing

    private func handleTap(at location: CGPoint, center: CGPoint, zoom: CGFloat) {
        if let hit = nearestNode(to: location, center: center, zoom: zoom) {
            selectedID = graph.nodes[hit].id
        } else {
            selectedID = nil
        }
    }

    /// The index of the node whose drawn circle is nearest the point, within a
    /// zoom-aware grab radius (node radius + a small slop), or nil if none is close.
    private func nearestNode(to point: CGPoint, center: CGPoint, zoom: CGFloat) -> Int? {
        let positions = layout.positions
        guard positions.count == graph.nodes.count else { return nil }
        var best: Int?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, node) in graph.nodes.enumerated() {
            let p = worldToScreen(positions[i], center: center, zoom: zoom)
            let dx = p.x - point.x, dy = p.y - point.y
            let dist = (dx * dx + dy * dy).squareRoot()
            let grab = nodeRadius(node) * zoom + 8
            if dist <= grab, dist < bestDist { best = i; bestDist = dist }
        }
        return best
    }
}

// MARK: - Graph identity helpers

private extension KnowledgeGraphModel.KnowledgeGraph {
    /// A cheap identity signature so the view only rebuilds/re-heats the layout when
    /// the node set actually changes (not on every unrelated re-render). Node count +
    /// edge count is enough — a changed mention count re-heats via the same path.
    var nodeSignature: String { "\(nodes.count)-\(edges.count)" }

    /// Index-by-id map for edge drawing, built once per draw pass.
    var indexByID: [EntityID: Int] {
        Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
    }
}
