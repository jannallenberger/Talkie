import XCTest
@testable import Talkie

/// L4: `WordFrequencyStore` accumulates the user's word/phrase counts at record
/// time (transcripts are pruned after 7 days, so this can't be recomputed later).
///
/// The store reads/writes a fixed `wordfreq.json` under Application Support, so
/// the persistence tests snapshot whatever is on disk in `setUp` and restore it
/// in `tearDown` — a developer running the suite never loses their real vocab
/// store (same discipline as `DictionaryStoreLoadTests`). The tokenizer and
/// phrase-builder are pure statics and are exercised directly, no file needed.
@MainActor
final class WordFrequencyStoreTests: XCTestCase {
    private var fileURL: URL { AppPaths.supportDirectory().appendingPathComponent("wordfreq.json") }
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = try? Data(contentsOf: fileURL)
        try? FileManager.default.removeItem(at: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        if let d = saved { try? d.write(to: fileURL) }
        super.tearDown()
    }

    // MARK: Tokenizer

    func testTokenizeLowercases() {
        XCTAssertEqual(WordFrequencyStore.tokenize("Hello WORLD Foo"),
                       ["hello", "world", "foo"])
    }

    func testTokenizeSplitsOnPunctuationAndWhitespace() {
        XCTAssertEqual(WordFrequencyStore.tokenize("one, two. three! four?"),
                       ["one", "two", "three", "four"])
    }

    func testTokenizeKeepsInWordApostrophe() {
        // Straight and curly apostrophes both survive between word chars.
        XCTAssertEqual(WordFrequencyStore.tokenize("don't can't won't"),
                       ["don't", "can't", "won't"])
        XCTAssertEqual(WordFrequencyStore.tokenize("it\u{2019}s"), ["it\u{2019}s"])
    }

    func testTokenizeKeepsInWordHyphen() {
        XCTAssertEqual(WordFrequencyStore.tokenize("context-aware voice-to-text"),
                       ["context-aware", "voice-to-text"])
    }

    func testTokenizeTrimsEdgeConnectors() {
        // Leading/trailing/standalone apostrophes and hyphens are not part of a word.
        XCTAssertEqual(WordFrequencyStore.tokenize("-dash- 'quote' word"),
                       ["dash", "quote", "word"])
        // A bare connector between spaces yields nothing.
        XCTAssertEqual(WordFrequencyStore.tokenize("a - b"), [])
    }

    func testTokenizeLengthLowerBound() {
        // 2 chars dropped, 3 chars kept.
        XCTAssertEqual(WordFrequencyStore.tokenize("ab abc"), ["abc"])
        XCTAssertEqual(WordFrequencyStore.tokenize("a I to"), [])
    }

    func testTokenizeLengthUpperBound() {
        let ok = String(repeating: "x", count: 24)      // exactly 24 → kept
        let tooLong = String(repeating: "y", count: 25)  // 25 → dropped
        XCTAssertEqual(WordFrequencyStore.tokenize("\(ok) \(tooLong)"), [ok])
    }

    func testTokenizeKeepsDigitsAndAlphanumerics() {
        XCTAssertEqual(WordFrequencyStore.tokenize("swift6 claude md macos26"),
                       ["swift6", "claude", "macos26"])
    }

    // MARK: Content tokens (stop-word filtering)

    func testContentTokensStripStopWords() {
        // "the", "and", "with", "your" are stop words; "parrot"/"macaw" are not.
        XCTAssertEqual(WordFrequencyStore.contentTokens(in: "the parrot and the macaw"),
                       ["parrot", "macaw"])
    }

    func testContentTokensAcrossLanguages() {
        // German/French/Spanish function words are filtered too.
        XCTAssertEqual(WordFrequencyStore.contentTokens(in: "der Papagei und die Katze"),
                       ["papagei", "katze"])
        XCTAssertEqual(WordFrequencyStore.contentTokens(in: "les oiseaux dans les arbres"),
                       ["oiseaux", "arbres"])
    }

    func testContentTokensAllStopWordsIsEmpty() {
        XCTAssertTrue(WordFrequencyStore.contentTokens(in: "the and but for with").isEmpty)
    }

    // MARK: Phrases (sentence-bounded trigrams)

