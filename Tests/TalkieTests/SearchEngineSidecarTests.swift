import XCTest
import NaturalLanguage
@testable import Talkie

/// L13-a — the `SearchEngine` end of the persisted vector sidecar. `VectorSidecarTests`
/// covers the pure file format + reuse identity; this drives the live rebuild path
/// (`scheduleRebuild` → load sidecar → build → save sidecar) on the real `@MainActor`
/// engine against a temp support dir, proving:
///   • a rebuild persists a sidecar to `<tempSupport>/search/`;
///   • the delete cascade: after a record is removed from the corpus, the next
///     rebuild rewrites the sidecar WITHOUT that record's content hash;
///   • `clearSidecar()` (the "Clear everything" hook) wipes the files.
///
/// Hermetic: the engine is built with an explicit temp `sidecarDirectory`, so it
/// never reads or writes the developer's real support directory. The rebuild is
/// debounced + off-main, so we poll the on-disk sidecar with a bounded timeout
/// rather than reaching into private engine state.
@MainActor
final class SearchEngineSidecarTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-engine-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        try super.tearDownWithError()
    }

    private var searchDir: URL { tmp.appendingPathComponent("search", isDirectory: true) }

    private func dictation(_ id: String, _ text: String, at unix: Double) -> DictationEntry {
        DictationEntry(id: UUID(uuidString: id)!, timestampUnix: unix, text: text,
                       wordCount: text.split(separator: " ").count, durationSec: 1)
    }

    /// Poll the sidecar (via a fresh reader on the same dir) until it has content or
    /// we time out. The rebuild is a 200ms debounce + a detached build, so ~5s of
    /// slack is generous without being flaky.
    private func waitForSidecar(deadline: TimeInterval = 5) async -> [String: [Double]] {
        let reader = VectorSidecar(supportDirectory: tmp)
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            let map = reader.load()
            if !map.isEmpty { return map }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return reader.load()
    }

    func testRebuildPersistsSidecar() async throws {
        try XCTSkipUnless(NLEmbedding.sentenceEmbedding(for: .english) != nil,
                          "needs the on-device English sentence model")
        let engine = SearchEngine(sidecarDirectory: tmp)
        engine.scheduleRebuild(
            dictations: [dictation("00000000-0000-0000-0000-000000000001", "the launch retro notes", at: 1),
                         dictation("00000000-0000-0000-0000-000000000002", "quarterly revenue forecast", at: 2)],
            meetings: [], graph: .empty)

        let map = await waitForSidecar()
        XCTAssertEqual(map.count, 2, "both dictations' vectors persisted to the sidecar")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: searchDir.appendingPathComponent("vectors.bin").path))
    }

    /// The delete cascade: rebuild with two records (sidecar holds two hashes), then
    /// rebuild with only one (the other was "deleted") and confirm the sidecar now
    /// holds exactly the surviving record's hash — the deleted vector aged out.
    func testDeleteCascadeDropsHash() async throws {
        try XCTSkipUnless(NLEmbedding.sentenceEmbedding(for: .english) != nil,
                          "needs the on-device English sentence model")
        let engine = SearchEngine(sidecarDirectory: tmp)

        let keep = dictation("00000000-0000-0000-0000-0000000000AA", "keep this one around", at: 1)
        let gone = dictation("00000000-0000-0000-0000-0000000000BB", "this record gets deleted", at: 2)
        let keepHash = VectorSidecar.contentHash(String(keep.text.prefix(SemanticIndex.maxIndexedChars)))
        let goneHash = VectorSidecar.contentHash(String(gone.text.prefix(SemanticIndex.maxIndexedChars)))

        engine.scheduleRebuild(dictations: [keep, gone], meetings: [], graph: .empty)
        var map = await waitForSidecar()
        XCTAssertEqual(map.count, 2, "precondition: both hashes present")
        XCTAssertNotNil(map[goneHash])

        // "Delete" gone → rebuild with only keep.
        engine.scheduleRebuild(dictations: [keep], meetings: [], graph: .empty)
        // Wait until the sidecar reflects exactly one hash (the rewrite happened).
        let reader = VectorSidecar(supportDirectory: tmp)
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            map = reader.load()
            if map.count == 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(Set(map.keys), [keepHash], "deleted record's hash aged out of the sidecar")
        XCTAssertNil(map[goneHash], "the deleted hash is gone")
    }

    /// `clearSidecar()` — the "Clear everything" hook — deletes the files immediately,
    /// without waiting for a rebuild.
    func testClearSidecarWipesFiles() async throws {
        try XCTSkipUnless(NLEmbedding.sentenceEmbedding(for: .english) != nil,
                          "needs the on-device English sentence model")
        let engine = SearchEngine(sidecarDirectory: tmp)
        engine.scheduleRebuild(
            dictations: [dictation("00000000-0000-0000-0000-0000000000CC", "something to index", at: 1)],
            meetings: [], graph: .empty)
        _ = await waitForSidecar()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: searchDir.appendingPathComponent("vectors.bin").path), "precondition: written")

        engine.clearSidecar()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: searchDir.appendingPathComponent("vectors.bin").path), "cleared immediately")
        XCTAssertTrue(VectorSidecar(supportDirectory: tmp).load().isEmpty)
    }
}
