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

/// A8 — the transcript editor learns from a whole-note edit, not a single live
/// field change. `TranscriptEditCorrections.extract` segments the edit into
/// contiguous changed regions and reuses `CorrectionExtractor.extract` on each, so
/// a note fixed in several places at once teaches several rules — while the same
/// respelling-only guards still reject deletions, rewrites, and prose edits.
final class TranscriptEditCorrectionsTests: XCTestCase {

    // MARK: The single-fix case still works

    /// One respelling in a longer transcript → exactly one rule (the acceptance
    /// criterion: "cloud MD" → "claude.md" offers exactly one learn chip).
    func testSingleRespellingInTranscript() {
        let before = "We talked about the cloud MD file and the deploy plan for next week."
        let after = "We talked about the claude.md file and the deploy plan for next week."
        let result = TranscriptEditCorrections.extract(before: before, after: after)
        XCTAssertEqual(result.count, 1, "one changed region → one rule")
        XCTAssertEqual(result.first?.from, "cloud MD")
        XCTAssertEqual(result.first?.to, "claude.md")
    }

    /// A single-word respelling mid-transcript.
    func testSingleWordRespelling() {
        let result = TranscriptEditCorrections.extract(
            before: "the correlate engine indexes everything",
            after: "the coralate engine indexes everything"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.from.lowercased(), "correlate")
        XCTAssertEqual(result.first?.to.lowercased(), "coralate")
    }

    // MARK: The multi-fix case CorrectionExtractor alone cannot do

    /// Two scattered fixes in one save. `CorrectionExtractor.extract` over the whole
    /// string returns nothing (the middle spans both edits); the region splitter
    /// teaches BOTH. This is the core reason A8 needs a splitter.
    func testTwoScatteredRespellingsBothLearned() {
        let before = "First we synced on cloud MD then reviewed the cubernetis rollout carefully."
        let after = "First we synced on claude.md then reviewed the kubernetes rollout carefully."

        // Baseline: the single-region extractor gives up on this shape.
        XCTAssertTrue(
            CorrectionExtractor.extract(before: before, after: after, inserted: before).isEmpty,
            "whole-transcript extract can't isolate two scattered fixes")

        let result = TranscriptEditCorrections.extract(before: before, after: after)
        XCTAssertEqual(result.count, 2, "each changed region teaches its own rule")
        let pairs = Dictionary(uniqueKeysWithValues: result.map { ($0.from.lowercased(), $0.to.lowercased()) })
        XCTAssertEqual(pairs["cloud md"], "claude.md")
        XCTAssertEqual(pairs["cubernetis"], "kubernetes")
    }

    /// Three fixes, in reading order.
    func testThreeFixesInReadingOrder() {
        let before = "alpha talked to correlate about cubernetis and the cloud MD doc"
        let after = "alpha talked to coralate about kubernetes and the claude.md doc"
        let result = TranscriptEditCorrections.extract(before: before, after: after)
        XCTAssertEqual(result.map { $0.to.lowercased() },
                       ["coralate", "kubernetes", "claude.md"],
                       "rules come back in the order they appear in the transcript")
    }

    /// A merge fix ("Higgs field" → "Higgsfield") embedded in a transcript region.
    func testMergeFixInTranscript() {
        let before = "the Higgs field results were surprising to everyone on the call"
        let after = "the Higgsfield results were surprising to everyone on the call"
        let result = TranscriptEditCorrections.extract(before: before, after: after)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.from, "Higgs field")
        XCTAssertEqual(result.first?.to, "Higgsfield")
    }

    // MARK: Non-respelling edits teach nothing (acceptance: delete a paragraph)

    /// Deleting a whole sentence/paragraph is not a respelling → no rules.
    func testDeletingParagraphTeachesNothing() {
        let before = "Intro line here. This entire middle sentence gets removed. Closing line here."
        let after = "Intro line here. Closing line here."
        let result = TranscriptEditCorrections.extract(before: before, after: after)
        XCTAssertTrue(result.isEmpty, "a deletion is not a respelling")
    }

    /// Inserting new words teaches nothing.
    func testInsertingWordsTeachesNothing() {
        let before = "we shipped the build"
        let after = "we finally shipped the whole build today"
        let result = TranscriptEditCorrections.extract(before: before, after: after)
        XCTAssertTrue(result.isEmpty, "pure insertions aren't corrections")
    }

    /// Swapping to an unrelated word is rejected by the plausibility floor.
    func testUnrelatedWordSwapRejected() {
        let result = TranscriptEditCorrections.extract(
            before: "the cat sat on the mat quietly",
            after: "the dog sat on the mat quietly")
        XCTAssertTrue(result.isEmpty, "an unrelated swap must not be learned")
    }

    /// A rewrite of a clause (multiple words changed with no 1↔N shape) teaches
    /// nothing — each region fails the respelling guard.
    func testClauseRewriteTeachesNothing() {
        let before = "the meeting was about the quarterly budget numbers"
        let after = "the meeting covered next year hiring plans instead"
        let result = TranscriptEditCorrections.extract(before: before, after: after)
        XCTAssertTrue(result.isEmpty, "a multi-word rewrite is not a respelling")
    }

    /// No change at all → nothing.
    func testNoChange() {
        let text = "nothing here changed at all between the two versions"
        XCTAssertTrue(TranscriptEditCorrections.extract(before: text, after: text).isEmpty)
    }

    /// Duplicate identical fixes (same word mis-spelled twice, both corrected the
    /// same way) collapse to one rule.
    func testDuplicateFixesDeduped() {
        let before = "cubernetis here and cubernetis there and cubernetis everywhere else"
        let after = "kubernetes here and kubernetes there and kubernetes everywhere else"
        let result = TranscriptEditCorrections.extract(before: before, after: after)
        XCTAssertEqual(result.count, 1, "the same from→to fix is only offered once")
        XCTAssertEqual(result.first?.to.lowercased(), "kubernetes")
    }

    /// The region cap bounds how many rules one save can yield. Eight distinct
    /// respellings, each a lone changed word between unchanged anchor words (so the
    /// splitter sees eight separate regions, not one rewrite); the cap is 5.
    func testRegionCapBoundsResults() {
        let before = "xx aaaa yy bbbb zz cccc qq dddd ww eeee rr ffff tt gggg pp hhhh vv"
        let after  = "xx aaab yy bbbc zz cccd qq ddde ww eeef rr fffg tt gggh pp hhhi vv"
        let result = TranscriptEditCorrections.extract(before: before, after: after)
        XCTAssertEqual(result.count, TranscriptEditCorrections.maxRegions,
                       "a huge rewrite can't spew more than the cap")
    }

    /// With no unchanged context BETWEEN two adjacent changed words, the edit reads
    /// as one wide rewrite region (nothing to anchor on), so it teaches nothing —
    /// the conservative, correct behavior. This documents the anchoring dependency.
    func testAdjacentChangesWithoutAnchorTeachNothing() {
        let result = TranscriptEditCorrections.extract(
            before: "correlate cubernetis",
            after: "coralate kubernetes")
        XCTAssertTrue(result.isEmpty,
                      "two adjacent fixes with no unchanged word between them can't be separated")
    }
}
