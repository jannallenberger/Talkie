import XCTest
@testable import Talkie

/// A4 — `.talkiepack` one-file dictionary format. Covers the two things that gate the
/// later curated-pack features: the pure codec (round-trip + tolerant decode so a v1
/// reader reads v1 files forever) and the merge (idempotent, never clobbers a user's
/// rules, malformed → no change).
///
/// The `DictionaryStore` tests drive a real file at the fixed Application Support path
/// (the store owns that path), snapshotting whatever is there and restoring it on
/// teardown so a developer running the suite never loses their curated dictionary —
/// same discipline as `DictionaryStoreLoadTests`.
final class TalkiePackTests: XCTestCase {

    // MARK: Pure codec

    func testEncodeDecodeRoundTripsExactly() throws {
        let pack = TalkiePack(
            name: "Kubernetes terms",
            description: "Cluster jargon",
            attribution: "shared by @dave",
            createdAtUnix: 1_700_000_000,
            vocabulary: ["Kubernetes", "idempotent", "kubectl"],
            replacements: [
                .init(from: "correlate", to: "Coralate", caseSensitive: false, wholeWord: true),
                .init(from: "cube control", to: "kubectl", caseSensitive: nil, wholeWord: nil),
            ]
        )

        let data = try pack.encoded()
        let decoded = try TalkiePack.decoded(from: data)

        XCTAssertEqual(decoded, pack, "a pack must survive an encode→decode round-trip byte-for-byte in value")
    }

    /// Tolerant decode: unknown future fields are ignored, missing optionals default,
    /// and a missing `formatVersion` reads as 1 — so a v1 build reads a v2 file.
    func testTolerantDecodeIgnoresUnknownFieldsAndDefaultsMissing() throws {
        let json = """
        {
          "formatVersion": 2,
          "name": "Future pack",
          "createdAtUnix": 123,
          "vocabulary": ["Talkie"],
          "replacements": [ { "from": "talky", "to": "Talkie" } ],
          "someFutureField": { "nested": true },
          "tags": ["brand"]
        }
        """
        let pack = try TalkiePack.decoded(from: Data(json.utf8))

        XCTAssertEqual(pack.formatVersion, 2, "unknown-but-present formatVersion is preserved")
        XCTAssertEqual(pack.name, "Future pack")
        XCTAssertNil(pack.description, "a missing optional decodes to nil, not a failure")
        XCTAssertEqual(pack.vocabulary, ["Talkie"])
        XCTAssertEqual(pack.replacements.count, 1)
        // The terse rule (no case/whole-word) resolves to the app's defaults.
        XCTAssertEqual(pack.replacements[0].resolvedCaseSensitive, false)
        XCTAssertEqual(pack.replacements[0].resolvedWholeWord, true)
    }

    /// A missing `formatVersion` / `name` still decodes with sane defaults.
    func testDecodeDefaultsFormatVersionAndName() throws {
        let json = """
        { "vocabulary": ["A"], "replacements": [] }
        """
        let pack = try TalkiePack.decoded(from: Data(json.utf8))
        XCTAssertEqual(pack.formatVersion, 1, "absent formatVersion defaults to 1")
        XCTAssertFalse(pack.name.isEmpty, "absent name gets a neutral placeholder, not empty")
        XCTAssertEqual(pack.createdAtUnix, 0)
    }

    /// One malformed rule (missing `to`) is dropped, not fatal — a single bad entry
    /// can't poison an otherwise-good pack.
    func testDecodeDropsRulesMissingRequiredFields() throws {
        let json = """
        {
          "name": "Mixed",
          "createdAtUnix": 0,
          "vocabulary": ["  ", "Real"],
          "replacements": [
            { "from": "a", "to": "A" },
            { "from": "b" },
            { "to": "C" },
            { "from": "   ", "to": "D" }
          ]
        }
        """
        let pack = try TalkiePack.decoded(from: Data(json.utf8))
        XCTAssertEqual(pack.replacements.map(\.to), ["A"], "only the complete rule survives")
        // Blank vocab entries stay in the raw vocabulary array here; the store's merge
        // trims/skips them (covered below). Decode only guarantees the object parses.
        XCTAssertTrue(pack.vocabulary.contains("Real"))
    }

