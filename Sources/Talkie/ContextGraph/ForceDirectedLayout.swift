import CoreGraphics
import Foundation

/// A tiny, dependency-free **force-directed layout** for the knowledge graph — a
/// classic spring/charge simulation with a `step()` API so it can be driven by a
/// timer from the view and exercised deterministically from a test.
///
/// Three forces, integrated with velocity + damping each `step()`:
///   • **Charge** — every pair of nodes repels (Coulomb-like, `1/d²`), so nodes
///     spread out instead of piling up. O(n²), which is fine at the ≤250-node cap.
///   • **Spring** — each edge pulls its two endpoints toward a rest length (Hooke),
///     so connected nodes cluster. Heavier edges (more shared sources) pull harder.
///   • **Gravity** — a gentle pull toward the origin so disconnected components and
///     lone nodes don't drift off to infinity.
///
/// Positions are seeded **deterministically on a circle by index** (never random,
/// never clock-seeded), so the same graph always lays out the same way and the sim
/// is reproducible in tests. The engine works in an origin-centred abstract space;
/// the view maps that to screen coordinates with its own pan/zoom transform.
struct ForceDirectedLayout {

    /// Tunable constants. Defaults chosen to settle a few-hundred-node graph into a
    /// readable spread within a couple of seconds at ~60 steps/sec.
    struct Parameters {
        /// Repulsion strength between every pair of nodes. Tuned HIGH so the graph
        /// SPREADS (like Obsidian) — nodes separate instead of piling into an overlapping
        /// blob, so the edges/clusters between people, projects, and terms are visible.
        var charge: Double = 13_000
        /// Spring stiffness along edges.
        var stiffness: Double = 0.02
        /// Rest length a spring pulls toward — the natural gap between two linked nodes.
        var restLength: Double = 115
        /// Pull toward the centre (per unit distance).
        var gravity: Double = 0.015
        /// Velocity retained each step (0…1). Lower = settles faster / stiffer.
        var damping: Double = 0.85
        /// Floor on pairwise distance so the spring math can't divide by zero.
        var minDistance: Double = 0.5
        /// Softening added to the charge denominator (`charge/(d²+soft²)`) so repulsion
        /// is BOUNDED — two near-coincident nodes can never generate a screen-flinging
        /// force the way the old `1/d²`-with-a-tiny-floor did. Also acts as a node's
        /// effective "personal space" radius.
        var chargeSoftening: Double = 34
        /// Hard cap on a node's per-step speed, so no single frame can jump a node clear
        /// across the canvas (the other half of keeping the sim from exploding).
        var maxSpeed: Double = 22
        /// Extra centring pull per unit of node degree — high-degree HUBS are drawn
        /// toward the middle so the layout reads as a hierarchy (hubs central, leaves
        /// radiating out) instead of a uniform cloud.
        var hubGravity: Double = 0.03
        /// Radius of the seeding circle.
        var seedRadius: Double = 240
        /// Below this total kinetic energy the sim is considered settled.
        var settleEnergy: Double = 0.4

        static let `default` = Parameters()

        /// A cheap value signature over just the user-tunable force fields, so a
        /// SwiftUI `.onChange` can re-heat the sim on an actual slider change without
        /// needing `Parameters` to be `Equatable` wholesale.
        var forceSignature: String {
            "\(charge)|\(stiffness)|\(restLength)|\(gravity)|\(chargeSoftening)|\(maxSpeed)|\(hubGravity)|\(damping)"
        }
    }

    private(set) var positions: [CGPoint]
    private var velocities: [CGVector]
    /// Endpoint index pairs + weights, resolved once from `EntityID` edges at init so
    /// the hot `step()` loop works on plain `Int` indices.
    private let springs: [(a: Int, b: Int, weight: Double)]
    /// The live force constants. `var` (not `let`) so the controls panel can retune
    /// them mid-flight via `updateParameters(_:)` — the running positions are kept and
    /// the caller re-heats the sim, so the layout eases into the new shape rather than
    /// resetting.
    private(set) var params: Parameters
    /// Nodes pinned by the user (a dragged node) are held in place — the sim still
    /// reads their position for forces on others, but never moves them itself.
    private var pinned: Set<Int>
    /// Per-node degree (resolved edge count), for degree-weighted centring (hierarchy).
    private let degrees: [Double]

    let nodeCount: Int

    /// Build a layout for `nodes` connected by `edges`. Positions are seeded on a
    /// circle by node index (golden-angle spacing so even a large ring spreads
    /// evenly), fully deterministic — no `Date`, no `random`.
    init(nodes: [KnowledgeGraphModel.Node], edges: [KnowledgeGraphModel.Edge],
         parameters: Parameters = .default) {
        self.params = parameters
        self.nodeCount = nodes.count
        self.pinned = []

        // Deterministic seed: golden-angle spiral on a circle, indexed by node order.
        // The +1 offset and sqrt spread keep the very first nodes off the exact centre.
        let golden = Double.pi * (3 - (5.0).squareRoot()) // ~2.399963 rad
        var pos: [CGPoint] = []
        pos.reserveCapacity(nodes.count)
        for i in 0..<nodes.count {
            let angle = Double(i) * golden
            let radius = parameters.seedRadius * ((Double(i) + 0.5) / Double(max(1, nodes.count))).squareRoot()
            pos.append(CGPoint(x: radius * cos(angle), y: radius * sin(angle)))
        }
        self.positions = pos
        self.velocities = Array(repeating: .zero, count: nodes.count)

        // Resolve EntityID edges → index pairs once.
        let indexByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        let resolvedSprings = edges.compactMap { (edge) -> (a: Int, b: Int, weight: Double)? in
            guard let a = indexByID[edge.a], let b = indexByID[edge.b], a != b else { return nil }
            return (a, b, Double(max(1, edge.weight)))
        }
        self.springs = resolvedSprings
        // Degree per node from the resolved springs — drives hub-weighted centring.
        var deg = Array(repeating: 0.0, count: nodes.count)
        for s in resolvedSprings { deg[s.a] += 1; deg[s.b] += 1 }
        self.degrees = deg
    }

