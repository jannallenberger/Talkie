import XCTest
@testable import Talkie

/// I3 — true delete. Deleting a dictation or meeting must also erase the graph's
/// provenance snippets of its text (up to 120 chars of the literal dictation), and
/// the delete decision must be a pure, testable policy. These tests cover:
///   • the pure `ContextGraphPolicy.purge` (mentions decrement, empty-provenance
///     drop, pinned survival, whole-source-class purge);
///   • the store-level `ContextGraphStore.purge` with a real temp directory, where
///     the headline assertion is a byte-level `grep` of the deleted snippet over the
///     on-disk `entities.json` finding NOTHING;
///   • that re-ingesting a purged sourceID counts as a genuinely new mention again.
/// Hermetic: the store is built with `ContextGraphStore(directory:)` on a fresh temp
/// dir, so nothing touches the developer's real graph and the disk state is owned by
/// the test. The `FileShredder` overwrite behavior is covered in `FileShredderTests`.
final class GraphPurgeTests: XCTestCase {
    private let now = 1_000_000_000.0

    private func prov(_ source: ProvenanceSource, _ id: String?, snippet: String?,
                      at date: Double) -> Provenance {
        Provenance(source: source, sourceID: id, dateUnix: date, snippet: snippet)
    }

    private func entity(_ name: String, kind: EntityKind = .term, mentions: Int,
                        pinned: Bool = false, provenance: [Provenance]) -> Entity {
        Entity(id: EntityID(kind: kind, key: ContextGraphPolicy.key(kind, name)),
               displayName: name, aliases: [], mentions: mentions, pinned: pinned,
               firstSeenUnix: provenance.map(\.dateUnix).min() ?? now,
               lastSeenUnix: provenance.map(\.dateUnix).max() ?? now,
               provenance: provenance)
    }

    // MARK: Pure policy — ContextGraphPolicy.purge

    /// Two dictations mention one entity. Purging ONE of them removes only that
    /// source's provenance, decrements `mentions` by exactly one, and keeps the entity
    /// (the other dictation still justifies it).
    func testPurgeOneSourceDecrementsMentionsAndKeepsShared() {
        let shared = entity("Talkie", mentions: 2, provenance: [
            prov(.dictation, "A", snippet: "shipping Talkie today", at: now),
            prov(.dictation, "B", snippet: "Talkie needs a fix", at: now + 1),
        ])
        let kept = ContextGraphPolicy.purge(entities: [shared], source: .dictation, sourceID: "A")
        XCTAssertEqual(kept.count, 1, "entity survives because dictation B still mentions it")
        XCTAssertEqual(kept[0].mentions, 1, "mentions drops by exactly the one purged provenance")
        XCTAssertEqual(kept[0].provenance.count, 1)
        XCTAssertEqual(kept[0].provenance.first?.sourceID, "B", "only the non-purged provenance remains")
    }

    /// Purging the ONLY source of an entity removes the entity entirely (no orphaned,
    /// provenance-less fact left behind).
    func testPurgeOnlySourceDropsEntity() {
        let solo = entity("Ephemeral", mentions: 1, provenance: [
            prov(.dictation, "A", snippet: "one-off mention", at: now),
        ])
        let kept = ContextGraphPolicy.purge(entities: [solo], source: .dictation, sourceID: "A")
        XCTAssertTrue(kept.isEmpty, "an entity with no provenance left and no pin is dropped")
    }

    /// A pinned dictionary term survives even when its last provenance is purged — the
    /// user taught it directly, so it outlives the source that first surfaced it.
    func testPurgeKeepsPinnedEvenWhenProvenanceEmpties() {
        let pinned = entity("Kubernetes", mentions: 1, pinned: true, provenance: [
            prov(.dictation, "A", snippet: "deploying to Kubernetes", at: now),
        ])
        let kept = ContextGraphPolicy.purge(entities: [pinned], source: .dictation, sourceID: "A")
        XCTAssertEqual(kept.count, 1, "pinned term is never dropped by a purge")
        XCTAssertTrue(kept[0].provenance.isEmpty, "its dictation provenance is still removed")
        XCTAssertEqual(kept[0].mentions, 0, "mentions floors at 0, never underflows")
        XCTAssertTrue(kept[0].pinned, "still pinned")
    }

    /// `sourceID == nil` purges the WHOLE source class: every `.dictation` provenance
    /// goes, while a `.meeting` provenance on the same entity is untouched.
    func testPurgeWholeSourceClassLeavesOtherSources() {
        let mixed = entity("Roadmap", mentions: 3, provenance: [
            prov(.dictation, "A", snippet: "roadmap in standup", at: now),
            prov(.dictation, "B", snippet: "roadmap again", at: now + 1),
            prov(.meeting, "M", snippet: "roadmap review meeting", at: now + 2),
        ])
        let kept = ContextGraphPolicy.purge(entities: [mixed], source: .dictation, sourceID: nil)
        XCTAssertEqual(kept.count, 1, "entity survives on the surviving meeting provenance")
        XCTAssertEqual(kept[0].provenance.count, 1)
        XCTAssertEqual(kept[0].provenance.first?.source, .meeting, "only meeting provenance remains")
        XCTAssertEqual(kept[0].mentions, 1, "both dictation mentions removed, meeting one stays")
    }