    func testMalformedJSONThrowsMalformed() {
        let garbage = Data("{ not json at all ".utf8)
        XCTAssertThrowsError(try TalkiePack.decoded(from: garbage)) { error in
            XCTAssertEqual(error as? TalkiePackError, .malformed,
                           "unreadable bytes must throw .malformed so the UI can show an error and change nothing")
        }
    }

    func testSuggestedFileNameIsSafe() {
        let pack = TalkiePack(name: "Jann/Dave: terms", createdAtUnix: 0,
                              vocabulary: [], replacements: [])
        let name = pack.suggestedFileName
        XCTAssertFalse(name.contains("/"), "path separators must be stripped from the export filename")
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix(".talkiepack"))
    }

    // MARK: Merge against a live DictionaryStore

    @MainActor
    func testExportThenWipeThenImportRestoresExactly() throws {
        let fx = DictionaryFixture(); defer { fx.restore() }
        fx.wipe()

        let store = DictionaryStore()
        // A known-good starting dictionary.
        store.vocabulary = ["Kubernetes", "idempotent"]
        store.replacements = [
            Replacement(from: "correlate", to: "Coralate", caseSensitive: false, wholeWord: true),
            Replacement(from: "api", to: "API", caseSensitive: true, wholeWord: true, learned: true),
        ]

        // Export → serialize (as the save panel would).
        let pack = store.exportPack(name: "Round trip", description: nil, attribution: nil)
        let bytes = try pack.encoded()

        // Wipe the on-disk store completely and start fresh (as if a new machine).
        fx.wipe()
        let fresh = DictionaryStore()
        fresh.vocabulary = []
        fresh.replacements = []

        // Reimport.
        let reloaded = try TalkiePack.decoded(from: bytes)
        let summary = fresh.merge(pack: reloaded)

        XCTAssertEqual(Set(fresh.vocabulary), ["Kubernetes", "idempotent"],
                       "vocabulary must round-trip through export→import")
        XCTAssertEqual(summary.vocabularyAdded, 2)
        // Rules restored with the same from/to/flags. The learned flag is intentionally
        // NOT preserved — imported rules are curated, not learned.
        let byFrom = Dictionary(uniqueKeysWithValues: fresh.replacements.map { ($0.from, $0) })
        XCTAssertEqual(byFrom["correlate"]?.to, "Coralate")
        XCTAssertEqual(byFrom["api"]?.to, "API")
        XCTAssertEqual(byFrom["api"]?.caseSensitive, true, "flags survive the round-trip")
        XCTAssertEqual(byFrom["api"]?.wholeWord, true)
        XCTAssertEqual(byFrom["api"]?.isLearned, false, "imported rules are curated, never learned")
        XCTAssertEqual(summary.replacementsAdded, 2)
    }

    /// Importing a pack twice adds nothing the second time, and a user's edited rule is
    /// never clobbered.
    @MainActor
    func testDoubleImportAddsNothingAndNeverClobbersUserRules() throws {
        let fx = DictionaryFixture(); defer { fx.restore() }
        fx.wipe()

        let store = DictionaryStore()
        store.vocabulary = ["existing"]
        // The user's own curated rule that maps the SAME `from` to a DIFFERENT `to`
        // than the pack — importing must not overwrite it.
        store.replacements = [
            Replacement(from: "kates", to: "Kate S.", caseSensitive: false, wholeWord: true),
        ]

        let pack = TalkiePack(
            name: "Team pack", createdAtUnix: 0,
            vocabulary: ["existing", "EXISTING", "new-term"],   // case-insensitive dup + dup-in-pack
            replacements: [
                .init(from: "kates", to: "Kubernetes", caseSensitive: nil, wholeWord: nil), // collides on from+to? No — different `to`
                .init(from: "correlate", to: "Coralate", caseSensitive: nil, wholeWord: nil),
                .init(from: "Correlate", to: "Coralate", caseSensitive: nil, wholeWord: nil), // dup within pack
            ]
        )

        let first = store.merge(pack: pack)
        XCTAssertEqual(first.vocabularyAdded, 1, "only 'new-term' is new; 'existing'/'EXISTING' dedup")
        XCTAssertEqual(first.vocabularySkipped, 2)
        // "kates→Kubernetes" is a NEW (from,to) pair, so it's added ALONGSIDE the user's
        // "kates→Kate S." — the user's rule is untouched. "correlate→Coralate" adds once
        // (the second, case-different copy dedups within the pack).
        XCTAssertEqual(first.replacementsAdded, 2)

        // The user's original rule still exists, unchanged.
        XCTAssertTrue(store.replacements.contains { $0.from == "kates" && $0.to == "Kate S." },
                      "the user's own rule must never be overwritten by an import")

        let vocabAfterFirst = store.vocabulary
        let rulesAfterFirst = store.replacements

        // Second import of the same pack: pure no-op.
        let second = store.merge(pack: pack)
        XCTAssertTrue(second.isEmpty, "re-importing the same pack must add nothing")
        XCTAssertEqual(second.vocabularyAdded, 0)
        XCTAssertEqual(second.replacementsAdded, 0)
        XCTAssertEqual(store.vocabulary, vocabAfterFirst, "vocabulary unchanged on re-import")
        XCTAssertEqual(store.replacements.map(\.from), rulesAfterFirst.map(\.from),
                       "replacements unchanged on re-import")
    }

    /// The preview is a faithful dry-run: its new-count equals what `merge` then adds,
    /// and collisions (existing + within-pack) are flagged.
    @MainActor
    func testPreviewMatchesMerge() throws {
        let fx = DictionaryFixture(); defer { fx.restore() }
        fx.wipe()

        let store = DictionaryStore()
        store.vocabulary = ["alpha"]
        store.replacements = [Replacement(from: "x", to: "X")]

        let pack = TalkiePack(
            name: "Preview", createdAtUnix: 0,
            vocabulary: ["alpha", "beta", "beta"],  // 1 existing, 1 new (deduped within pack)
            replacements: [
                .init(from: "x", to: "X", caseSensitive: nil, wholeWord: nil),   // existing
                .init(from: "y", to: "Y", caseSensitive: nil, wholeWord: nil),   // new
            ]
        )

        let preview = store.previewMerge(pack: pack)
        XCTAssertEqual(preview.newVocabCount, 1, "only 'beta' is new")
        XCTAssertEqual(preview.newRuleCount, 1, "only y→Y is new")
        // Rows carry the existing flag for the UI to dim.
        XCTAssertTrue(preview.vocab.first { $0.term == "alpha" }?.existing == true)
        XCTAssertTrue(preview.rules.first { $0.from == "x" }?.existing == true)

        let summary = store.merge(pack: pack)
        XCTAssertEqual(summary.vocabularyAdded, preview.newVocabCount,
                       "preview's new-count must equal what merge adds")
        XCTAssertEqual(summary.replacementsAdded, preview.newRuleCount)
    }

    /// A malformed pack never reaches `merge`; the decode throws and the store is
    /// untouched. This mirrors the UI path (decode → error → change nothing).
    @MainActor
    func testMalformedPackChangesNothing() throws {
        let fx = DictionaryFixture(); defer { fx.restore() }
        fx.wipe()

        let store = DictionaryStore()
        store.vocabulary = ["keep-me"]
        store.replacements = [Replacement(from: "a", to: "A")]
        let vocabBefore = store.vocabulary
        let rulesBefore = store.replacements

        let garbage = Data("not a pack".utf8)
        XCTAssertThrowsError(try TalkiePack.decoded(from: garbage))

        // Nothing was merged because decode failed first.
        XCTAssertEqual(store.vocabulary, vocabBefore)
        XCTAssertEqual(store.replacements.map(\.from), rulesBefore.map(\.from))
    }
}

/// Snapshots + restores the real `dictionary.json` so store tests can drive it without
/// destroying a developer's curated dictionary. Same pattern as `DictionaryStoreLoadTests`.
@MainActor
private final class DictionaryFixture {
    private let fileURL: URL
    private let corruptURL: URL
    private let savedMain: Data?
    private let savedCorrupt: Data?

    init() {
        // Compute the paths locally (not via a `self` computed property) so we can
        // read them before the stored `saved*` properties are initialized.
        let file = AppPaths.supportDirectory().appendingPathComponent("dictionary.json")
        let corrupt = file.appendingPathExtension("corrupt")
        self.fileURL = file
        self.corruptURL = corrupt
        self.savedMain = try? Data(contentsOf: file)
        self.savedCorrupt = try? Data(contentsOf: corrupt)
    }

    func wipe() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: corruptURL)
    }

    func restore() {
        wipe()
        if let d = savedMain { try? d.write(to: fileURL) }
        if let d = savedCorrupt { try? d.write(to: corruptURL) }
    }
}
