import XCTest
@testable import Talkie

/// L4: the milestone ladder is pure arithmetic against a fixed threshold set, so
/// it's tested exhaustively at every boundary — the exact-hit, one-below, and
/// one-above of each rung — plus the two edge regimes (below the first rung, past
/// the last) and multi-rung jumps. A rung is `>=`, so landing exactly on a
/// threshold counts as reaching it.
final class MilestoneLadderTests: XCTestCase {

    private var thresholds: [Int] { MilestoneLadder.thresholds }

    // MARK: thresholds shape

    func testThresholdsAreTheExpectedLadder() {
        XCTAssertEqual(MilestoneLadder.thresholds,
                       [10_000, 25_000, 50_000, 100_000, 250_000,
                        500_000, 750_000, 1_000_000, 2_000_000])
    }

    func testThresholdsAreStrictlyAscending() {
        for i in 1..<thresholds.count {
            XCTAssertLessThan(thresholds[i - 1], thresholds[i],
                              "ladder must be strictly ascending at index \(i)")
        }
    }

    // MARK: tier(for:)

    func testTierBelowFirstRungIsNil() {
        XCTAssertNil(MilestoneLadder.tier(for: 0))
        XCTAssertNil(MilestoneLadder.tier(for: 1))
        XCTAssertNil(MilestoneLadder.tier(for: 9_999))
    }

    func testTierExactlyOnFirstRungIsZero() {
        XCTAssertEqual(MilestoneLadder.tier(for: 10_000), 0)
    }

    func testTierAtEveryExactThresholdReturnsThatIndex() {
        for (i, t) in thresholds.enumerated() {
            XCTAssertEqual(MilestoneLadder.tier(for: t), i,
                           "total == thresholds[\(i)] (\(t)) should be tier \(i)")
        }
    }

    func testTierOneBelowEachThresholdReturnsPreviousIndex() {
        for (i, t) in thresholds.enumerated() {
            let expected: Int? = i == 0 ? nil : i - 1
            XCTAssertEqual(MilestoneLadder.tier(for: t - 1), expected,
                           "total == \(t - 1) (one below rung \(i)) should be tier \(String(describing: expected))")
        }
    }

    func testTierOneAboveEachThresholdReturnsThatIndex() {
        for (i, t) in thresholds.enumerated() {
            // One above a rung is still on that rung until the next threshold.
            XCTAssertEqual(MilestoneLadder.tier(for: t + 1), i,
                           "total == \(t + 1) (one above rung \(i)) should still be tier \(i)")
        }
    }

    func testTierWayAboveTopRungClampsToLastIndex() {
        XCTAssertEqual(MilestoneLadder.tier(for: 5_000_000), thresholds.count - 1)
        XCTAssertEqual(MilestoneLadder.tier(for: Int.max), thresholds.count - 1)
    }

    func testTierMidBandReturnsLowerRung() {
        // Halfway between 25k (idx1) and 50k (idx2) is still tier 1.
        XCTAssertEqual(MilestoneLadder.tier(for: 37_500), 1)
    }

    // MARK: next(after:)

    func testNextBelowFirstRungTargetsFirstRungFromZero() {
        let n = MilestoneLadder.next(after: 0)
        XCTAssertEqual(n?.threshold, 10_000)
        XCTAssertEqual(n?.progress ?? -1, 0, accuracy: 1e-9)
    }

    func testNextHalfwayIntoFirstBand() {
        let n = MilestoneLadder.next(after: 5_000)
        XCTAssertEqual(n?.threshold, 10_000)
        XCTAssertEqual(n?.progress ?? -1, 0.5, accuracy: 1e-9)
    }

    func testNextProgressMeasuredFromPreviousRung() {
        // Between 10k (prev) and 25k (next); 17,500 is exactly halfway.
        let n = MilestoneLadder.next(after: 17_500)
        XCTAssertEqual(n?.threshold, 25_000)
        XCTAssertEqual(n?.progress ?? -1, 0.5, accuracy: 1e-9)
    }

    func testNextExactlyOnARungTargetsTheFollowingRungAtZeroProgress() {
        // Sitting exactly on 25k: the next rung is 50k, and progress from 25k is 0.
        let n = MilestoneLadder.next(after: 25_000)
        XCTAssertEqual(n?.threshold, 50_000)
        XCTAssertEqual(n?.progress ?? -1, 0, accuracy: 1e-9)
    }

