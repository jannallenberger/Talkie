import XCTest
@testable import Talkie

/// The confidence-gated ("weighted") learned rule. When a correction's TARGET is
/// itself an ordinary dictionary word (e.g. "their"→"there"), Talkie must NOT
/// rewrite every future `from` blindly — that would clobber the times the user
/// really said `from`. Such a rule is stored *weighted* and fires only when the
/// recognizer was UNSURE it heard `from` this session; when it was confident,
/// `from` stands. Jargon targets the dictionary doesn't know (e.g. "Coralate")
/// stay HARD always-replace rules so they keep snapping every time.
///
/// These pin the pure, deterministic decision surface: `recognizerWasUnsure`, the
/// `apply` gate, and the classifier that routes a learned correction to the gated
/// or the hard path.
final class WeightedCorrectionTests: XCTestCase {

    // MARK: recognizerWasUnsure — "did the engine doubt it heard `from`?"

    func testUnsureWhenBelowFloor() {
        let confs = [WordConfidence(word: "their", confidence: 0.20)]
        XCTAssertTrue(TextProcessor.recognizerWasUnsure(about: "their", in: confs))
    }

    func testSureWhenAtOrAboveFloor() {
        let confs = [WordConfidence(word: "their", confidence: 0.90)]
        XCTAssertFalse(TextProcessor.recognizerWasUnsure(about: "their", in: confs))
    }

    func testNotUnsureWhenWordAbsent() {
        let confs = [WordConfidence(word: "there", confidence: 0.10)]
        XCTAssertFalse(TextProcessor.recognizerWasUnsure(about: "their", in: confs),
                       "a low confidence on a DIFFERENT word says nothing about `from`")
    }

    func testEmptyConfidencesAreNotUnsure() {
        XCTAssertFalse(TextProcessor.recognizerWasUnsure(about: "their", in: []))
    }

    /// Matching ignores case and surrounding punctuation ("Their," == "their").
    func testMatchIgnoresCaseAndPunctuation() {
        let confs = [WordConfidence(word: "Their,", confidence: 0.15)]
        XCTAssertTrue(TextProcessor.recognizerWasUnsure(about: "their", in: confs))
    }

    /// Any single low-confidence occurrence flips it, even beside a confident one.
    func testAnyLowOccurrenceCounts() {
        let confs = [
            WordConfidence(word: "their", confidence: 0.95),
            WordConfidence(word: "their", confidence: 0.18),
        ]
        XCTAssertTrue(TextProcessor.recognizerWasUnsure(about: "their", in: confs))
    }

    // MARK: apply() gate — weighted rules

    private func weighted(_ from: String, _ to: String) -> Replacement {
        Replacement(from: from, to: to, caseSensitive: false, wholeWord: true,
                    learned: true, weighted: true)
    }

    func testWeightedRuleFiresWhenUnsure() {
        let out = TextProcessor.apply(
            replacements: [weighted("their", "there")],
            removeFillers: false, autoCapitalize: false,
            to: "i left their",
            wordConfidences: [WordConfidence(word: "their", confidence: 0.20)]
        )
        XCTAssertEqual(out.text, "i left there", "unsure recognizer → prefer the learned word")
    }

    func testWeightedRuleHeldWhenConfident() {
        let out = TextProcessor.apply(
            replacements: [weighted("their", "there")],
            removeFillers: false, autoCapitalize: false,
            to: "i love their dog",
            wordConfidences: [WordConfidence(word: "their", confidence: 0.92)]
        )
        XCTAssertEqual(out.text, "i love their dog", "confident recognizer → `from` stands")
    }

    func testWeightedRuleHeldWithoutConfidences() {
        let out = TextProcessor.apply(
            replacements: [weighted("their", "there")],
            removeFillers: false, autoCapitalize: false,
            to: "over their"
        )
        XCTAssertEqual(out.text, "over their", "no confidence evidence → conservative, leave it")
    }

    /// The jargon path is untouched: a HARD (non-weighted) rule always applies,
    /// even with no confidences — so a learned "Coralate" keeps snapping every time.
    func testHardRuleAlwaysApplies() {
        let hard = Replacement(from: "correlate", to: "Coralate", learned: true) // weighted == nil
        let out = TextProcessor.apply(
            replacements: [hard],
            removeFillers: false, autoCapitalize: false,
            to: "the correlate engine"
        )
        XCTAssertEqual(out.text, "the Coralate engine")
    }

    // MARK: isOrdinaryDictionaryWord — routes a learned correction to a path

    /// A common dictionary word → the gated (weighted) path. Deterministic via the
    /// built-in common-word set, so this needs no spell-checker.
    @MainActor func testCommonWordIsOrdinary() {
        XCTAssertTrue(DictionaryStore.isOrdinaryDictionaryWord("there"))
        XCTAssertTrue(DictionaryStore.isOrdinaryDictionaryWord("their"))
    }

    /// A multi-word target is never a single dictionary word → hard path.
    /// Deterministic (short-circuits before the spell checker).
    @MainActor func testPhraseIsNotOrdinary() {
        XCTAssertFalse(DictionaryStore.isOrdinaryDictionaryWord("higgs field"))
    }

    /// Novel jargon the system dictionary doesn't know → hard always-replace path.
    @MainActor func testNonsenseWordIsNotOrdinary() {
        XCTAssertFalse(DictionaryStore.isOrdinaryDictionaryWord("xqzptlv"))
    }
}
