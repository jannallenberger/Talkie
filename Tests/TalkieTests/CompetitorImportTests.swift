import XCTest
@testable import Talkie

/// A7 — importing a competitor dictation app's dictionary (VoiceInk / Superwhisper /
/// Wispr Flow) into Talkie. The parsers are pure and fixture-driven: given a plausible
/// export shaped like each app's documented format, they must produce a `TalkiePack`
/// with the expected terms and rules, and that pack must flow through A4's existing
/// preview/merge path unchanged (one code path — we assert the merge, not a bespoke one).
///
/// The two acceptance criteria live here as the load-bearing tests:
///   1. each app's fixture imports the expected terms/rules through the preview sheet, and
///   2. an unrecognized/corrupt file produces a friendly error and ZERO mutations.
///
/// Fixtures are JSON string literals (the committed test file *is* the committed
/// fixture, matching the repo's in-code fixture idiom — see `ClaudeTranscriptLearnerTests`
/// / `RepoTermMinerTests`, which build their fixture trees in code rather than shipping
/// resource files). The one on-disk path (`readPack(app:from:)`) is exercised by writing
/// a fixture to a temp file.
final class CompetitorImportTests: XCTestCase {

    // MARK: - VoiceInk

    /// VoiceInk's documented shape: a `dictionaryItems` word list and `wordReplacements`
    /// rules with `originalText`/`replacementText`.
    private static let voiceInkFixture = """
    {
      "dictionaryItems": ["Kubernetes", "kubectl", "Coralate"],
      "wordReplacements": [
        { "originalText": "cube control", "replacementText": "kubectl" },
        { "originalText": "correlate", "replacementText": "Coralate", "matchCase": false }
      ],
      "someFutureVoiceInkField": { "ignored": true }
    }
    """

    func testVoiceInkParsesVocabularyAndRules() throws {
        let pack = try CompetitorDictionaryImport.App.voiceInk.parse(Data(Self.voiceInkFixture.utf8))
        XCTAssertEqual(pack.vocabulary, ["Kubernetes", "kubectl", "Coralate"],
                       "VoiceInk dictionaryItems become vocabulary, in order")
        XCTAssertEqual(pack.replacements.map(\.from), ["cube control", "correlate"])
        XCTAssertEqual(pack.replacements.map(\.to), ["kubectl", "Coralate"])
        XCTAssertEqual(pack.attribution, "Imported from VoiceInk",
                       "the pack is stamped with provenance for the preview sheet")
        XCTAssertEqual(pack.name, "VoiceInk dictionary")
    }

    /// Field-name drift: an older/newer VoiceInk that used `customWords` + `from`/`to`
    /// must still import (version tolerance is the whole design stance).
    func testVoiceInkToleratesAlternateFieldNames() throws {
        let json = """
        {
          "customWords": ["Talkie"],
          "replacements": [ { "from": "talky", "to": "Talkie" } ]
        }
        """
        let pack = try CompetitorDictionaryImport.App.voiceInk.parse(Data(json.utf8))
        XCTAssertEqual(pack.vocabulary, ["Talkie"])
        XCTAssertEqual(pack.replacements.first?.from, "talky")
        XCTAssertEqual(pack.replacements.first?.to, "Talkie")
    }

    // MARK: - Superwhisper

    /// Superwhisper's documented shape: `vocabulary` + `replacements` with
    /// `original`/`replacement`, sometimes nested under a `dictionary` object.
    private static let superwhisperFixture = """
    {
      "dictionary": {
        "vocabulary": ["Coralate", "Talkie", "idempotent"],
        "replacements": [
          { "original": "correlate", "replacement": "Coralate" },
          { "original": "idem potent", "replacement": "idempotent" }
        ]
      }
    }
    """

    func testSuperwhisperParsesNestedDictionary() throws {
        let pack = try CompetitorDictionaryImport.App.superwhisper.parse(Data(Self.superwhisperFixture.utf8))
        XCTAssertEqual(pack.vocabulary, ["Coralate", "Talkie", "idempotent"],
                       "Superwhisper vocabulary is read even when nested under `dictionary`")
        XCTAssertEqual(pack.replacements.map(\.from), ["correlate", "idem potent"])
        XCTAssertEqual(pack.replacements.map(\.to), ["Coralate", "idempotent"])
        XCTAssertEqual(pack.attribution, "Imported from Superwhisper")
    }

    /// The un-nested variant (payload at the root, `words` for the list) also imports.
    func testSuperwhisperToleratesFlatShapeAndWordsKey() throws {
        let json = """
        {
          "words": ["Alpha", "Beta"],
          "substitutions": [ { "input": "alfa", "output": "Alpha" } ]
        }
        """
        let pack = try CompetitorDictionaryImport.App.superwhisper.parse(Data(json.utf8))
        XCTAssertEqual(pack.vocabulary, ["Alpha", "Beta"])
        XCTAssertEqual(pack.replacements.first?.from, "alfa")
        XCTAssertEqual(pack.replacements.first?.to, "Alpha")
    }

    // MARK: - Wispr Flow

