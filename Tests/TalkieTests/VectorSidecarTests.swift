import XCTest
import NaturalLanguage
@testable import Talkie

/// L13-a — persisted vector sidecar. The semantic index used to re-embed every
/// record on every rebuild and every relaunch; the sidecar caches sentence vectors
/// on disk keyed by a stable content hash so a rebuild re-embeds only new/changed
/// records. These tests prove:
///   • round-trip identity (write → read gives back the exact floats + hashes);
///   • failure-tolerance (corruption / count mismatch / dimension change / model
///     change / missing files ⇒ treated as ABSENT ⇒ the caller does a cold rebuild);
///   • reuse actually happens (a cached vector is used verbatim, not re-embedded),
///     so a relaunch embeds only records the cache doesn't already hold;
///   • the delete/clear cascade removes hashes (a save writes only current hashes;
///     `clear()` deletes the files);
///   • **warm == cold**: results built with reuse are byte-identical to a cold
///     rebuild — the cache is an exact optimization, never an approximation.
///   • **privacy**: nothing written to `search/` contains literal record text.
///
/// Hermetic: every sidecar is rooted at a fresh temp dir, so nothing touches the
/// developer's real `~/Library/Application Support/Talkie/search/`.
final class VectorSidecarTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-sidecar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    /// The `search/` subfolder the sidecar writes into, under our temp support dir.
    private var searchDir: URL { tmp.appendingPathComponent("search", isDirectory: true) }

    // MARK: Round-trip identity

    /// Write a known hash→vector map, read it back, and assert exact identity of
    /// both the keys and every float (Float32 precision, so cast the doubles through
    /// Float first when building the expectation).
    func testRoundTripIdentity() {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        let a = (0..<8).map { Double(Float(0.1 * Double($0) - 0.3)) }
        let b = (0..<8).map { Double(Float(-0.05 * Double($0) + 0.9)) }
        let written: [String: [Double]] = ["hashA": a, "hashB": b]

        sidecar.save(vectorsByHash: written)
        let read = sidecar.load()

        XCTAssertEqual(Set(read.keys), Set(written.keys), "all hashes round-trip")
        for (k, v) in written {
            XCTAssertEqual(read[k]?.count, v.count, "dimension preserved for \(k)")
            for i in v.indices {
                XCTAssertEqual(read[k]![i], v[i], accuracy: 0,
                               "float \(i) of \(k) round-trips exactly (Float32)")
            }
        }
    }

    /// A save with rows of a single consistent dimension writes exactly three files
    /// with the documented names; a subsequent load sees them.
    func testWritesExpectedFiles() {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        sidecar.save(vectorsByHash: ["h": [Double](repeating: 0.25, count: 4)])
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: searchDir.appendingPathComponent("vectors.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: searchDir.appendingPathComponent("vector_ids.json").path))
        XCTAssertTrue(fm.fileExists(atPath: searchDir.appendingPathComponent("index_meta.json").path))
    }

    // MARK: Failure tolerance → treated absent → cold rebuild

    func testMissingFilesLoadEmpty() {
        let sidecar = VectorSidecar(supportDirectory: tmp) // nothing written yet
        XCTAssertTrue(sidecar.load().isEmpty, "absent sidecar ⇒ empty reuse ⇒ cold rebuild")
    }

    func testNilDirectoryDisablesPersistence() {
        let sidecar = VectorSidecar(supportDirectory: nil)
        sidecar.save(vectorsByHash: ["h": [1, 2, 3]])
        XCTAssertTrue(sidecar.load().isEmpty, "nil dir ⇒ never persists, load is empty")
    }

    /// A truncated `vectors.bin` (row count no longer matches the id count / meta
    /// dimension) must be rejected wholesale, not partially trusted.
    func testTruncatedBlobTreatedAbsent() throws {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        sidecar.save(vectorsByHash: ["a": [0.1, 0.2, 0.3, 0.4], "b": [0.5, 0.6, 0.7, 0.8]])
        // Corrupt: lop the last byte off the blob so it's no longer count×dim Float32.
        let blobURL = searchDir.appendingPathComponent("vectors.bin")
        var blob = try Data(contentsOf: blobURL)
        blob.removeLast()
        try blob.write(to: blobURL)
        XCTAssertTrue(sidecar.load().isEmpty, "torn blob ⇒ treated absent")
    }

    /// If the recorded dimension changes (e.g. a different model wrote the meta),
    /// the blob no longer divides evenly and must be discarded.
    func testDimensionMismatchTreatedAbsent() throws {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        sidecar.save(vectorsByHash: ["a": [0.1, 0.2, 0.3, 0.4]])
        // Rewrite meta with a bogus larger dimension; blob length no longer matches.
        let metaURL = searchDir.appendingPathComponent("index_meta.json")
        let json = "{\"schemaVersion\":\(VectorSidecar.schemaVersion),\"dimension\":9999,\"modelKind\":\"\(VectorSidecar.modelKind)\",\"builtUnix\":0}"
        try json.data(using: .utf8)!.write(to: metaURL)
        XCTAssertTrue(sidecar.load().isEmpty, "dimension change ⇒ discard blob, cold rebuild")
    }

    /// A different `modelKind` in the meta means the floats are from another model —
    /// never mix them; treat as absent.
    func testModelKindMismatchTreatedAbsent() throws {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        sidecar.save(vectorsByHash: ["a": [0.1, 0.2, 0.3, 0.4]])
        let metaURL = searchDir.appendingPathComponent("index_meta.json")
        let json = "{\"schemaVersion\":\(VectorSidecar.schemaVersion),\"dimension\":4,\"modelKind\":\"some-other-model\",\"builtUnix\":0}"
        try json.data(using: .utf8)!.write(to: metaURL)
        XCTAssertTrue(sidecar.load().isEmpty, "model change ⇒ discard blob")
    }

    /// A schemaVersion bump invalidates the cache.
    func testSchemaVersionMismatchTreatedAbsent() throws {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        sidecar.save(vectorsByHash: ["a": [0.1, 0.2, 0.3, 0.4]])
        let metaURL = searchDir.appendingPathComponent("index_meta.json")
        let json = "{\"schemaVersion\":\(VectorSidecar.schemaVersion + 1),\"dimension\":4,\"modelKind\":\"\(VectorSidecar.modelKind)\",\"builtUnix\":0}"
        try json.data(using: .utf8)!.write(to: metaURL)
        XCTAssertTrue(sidecar.load().isEmpty, "schemaVersion bump ⇒ discard blob")
    }

    /// Garbage in the meta file (not even JSON) is tolerated as absent.
    func testCorruptMetaTreatedAbsent() throws {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        sidecar.save(vectorsByHash: ["a": [0.1, 0.2, 0.3, 0.4]])
        try "not json {{{".data(using: .utf8)!
            .write(to: searchDir.appendingPathComponent("index_meta.json"))
        XCTAssertTrue(sidecar.load().isEmpty, "undecodable meta ⇒ treated absent")
    }

    // MARK: Content hash stability

    /// The reuse key must be process-independent (stable across launches), so equal
    /// text always hashes equal and different text differs. (A per-run-seeded
    /// `Hashable` would break cross-process reuse — this is the FNV-1a precedent.)
    func testContentHashIsStableAndDistinct() {
        XCTAssertEqual(VectorSidecar.contentHash("who is Sarah"),
                       VectorSidecar.contentHash("who is Sarah"),
                       "same text ⇒ same key, every run")
        XCTAssertNotEqual(VectorSidecar.contentHash("who is Sarah"),
                          VectorSidecar.contentHash("who is Bob"),
                          "different text ⇒ different key")
    }

    // MARK: Clear (delete cascade — files removed)

    func testClearRemovesFiles() {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        sidecar.save(vectorsByHash: ["h": [0.1, 0.2, 0.3, 0.4]])
        XCTAssertFalse(sidecar.load().isEmpty, "precondition: sidecar populated")
        sidecar.clear()
        XCTAssertTrue(sidecar.load().isEmpty, "clear() ⇒ load empty")
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: searchDir.appendingPathComponent("vectors.bin").path))
        XCTAssertFalse(fm.fileExists(atPath: searchDir.appendingPathComponent("vector_ids.json").path))
        XCTAssertFalse(fm.fileExists(atPath: searchDir.appendingPathComponent("index_meta.json").path))
    }

    /// A save that no longer includes a previously-cached hash must drop that row —
    /// this is how a deleted/pruned record's vector ages out of the on-disk cache.
    func testSaveOnlyKeepsCurrentHashes() {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        sidecar.save(vectorsByHash: ["keep": [0.1, 0.2, 0.3, 0.4],
                                     "drop": [0.9, 0.8, 0.7, 0.6]])
        // Rewrite with only "keep" — simulates a rebuild after "drop"'s source was deleted.
        sidecar.save(vectorsByHash: ["keep": [0.1, 0.2, 0.3, 0.4]])
        let read = sidecar.load()
        XCTAssertEqual(Set(read.keys), ["keep"], "the dropped hash is gone from disk")
    }

    /// An empty save (nothing embeddable) clears the cache rather than leaving a
    /// stale blob behind.
    func testEmptySaveClears() {
        let sidecar = VectorSidecar(supportDirectory: tmp)
        sidecar.save(vectorsByHash: ["h": [0.1, 0.2, 0.3, 0.4]])
        sidecar.save(vectorsByHash: [:])
        XCTAssertTrue(sidecar.load().isEmpty, "empty save ⇒ cache cleared, not stale")
    }

    // MARK: Reuse actually happens (relaunch embeds only new records)

    /// Build a `SemanticIndex` with a reuse map that carries a SENTINEL vector for a
    /// record's hash. If reuse works, that record's persisted vector equals the
    /// sentinel (which the real model would never produce), proving the cache was
    /// used instead of re-embedding. A second, un-cached record is embedded fresh,
    /// so the index ends up holding both — the "only new records get embedded" path.
    func testReuseUsesCachedVectorVerbatim() {
        let cached = SearchRecord(id: "dictation:1", text: "the quarterly launch retro",
                                  kind: .dictation, dateUnix: 1)
        let fresh = SearchRecord(id: "dictation:2", text: "an entirely different sentence here",
                                 kind: .dictation, dateUnix: 2)
        let cachedHash = VectorSidecar.contentHash(
            String(cached.text.prefix(SemanticIndex.maxIndexedChars)))
        // A sentinel the model can't emit for this text (all 42s, model dim width).
        let sentinel = [Double](repeating: 42, count: 512)

        let index = SemanticIndex(records: [cached, fresh], reuse: [cachedHash: sentinel])

        XCTAssertEqual(index.vectorsByHash[cachedHash], sentinel,
                       "cached record used the reuse vector verbatim (no re-embed)")
        let freshHash = VectorSidecar.contentHash(
            String(fresh.text.prefix(SemanticIndex.maxIndexedChars)))
        XCTAssertNotNil(index.vectorsByHash[freshHash], "uncached record was embedded now")
        XCTAssertNotEqual(index.vectorsByHash[freshHash], sentinel,
                          "the fresh record is a real embedding, not the sentinel")
    }

    /// With an EMPTY reuse map, the index must behave exactly like the old
    /// always-embed path: it still produces a vector for embeddable text.
    func testEmptyReuseMatchesColdEmbed() throws {
        try XCTSkipUnless(NLEmbedding.sentenceEmbedding(for: .english) != nil,
                          "needs the on-device English sentence model")
        let r = SearchRecord(id: "dictation:1", text: "shipping the search sidecar today",
                             kind: .dictation, dateUnix: 1)
        let cold = SemanticIndex(records: [r]) // no reuse — old behavior
        let hash = VectorSidecar.contentHash(String(r.text.prefix(SemanticIndex.maxIndexedChars)))
        XCTAssertNotNil(cold.vectorsByHash[hash], "cold build embeds the record")
    }

    // MARK: Warm == Cold (exact, not approximate)

    /// The headline guarantee: search results from a WARM rebuild (reusing persisted
    /// vectors) are byte-identical to a COLD rebuild (embedding from scratch). We
    /// build cold, persist, reload the sidecar, build warm from that reuse map, and
    /// assert the two indices return the same hits in the same order with the same
    /// scores across several queries.
    func testWarmResultsIdenticalToCold() throws {
        try XCTSkipUnless(NLEmbedding.sentenceEmbedding(for: .english) != nil,
                          "needs the on-device English sentence model")
        let records = [
            SearchRecord(id: "dictation:1", text: "who is Sarah on the launch team",
                         kind: .dictation, dateUnix: 1),
            SearchRecord(id: "dictation:2", text: "the Q3 revenue forecast looks strong",
                         kind: .dictation, dateUnix: 2),
            SearchRecord(id: "meeting:3", text: "standup notes about the deployment pipeline",
                         kind: .meeting, dateUnix: 3),
            SearchRecord(id: "entity:person:sarah", text: "Sarah",
                         kind: .entity, dateUnix: 4),
        ]

        // COLD build, then persist its vectors to the sidecar.
        let sidecar = VectorSidecar(supportDirectory: tmp)
        let cold = SemanticIndex(records: records)
        sidecar.save(vectorsByHash: cold.vectorsByHash)

        // WARM build from the reloaded sidecar (this is the relaunch path).
        let reuse = sidecar.load()
        XCTAssertFalse(reuse.isEmpty, "sidecar persisted the cold vectors")
        let warm = SemanticIndex(records: records, reuse: reuse)

        for q in ["Sarah", "revenue", "deployment", "who is on the team", "forecast strong"] {
            let coldHits = cold.search(q)
            let warmHits = warm.search(q)
            XCTAssertEqual(coldHits.map(\.id), warmHits.map(\.id),
                           "query \"\(q)\": identical hit ids in identical order")
            XCTAssertEqual(coldHits.count, warmHits.count, "query \"\(q)\": same hit count")
            for (c, w) in zip(coldHits, warmHits) {
                XCTAssertEqual(c.score, w.score, accuracy: 1e-12,
                               "query \"\(q)\": identical score for \(c.id) (exact reuse)")
            }
        }
    }

    // MARK: Privacy — no literal text on disk

    /// After a real save, grep the entire `search/` directory for a distinctive
    /// phrase from a record: it must appear NOWHERE. Only content hashes and floats
    /// are persisted — never transcript text.
    func testNoLiteralTextOnDisk() throws {
        try XCTSkipUnless(NLEmbedding.sentenceEmbedding(for: .english) != nil,
                          "needs the on-device English sentence model")
        let secret = "xyzzyplugh"  // a token that only appears in the dictated text
        let record = SearchRecord(id: "dictation:1",
                                  text: "the secret passphrase is \(secret) do not leak it",
                                  kind: .dictation, dateUnix: 1)
        let sidecar = VectorSidecar(supportDirectory: tmp)
        let index = SemanticIndex(records: [record])
        sidecar.save(vectorsByHash: index.vectorsByHash)

        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty, "sidecar wrote files")
        for file in files {
            let data = try Data(contentsOf: file)
            // Search the raw bytes for the secret token (UTF-8) — must be absent.
            let needle = Array(secret.utf8)
            let haystack = Array(data)
            XCTAssertFalse(containsSubsequence(haystack, needle),
                           "\(file.lastPathComponent) must NOT contain the dictated phrase")
            // The full sentence must obviously be absent too.
            if let text = String(data: data, encoding: .utf8) {
                XCTAssertFalse(text.contains(secret), "\(file.lastPathComponent) has no literal text")
            }
        }
    }

    /// Byte-subsequence search (no Foundation string dependency, works on the raw
    /// binary `vectors.bin` too).
    private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            var match = true
            for i in needle.indices where haystack[start + i] != needle[i] { match = false; break }
            if match { return true }
        }
        return false
    }
}
