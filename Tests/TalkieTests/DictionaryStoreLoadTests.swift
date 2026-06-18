import XCTest
@testable import Talkie

/// P2-11 (data-integrity): `DictionaryStore.load()` must distinguish an ABSENT
/// store file (seed defaults) from an UNDECODABLE one (preserve the bytes, fall
/// back to in-memory defaults, and NEVER re-save over the user's on-disk vocab).
///
/// `DictionaryStore` reads/writes a fixed path under Application Support, so
/// these tests drive `load()` against a real file at that path. Each test
/// snapshots whatever is there first and restores it on teardown, so a developer
/// running the suite never loses their own curated dictionary.
@MainActor
final class DictionaryStoreLoadTests: XCTestCase {
    private var fileURL: URL { AppPaths.supportDirectory().appendingPathComponent("dictionary.json") }
    private var corruptURL: URL { fileURL.appendingPathExtension("corrupt") }

    private var savedMain: Data?
    private var savedCorrupt: Data?

    override func setUp() {
        super.setUp()
        savedMain = try? Data(contentsOf: fileURL)
        savedCorrupt = try? Data(contentsOf: corruptURL)
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: corruptURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: corruptURL)
        if let d = savedMain { try? d.write(to: fileURL) }
        if let d = savedCorrupt { try? d.write(to: corruptURL) }
        super.tearDown()
    }

    /// ABSENT: no file on disk → seed the illustrative defaults and persist them.
    func testAbsentFileSeedsDefaults() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        let store = DictionaryStore()

        XCTAssertEqual(store.replacements.map(\.from), ["talkie"])
        XCTAssertEqual(store.replacements.map(\.to), ["Talkie"])
        // First-run seeding DOES persist, so the UI survives a relaunch.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "absent → should seed + save")
    }

    /// UNDECODABLE: a present-but-corrupt file must NOT overwrite curated vocab.
    /// The bad bytes are renamed to `*.corrupt`, the in-memory state falls back to
    /// defaults, and — critically — `load()` does not re-save over the on-disk
    /// vocab (the original is moved aside, never clobbered in place).
    func testUndecodableFileIsQuarantinedAndNotOverwritten() throws {
        let garbage = Data("{ this is not valid json ".utf8)
        try garbage.write(to: fileURL)

        let store = DictionaryStore()

        // The corrupt bytes were preserved by renaming, not destroyed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path),
                      "undecodable file should be renamed to *.corrupt")
        XCTAssertEqual(try Data(contentsOf: corruptURL), garbage,
                       "the original bad bytes must be preserved verbatim")
        // The bad file is no longer at the live path...
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "the live path should not be re-saved (clobbered) on the failure branch")
        // ...and we fell back to in-memory defaults rather than blank/garbage.
        XCTAssertEqual(store.replacements.map(\.to), ["Talkie"])
        XCTAssertTrue(store.vocabulary.isEmpty)
    }

    /// A well-formed file with the user's curated vocab loads intact and is never
    /// re-seeded — the regression this whole fix protects.
    func testValidFileLoadsCuratedVocabUntouched() throws {
        let json = """
        {"replacements":[{"id":"\(UUID().uuidString)","from":"correlate","to":"Coralate","caseSensitive":false,"wholeWord":true}],"vocabulary":["Kubernetes","idempotent"]}
        """
        try Data(json.utf8).write(to: fileURL)

        let store = DictionaryStore()

        XCTAssertEqual(store.replacements.map(\.to), ["Coralate"])
        XCTAssertEqual(store.vocabulary, ["Kubernetes", "idempotent"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path),
                       "a valid file must not be quarantined")
    }
}