    /// Wispr Flow's documented shape: a `dictionary` array of entries, each with a `word`
    /// and optionally a spoken form (`pronunciation`) that should map to it.
    private static let wisprFixture = """
    {
      "dictionary": [
        { "word": "Coralate" },
        { "word": "kubectl", "pronunciation": "cube control" },
        { "word": "Talkie", "pronunciation": "Talkie" }
      ]
    }
    """

    func testWisprParsesEntriesAndSynthesizesRules() throws {
        let pack = try CompetitorDictionaryImport.App.wisprFlow.parse(Data(Self.wisprFixture.utf8))
        XCTAssertEqual(pack.vocabulary, ["Coralate", "kubectl", "Talkie"],
                       "every entry's word becomes a vocabulary term")
        // Only the entry whose pronunciation DIFFERS from the word yields a rule; the
        // "Talkie"/"Talkie" entry does not (spoken == written, nothing to correct).
        XCTAssertEqual(pack.replacements.count, 1)
        XCTAssertEqual(pack.replacements.first?.from, "cube control")
        XCTAssertEqual(pack.replacements.first?.to, "kubectl")
        XCTAssertEqual(pack.attribution, "Imported from Wispr Flow")
    }

    /// Wispr's most-generous fallbacks: a bare top-level array of entries imports too.
    func testWisprToleratesTopLevelArray() throws {
        let json = """
        [
          { "term": "Zephyr" },
          { "text": "Nimbus", "spoken": "nim bus" }
        ]
        """
        let pack = try CompetitorDictionaryImport.App.wisprFlow.parse(Data(json.utf8))
        XCTAssertEqual(Set(pack.vocabulary), ["Zephyr", "Nimbus"])
        XCTAssertEqual(pack.replacements.first?.from, "nim bus")
        XCTAssertEqual(pack.replacements.first?.to, "Nimbus")
    }

    // MARK: - The whole flow through A4's preview/merge (one code path)

    /// The acceptance criterion: a competitor fixture imports the expected terms/rules
    /// THROUGH the same preview + merge that a native `.talkiepack` uses. We stage the
    /// preview (what the sheet shows) and then commit the merge, asserting the counts and
    /// the resulting dictionary — proving the competitor path reuses A4 end to end.
    @MainActor
    func testCompetitorPackFlowsThroughPreviewAndMerge() throws {
        let fx = DictionaryFixtureA7(); defer { fx.restore() }
        fx.wipe()

        let store = DictionaryStore()
        // Pre-seed one overlapping term + one overlapping rule so the preview must mark
        // collisions and the merge must skip them (never clobber).
        store.vocabulary = ["Coralate"]
        store.replacements = [Replacement(from: "correlate", to: "Coralate")]

        let pack = try CompetitorDictionaryImport.App.voiceInk.parse(Data(Self.voiceInkFixture.utf8))

        // Preview (dry-run the sheet shows).
        let preview = store.previewMerge(pack: pack)
        XCTAssertEqual(preview.packName, "VoiceInk dictionary")
        XCTAssertEqual(preview.attribution, "Imported from VoiceInk")
        // "Coralate" already exists → 2 new words (Kubernetes, kubectl).
        XCTAssertEqual(preview.newVocabCount, 2)
        // "correlate→Coralate" already exists → 1 new rule (cube control→kubectl).
        XCTAssertEqual(preview.newRuleCount, 1)
        XCTAssertTrue(preview.vocab.first { $0.term == "Coralate" }?.existing == true,
                      "an already-present term is flagged so the sheet dims it")

        // Commit (what Confirm does).
        let summary = store.merge(pack: pack)
        XCTAssertEqual(summary.vocabularyAdded, preview.newVocabCount,
                       "merge adds exactly what the preview promised")
        XCTAssertEqual(summary.replacementsAdded, preview.newRuleCount)
        XCTAssertEqual(Set(store.vocabulary), ["Coralate", "Kubernetes", "kubectl"])
        // The user's original rule is intact and imported rules are curated, not learned.
        XCTAssertTrue(store.replacements.contains { $0.from == "cube control" && $0.to == "kubectl" && $0.isLearned == false })
        XCTAssertTrue(store.replacements.contains { $0.from == "correlate" && $0.to == "Coralate" })

        // Re-importing the same competitor file is a pure no-op (idempotent, via A4).
        let second = store.merge(pack: pack)
        XCTAssertTrue(second.isEmpty, "re-importing the same competitor pack adds nothing")
    }

    /// The on-disk read path used by both the auto-detect entry and the picker fallback:
    /// write a fixture to a temp file, read it back through `readPack`, and confirm the
    /// pack matches the in-memory parse.
    func testReadPackFromDiskMatchesParse() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceink-\(UUID().uuidString).json")
        try Data(Self.voiceInkFixture.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let pack = try CompetitorDictionaryImport.readPack(app: .voiceInk, from: url)
        XCTAssertEqual(pack.vocabulary, ["Kubernetes", "kubectl", "Coralate"])
        XCTAssertEqual(pack.replacements.count, 2)
    }

