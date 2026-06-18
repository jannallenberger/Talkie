import XCTest
@testable import Talkie

/// Hardening tests for the context graph: idempotent backfill (provenance dedupe +
/// watermark), earliest-wins `firstSeenUnix`, capacity eviction, staleness pruning,
/// and the stable commitment key. The non-trivial decisions live in the pure,
/// actor-free `ContextGraphPolicy`, so most of this needs no disk, clock, or actor;
/// the two store-level tests exercise the real `@MainActor` fold and assert only on
/// unique, test-owned entities so they are deterministic regardless of any existing
/// on-disk graph.
final class ContextGraphHardeningTests: XCTestCase {
    private let now = 1_000_000_000.0
    private let day = 86_400.0
    /// Far enough in the future to sit above any real on-disk backfill watermark, so
    /// the store-level tests ingest deterministically regardless of existing data.
    private let future = 5_000_000_000.0 // ~year 2128

    private func prov(_ source: ProvenanceSource, _ id: String?, _ date: Double) -> Provenance {
        Provenance(source: source, sourceID: id, dateUnix: date, snippet: nil)
    }

    private func entity(_ name: String, kind: EntityKind = .term, mentions: Int = 1,
                        pinned: Bool = false, first: Double, last: Double) -> Entity {
        Entity(id: EntityID(kind: kind, key: ContextGraphPolicy.key(kind, name)),
               displayName: name, aliases: [], mentions: mentions, pinned: pinned,
               firstSeenUnix: first, lastSeenUnix: last,
               provenance: [prov(.dictation, name, last)])
    }

    // MARK: P1-11 — provenance dedupe (the core of idempotent re-ingest)

    /// The same (source, sourceID) is not a new mention; a different sourceID, a
    /// different source, and a distinct nil-id source all are.
    func testIsNewProvenanceDedupesBySourceAndID() {
        let existing = [prov(.dictation, "A", now)]
        XCTAssertFalse(ContextGraphPolicy.isNewProvenance(prov(.dictation, "A", now + 5), in: existing),
                       "same (source, sourceID) must not count again, even at a later time")
        XCTAssertTrue(ContextGraphPolicy.isNewProvenance(prov(.dictation, "B", now), in: existing))
        XCTAssertTrue(ContextGraphPolicy.isNewProvenance(prov(.meeting, "A", now), in: existing))
    }

    /// A nil sourceID (e.g. a dictionary pin) dedupes against another nil of the same
    /// source — re-pinning the same term is idempotent.
    func testIsNewProvenanceHandlesNilSourceID() {
        let existing = [prov(.dictionary, nil, now)]
        XCTAssertFalse(ContextGraphPolicy.isNewProvenance(prov(.dictionary, nil, now), in: existing))
        XCTAssertTrue(ContextGraphPolicy.isNewProvenance(prov(.calendar, nil, now), in: existing))
    }

    // MARK: P1-11 / P1-23 — store-level idempotency + earliest-wins firstSeen

