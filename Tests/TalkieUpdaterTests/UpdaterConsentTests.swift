import XCTest
@testable import TalkieUpdater

/// Pure-logic tests for the dev-tools updater's one-time consent gate — the
/// `UpdaterConsent.mayAutoCheck` truth table and the fail-closed default-state
/// behavior. The gate decides whether a dev build's launch-time check (and the
/// `gh auth status` probe behind it) may touch GitHub at all. Exercised without
/// any network, `gh` spawn, or UI: `mayAutoCheck` is a pure function, and the
/// state round-trip is checked against `UserDefaults.standard` with the key
/// saved and restored so the suite leaves no residue.
final class UpdaterConsentTests: XCTestCase {

    // MARK: mayAutoCheck — the full truth table

    /// The ONLY combination that permits an automatic launch check: consent
    /// explicitly granted AND the launch toggle left on.
    func testGrantedAndAutoOnAllowsCheck() {
        XCTAssertTrue(UpdaterConsent.mayAutoCheck(consent: .granted, autoCheckOn: true))
    }

    /// Granted but the collaborator turned the launch toggle off → no auto-check.
    func testGrantedButAutoOffBlocksCheck() {
        XCTAssertFalse(UpdaterConsent.mayAutoCheck(consent: .granted, autoCheckOn: false))
    }

    /// Never asked → fail-closed, regardless of the toggle. This is the state
    /// every existing collaborator lands in (consent key absent), even if their
    /// auto-check default was previously ON.
    func testUnaskedNeverChecks() {
        XCTAssertFalse(UpdaterConsent.mayAutoCheck(consent: .unasked, autoCheckOn: true))
        XCTAssertFalse(UpdaterConsent.mayAutoCheck(consent: .unasked, autoCheckOn: false))
    }

    /// Explicitly declined → fail-closed, regardless of the toggle.
    func testDeclinedNeverChecks() {
        XCTAssertFalse(UpdaterConsent.mayAutoCheck(consent: .declined, autoCheckOn: true))
        XCTAssertFalse(UpdaterConsent.mayAutoCheck(consent: .declined, autoCheckOn: false))
    }

    /// Consent must be *granted* — no non-granted state ever permits a check,
    /// no matter the toggle. Exhaustive cross-product guard.
    func testOnlyGrantedEverPermits() {
        for state in [UpdaterConsent.State.unasked, .declined] {
            for auto in [true, false] {
                XCTAssertFalse(
                    UpdaterConsent.mayAutoCheck(consent: state, autoCheckOn: auto),
                    "state \(state), autoCheckOn \(auto) should not permit a check"
                )
            }
        }
    }

    // MARK: default state — fail-closed on a fresh key

    /// A fresh build (consent key absent) reads as `.unasked`, so the pure policy
    /// forbids an auto-check even with the auto toggle defaulted ON — the
    /// fail-closed guarantee for existing collaborators.
    func testAbsentKeyReadsUnaskedAndBlocks() {
        withCleanConsentKey {
            XCTAssertEqual(UpdaterConsent.current, .unasked)
            XCTAssertFalse(
                UpdaterConsent.mayAutoCheck(consent: UpdaterConsent.current, autoCheckOn: true)
            )
        }
    }

    /// An unrecognized stored value also reads as `.unasked` (fail-closed), so a
    /// corrupt or forward-incompatible default can never silently permit a check.
    func testUnrecognizedRawValueReadsUnasked() {
        withCleanConsentKey {
            UserDefaults.standard.set("garbage-value", forKey: UpdaterConsent.key)
            XCTAssertEqual(UpdaterConsent.current, .unasked)
        }
    }

    /// `set` then `current` round-trips each state faithfully.
    func testSetPersistsAndReadsBack() {
        withCleanConsentKey {
            for state in [UpdaterConsent.State.granted, .declined, .unasked] {
                UpdaterConsent.set(state)
                XCTAssertEqual(UpdaterConsent.current, state)
            }
        }
    }

    // MARK: helpers

    /// Runs `body` with the consent key removed, restoring whatever was there
    /// (usually nothing) afterward — so the suite never pollutes real defaults.
    private func withCleanConsentKey(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: UpdaterConsent.key)
        defaults.removeObject(forKey: UpdaterConsent.key)
        defer {
            if let saved {
                defaults.set(saved, forKey: UpdaterConsent.key)
            } else {
                defaults.removeObject(forKey: UpdaterConsent.key)
            }
        }
        body()
    }
}
