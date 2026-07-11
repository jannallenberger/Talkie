import XCTest
@testable import Talkie

/// The false-boost guard's multi-word admission rule (WP4/4d). Before, ANY
/// multi-word phrase was admitted unconditionally on the theory that a phrase can't
/// collide with a single common word — but a phrase made entirely of short/common
/// words ("For me", "and the") is a recognizer no-op that only risks stamping
/// caps/spacing onto ordinary speech, and it bypassed `NicheTermGuard` entirely,
/// producing 10 recorded mid-sentence "For me" injections. A phrase is now safe only
/// when it carries at least one distinctive token (≥4 chars, not a high-frequency
/// common word).
final class NicheTermGuardTests: XCTestCase {
    func testAllCommonWordPhraseIsRejected() {
        XCTAssertFalse(NicheTermGuard.default.isSafeToInject("for me"),
                       "a phrase made entirely of short/common words must never be injected")
    }

    func testDistinctivePhraseIsAdmitted() {
        XCTAssertTrue(NicheTermGuard.default.isSafeToInject("context graph"),
                      "a phrase carrying a genuinely distinctive token stays safe to inject")
    }
}
