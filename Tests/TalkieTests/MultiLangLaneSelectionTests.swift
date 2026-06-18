import XCTest
@testable import Talkie

/// The lane-selection cap (P2-06): N spoken languages × {mic, far-end} must not
/// spin up an unbounded number of live recognizers. `selectLaneLocales` is the
/// pure seam that bounds the candidate locales per stream.
final class MultiLangLaneSelectionTests: XCTestCase {
    private func select(_ ids: [String], limit: Int = MultiLangStreamTranscriber.maxLanes) -> [String] {
        MultiLangStreamTranscriber.selectLaneLocales(ids, limit: limit)
    }

    /// Within budget: the list passes through unchanged.
    func testUnderBudgetPassesThrough() {
        XCTAssertEqual(select(["en-US", "de-DE"]), ["en-US", "de-DE"])
    }

    /// Over budget: capped to `maxLanes`, keeping the first (primary) locales —
    /// the first lane is the live-segment lane, so order must be preserved.
    func testOverBudgetCapsToMaxLanesKeepingOrder() {
        let ids = ["en-US", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR"]
        let picked = select(ids)
        XCTAssertEqual(picked.count, MultiLangStreamTranscriber.maxLanes)
        XCTAssertEqual(picked, Array(ids.prefix(MultiLangStreamTranscriber.maxLanes)))
        XCTAssertEqual(picked.first, "en-US")
    }

    /// An explicit smaller budget is honored.
    func testExplicitLimitHonored() {
        XCTAssertEqual(select(["en-US", "de-DE", "fr-FR"], limit: 2), ["en-US", "de-DE"])
    }

    /// Duplicates (and blank entries) are dropped before the cap, so the budget
    /// counts distinct lanes, not raw input length.
    func testDeduplicatesAndDropsBlanksPreservingOrder() {
        let picked = select(["en-US", "en-US", "  ", "de-DE", "en-US"])
        XCTAssertEqual(picked, ["en-US", "de-DE"])
    }

    /// Defensive edges: empty input and a non-positive limit yield no lanes.
    func testEmptyAndNonPositiveLimit() {
        XCTAssertEqual(select([]), [])
        XCTAssertEqual(select(["en-US", "de-DE"], limit: 0), [])
        XCTAssertEqual(select(["en-US"], limit: -3), [])
    }

    /// The cap is a sane positive ceiling.
    func testMaxLanesIsPositive() {
        XCTAssertGreaterThan(MultiLangStreamTranscriber.maxLanes, 1)
    }
}
