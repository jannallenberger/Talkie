import XCTest
@testable import Talkie

/// WS-M — the pure knowledge-graph derivation and the force-layout stepper. Both
/// are deliberately UI-free and deterministic, so these exercise them without any
/// SwiftUI, disk, or clock:
///   • `KnowledgeGraphModel.build` — commitment exclusion, co-occurrence edges via
///     shared provenance `sourceID`, unordered-pair dedup + weight accumulation,
///     self-loop impossibility, degree, and the top-by-mentions cap.
///   • `ForceDirectedLayout` — deterministic seeding + a settling sanity check.
final class KnowledgeGraphModelTests: XCTestCase {
    private let now = 1_000_000_000.0

    private func prov(_ id: String?, at date: Double? = nil) -> Provenance {
        Provenance(source: .dictation, sourceID: id, dateUnix: date ?? now, snippet: nil)
    }

    private func entity(_ name: String, kind: EntityKind, mentions: Int,
                        sources: [String?], lastSeen: Double? = nil) -> Entity {
        let provs = sources.map { prov($0) }
        return Entity(id: EntityID(kind: kind, key: name.lowercased()),
                      displayName: name, aliases: [], mentions: mentions, pinned: false,
                      firstSeenUnix: now, lastSeenUnix: lastSeen ?? now, provenance: provs)
    }

    // MARK: build — node selection

    /// Commitments are action items, not things — they must never become nodes.
    func testCommitmentsExcludedFromNodes() {
        let entities = [
            entity("Alice", kind: .person, mentions: 3, sources: ["m1"]),
            entity("Ship the beta", kind: .commitment, mentions: 2, sources: ["m1"]),
            entity("Roadmap", kind: .project, mentions: 1, sources: ["m1"]),
        ]
        let graph = KnowledgeGraphModel.build(from: entities)
        XCTAssertEqual(graph.nodes.count, 2, "only the person and project become nodes")
        XCTAssertFalse(graph.nodes.contains { $0.kind == .commitment })
        XCTAssertEqual(graph.totalEligible, 2, "the commitment isn't counted as eligible either")
    }

    func testEmptyInputYieldsEmptyGraph() {
        XCTAssertTrue(KnowledgeGraphModel.build(from: []).isEmpty)
        // A graph of only commitments is also empty (none are eligible).
        let onlyCommitments = [entity("Do X", kind: .commitment, mentions: 1, sources: ["s"])]
        XCTAssertTrue(KnowledgeGraphModel.build(from: onlyCommitments).isEmpty)
    }

    // MARK: build — co-occurrence edges

    /// Two entities sharing one source get exactly one weight-1 edge; a third entity
    /// from an unrelated source is an isolated node.
    func testSharedSourceCreatesSingleEdge() {
        let entities = [
            entity("Alice", kind: .person, mentions: 2, sources: ["m1"]),
            entity("Bob", kind: .person, mentions: 2, sources: ["m1"]),
            entity("Lonely", kind: .term, mentions: 1, sources: ["m2"]),
        ]
        let graph = KnowledgeGraphModel.build(from: entities)
        XCTAssertEqual(graph.edges.count, 1, "one shared source → one edge")
        XCTAssertEqual(graph.edges.first?.weight, 1)
        // Degrees: Alice & Bob 1 each, Lonely 0.
        let lonely = graph.nodes.first { $0.displayName == "Lonely" }
        XCTAssertEqual(lonely?.degree, 0, "an entity whose source touched only it has no edges")
    }

    /// Sharing multiple sources accumulates weight on the SAME (deduped) edge — one
    /// undirected edge, weight = number of shared sources.
    func testMultipleSharedSourcesAccumulateWeightOnOneEdge() {
        let entities = [
            entity("Alice", kind: .person, mentions: 3, sources: ["m1", "m2", "m3"]),
            entity("Bob", kind: .person, mentions: 3, sources: ["m1", "m2"]),
        ]
        let graph = KnowledgeGraphModel.build(from: entities)
        XCTAssertEqual(graph.edges.count, 1, "still one undirected edge, not two directed ones")
        XCTAssertEqual(graph.edges.first?.weight, 2, "they share m1 and m2 → weight 2")
    }

