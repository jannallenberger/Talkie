import XCTest
@testable import Talkie

/// L5-a: the copy table must line up one-to-one with the ladder's rungs, and
/// every rung must resolve to a non-empty, localized name AND equivalence. These
/// guard against a rung being added to `MilestoneLadder.thresholds` without its
/// copy (or vice versa), and against a `.loc` key going missing from the catalogs
/// (a missing key makes `.loc` fall back to the English source — still non-empty —
/// so we additionally assert the equivalence keeps its honest "≈" marker).
final class MilestoneCopyTests: XCTestCase {

    func testCopyCoversEveryThreshold() {
        XCTAssertEqual(MilestoneCopy.all.count, MilestoneLadder.thresholds.count,
                       "copy table must have exactly one entry per ladder rung")
    }

    func testLadderCoversAllNineThresholds() {
        // The ladder is the fixed 9-rung set; copy must match it rung-for-rung.
        XCTAssertEqual(MilestoneLadder.thresholds.count, 9)
        XCTAssertEqual(MilestoneCopy.all.count, 9)
    }

    func testEveryTierIndexResolvesToNonEmptyNameAndEquivalence() {
        for i in 0..<MilestoneLadder.thresholds.count {
            guard let tier = MilestoneCopy.tier(i) else {
                return XCTFail("tier(\(i)) returned nil but is a valid rung index")
            }
            XCTAssertFalse(tier.name.trimmingCharacters(in: .whitespaces).isEmpty,
                           "tier \(i) name is empty")
            XCTAssertFalse(tier.equivalence.trimmingCharacters(in: .whitespaces).isEmpty,
                           "tier \(i) equivalence is empty")
        }
    }

    func testEveryEquivalenceKeepsTheApproximationMarker() {
        // Honesty guard: a dictated-word count is not finished prose, so every
        // equivalence must stay a playful approximation — never a strict claim.
        for (i, tier) in MilestoneCopy.all.enumerated() {
            XCTAssertTrue(tier.equivalence.contains("≈"),
                          "tier \(i) equivalence must keep the ≈ approximation marker: \(tier.equivalence)")
        }
    }

    func testTierIndexOutOfRangeIsNil() {
        XCTAssertNil(MilestoneCopy.tier(-1))
        XCTAssertNil(MilestoneCopy.tier(MilestoneLadder.thresholds.count))
        XCTAssertNil(MilestoneCopy.tier(999))
    }

    func testTierNamesAreDistinct() {
        let names = MilestoneCopy.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "tier names should be unique")
    }

    /// The names in the spec, in order — a change here should be deliberate.
    func testTierNamesMatchTheSpecOrder() {
        XCTAssertEqual(MilestoneCopy.all.map(\.name),
                       ["First Feathers", "Fledgling", "Finding Your Voice",
                        "Full Plumage", "Storyteller", "Silver Tongue",
                        "Golden Voice", "Legendary", "Mythical"])
    }
}