    /// Retune the force constants without disturbing the current positions/velocities
    /// — used by the controls panel so dragging a Forces slider reshapes the *running*
    /// layout (the caller re-heats the sim so it eases toward the new equilibrium)
    /// instead of snapping back to the seed ring. Only the tunable force fields are
    /// swapped; the structural seed radius is left as-built.
    mutating func updateParameters(_ new: Parameters) {
        params.charge = new.charge
        params.stiffness = new.stiffness
        params.restLength = new.restLength
        params.gravity = new.gravity
        params.chargeSoftening = new.chargeSoftening
        params.maxSpeed = new.maxSpeed
        params.hubGravity = new.hubGravity
        params.damping = new.damping
    }

    /// Pin a node (while the user drags it): the sim reads its position but never
    /// integrates forces onto it. Passing `nil` clears all pins.
    mutating func setPinned(_ index: Int?) {
        if let index, index >= 0, index < nodeCount { pinned = [index] }
        else if index == nil { pinned.removeAll() }
    }

    /// Directly place a node (a drag sets the grabbed node's position each frame) and
    /// zero its velocity so it doesn't fling when released.
    mutating func setPosition(_ point: CGPoint, at index: Int) {
        guard index >= 0, index < nodeCount else { return }
        positions[index] = point
        velocities[index] = .zero
    }

    /// Advance the simulation one tick. Returns the total kinetic energy after the
    /// step — the caller stops the timer once this drops below `params.settleEnergy`
    /// (and re-heats by simply resuming `step()` calls, e.g. after a drag).
    @discardableResult
    mutating func step() -> Double {
        guard nodeCount > 1 else { return 0 }
        let n = nodeCount
        var forces = Array(repeating: CGVector.zero, count: n)

        // Charge: every unordered pair repels. Symmetric, so compute once per pair.
        for i in 0..<n {
            let pi = positions[i]
            for j in (i + 1)..<n {
                let pj = positions[j]
                var dx = Double(pi.x - pj.x)
                var dy = Double(pi.y - pj.y)
                var distSq = dx * dx + dy * dy
                if distSq < params.minDistance * params.minDistance {
                    // Nudge coincident nodes apart deterministically (by index parity)
                    // rather than by randomness, so the sim stays reproducible.
                    dx = params.minDistance * (i % 2 == 0 ? 1 : -1)
                    dy = params.minDistance * (j % 2 == 0 ? 1 : -1)
                    distSq = dx * dx + dy * dy
                }
                let dist = distSq.squareRoot()
                // Softened Coulomb: BOUNDED repulsion (max ≈ charge/soft²) so close nodes
                // firmly push apart without ever flinging across the screen.
                let soft = params.chargeSoftening
                let repulse = params.charge / (distSq + soft * soft)
                let ux = dx / dist, uy = dy / dist
                forces[i].dx += ux * repulse
                forces[i].dy += uy * repulse
                forces[j].dx -= ux * repulse
                forces[j].dy -= uy * repulse
            }
        }

        // Spring: each edge pulls its endpoints toward the rest length.
        for spring in springs {
            let pa = positions[spring.a], pb = positions[spring.b]
            let dx = Double(pb.x - pa.x)
            let dy = Double(pb.y - pa.y)
            let dist = max(params.minDistance, (dx * dx + dy * dy).squareRoot())
            let displacement = dist - params.restLength
            let force = params.stiffness * spring.weight * displacement
            let ux = dx / dist, uy = dy / dist
            forces[spring.a].dx += ux * force
            forces[spring.a].dy += uy * force
            forces[spring.b].dx -= ux * force
            forces[spring.b].dy -= uy * force
        }

        // Gravity toward the origin, then integrate (velocity + damping).
        var energy = 0.0
        for i in 0..<n {
            if pinned.contains(i) { velocities[i] = .zero; continue }
            // Degree-weighted centring: hubs feel more gravity → they settle central and
            // leaves radiate out, so the graph reads as a hierarchy, not a flat cloud.
            let g = params.gravity + params.hubGravity * degrees[i]
            forces[i].dx -= Double(positions[i].x) * g
            forces[i].dy -= Double(positions[i].y) * g

            var v = velocities[i]
            v.dx = (v.dx + forces[i].dx) * params.damping
            v.dy = (v.dy + forces[i].dy) * params.damping
            // Speed clamp: no single step may fling a node across the canvas.
            let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
            if speed > params.maxSpeed {
                let scale = params.maxSpeed / speed
                v.dx *= scale; v.dy *= scale
            }
            velocities[i] = v
            positions[i].x += CGFloat(v.dx)
            positions[i].y += CGFloat(v.dy)
            energy += v.dx * v.dx + v.dy * v.dy
        }
        return energy / Double(n)
    }

    /// Run `count` steps (used by tests and by an initial warm-up). Returns the final
    /// per-node kinetic energy.
    @discardableResult
    mutating func settle(steps count: Int) -> Double {
        var energy = 0.0
        for _ in 0..<max(0, count) { energy = step() }
        return energy
    }

    /// The axis-aligned bounding box of all current positions (for fit-to-view). Nil
    /// when empty.
    var bounds: CGRect? {
        guard let first = positions.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in positions {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