    /// A source that mentions three entities fully connects them: 3 pairwise edges,
    /// each degree 2. Confirms clique expansion + no self-loops.
    func testThreeWayCoOccurrenceIsAClique() {
        let entities = [
            entity("A", kind: .term, mentions: 1, sources: ["s"]),
            entity("B", kind: .term, mentions: 1, sources: ["s"]),
            entity("C", kind: .term, mentions: 1, sources: ["s"]),
        ]
        let graph = KnowledgeGraphModel.build(from: entities)
        XCTAssertEqual(graph.edges.count, 3, "3 nodes fully connected = 3 edges")
        XCTAssertTrue(graph.nodes.allSatisfy { $0.degree == 2 })
        // No self-loops: every edge connects two DISTINCT ids.
        XCTAssertTrue(graph.edges.allSatisfy { $0.a != $0.b })
    }

    /// Provenance with a nil `sourceID` (e.g. a bare dictionary pin) carries no join,
    /// so it must never link entities — otherwise every un-sourced term would fuse.
    func testNilSourceIDDoesNotConnect() {
        let entities = [
            entity("Pinned1", kind: .term, mentions: 1, sources: [nil]),
            entity("Pinned2", kind: .term, mentions: 1, sources: [nil]),
        ]
        let graph = KnowledgeGraphModel.build(from: entities)
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertTrue(graph.edges.isEmpty, "nil sourceIDs are not a shared join key")
    }

    // MARK: build — the cap

    /// The top-N cap keeps the most-mentioned entities and flags that it trimmed.
    func testCapKeepsTopByMentionsAndFlags() {
        let entities = (0..<10).map { i in
            entity("E\(i)", kind: .term, mentions: i, sources: ["s\(i)"])
        }
        let graph = KnowledgeGraphModel.build(from: entities, cap: 3)
        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertTrue(graph.wasCapped)
        XCTAssertEqual(graph.totalEligible, 10)
        // The three kept are the highest mention counts (9, 8, 7).
        let kept = Set(graph.nodes.map(\.displayName))
        XCTAssertEqual(kept, ["E9", "E8", "E7"])
    }

    /// Edges are only built among KEPT nodes: an edge to a capped-out entity is dropped.
    func testCapDropsEdgesToRemovedNodes() {
        let entities = [
            entity("Hub", kind: .person, mentions: 100, sources: ["s"]),
            entity("Keep", kind: .person, mentions: 50, sources: ["s"]),
            entity("Drop", kind: .person, mentions: 1, sources: ["s"]),
        ]
        // Cap to 2 → Drop is removed; the Hub–Drop and Keep–Drop edges must vanish,
        // leaving only Hub–Keep.
        let graph = KnowledgeGraphModel.build(from: entities, cap: 2)
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(graph.edges.count, 1, "only the edge between the two kept nodes survives")
    }

    // MARK: ForceDirectedLayout

    /// Seeding is deterministic (no random / clock): two layouts of the same graph
    /// start at identical positions.
    func testLayoutSeedingIsDeterministic() {
        let nodes = (0..<12).map {
            KnowledgeGraphModel.Node(id: EntityID(kind: .term, key: "n\($0)"),
                                     displayName: "n\($0)", kind: .term, mentions: 1, degree: 0)
        }
        let a = ForceDirectedLayout(nodes: nodes, edges: [])
        let b = ForceDirectedLayout(nodes: nodes, edges: [])
        XCTAssertEqual(a.positions, b.positions, "index-seeded positions are reproducible")
        // And they aren't all stacked at the origin.
        XCTAssertTrue(a.positions.contains { $0 != .zero })
    }

    /// The sim settles: repeated steps drive the per-node kinetic energy down toward
    /// the settle threshold, and two identical runs converge to identical positions.
    func testLayoutSettlesAndIsReproducible() {
        let nodes = (0..<20).map {
            KnowledgeGraphModel.Node(id: EntityID(kind: .term, key: "n\($0)"),
                                     displayName: "n\($0)", kind: .term, mentions: 1, degree: 0)
        }
        // A ring of edges so springs have something to relax.
        let edges = (0..<20).map { i in
            KnowledgeGraphModel.Edge(a: nodes[i].id, b: nodes[(i + 1) % 20].id, weight: 1)
        }
        var sim = ForceDirectedLayout(nodes: nodes, edges: edges)
        let early = sim.step()
        let settled = sim.settle(steps: 400)
        XCTAssertLessThan(settled, early, "energy decreases as the layout relaxes")
        XCTAssertTrue(settled.isFinite, "positions never blow up to NaN/inf")

        var sim2 = ForceDirectedLayout(nodes: nodes, edges: edges)
        sim2.step(); sim2.settle(steps: 400)
        XCTAssertEqual(sim.positions, sim2.positions, "the whole run is deterministic")
    }
}