    /// A file that doesn't exist is `.unreadable`, not a crash (the file vanished between
    /// detect and read, or a permission was revoked).
    func testReadPackMissingFileThrowsUnreadable() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertThrowsError(try CompetitorDictionaryImport.readPack(app: .voiceInk, from: missing)) { error in
            XCTAssertEqual(error as? CompetitorImportError, .unreadable)
        }
    }

    // MARK: - Corrupt / unrecognized → friendly error, ZERO mutations

    /// Garbage bytes throw `.unrecognizedFormat` for every parser — never a crash.
    func testGarbageBytesThrowForEveryParser() {
        let garbage = Data("{ not json at all ".utf8)
        for app in CompetitorDictionaryImport.App.allCases {
            XCTAssertThrowsError(try app.parse(garbage),
                                 "\(app.displayName) must reject unparseable bytes") { error in
                XCTAssertEqual(error as? CompetitorImportError, .unrecognizedFormat)
            }
        }
    }

    /// Valid JSON that simply isn't a dictionary we recognize (no vocab, no rules) is
    /// `.unrecognizedFormat` — "we read it but there's nothing to import" is the honest
    /// answer, and it means the preview is never staged.
    func testValidJsonWithNothingImportableThrows() {
        let empty = Data("""
        { "unrelated": true, "settings": { "theme": "dark" } }
        """.utf8)
        for app in CompetitorDictionaryImport.App.allCases {
            XCTAssertThrowsError(try app.parse(empty)) { error in
                XCTAssertEqual(error as? CompetitorImportError, .unrecognizedFormat,
                               "\(app.displayName): parseable-but-empty is unrecognized, not an empty import")
            }
        }
    }

    /// A JSON scalar / bare string root is rejected too (not an object or entry array).
    func testScalarRootThrows() {
        let scalar = Data("\"just a string\"".utf8)
        for app in CompetitorDictionaryImport.App.allCases {
            XCTAssertThrowsError(try app.parse(scalar)) { error in
                XCTAssertEqual(error as? CompetitorImportError, .unrecognizedFormat)
            }
        }
    }

    /// The end-to-end zero-mutation guarantee: a corrupt competitor file NEVER reaches
    /// `merge`, so the store is byte-for-byte unchanged. Mirrors the UI path (parse →
    /// error → change nothing).
    @MainActor
    func testCorruptCompetitorFileChangesNothing() {
        let fx = DictionaryFixtureA7(); defer { fx.restore() }
        fx.wipe()

        let store = DictionaryStore()
        store.vocabulary = ["keep-me"]
        store.replacements = [Replacement(from: "a", to: "A")]
        let vocabBefore = store.vocabulary
        let rulesBefore = store.replacements.map(\.from)

        let garbage = Data("not a dictionary at all".utf8)
        XCTAssertThrowsError(try CompetitorDictionaryImport.App.superwhisper.parse(garbage))

        // Nothing merged because parse failed first.
        XCTAssertEqual(store.vocabulary, vocabBefore, "a corrupt import must not touch vocabulary")
        XCTAssertEqual(store.replacements.map(\.from), rulesBefore, "a corrupt import must not touch rules")
    }

    /// One malformed replacement entry (missing its `to`) is dropped, not fatal — a single
    /// bad row can't poison an otherwise-good competitor file.
    func testMalformedRuleEntryIsDroppedNotFatal() throws {
        let json = """
        {
          "dictionaryItems": ["Real"],
          "wordReplacements": [
            { "originalText": "good", "replacementText": "Good" },
            { "originalText": "orphan-from-only" },
            { "replacementText": "orphan-to-only" }
          ]
        }
        """
        let pack = try CompetitorDictionaryImport.App.voiceInk.parse(Data(json.utf8))
        XCTAssertEqual(pack.replacements.map(\.to), ["Good"],
                       "only the complete rule survives; the two half-rules are dropped")
        XCTAssertEqual(pack.vocabulary, ["Real"])
    }

    // MARK: - Auto-detect

    /// Detection is a set of cheap fileExists checks over each app's default locations.
    /// On a CI box none of the competitor apps are installed, so the result must be empty
    /// — and, crucially, calling it must not throw or crash regardless of the machine.
    func testDetectInstalledAppsDoesNotCrash() {
        let detected = CompetitorDictionaryImport.detectInstalledApps()
        // We can't assert a specific count (a developer's machine MIGHT have one of these
        // apps), only that every returned entry points at a file that actually exists —
        // detection never invents a path.
        for entry in detected {
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.fileURL.path),
                          "detection only reports apps whose file is really on disk")
        }
    }
}

/// Snapshots + restores the real `dictionary.json` so the store-backed tests can drive it
/// without destroying a developer's curated dictionary. Same pattern as `TalkiePackTests`'
/// fixture (named distinctly to avoid a symbol clash across test files in the target).
@MainActor
private final class DictionaryFixtureA7 {
    private let fileURL: URL
    private let corruptURL: URL
    private let savedMain: Data?
    private let savedCorrupt: Data?

    init() {
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
