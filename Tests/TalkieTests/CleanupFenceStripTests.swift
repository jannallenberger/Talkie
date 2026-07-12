import XCTest
@testable import Talkie

/// Regression tests for `CleanupEngine.stripFenceMarkers(from:nonce:)` — the fence
/// removal that runs on the on-device model's cleanup output.
///
/// Bug this locks down: the model doesn't only echo the two fence markers we send
/// (`<<<DICTATION nonce>>>` / `<<<END DICTATION nonce>>>`) — it sometimes prefixes
/// its rewrite with a self-labeled variant that reuses the same per-call nonce,
/// e.g. `<<<REWRITTEN DICTATION nonce>>>`. The old strip removed only the two exact
/// strings, so that variant leaked into the pasted text (user saw a literal
/// "<<<REWRITTEN DICTATION 5f6c922d037a2a55>>>" at the top of their dictation). The
/// fix strips any `<<<…nonce…>>>` marker, keyed on the unguessable nonce.
final class CleanupFenceStripTests: XCTestCase {

    /// The exact reported failure: an invented "REWRITTEN DICTATION" header carrying
    /// the call nonce must be removed, leaving only the user's words.
    func testStripsInventedRewrittenDictationHeader() {
        let nonce = "5f6c922d037a2a55"
        let raw = "<<<REWRITTEN DICTATION \(nonce)>>>\nWe need to get rid of that marker."
        XCTAssertEqual(
            CleanupEngine.stripFenceMarkers(from: raw, nonce: nonce),
            "We need to get rid of that marker.")
    }

    /// The two markers we actually send are still stripped (no regression).
    func testStripsTheExactOpenAndCloseMarkers() {
        let nonce = "abc123def456"
        let raw = "<<<DICTATION \(nonce)>>>\nHello there world\n<<<END DICTATION \(nonce)>>>"
        XCTAssertEqual(
            CleanupEngine.stripFenceMarkers(from: raw, nonce: nonce),
            "Hello there world")
    }

    /// Any label the model wraps around the nonce is removed — the strip keys on the
    /// nonce, not on a fixed set of labels.
    func testStripsArbitraryLabelAroundNonce() {
        let nonce = "deadbeefcafef00d"
        let raw = "<<<OUTPUT \(nonce)>>>result<<<DONE \(nonce)>>>"
        XCTAssertEqual(CleanupEngine.stripFenceMarkers(from: raw, nonce: nonce), "result")
    }

    /// The model may echo the hex nonce in a different case; matching is
    /// case-insensitive so an upper-cased echo is still stripped.
    func testNonceMatchIsCaseInsensitive() {
        let nonce = "00ff00ff00ff00ff"
        let raw = "<<<REWRITTEN DICTATION \(nonce.uppercased())>>>\nkept text"
        XCTAssertEqual(CleanupEngine.stripFenceMarkers(from: raw, nonce: nonce), "kept text")
    }

    /// Deliberate boundary: a `<<<…>>>`-shaped token that does NOT carry the nonce is
    /// left alone — matching on the unguessable nonce is what makes the strip safe to
    /// run on real dictation (it can never eat content the speaker actually said).
    func testLeavesNonNonceAngleBracketTextUntouched() {
        let nonce = "1111222233334444"
        let raw = "the config uses <<<PLACEHOLDER>>> as a token"
        XCTAssertEqual(
            CleanupEngine.stripFenceMarkers(from: raw, nonce: nonce),
            "the config uses <<<PLACEHOLDER>>> as a token")
    }

    /// A bare occurrence of the nonce hex in prose (not wrapped in a fence) is not a
    /// marker and must be preserved.
    func testLeavesBareNonceHexInProse() {
        let nonce = "abcdef0123456789"
        let raw = "my commit is \(nonce) on main"
        XCTAssertEqual(CleanupEngine.stripFenceMarkers(from: raw, nonce: nonce), raw)
    }

    /// Ordinary cleaned output with no markers passes through (just trimmed).
    func testPassesThroughMarkerlessText() {
        XCTAssertEqual(
            CleanupEngine.stripFenceMarkers(from: "  just some words.  ", nonce: "0011223344556677"),
            "just some words.")
    }
}
