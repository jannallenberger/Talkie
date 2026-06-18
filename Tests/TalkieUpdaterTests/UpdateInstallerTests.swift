import XCTest
import CryptoKit
@testable import TalkieUpdater

/// Pure-logic tests for the updater's artifact-verification gate — the
/// size-and-SHA-256 check that `UpdateInstaller.performInstall` runs BEFORE it
/// de-quarantines and swaps in the downloaded code (P1-01). Exercised without any
/// download, unzip, or process spawn.
final class UpdateInstallerTests: XCTestCase {
    /// Some bytes to stand in for a downloaded zip, plus their real SHA-256.
    private let payload = Data("the bytes of a downloaded Talkie.app.zip".utf8)

    private var payloadSHA: String {
        SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: verifyArtifact

    func testCorrectSizeAndSHASucceeds() {
        let result = UpdateInstaller.verifyArtifact(
            zipData: payload,
            expectedSize: payload.count,
            expectedSHA256: payloadSHA
        )
        assertSuccess(result)
    }

    func testSizeMismatchFails() {
        let result = UpdateInstaller.verifyArtifact(
            zipData: payload,
            expectedSize: payload.count + 1,   // advertised size differs
            expectedSHA256: payloadSHA
        )
        assertBadArtifact(result, containing: "size mismatch")
    }

    func testSHAMismatchWithCorrectSizeFails() {
        // A digest of the right length but the wrong content (size still matches).
        let wrong = SHA256.hash(data: Data("a different artifact entirely…!".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let result = UpdateInstaller.verifyArtifact(
            zipData: payload,
            expectedSize: payload.count,
            expectedSHA256: wrong
        )
        assertBadArtifact(result, containing: "SHA-256 mismatch")
    }

    func testAbsentSHAWithCorrectSizeSucceeds() {
        // Older releases predating digest publishing: no SHA to enforce, so the
        // size gate alone must let the install proceed (don't brick them).
        let result = UpdateInstaller.verifyArtifact(
            zipData: payload,
            expectedSize: payload.count,
            expectedSHA256: nil
        )
        assertSuccess(result)
    }

    func testAbsentSHAStillEnforcesSize() {
        // The fail-closed size gate stays in force even without a published digest.
        let result = UpdateInstaller.verifyArtifact(
            zipData: payload,
            expectedSize: payload.count - 1,
            expectedSHA256: nil
        )
        assertBadArtifact(result, containing: "size mismatch")
    }

    func testUppercaseExpectedSHAStillMatches() {
        // The publisher's digest is normalized, so case doesn't cause a false miss.
        let result = UpdateInstaller.verifyArtifact(
            zipData: payload,
            expectedSize: payload.count,
            expectedSHA256: payloadSHA.uppercased()
        )
        assertSuccess(result)
    }

    // MARK: helpers

    private func assertSuccess(
        _ result: Result<Void, UpdaterError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("expected success, got \(error)", file: file, line: line)
        }
    }

    private func assertBadArtifact(
        _ result: Result<Void, UpdaterError>,
        containing needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("expected .badArtifact failure, got success", file: file, line: line)
        case .failure(let error):
            guard case .badArtifact(let why) = error else {
                return XCTFail("expected .badArtifact, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                why.contains(needle),
                "expected reason to mention \"\(needle)\", got \"\(why)\"",
                file: file, line: line
            )
        }
    }
}