    func testPhrasesAreSentenceBoundedTrigrams() {
        // Single 4-token sentence → two overlapping trigrams.
        let p = WordFrequencyStore.phrases(in: "alpha beta gamma delta")
        XCTAssertEqual(p, ["alpha beta gamma", "beta gamma delta"])
    }

    func testPhrasesDoNotSpanSentenceBoundaries() {
        // The period splits the stream; neither 3-token sentence crosses it.
        let p = WordFrequencyStore.phrases(in: "alpha beta gamma. delta epsilon zeta")
        XCTAssertEqual(Set(p), Set(["alpha beta gamma", "delta epsilon zeta"]))
        XCTAssertFalse(p.contains("gamma delta epsilon"))
    }

    func testPhrasesSplitOnNewline() {
        let p = WordFrequencyStore.phrases(in: "one two three\nfour five six")
        XCTAssertEqual(Set(p), Set(["one two three", "four five six"]))
    }

    func testPhrasesRequireAtLeastOneContentWord() {
        // All four tokens are ≥3 chars (so none are dropped by the length filter),
        // and "and"/"the"/"but" are stop words while "parrot" is content.
        let p = WordFrequencyStore.phrases(in: "and the but parrot")
        // trigrams: [and the but] (all stop → drop), [the but parrot] (has "parrot" → keep)
        XCTAssertEqual(p, ["the but parrot"])
    }

    func testPhrasesTooShortSentenceYieldsNothing() {
        XCTAssertTrue(WordFrequencyStore.phrases(in: "just two").isEmpty)
        XCTAssertTrue(WordFrequencyStore.phrases(in: "one. two. three.").isEmpty)
    }

    // MARK: record

    func testRecordIncrementsWordCounts() {
        let store = WordFrequencyStore()
        store.record(text: "parrot parrot macaw")
        XCTAssertEqual(store.words["parrot"], 2)
        XCTAssertEqual(store.words["macaw"], 1)
        XCTAssertNil(store.words["the"], "stop words are never counted")
    }

    func testRecordAccumulatesAcrossCalls() {
        let store = WordFrequencyStore()
        store.record(text: "parrot")
        store.record(text: "parrot")
        XCTAssertEqual(store.words["parrot"], 2)
    }

    func testRecordBuildsPhraseCounts() {
        let store = WordFrequencyStore()
        store.record(text: "the quick brown parrot")
        // "the quick brown" & "quick brown parrot" both carry a content word.
        XCTAssertEqual(store.phrases["the quick brown"], 1)
        XCTAssertEqual(store.phrases["quick brown parrot"], 1)
    }

    func testRecordEmptyTextIsNoOp() {
        let store = WordFrequencyStore()
        store.record(text: "")
        store.record(text: "   .!?  ")
        XCTAssertTrue(store.words.isEmpty)
        XCTAssertTrue(store.phrases.isEmpty)
    }

    // MARK: record → purge round trip

    func testRecordThenPurgeReturnsToEmpty() {
        let store = WordFrequencyStore()
        let text = "The context-aware parrot doesn't forget your jargon. It learns claude md fast."
        store.record(text: text)
        XCTAssertFalse(store.words.isEmpty)
        XCTAssertFalse(store.phrases.isEmpty)

        store.purge(text: text)
        XCTAssertTrue(store.words.isEmpty, "purge must be the exact inverse of record (words)")
        XCTAssertTrue(store.phrases.isEmpty, "purge must be the exact inverse of record (phrases)")
    }

    func testPurgeDecrementsButKeepsSurvivingCounts() {
        let store = WordFrequencyStore()
        store.record(text: "parrot parrot")   // parrot → 2
        store.record(text: "parrot macaw")    // parrot → 3, macaw → 1
        store.purge(text: "parrot macaw")     // parrot → 2, macaw → 0 (dropped)
        XCTAssertEqual(store.words["parrot"], 2)
        XCTAssertNil(store.words["macaw"], "an entry decremented to 0 is dropped")
    }

    func testPurgeFloorsAtZeroForUnknownText() {
        let store = WordFrequencyStore()
        store.record(text: "parrot")
        // Purging text never recorded must not push any count negative or crash.
        store.purge(text: "elephant giraffe hippopotamus")
        XCTAssertEqual(store.words["parrot"], 1)
        XCTAssertNil(store.words["elephant"])
    }

