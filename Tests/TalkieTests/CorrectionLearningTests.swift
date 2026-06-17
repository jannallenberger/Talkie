import XCTest
@testable import Talkie

/// P2-12 (data-integrity): a single spoken edit must NOT become a permanent
/// global whole-word replacement. Two guards work together, both tested here as
/// pure logic:
///   1. `CorrectionLedger` — require N≥3 observations of the SAME correction
///      before it's promoted to a persisted rule.
///   2. `CorrectionExtractor.isPlausibleCorrection` — a respelling-only floor
///      (shared prefix / small edit distance) so an unrelated word swap is never
///      learned regardless of how often it's seen.
final class CorrectionLearningTests: XCTestCase {

    // MARK: Threshold (N≥3)

    /// 1–2 observations are NOT persisted; the 3rd identical observation is.
    func testThirdIdenticalObservationPersists() {
        var ledger = CorrectionLedger()
        XCTAssertEqual(CorrectionLedger.threshold, 3)

        XCTAssertFalse(ledger.observe(from: "correlate", to: "Coralate"), "1st → pending")
        XCTAssertFalse(ledger.observe(from: "correlate", to: "Coralate"), "2nd → pending")
        XCTAssertTrue(ledger.observe(from: "correlate", to: "Coralate"), "3rd → persist")
    }

    /// Promotion fires EXACTLY once (on the crossing observation), not again.
    func testPromotionFiresOnlyOnce() {
        var ledger = CorrectionLedger()
        _ = ledger.observe(from: "api", to: "API")
        _ = ledger.observe(from: "api", to: "API")
        XCTAssertTrue(ledger.observe(from: "api", to: "API"))  // crosses
        XCTAssertFalse(ledger.observe(from: "api", to: "API"), "already a rule → no re-add")
    }

    /// Candidates are keyed case-insensitively on the (from→to) pair, and
    /// distinct pairs accumulate independently.
    func testKeyingAndIndependentCounts() {
        var ledger = CorrectionLedger()
        _ = ledger.observe(from: "Correlate", to: "Coralate")  // case-insensitive
        XCTAssertEqual(ledger.count(from: "correlate", to: "coralate"), 1)

        _ = ledger.observe(from: "teh", to: "the")
        XCTAssertEqual(ledger.count(from: "correlate", to: "coralate"), 1, "other pair didn't bump this one")
        XCTAssertEqual(ledger.count(from: "teh", to: "the"), 1)
    }

    // MARK: Plausibility floor

    /// Genuine respellings pass the plausibility floor.
    func testPlausibleRespellingsPass() {
        XCTAssertTrue(CorrectionExtractor.isPlausibleCorrection(from: "correlate", to: "coralate"))
        XCTAssertTrue(CorrectionExtractor.isPlausibleCorrection(from: "cubernets", to: "kubernetes"))
        XCTAssertTrue(CorrectionExtractor.isPlausibleCorrection(from: "teh", to: "the"))
        XCTAssertTrue(CorrectionExtractor.isPlausibleCorrection(from: "definately", to: "definitely"))
    }

    /// Unrelated words (far edit distance, no shared prefix) are rejected.
    func testImplausibleSwapsRejected() {
        XCTAssertFalse(CorrectionExtractor.isPlausibleCorrection(from: "cat", to: "dog"))
        XCTAssertFalse(CorrectionExtractor.isPlausibleCorrection(from: "hello", to: "goodbye"))
        XCTAssertFalse(CorrectionExtractor.isPlausibleCorrection(from: "banana", to: "telephone"))
        XCTAssertFalse(CorrectionExtractor.isPlausibleCorrection(from: "apple", to: "apple"), "identical isn't a correction")
    }

    /// A far-distance pair is NEVER persisted even if observed past the
    /// threshold — the extractor would never emit it, so the ledger never sees
    /// it. We assert the floor directly to lock that contract in.
    func testImplausiblePairNeverPersistsRegardlessOfCount() {
        let from = "cat", to = "dog"
        XCTAssertFalse(CorrectionExtractor.isPlausibleCorrection(from: from, to: to))
        // Even if something tried to feed it repeatedly, the floor is the gate.
        var ledger = CorrectionLedger()
        for _ in 0..<5 {
            // Guard mirrors extract(): only plausible pairs reach the ledger.
            if CorrectionExtractor.isPlausibleCorrection(from: from, to: to) {
                _ = ledger.observe(from: from, to: to)
            }
        }
        XCTAssertEqual(ledger.count(from: from, to: to), 0, "implausible pair must never be counted")
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

    // MARK: Extractor end-to-end (floor wired in)

    /// A plausible single-word swap is extracted...
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

    /// ...but an implausible single-word swap is dropped by the floor.
    func testExtractDropsImplausibleSwap() {
        let result = CorrectionExtractor.extract(
            before: "the cat ran",
            after: "the dog ran",
            inserted: "the cat ran"
        )
        XCTAssertTrue(result.isEmpty, "an unrelated word swap must not be learned")
    }
}
