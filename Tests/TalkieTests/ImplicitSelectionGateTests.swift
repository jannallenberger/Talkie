import XCTest
@testable import Talkie

/// Guards `ImplicitSelectionGate.eligible(...)` — the fallback that lets a
/// command like "make this a list" act on your last dictation when nothing is
/// selected. Every case here answers "would this let a rewrite command reach
/// backward and replace text it shouldn't." Mirrors the structure of
/// `CrossSurfaceFalsePositiveTests.swift` (a different command-safety issue
/// fixed earlier the same night): must-be-nil cases first (fail closed), then
/// must-be-eligible cases proving the happy path still works.
final class ImplicitSelectionGateTests: XCTestCase {
    private let sameApp = TargetApp(bundleID: "com.example.app", name: "Example", category: .other)
    private let otherApp = TargetApp(bundleID: "com.example.other", name: "Other", category: .other)

    private func entry(secondsAgo: TimeInterval, bundleID: String?, text: String = "buy milk, eggs, bread",
                        now: Date) -> DictationEntry {
        DictationEntry(timestampUnix: now.addingTimeInterval(-secondsAgo).timeIntervalSince1970,
                       text: text, bundleID: bundleID)
    }

    // MARK: Must NOT be eligible (fail closed)

    func testJustOverTheWindowIsNotEligible() {
        let now = Date()
        let last = entry(secondsAgo: 46, bundleID: sameApp.bundleID, now: now)
        XCTAssertNil(ImplicitSelectionGate.eligible(lastEntry: last, now: now, currentTarget: sameApp))
    }

    func testDifferentBundleIDIsNotEligibleEvenWhenVeryRecent() {
        let now = Date()
        let last = entry(secondsAgo: 2, bundleID: otherApp.bundleID, now: now)
        XCTAssertNil(ImplicitSelectionGate.eligible(lastEntry: last, now: now, currentTarget: sameApp),
                     "a recent dictation in a different app must never be treated as 'what's on screen now'")
    }

    func testMissingBundleIDFailsClosedRatherThanAssumingAMatch() {
        let now = Date()
        // A pre-migration entry with no recorded bundleID — must not be
        // treated as eligible just because it's recent; missing data fails
        // closed, not open.
        let last = entry(secondsAgo: 1, bundleID: nil, now: now)
        XCTAssertNil(ImplicitSelectionGate.eligible(lastEntry: last, now: now, currentTarget: sameApp))
    }

    func testEmptyHistoryIsNotEligible() {
        XCTAssertNil(ImplicitSelectionGate.eligible(lastEntry: nil, now: Date(), currentTarget: sameApp))
    }

    func testBlankDictationTextIsNotEligible() {
        let now = Date()
        let last = entry(secondsAgo: 1, bundleID: sameApp.bundleID, text: "   ", now: now)
        XCTAssertNil(ImplicitSelectionGate.eligible(lastEntry: last, now: now, currentTarget: sameApp))
    }

    // MARK: Must be eligible (the feature actually working)

    func testRecentSameAppDictationIsEligible() {
        let now = Date()
        let last = entry(secondsAgo: 5, bundleID: sameApp.bundleID, now: now)
        let result = ImplicitSelectionGate.eligible(lastEntry: last, now: now, currentTarget: sameApp)
        XCTAssertEqual(result?.text, "buy milk, eggs, bread")
    }

    func testJustUnderTheWindowIsEligible() {
        let now = Date()
        let last = entry(secondsAgo: 44, bundleID: sameApp.bundleID, now: now)
        XCTAssertNotNil(ImplicitSelectionGate.eligible(lastEntry: last, now: now, currentTarget: sameApp))
    }
}
