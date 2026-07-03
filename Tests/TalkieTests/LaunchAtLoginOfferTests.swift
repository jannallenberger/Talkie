import XCTest
@testable import Talkie

/// H8 — the earned launch-at-login offer. After three consecutive days of real use,
/// Talkie offers once (in one tap) to start at login so the hotkey stops dying
/// silently after every reboot. These pin the pure gate that decides whether to
/// surface the offer, and the once-ever resolved latch that guarantees it's shown at
/// most once, ever (including across relaunches).
///
/// The gate (`LaunchAtLoginOffer.shouldOffer`) is a pure function of three inputs, so
/// it's tested directly — no HUD, no file system. The resolved latch is exercised
/// against a throwaway `UserDefaults` suite so it never touches the developer's real
/// plist.
@MainActor
final class LaunchAtLoginOfferTests: XCTestCase {

    // MARK: The earned-streak gate

    /// The happy path: toggle off, never resolved, streak just reached the threshold.
    func testOffersWhenEarnedAndUnresolved() {
        XCTAssertTrue(
            LaunchAtLoginOffer.shouldOffer(launchAtLogin: false, resolved: false, currentStreak: 3),
            "A 3-day streak with the toggle off and the offer unresolved should surface the offer.")
    }

    /// A streak below the threshold never earns the offer, even one day short.
    func testDoesNotOfferBelowStreakThreshold() {
        for streak in 0...(LaunchAtLoginOffer.requiredStreak - 1) {
            XCTAssertFalse(
                LaunchAtLoginOffer.shouldOffer(launchAtLogin: false, resolved: false, currentStreak: streak),
                "A streak of \(streak) is below the required \(LaunchAtLoginOffer.requiredStreak) and must not offer.")
        }
    }

    /// A longer streak still qualifies — the threshold is a floor, not an exact match.
    func testOffersForLongerStreak() {
        XCTAssertTrue(
            LaunchAtLoginOffer.shouldOffer(launchAtLogin: false, resolved: false, currentStreak: 30),
            "Any streak at or above the threshold should offer; the check is `>=`, not `==`.")
    }

    /// Users who already turned the Behavior-card toggle on never see the offer —
    /// there is nothing to offer them.
    func testNeverOffersWhenAlreadyEnabled() {
        XCTAssertFalse(
            LaunchAtLoginOffer.shouldOffer(launchAtLogin: true, resolved: false, currentStreak: 10),
            "If launch-at-login is already on, the offer must never appear (nothing to enable).")
    }

    /// Once resolved (accepted OR ignored), the offer never appears again regardless
    /// of how long the streak grows — this is the once-ever contract.
    func testNeverOffersOnceResolved() {
        XCTAssertFalse(
            LaunchAtLoginOffer.shouldOffer(launchAtLogin: false, resolved: true, currentStreak: 99),
            "A resolved offer must never reappear, even with a long streak — offered once, ever.")
    }

    // MARK: The once-ever resolved latch (persistence contract)

    /// A fresh install has never resolved the offer; after `resolve()` it reads back
    /// resolved and stays that way — the flag that survives relaunches (it's a plain
    /// persisted boolean, so a new process reading the same store sees `true`).
    func testResolvedLatchPersistsOnceSet() throws {
        let suiteName = "LaunchAtLoginOfferTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(LaunchAtLoginOffer.isResolved(defaults: defaults),
                       "A fresh install has never resolved the offer.")

        LaunchAtLoginOffer.resolve(defaults: defaults)
        XCTAssertTrue(LaunchAtLoginOffer.isResolved(defaults: defaults),
                      "After resolving, the latch reads resolved — this is what a relaunch would read.")

        // Idempotent: resolving again (e.g. the timeout firing after a tap already
        // resolved) leaves it resolved, never toggles it back.
        LaunchAtLoginOffer.resolve(defaults: defaults)
        XCTAssertTrue(LaunchAtLoginOffer.isResolved(defaults: defaults),
                      "Resolving twice is idempotent — the offer stays resolved forever.")
    }

    /// End-to-end of the two states that matter in the pipeline: an unresolved earned
    /// user is offered; after resolution the same user (same streak) is not — proving
    /// "ignore it → never appears again" composes with the earned gate.
    func testIgnoredOfferNeverReappears() throws {
        let suiteName = "LaunchAtLoginOfferTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Earned, unresolved → offered.
        XCTAssertTrue(
            LaunchAtLoginOffer.shouldOffer(launchAtLogin: false,
                                           resolved: LaunchAtLoginOffer.isResolved(defaults: defaults),
                                           currentStreak: 5),
            "First eligible dictation offers the earned launch-at-login prompt.")

        // The offer is dismissed/ignored → mark resolved (what the timeout path does).
        LaunchAtLoginOffer.resolve(defaults: defaults)

        // Same earned user, later dictation → never again.
        XCTAssertFalse(
            LaunchAtLoginOffer.shouldOffer(launchAtLogin: false,
                                           resolved: LaunchAtLoginOffer.isResolved(defaults: defaults),
                                           currentStreak: 5),
            "Once resolved, a later dictation with the same streak must not re-offer.")
    }
}
