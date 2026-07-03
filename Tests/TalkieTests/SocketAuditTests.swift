import XCTest
@testable import Talkie

/// Tests for the live socket-audit (feature I5) and the proof-card value model.
///
/// `SocketAudit.snapshot()` reads real OS state (this process's own file
/// descriptors), so the deterministic, non-flaky assertions here are about
/// *invariants and contracts*, not a hardcoded count: the audit always returns an
/// available snapshot for a normally-running process, the count is never negative,
/// and the `unavailable` sentinel behaves as documented. We deliberately do NOT
/// assert the count equals 0 in the test process — the XCTest runner is not the
/// shipped, sandboxed app and may itself hold unrelated sockets, so pinning 0 here
/// would be a flaky lie. The "0 while dictating/recording/summarizing" claim is a
/// human-verified acceptance criterion against the installed app.
///
/// The proof-card model (`ProofCardData`, `ProofCardExporter.plainText`) is pure
/// given its input, so those are asserted exactly.
final class SocketAuditTests: XCTestCase {

    // MARK: Snapshot contract

    func testUnavailableSentinelReportsNotAvailable() {
        let snap = SocketAudit.Snapshot.unavailable
        XCTAssertFalse(snap.isAvailable, "the sentinel must report isAvailable == false")
        XCTAssertLessThan(snap.internetSockets, 0, "unavailable is signalled by a negative count")
    }

    func testAvailableSnapshotReportsAvailable() {
        let snap = SocketAudit.Snapshot(internetSockets: 0, readAtUnix: 123)
        XCTAssertTrue(snap.isAvailable, "a zero (or positive) count is a real, available reading")
        XCTAssertEqual(snap.readAtUnix, 123, "the read timestamp is carried verbatim")
    }

    func testLiveSnapshotIsAvailableAndNonNegative() {
        // A normally-running process can always list its own fds, so the audit
        // must succeed; the count is a real non-negative number.
        let snap = SocketAudit.snapshot()
        XCTAssertTrue(snap.isAvailable,
                      "own-pid fd introspection should succeed for the test process")
        XCTAssertGreaterThanOrEqual(snap.internetSockets, 0,
                                    "an available snapshot never reports a negative socket count")
        XCTAssertGreaterThan(snap.readAtUnix, 0,
                             "a live snapshot stamps the wall-clock read time")
    }

    func testRepeatedSnapshotsStayConsistentlyAvailable() {
        // The introspection is a pure read with no teardown between calls, so it
        // must be repeatable (this also exercises the buffer-sizing loop twice).
        for _ in 0..<3 {
            XCTAssertTrue(SocketAudit.snapshot().isAvailable,
                          "each independent audit call should succeed")
        }
    }

    // MARK: ProofCardData.socketLine (pure formatting)

    func testSocketLineShowsCountWhenAvailable() {
        let data = makeData(internetSockets: 0)
        XCTAssertEqual(data.socketLine, "Open network sockets: 0",
                       "an available zero renders the count")
    }

    func testSocketLineShowsCountForNonZero() {
        let data = makeData(internetSockets: 3)
        XCTAssertEqual(data.socketLine, "Open network sockets: 3",
                       "a nonzero count is shown verbatim, not hidden")
    }

    func testSocketLineDegradesHonestlyWhenUnavailable() {
        let data = makeData(internetSockets: nil)
        XCTAssertEqual(data.socketLine, "Open network sockets: couldn't read",
                       "a nil count reads as 'couldn't read', never a false 0")
    }

    // MARK: ProofCardExporter.plainText (pure given data)

    @MainActor
    func testPlainTextCarriesRealValuesNotPlaceholders() {
        let data = ProofCardData(
            entitlements: [
                .init(label: "Microphone capture", key: "com.apple.security.device.audio-input", isNetwork: false)
            ],
            hasNetwork: false,
            internetSockets: 0,
            cdhash: "abc123",
            version: "1.4.0",
            takenAt: Date(timeIntervalSince1970: 0)
        )
        let text = ProofCardExporter.plainText(data)
        XCTAssertTrue(text.contains("Open network sockets: 0"), "socket count is in the text twin")
        XCTAssertTrue(text.contains("Microphone capture"), "entitlement label is listed")
        XCTAssertTrue(text.contains("No network entitlement."), "the honest no-network line is present")
        XCTAssertTrue(text.contains("abc123"), "the real cdhash is embedded, not a placeholder")
        XCTAssertTrue(text.contains("1.4.0"), "the real version is embedded")
    }

    @MainActor
    func testPlainTextDegradesForUnsignedBuild() {
        let data = ProofCardData(
            entitlements: [],
            hasNetwork: false,
            internetSockets: nil,
            cdhash: nil,
            version: nil,
            takenAt: Date(timeIntervalSince1970: 0)
        )
        let text = ProofCardExporter.plainText(data)
        XCTAssertTrue(text.contains("none readable"),
                      "an un-signed build says entitlements aren't readable, not a fake list")
        XCTAssertTrue(text.contains("unsigned build (no cdhash)"),
                      "a missing cdhash degrades honestly")
        XCTAssertFalse(text.contains("Version:"),
                       "no version line when the version is unknown")
    }

    // MARK: helper

    private func makeData(internetSockets: Int?) -> ProofCardData {
        ProofCardData(
            entitlements: [],
            hasNetwork: false,
            internetSockets: internetSockets,
            cdhash: nil,
            version: nil,
            takenAt: Date(timeIntervalSince1970: 0)
        )
    }
}
