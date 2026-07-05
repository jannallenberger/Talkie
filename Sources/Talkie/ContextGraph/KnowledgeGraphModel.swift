import Foundation

/// Pure, UI-free derivation of a **knowledge graph** from context-graph entities —
/// the nodes-and-edges the interactive `KnowledgeGraphView` draws (WS-M). Kept
/// deliberately free of SwiftUI, `@MainActor`, disk, and any clock so it can be
/// unit-tested in isolation: give it `[Entity]`, get back a `KnowledgeGraph`.
///
/// **Nodes** are the people, projects, and terms the user talks about (commitments
/// are action items, not things, so they are excluded). **Edges are co-occurrence**:
/// two entities are connected when they share a provenance `sourceID` — i.e. the
/// same dictation or meeting mentioned both — and the edge's weight is the number of
/// sources they share. This is the same `Provenance.sourceID` join key that powers
/// true-delete, reused here as the graph's connective tissue.
enum KnowledgeGraphModel {

    /// Performance cap: the O(n²) charge step in the layout and the O(sources · pairs)
    /// edge build both stay comfortable at a few hundred nodes, and a graph denser than
    /// this reads as hairball rather than insight. We keep the top `nodeCap` entities by
    /// `mentions` (the most-talked-about) and note when the graph was capped.
    static let nodeCap = 250

    /// One node: an entity reduced to just what the view needs to place and paint it.
    /// `id` is the entity's stable `EntityID`, so a tap can re-fetch the full `Entity`
    /// (with provenance) from the live store for the inspector.
    struct Node: Identifiable, Hashable, Sendable {
        let id: EntityID
        let displayName: String
        let kind: EntityKind
        let mentions: Int
        /// How many distinct other nodes this one is connected to. Drives node radius
        /// alongside `mentions`, so a well-connected hub reads larger.
        let degree: Int
    }

    /// One undirected edge between two nodes, referenced by their `EntityID`. `a` and
    /// `b` are stored in a stable order (see `Edge.ordered`) so an unordered pair is
    /// deduped to a single edge. `weight` is the count of shared provenance sources.
    struct Edge: Hashable, Sendable {
        let a: EntityID
        let b: EntityID
        let weight: Int

        /// A canonical, order-independent key for the pair `{x, y}` so `{x, y}` and
        /// `{y, x}` collapse to one edge. `EntityID` isn't `Comparable`, so we order by
        /// its `(kind, key)` string form — deterministic and dependency-free.
        static func orderedPair(_ x: EntityID, _ y: EntityID) -> (EntityID, EntityID) {
            sortKey(x) <= sortKey(y) ? (x, y) : (y, x)
        }

        private static func sortKey(_ id: EntityID) -> String { "\(id.kind.rawValue)\u{1}\(id.key)" }
    }

    /// The derived graph: nodes + edges, plus whether the source set was capped (so the
    /// view can honestly note "showing the top N of M").
    struct KnowledgeGraph: Sendable {
        let nodes: [Node]
        let edges: [Edge]
        /// The full entity count before the `nodeCap` was applied (== `nodes.count` when
        /// nothing was dropped). Lets the UI say "top 250 of 1,240".
        let totalEligible: Int

        var wasCapped: Bool { totalEligible > nodes.count }
        var isEmpty: Bool { nodes.isEmpty }

        static let empty = KnowledgeGraph(nodes: [], edges: [], totalEligible: 0)
    }

    /// Derive the knowledge graph from a set of entities.
    ///
    /// 1. Keep only `.person` / `.project` / `.term` (drop `.commitment`).
    /// 2. Cap to the top `cap` by `mentions` (ties broken by `lastSeenUnix`, newest
    ///    first) so the busiest graph still lays out fast and reads clearly.
    /// 3. Group the kept entities by each shared provenance `sourceID`; for every source
    ///    that touched ≥2 kept entities, connect each co-occurring pair. Accumulate a
    ///    pair's weight across all the sources it shares. Self-loops are impossible (a
    ///    pair is two distinct entities), and unordered pairs are deduped via
    ///    `Edge.orderedPair`.
    /// 4. Compute each node's `degree` from the final edge set.
    ///
    /// Deterministic: no randomness, no clock — the same input always yields the same
    /// graph, including node order (the mention-sorted order the cap produced).
    static func build(from entities: [Entity], cap: Int = nodeCap) -> KnowledgeGraph {
        // 1. Things, not action items.
        let eligible = entities.filter { $0.kind != .commitment }
        guard !eligible.isEmpty else { return .empty }

        // 2. Top-by-mentions cap (deterministic tie-break on recency, then key).
        let ranked = eligible.sorted { lhs, rhs in
            if lhs.mentions != rhs.mentions { return lhs.mentions > rhs.mentions }
            if lhs.lastSeenUnix != rhs.lastSeenUnix { return lhs.lastSeenUnix > rhs.lastSeenUnix }
            return lhs.id.key < rhs.id.key
        }
        let kept = Array(ranked.prefix(max(0, cap)))
        let keptIDs = Set(kept.map(\.id))

        // 3. Co-occurrence edges. Bucket kept entities by each shared provenance
        //    sourceID; a source that names ≥2 of them links every pair among them.
        //    `sourceID == nil` provenance (e.g. a bare dictionary pin) carries no
        //    join, so it never links anything — grouping on it would wrongly fuse
        //    every un-sourced term into one clique.
        var membersBySource: [String: Set<EntityID>] = [:]
        for entity in kept {
            for prov in entity.provenance {
                guard let sourceID = prov.sourceID else { continue }
                membersBySource[sourceID, default: []].insert(entity.id)
            }
        }

        var weightByPair: [PairKey: Int] = [:]
        for members in membersBySource.values where members.count >= 2 {
            let ids = Array(members)
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let (a, b) = Edge.orderedPair(ids[i], ids[j])
                    weightByPair[PairKey(a: a, b: b), default: 0] += 1
                }
            }
        }

        // 4. Materialize edges and per-node degree.
        var degree: [EntityID: Int] = [:]
        var edges: [Edge] = []
        edges.reserveCapacity(weightByPair.count)
        for (pair, weight) in weightByPair {
            edges.append(Edge(a: pair.a, b: pair.b, weight: weight))
            degree[pair.a, default: 0] += 1
            degree[pair.b, default: 0] += 1
        }

        let nodes = kept.map { entity in
            Node(id: entity.id, displayName: entity.displayName, kind: entity.kind,
                 mentions: entity.mentions, degree: degree[entity.id] ?? 0)
        }

        // Guard: every edge endpoint is a kept node (defensive — membership was built
        // only from kept entities, so this always holds, but keeps the invariant local).
        let cleanEdges = edges.filter { keptIDs.contains($0.a) && keptIDs.contains($0.b) }

        return KnowledgeGraph(nodes: nodes, edges: cleanEdges, totalEligible: eligible.count)
    }

    /// Hashable key for an ordered `EntityID` pair, so `weightByPair` dedupes unordered
    /// pairs to one entry. (A tuple can't be a `Dictionary` key.)
    private struct PairKey: Hashable {
        let a: EntityID
        let b: EntityID
    }
}
