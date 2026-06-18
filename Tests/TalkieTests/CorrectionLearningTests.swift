import XCTest
@testable import Talkie

/// Live correction learning is pure-logic-tested through `CorrectionExtractor`:
/// given the field BEFORE an edit, the field AFTER, and the text Talkie inserted,
/// it extracts at most one trustworthy from→to rule. Two guards keep it safe:
///   1. The edit must be a localized SUBSTITUTION of words Talkie itself inserted
///      (1→1, or a merge/split where one side is a single word) — never an
///      insertion, a deletion, a scattered multi-region edit, or a change to the
///      user's own surrounding prose.
///   2. `isPlausibleCorrection` — a respelling-only floor (spacing fix / shared
///      prefix / small edit distance) so an unrelated word swap is never learned.
final class CorrectionLearningTests: XCTestCase {

    // MARK: Plausibility floor

    func testPlausibleRespellingsPass() {
        XCTAssertTrue(CorrectionExtractor.isPlausibleCorrection(from: "correlate", to: "coralate"))
        XCTAssertTrue(CorrectionExtractor.isPlausibleCorrection(from: "cubernets", to: "kubernetes"))
        XCTAssertTrue(CorrectionExtractor.isPlausibleCorrection(from: "teh", to: "the"))
        XCTAssertTrue(CorrectionExtractor.isPlausibleCorrection(from: "definately", to: "definitely"))
    }

    /// A pure spacing change (same letters) is the most plausible correction.
    func testSpacingMergeIsPlausible() {
        XCTAssertTrue(CorrectionExtractor.isPlausibleCorrection(from: "higgs field", to: "higgsfield"))
    }

    func testImplausibleSwapsRejected() {
        XCTAssertFalse(CorrectionExtractor.isPlausibleCorrection(from: "cat", to: "dog"))
        XCTAssertFalse(CorrectionExtractor.isPlausibleCorrection(from: "hello", to: "goodbye"))
        XCTAssertFalse(CorrectionExtractor.isPlausibleCorrection(from: "banana", to: "telephone"))
        XCTAssertFalse(CorrectionExtractor.isPlausibleCorrection(from: "apple", to: "apple"), "identical isn't a correction")
    }

    // MARK: Helper primitives

    func testLevenshtein() {
        XCTAssertEqual(CorrectionExtractor.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(CorrectionExtractor.levenshtein("", "abc"), 3)
        XCTAssertEqual(CorrectionExtractor.levenshtein("same", "same"), 0)
    }

    func testCommonPrefixLength() {
        XCTAssertEqual(CorrectionExtractor.commonPrefixLength("coralate", "correlate"), 3)
        XCTAssertEqual(CorrectionExtractor.commonPrefixLength("cat", "dog"), 0)
    }

    // MARK: Single-word respelling

    /// A plausible single-word swap is extracted immediately (no threshold).
    func testExtractEmitsPlausibleSwap() {
        let result = CorrectionExtractor.extract(
            before: "the correlate engine",
            after: "the coralate engine",
            inserted: "the correlate engine"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.from.lowercased(), "correlate")
        XCTAssertEqual(result.first?.to.lowercased(), "coralate")
    }

    /// An implausible single-word swap is dropped by the floor.
    func testExtractDropsImplausibleSwap() {
        let result = CorrectionExtractor.extract(
            before: "the cat ran",
            after: "the dog ran",
            inserted: "the cat ran"
        )
        XCTAssertTrue(result.isEmpty, "an unrelated word swap must not be learned")
    }

    // MARK: Merge / split (the two-word case that used to be dropped)

    /// Two spoken words merged into one ("Higgs field" → "Higgsfield").
    func testExtractMergeTwoWordsIntoOne() {
        let result = CorrectionExtractor.extract(
            before: "the Higgs field theory",
            after: "the Higgsfield theory",
            inserted: "the Higgs field theory"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.from, "Higgs field")
        XCTAssertEqual(result.first?.to, "Higgsfield")
    }

    /// One word split into two ("Higgsfield" → "Higgs field").
    func testExtractSplitOneWordIntoTwo() {
        let result = CorrectionExtractor.extract(
            before: "use Higgsfield here",
            after: "use Higgs field here",
            inserted: "use Higgsfield here"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.from, "Higgsfield")
        XCTAssertEqual(result.first?.to, "Higgs field")
    }

    // MARK: Safety — only learn substitutions of Talkie's own words

    /// Adding a word (insertion) is not a correction.
    func testExtractIgnoresPureInsertion() {
        let result = CorrectionExtractor.extract(
            before: "the field",
            after: "the open field",
            inserted: "the field"
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// Deleting a word is not a correction.
    func testExtractIgnoresPureDeletion() {
        let result = CorrectionExtractor.extract(
            before: "the open field",
            after: "the field",
            inserted: "the open field"
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// An edit to a word Talkie did NOT insert (the user's surrounding prose) is
    /// never learned — only corrections to our own output count.
    func testExtractIgnoresEditOutsideInsertion() {
        let result = CorrectionExtractor.extract(
            before: "hello world correlate",
            after: "hello word correlate",
            inserted: "correlate" // only this was ours; "world"→"word" is the user's text
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// Two scattered edits must not be fused into one bogus phrase rule.
    func testExtractIgnoresMultiRegionEdit() {
        let result = CorrectionExtractor.extract(
            before: "alpha bravo charlie delta",
            after: "Alpha bravo charlie Delta",
            inserted: "alpha bravo charlie delta"
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// No edit at all → nothing learned.
    func testExtractNoChange() {
        let result = CorrectionExtractor.extract(
            before: "steady as she goes",
            after: "steady as she goes",
            inserted: "steady as she goes"
        )
        XCTAssertTrue(result.isEmpty)
    }
}