    func testNextJustBelowARungIsNearlyOne() {
        // One word below 25k: next is 25k, progress ~ (14_999/15_000).
        let n = MilestoneLadder.next(after: 24_999)
        XCTAssertEqual(n?.threshold, 25_000)
        XCTAssertEqual(n?.progress ?? -1, Double(14_999) / Double(15_000), accuracy: 1e-9)
    }

    func testNextAtTopRungIsNil() {
        XCTAssertNil(MilestoneLadder.next(after: 2_000_000))
    }

    func testNextPastTopRungIsNil() {
        XCTAssertNil(MilestoneLadder.next(after: 2_000_001))
        XCTAssertNil(MilestoneLadder.next(after: 10_000_000))
    }

    func testNextProgressAlwaysInUnitInterval() {
        for total in stride(from: 0, through: 2_100_000, by: 4_321) {
            if let p = MilestoneLadder.next(after: total)?.progress {
                XCTAssertGreaterThanOrEqual(p, 0, "progress < 0 at total \(total)")
                XCTAssertLessThanOrEqual(p, 1, "progress > 1 at total \(total)")
            }
        }
    }

    // MARK: crossed(from:to:)

    func testCrossedNoMovementIsNil() {
        XCTAssertNil(MilestoneLadder.crossed(from: 5_000, to: 5_000))
        XCTAssertNil(MilestoneLadder.crossed(from: 30_000, to: 30_000))
    }

    func testCrossedBackwardsIsNil() {
        XCTAssertNil(MilestoneLadder.crossed(from: 60_000, to: 20_000))
    }

    func testCrossedWithinSameBandIsNil() {
        // Both below the first rung.
        XCTAssertNil(MilestoneLadder.crossed(from: 100, to: 9_000))
        // Both in the [10k, 25k) band — no new rung.
        XCTAssertNil(MilestoneLadder.crossed(from: 11_000, to: 24_000))
    }

    func testCrossedFirstRungExactlyOnLanding() {
        // 9,999 → 10,000 clears rung 0.
        XCTAssertEqual(MilestoneLadder.crossed(from: 9_999, to: 10_000), 0)
    }

    func testCrossedSingleRung() {
        // Was on rung 0 (10k–25k), now reaches 25k → newly crossed rung 1.
        XCTAssertEqual(MilestoneLadder.crossed(from: 10_000, to: 25_000), 1)
    }

    func testCrossedReportsHighestOnMultiRungJump() {
        // From below everything straight to 300k: 300k is tier 4 (>=250k). The
        // biggest rung newly cleared is 4.
        XCTAssertEqual(MilestoneLadder.crossed(from: 0, to: 300_000), 4)
    }

    func testCrossedMultiRungFromMidLadder() {
        // From 30k (tier 1) to 1.2M (tier 7). Highest newly crossed is 7.
        XCTAssertEqual(MilestoneLadder.crossed(from: 30_000, to: 1_200_000), 7)
    }

    func testCrossedAllTheWayToTop() {
        XCTAssertEqual(MilestoneLadder.crossed(from: 0, to: 2_000_000), thresholds.count - 1)
        XCTAssertEqual(MilestoneLadder.crossed(from: 0, to: 9_999_999), thresholds.count - 1)
    }

    func testCrossedWhenAlreadyPastTargetIsNil() {
        // Already at the top rung; climbing higher crosses nothing new.
        XCTAssertNil(MilestoneLadder.crossed(from: 2_000_000, to: 3_000_000))
    }

    /// Walking the total up one rung at a time must fire each rung index exactly
    /// once, in order — the property that makes "celebrate on crossing" correct.
    func testCrossedFiresEachRungExactlyOnceOnMonotonicClimb() {
        var fired: [Int] = []
        var previous = 0
        // Step to just past each threshold in turn.
        for t in thresholds {
            let now = t // land exactly on the rung
            if let idx = MilestoneLadder.crossed(from: previous, to: now) {
                fired.append(idx)
            }
            previous = now
        }
        XCTAssertEqual(fired, Array(0..<thresholds.count))
    }
}
