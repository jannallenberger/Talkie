import XCTest
@testable import TalkieUpdater

/// Tests the release-body digest parser — how the updater reads the publisher's
/// `sha256:<hex>` line (written by `scripts/release_dev.sh`) out of GitHub release
/// notes into `UpdateRelease.assetSHA256`, since GitHub's API exposes no per-asset
/// digest.
final class GitHubReleasesTests: XCTestCase {
    private let validHex = String(repeating: "ab", count: 32)  // 64 lowercase hex chars

    func testParsesDigestLineAmidNotes() {
        let body = """
        Polish the niche corrector and tidy the settings pane.

        sha256:\(validHex)
        """
        XCTAssertEqual(ReleaseFetcher.sha256(fromBody: body), validHex)
    }

    func testIsCaseInsensitiveOnLabelAndNormalizesHex() {
        let body = "SHA256:\(validHex.uppercased())"
        XCTAssertEqual(ReleaseFetcher.sha256(fromBody: body), validHex)
    }

    func testAbsentDigestReturnsNil() {
        XCTAssertNil(ReleaseFetcher.sha256(fromBody: "Just a plain commit subject."))
    }

    func testRejectsWrongLengthDigest() {
        XCTAssertNil(ReleaseFetcher.sha256(fromBody: "sha256:deadbeef"))
    }

    func testRejectsNonHexDigest() {
        let notHex = String(repeating: "zz", count: 32)
        XCTAssertNil(ReleaseFetcher.sha256(fromBody: "sha256:\(notHex)"))
    }

    func testIgnoresDigestNotAtLineStart() {
        // A digest mentioned mid-prose must not be mistaken for the published one.
        XCTAssertNil(ReleaseFetcher.sha256(fromBody: "the sha256:\(validHex) was logged"))
    }
}
