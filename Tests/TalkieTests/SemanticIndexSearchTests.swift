import XCTest
@testable import Talkie

/// Pure-logic tests for `SemanticIndex` scoring — the blend of semantic cosine
/// and keyword overlap. No NL model I/O is required: `blendedScore` is exercised
/// directly, and the `search` assertions hold regardless of whether the on-device
/// embedding model is present (keyword overlap drives inclusion of an exact hit).
final class SemanticIndexSearchTests: XCTestCase {

    // MARK: blendedScore — the negative-cosine regression (P1-13)

    func testExactKeywordHitSurvivesNegativeCosine() {
        // A document that literally contains the query word (keyword == 1) must
        // never be dropped by an anti-correlated embedding (cosine == -1).
        // Old formula: 0.7 * (-1) + 0.3 * 1 = -0.4  -> dropped (score <= 0).
        // Fixed:       0.7 * max(0, -1) + 0.3 * 1 = 0.3 -> kept.
        let score = SemanticIndex.blendedScore(semantic: -1, keyword: 1)
        XCTAssertGreaterThan(score, 0, "an exact keyword hit must survive a negative cosine")
        XCTAssertEqual(score, 0.3, accuracy: 1e-9)
    }

    func testNegativeCosineClampsToZeroNotBelow() {
        // The semantic term is floored at 0; a more negative cosine can't push the
        // blended score any lower than a zero cosine would.
        XCTAssertEqual(SemanticIndex.blendedScore(semantic: -1, keyword: 0.5),
                       SemanticIndex.blendedScore(semantic: 0, keyword: 0.5),
                       accuracy: 1e-9)
    }

    func testPositiveCosineUnaffectedByClamp() {
        // Clamping is a no-op for non-negative cosines: ranking among real matches
        // is preserved exactly as before.
        XCTAssertEqual(SemanticIndex.blendedScore(semantic: 0.8, keyword: 0.5),
                       0.7 * 0.8 + 0.3 * 0.5, accuracy: 1e-9)
    }

    func testNoSignalScoresZero() {
        XCTAssertEqual(SemanticIndex.blendedScore(semantic: 0, keyword: 0), 0, accuracy: 1e-9)
    }

    // MARK: search — exact keyword hit is returned (end-to-end, model-agnostic)

    func testSearchReturnsRecordContainingExactQueryToken() {
        let records = [
            SearchRecord(id: "dictation:1", text: "Discussed the quarterly budget forecast",
                         kind: .dictation, dateUnix: 0),
            SearchRecord(id: "dictation:2", text: "Lunch plans for the weekend trip",
                         kind: .dictation, dateUnix: 0),
        ]
        let index = SemanticIndex(records: records)
        let hits = index.search("budget")

        // The record that literally contains "budget" is present, with a positive
        // score, regardless of the semantic cosine's sign.
        XCTAssertTrue(hits.contains { $0.id == "dictation:1" },
                      "an exact keyword match must always be returned")
        let hit = hits.first { $0.id == "dictation:1" }
        XCTAssertNotNil(hit)
        XCTAssertGreaterThan(hit?.score ?? 0, 0)
    }
}