    /// Purging a source that never touched an entity is a no-op for it.
    func testPurgeUnrelatedSourceIsNoOp() {
        let e = entity("Untouched", mentions: 1, provenance: [
            prov(.dictation, "A", snippet: "keep me", at: now),
        ])
        let kept = ContextGraphPolicy.purge(entities: [e], source: .dictation, sourceID: "Z")
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].mentions, 1, "no matching provenance → mentions unchanged")
        XCTAssertEqual(kept[0].provenance.count, 1)
    }

    // MARK: Store-level — the headline: deleted text is gone from disk

    @MainActor
    private func makeTempStore() -> (ContextGraphStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxgraph-purge-\(UUID().uuidString)", isDirectory: true)
        return (ContextGraphStore(directory: dir), dir.appendingPathComponent("entities.json"))
    }

    /// Ingest two dictations sharing an entity, then purge one by its sourceID: the
    /// entity survives with `mentions` decremented, and — the headline acceptance
    /// criterion — a `grep` of the purged dictation's snippet over the on-disk
    /// `entities.json` finds NOTHING, while the surviving dictation's text remains.
    @MainActor
    func testStorePurgeRemovesSnippetFromDiskKeepsShared() throws {
        let (store, fileURL) = makeTempStore()
        let secret = "the quarterly budget was slashed by forty percent"
        let survivor = "we also touched on hiring plans"

        store.ingest([ContextGraphExtractor.Candidate(kind: .term, displayName: "Budget")],
                     provenance: prov(.dictation, "DEL", snippet: secret, at: now))
        store.ingest([ContextGraphExtractor.Candidate(kind: .term, displayName: "Budget")],
                     provenance: prov(.dictation, "KEEP", snippet: survivor, at: now + 1))

        // Precondition: both snippets are on disk before the purge.
        let before = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(before.contains(secret), "sanity: the to-be-deleted snippet was persisted")
        XCTAssertTrue(before.contains(survivor))

        store.purge(source: .dictation, sourceID: "DEL")

        // Entity survives on the surviving dictation, mentions decremented.
        let entity = store.snapshot().lookup("Budget")
        XCTAssertNotNil(entity, "shared entity survives because the KEEP dictation still mentions it")
        XCTAssertEqual(entity?.mentions, 1, "mentions dropped from 2 to 1")

        // THE HEADLINE: the deleted dictation's text is gone from the on-disk graph.
        let after = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(after.contains(secret),
                       "grep of the deleted dictation's snippet over entities.json must find nothing")
        XCTAssertTrue(after.contains(survivor), "the surviving dictation's snippet is untouched")
    }

    /// Purging the only source of an entity removes the entity from the persisted
    /// graph entirely (not just its provenance).
    @MainActor
    func testStorePurgeOnlySourceRemovesEntityFromDisk() throws {
        let (store, fileURL) = makeTempStore()
        let text = "a fact mentioned exactly once"
        store.ingest([ContextGraphExtractor.Candidate(kind: .term, displayName: "Solo")],
                     provenance: prov(.dictation, "ONLY", snippet: text, at: now))

        store.purge(source: .dictation, sourceID: "ONLY")

        XCTAssertNil(store.snapshot().lookup("Solo"), "entity with no remaining provenance is gone")
        let after = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(after.contains(text), "its snippet is gone from disk too")
    }

    /// A pinned term (a taught dictionary rule) survives a whole-class dictation purge
    /// even though its dictation provenance is removed — the "learned rules stay"
    /// guarantee behind the Clear dialog's honest scope statement.
    @MainActor
    func testStorePinnedTermSurvivesClearAll() throws {
        let (store, _) = makeTempStore()
        // Pin a term the way the dictionary does, then also let a dictation mention it.
        store.pinTerm("Talkieism")
        store.ingest([ContextGraphExtractor.Candidate(kind: .term, displayName: "Talkieism")],
                     provenance: prov(.dictation, "D1", snippet: "used Talkieism in a sentence", at: now))

        // "Clear all dictation history" — purge the whole dictation source class.
        store.purge(source: .dictation, sourceID: nil)

        let entity = store.snapshot().lookup("Talkieism")
        XCTAssertNotNil(entity, "the pinned dictionary term survives Clear-all")
        XCTAssertTrue(entity?.pinned == true)
        XCTAssertFalse(entity?.provenance.contains { $0.source == .dictation } ?? true,
                       "its dictation provenance is gone; only the dictionary pin remains")
    }

    /// After purging a sourceID, re-ingesting that SAME sourceID counts as a genuinely
    /// new mention again (the purge truly forgot it — it is not still deduped away).
    @MainActor
    func testReingestAfterPurgeCountsAsNew() {
        let (store, _) = makeTempStore()
        let cand = [ContextGraphExtractor.Candidate(kind: .term, displayName: "Recurring")]
        store.ingest(cand, provenance: prov(.dictation, "R", snippet: "first time", at: now))
        XCTAssertEqual(store.snapshot().lookup("Recurring")?.mentions, 1)

        store.purge(source: .dictation, sourceID: "R")
        XCTAssertNil(store.snapshot().lookup("Recurring"), "purged away entirely")

        // Same sourceID again — must be treated as new, not silently deduped.
        store.ingest(cand, provenance: prov(.dictation, "R", snippet: "back again", at: now + 1))
        XCTAssertEqual(store.snapshot().lookup("Recurring")?.mentions, 1,
                       "re-ingesting a purged sourceID is a fresh mention, not a no-op")
    }
}