    // MARK: clearAll / reset

    func testClearAllEmptiesBoth() {
        let store = WordFrequencyStore()
        store.record(text: "the quick brown parrot flies south")
        XCTAssertFalse(store.words.isEmpty)
        store.clearAll()
        XCTAssertTrue(store.words.isEmpty)
        XCTAssertTrue(store.phrases.isEmpty)
    }

    func testResetIsClearAll() {
        let store = WordFrequencyStore()
        store.record(text: "parrot macaw toucan cockatoo")
        store.reset()
        XCTAssertTrue(store.words.isEmpty)
        XCTAssertTrue(store.phrases.isEmpty)
    }

    // MARK: Cap eviction

    func testWordCapEvictsLowestCounts() {
        let store = WordFrequencyStore()

        // A genuine favourite earns a high count while the map is still under cap
        // (the realistic path: it accumulates over time, not in one flooded save).
        let vip = "zzzzvip"
        for _ in 0..<10 { store.record(text: vip) }
        XCTAssertEqual(store.words[vip], 10)

        // Now flood the store past the cap with distinct singletons.
        let over = WordFrequencyStore.wordCap + 50
        for t in uniqueTokens(count: over) { store.record(text: t) }

        XCTAssertLessThanOrEqual(store.words.count, WordFrequencyStore.wordCap,
                                 "word map must be held to the cap on save")
        XCTAssertEqual(store.words[vip], 10,
                       "a high-count favourite outranks the singletons and survives eviction")
    }

    func testPhraseCapHoldsUnderLoad() {
        let store = WordFrequencyStore()
        // Each sentence of 3 unique tokens contributes exactly one trigram.
        let over = WordFrequencyStore.phraseCap + 40
        let toks = uniqueTokens(count: over * 3, prefix: "p")
        for i in 0..<over {
            let a = toks[i * 3], b = toks[i * 3 + 1], c = toks[i * 3 + 2]
            store.record(text: "\(a) \(b) \(c).")
        }
        XCTAssertLessThanOrEqual(store.phrases.count, WordFrequencyStore.phraseCap,
                                 "phrase map must be held to the cap on save")
    }

    // MARK: Persistence

    func testPersistsAndReloads() {
        do {
            let store = WordFrequencyStore()
            store.record(text: "the persistent parrot remembers everything")
        }
        // A fresh instance reads the same fixed path.
        let reloaded = WordFrequencyStore()
        XCTAssertEqual(reloaded.words["persistent"], 1)
        XCTAssertEqual(reloaded.words["parrot"], 1)
        XCTAssertEqual(reloaded.phrases["the persistent parrot"], 1)
    }

    func testCorruptFileLoadsEmpty() {
        // Write garbage to the store path, then construct: decode fails → empty,
        // no crash, no throw.
        try? Data("}{ not json at all".utf8).write(to: fileURL, options: .atomic)
        let store = WordFrequencyStore()
        XCTAssertTrue(store.words.isEmpty, "a corrupt file must decode to an empty store")
        XCTAssertTrue(store.phrases.isEmpty)
        // And the store is still usable afterward.
        store.record(text: "recovered parrot flies again")
        XCTAssertEqual(store.words["recovered"], 1)
    }

    func testMissingFileLoadsEmpty() {
        // setUp already removed the file.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let store = WordFrequencyStore()
        XCTAssertTrue(store.words.isEmpty)
        XCTAssertTrue(store.phrases.isEmpty)
    }

    // MARK: Helpers

    /// N distinct lowercase tokens guaranteed clear of the stop-word set and the
    /// 3–24 length bounds (e.g. "qaaaa", "qaaab", …). Deterministic.
    private func uniqueTokens(count: Int, prefix: String = "q") -> [String] {
        var out: [String] = []
        var i = 0
        while out.count < count {
            let suffix = String(i, radix: 36) // 0-9a-z
            let token = prefix + String(repeating: "a", count: max(0, 4 - suffix.count)) + suffix
            if !WordFrequencyStore.stopWords.contains(token) { out.append(token) }
            i += 1
        }
        return out
    }
}
