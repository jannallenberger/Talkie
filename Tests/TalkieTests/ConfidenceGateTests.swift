import XCTest
@testable import Talkie

/// Pure-logic tests for `ConfidenceGate` — the low-confidence review gate (A12).
/// This IS the shippable gate: the floor *value* is pending a human tuning pass
/// against real sessions, but the fire/suppress *logic* is pinned exhaustively
/// here. No disk, no recognizer, no clock — every input is a plain array.
///
/// The gate's contract, restated as invariants under test:
///   • never fires below `minDictationWords` (commands / one-liners),
///   • flags only word-like tokens ≥ `minWordLength` with confidence < `floor`,
///   • fires only when 1…`maxFlagged` words are flagged,
///   • suppresses a word the corrector already fixed this session,
///   • never flags a common word, a number, or punctuation.
final class ConfidenceGateTests: XCTestCase {

    /// Build a ≥ `minDictationWords` confidence array from high-confidence filler
    /// plus the caller's specific (word, confidence) pairs, so each test controls
    /// exactly the words it cares about while clearing the length gate.
    private func session(_ pairs: [(String, Double)], padTo count: Int = ConfidenceGate.minDictationWords)
        -> [WordConfidence] {
        var out = pairs.map { WordConfidence(word: $0.0, confidence: $0.1) }
        var i = 0
        while out.count < count {
            out.append(WordConfidence(word: "word\(i)", confidence: 0.95))
            i += 1
        }
        return out
    }

    // MARK: Length gate

    /// A short utterance (below the word floor) never shows the chip, even with a
    /// blatantly unsure jargon word — that's the command / one-liner case.
    func testBelowWordFloorNeverFires() {
        let wc = [
            WordConfidence(word: "deploy", confidence: 0.9),
            WordConfidence(word: "kubectl", confidence: 0.10),
        ]
        XCTAssertFalse(ConfidenceGate.evaluate(wordConfidences: wc).shouldShowChip,
                       "A 2-word utterance is below minDictationWords and must not fire the chip.")
    }

    /// Exactly at the word floor, an unsure jargon word does fire.
    func testAtWordFloorFires() {
        let wc = session([("kubernetes", 0.20)]) // padded to exactly minDictationWords
        XCTAssertEqual(wc.count, ConfidenceGate.minDictationWords)
        let decision = ConfidenceGate.evaluate(wordConfidences: wc)
        XCTAssertTrue(decision.shouldShowChip, "At minDictationWords a low-confidence jargon word should fire.")
        XCTAssertEqual(decision.flaggedWords, ["kubernetes"])
    }

    // MARK: Confidence floor

    /// A word at or above the floor is never flagged; the chip stays hidden when
    /// nothing dips below it.
    func testConfidentWordsNeverFlagged() {
        let wc = session([("kubernetes", ConfidenceGate.floor)]) // exactly at floor → NOT below
        XCTAssertFalse(ConfidenceGate.evaluate(wordConfidences: wc).shouldShowChip,
                       "confidence == floor is not < floor, so it must not be flagged.")
    }

    /// Just under the floor is flagged.
    func testJustUnderFloorFlagged() {
        let wc = session([("parakeet", ConfidenceGate.floor - 0.001)])
        XCTAssertEqual(ConfidenceGate.evaluate(wordConfidences: wc).flaggedWords, ["parakeet"])
    }

    // MARK: Word-likeness + length

    /// Short low-confidence tokens (< minWordLength) are ignored — they're the
    /// function words / fillers where a confidence dip is noise.
    func testShortWordsIgnored() {
        // "the" (3) and "of" (2) below the floor must not flag; the utterance is
        // otherwise all-confident, so the chip stays hidden.
        let wc = session([("the", 0.10), ("of", 0.05)])
        XCTAssertFalse(ConfidenceGate.evaluate(wordConfidences: wc).shouldShowChip,
                       "Tokens shorter than minWordLength must never be flagged.")
    }

    /// A low-confidence pure-number token is not a spelling the dictionary can fix,
    /// so it's never flagged.
    func testNumbersNotFlagged() {
        let wc = session([("2024", 0.10), ("42", 0.05)])
        XCTAssertFalse(ConfidenceGate.evaluate(wordConfidences: wc).shouldShowChip,
                       "Number-only tokens are not reviewable spellings.")
    }

    /// Bare punctuation is never word-like.
    func testPunctuationNotFlagged() {
        let wc = session([("——", 0.05), (".", 0.01), (",", 0.02)])
        XCTAssertFalse(ConfidenceGate.evaluate(wordConfidences: wc).shouldShowChip,
                       "Punctuation tokens are not reviewable words.")
    }