    /// Re-running `backfill` over the *same* dictations must not double `mentions`,
    /// and the watermark must make the second pass a no-op.
    /// A store backed by a fresh temporary directory, so disk state is hermetic and
    /// independent of any real on-disk graph or prior test run.
    @MainActor
    private func makeTempStore() -> ContextGraphStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxgraph-test-\(UUID().uuidString)", isDirectory: true)
        return ContextGraphStore(directory: dir)
    }

    @MainActor
    func testBackfillIsIdempotentAcrossRuns() {
        let store = makeTempStore()
        let token = "Idemtoken"
        let entry = DictationEntry(timestampUnix: future, text: "Working on \(token) today.")

        store.backfill(dictations: [entry], meetings: [])
        XCTAssertEqual(store.snapshot().lookup(token)?.mentions, 1,
                       "first backfill records exactly one mention")

        store.backfill(dictations: [entry], meetings: [])
        XCTAssertEqual(store.snapshot().lookup(token)?.mentions, 1,
                       "re-running backfill over the same source must not inflate mentions")
    }

    /// `firstSeenUnix` reflects the EARLIEST provenance even when a newer mention is
    /// folded in before an older one (backfill walks stores in arbitrary order).
    @MainActor
    func testFirstSeenIsEarliestRegardlessOfIngestOrder() {
        let store = makeTempStore()
        let token = "Firsttoken"
        // newer is listed BEFORE older so the entity is created from the newer
        // mention, then folded with the older one — firstSeen must still be earliest.
        let newer = DictationEntry(timestampUnix: future, text: "Discussing \(token) again.")
        let older = DictationEntry(timestampUnix: future - 30 * day, text: "First time: \(token).")

        store.backfill(dictations: [newer, older], meetings: [])

        let e = store.snapshot().lookup(token)
        XCTAssertEqual(e?.firstSeenUnix, future - 30 * day, "firstSeen must be the earliest provenance")
        XCTAssertEqual(e?.lastSeenUnix, future, "lastSeen must be the newest provenance")
        XCTAssertEqual(e?.mentions, 2, "two distinct sources = two mentions")
    }

    // MARK: P2-07 — eviction ranking + cap

    func testEvictionScoreFavorsMentionsAndRecency() {
        let frequent = entity("frequent", mentions: 10, first: now, last: now)
        let rare = entity("rare", mentions: 1, first: now, last: now)
        XCTAssertGreaterThan(ContextGraphPolicy.evictionScore(frequent, nowUnix: now),
                             ContextGraphPolicy.evictionScore(rare, nowUnix: now))

        let recent = entity("recent", mentions: 2, first: now, last: now)
        let old = entity("old", mentions: 2, first: now - 100 * day, last: now - 100 * day)
        XCTAssertGreaterThan(ContextGraphPolicy.evictionScore(recent, nowUnix: now),
                             ContextGraphPolicy.evictionScore(old, nowUnix: now))
    }

    /// Beyond the cap, the lowest-value non-pinned entities are evicted while pinned
    /// and high-value entities survive.
    func testEnforceCapEvictsLowestValueKeepsPinnedAndHighValue() {
        let highValue = entity("high", mentions: 50, first: now, last: now)
        let pinnedLow = entity("pinnedLow", mentions: 1, pinned: true, first: now, last: now)
        let mid = entity("mid", mentions: 5, first: now, last: now)
        let lowOld = entity("lowOld", mentions: 1, first: now - 90 * day, last: now - 90 * day)

        let kept = ContextGraphPolicy.enforceCap([highValue, pinnedLow, mid, lowOld],
                                                 nowUnix: now, cap: 3)
        let names = Set(kept.map(\.displayName))
        XCTAssertEqual(kept.count, 3)
        XCTAssertTrue(names.contains("high"), "high-value survives")
        XCTAssertTrue(names.contains("pinnedLow"), "pinned always survives even though it is lowest-value")
        XCTAssertTrue(names.contains("mid"))
        XCTAssertFalse(names.contains("lowOld"), "lowest-value non-pinned is evicted")
    }

    /// Pinned entities are retained even when they alone exceed the cap.
    func testEnforceCapNeverEvictsPinned() {
        let pins = (0..<5).map { entity("pin\($0)", mentions: 1, pinned: true, first: now, last: now) }
        let kept = ContextGraphPolicy.enforceCap(pins, nowUnix: now, cap: 2)
        XCTAssertEqual(kept.count, 5, "pinned entities are never evicted, even above the cap")
    }

    // MARK: P2-07 — staleness prune

    func testPruneDropsStaleNonPinnedKeepsPinnedAndFresh() {
        let fresh = entity("fresh", first: now, last: now)
        let staleOld = entity("stale", first: now - 365 * day, last: now - 365 * day)
        let pinnedOld = entity("pinnedStale", pinned: true, first: now - 365 * day, last: now - 365 * day)

        let kept = ContextGraphPolicy.prune([fresh, staleOld, pinnedOld], nowUnix: now,
                                            stalenessSeconds: 180 * day, cap: 1000)
        let names = Set(kept.map(\.displayName))
        XCTAssertTrue(names.contains("fresh"))
        XCTAssertTrue(names.contains("pinnedStale"), "pinned is never stale-pruned")
        XCTAssertFalse(names.contains("stale"), "non-pinned beyond staleness is pruned")
    }

    // MARK: P2-07 — stable commitment key

    /// Equivalent clauses (case / whitespace differences) collapse to one stable key,
    /// and the key is bounded rather than growing with the clause text.
    func testCommitmentKeyIsStableAndBounded() {
        let a = ContextGraphPolicy.key(.commitment, "I'll follow up with Sarah tomorrow")
        let b = ContextGraphPolicy.key(.commitment, "  i'll   follow up with sarah tomorrow  ")
        XCTAssertEqual(a, b, "case/whitespace-equivalent commitments share one key")

        let longClause = String(repeating: "do the thing and ", count: 20)
        let key = ContextGraphPolicy.key(.commitment, longClause)
        XCTAssertLessThan(key.count, longClause.count, "key must not grow with the clause text")
        XCTAssertTrue(key.hasPrefix("c:"))

        // Re-deriving the same clause yields the same key (run-stable hash).
        XCTAssertEqual(key, ContextGraphPolicy.key(.commitment, longClause))
    }

    /// Non-commitment kinds key on the lowercased display form (unchanged behavior).
    func testNonCommitmentKeyIsLowercasedDisplay() {
        XCTAssertEqual(ContextGraphPolicy.key(.person, "Sarah"), "sarah")
        XCTAssertEqual(ContextGraphPolicy.key(.project, "Talkie.app"), "talkie.app")
    }
}