    /// Real jargon shapes with internal joiners (kebab/dotted/pathy) ARE word-like
    /// and get flagged when unsure.
    func testJargonWithJoinersIsWordLike() {
        XCTAssertTrue(ConfidenceGate.isWordLike("claude.md"))
        XCTAssertTrue(ConfidenceGate.isWordLike("read-me"))
        XCTAssertTrue(ConfidenceGate.isWordLike("snake_case"))
        XCTAssertTrue(ConfidenceGate.isWordLike("src/main"))
        let wc = session([("claude.md", 0.15)])
        XCTAssertEqual(ConfidenceGate.evaluate(wordConfidences: wc).flaggedWords, ["claude.md"])
    }

    // MARK: Common-word suppression

    /// A common word must never be flagged even when the recognizer reports low
    /// confidence — the model gets these right; a dip is a calibration artifact.
    func testCommonWordNeverFlagged() {
        // "about" and "there" are in the built-in common set; low confidence must
        // not surface them.
        let wc = session([("about", 0.10), ("there", 0.12)])
        XCTAssertFalse(ConfidenceGate.evaluate(wordConfidences: wc).shouldShowChip,
                       "Common words are never review candidates.")
    }

    // MARK: Count ceiling

    /// More than `maxFlagged` unsure words means the whole utterance was off — the
    /// gate declines rather than throwing up a wall of chips.
    func testTooManyFlaggedSuppresses() {
        let wc = session([
            ("kubernetes", 0.10), ("parakeet", 0.10),
            ("higgsfield", 0.10), ("coralate", 0.10), // 4 > maxFlagged (3)
        ], padTo: 10)
        XCTAssertFalse(ConfidenceGate.evaluate(wordConfidences: wc).shouldShowChip,
                       "Above maxFlagged the utterance is broadly wrong — no spot-fix chip.")
    }

    /// Exactly `maxFlagged` unsure words fires, and the flagged list is capped at
    /// that count in transcript order.
    func testAtMaxFlaggedFires() {
        let wc = session([
            ("kubernetes", 0.10), ("parakeet", 0.12), ("higgsfield", 0.14),
        ], padTo: 10)
        let decision = ConfidenceGate.evaluate(wordConfidences: wc)
        XCTAssertTrue(decision.shouldShowChip)
        XCTAssertEqual(decision.flaggedWords, ["kubernetes", "parakeet", "higgsfield"],
                       "All three (== maxFlagged) flag, in spoken order.")
    }

    // MARK: Already-fixed suppression (the corrector did its job)

    /// When the niche corrector already fixed a word this session, the chip is
    /// suppressed for it — comparison is case-insensitive against the heard token.
    func testAlreadyFixedWordSuppressed() {
        let wc = session([("higgsfield", 0.10)])
        // The corrector swapped "Higgs field" → "Higgsfield"; the heard token here
        // ("higgsfield") is the canonical spelling, so it must not be re-offered.
        let decision = ConfidenceGate.evaluate(wordConfidences: wc, alreadyFixed: ["Higgsfield"])
        XCTAssertFalse(decision.shouldShowChip,
                       "A word the corrector already fixed this session is suppressed.")
    }

    /// Suppressing an already-fixed word still lets a *different* unsure word fire.
    func testAlreadyFixedSuppressesOnlyThatWord() {
        let wc = session([("higgsfield", 0.10), ("parakeet", 0.12)])
        let decision = ConfidenceGate.evaluate(wordConfidences: wc, alreadyFixed: ["higgsfield"])
        XCTAssertEqual(decision.flaggedWords, ["parakeet"],
                       "Only the already-fixed word is dropped; other unsure words remain.")
    }

    // MARK: De-duplication

    /// The same unsure word heard twice is one review item, not two.
    func testDuplicateUnsureWordDeduped() {
        let wc = session([("kubectl", 0.10), ("kubectl", 0.12)], padTo: 8)
        XCTAssertEqual(ConfidenceGate.evaluate(wordConfidences: wc).flaggedWords, ["kubectl"],
                       "A repeated unsure word collapses to a single flagged entry.")
    }

    // MARK: Empty / clean transcripts

    /// A clean, confident dictation of ample length shows nothing — the common case.
    func testCleanDictationShowsNothing() {
        let wc = (0..<12).map { WordConfidence(word: "word\($0)", confidence: 0.9) }
        XCTAssertFalse(ConfidenceGate.evaluate(wordConfidences: wc).shouldShowChip,
                       "Ordinary confident speech must not surface the chip.")
    }

    /// No confidences at all (e.g. the recognizer emitted none) never fires.
    func testEmptyConfidencesNeverFires() {
        XCTAssertFalse(ConfidenceGate.evaluate(wordConfidences: []).shouldShowChip)
    }
}
