import XCTest
@testable import Talkie

/// Pure-logic tests for the watched-inbox folder (D6): the quiescence gate (a file is
/// only picked up once its size has stopped changing, so a still-copying transfer is
/// never grabbed early) and the dedup / exclusion rules (the `Transcribed/` done-marker
/// folder is skipped, a file already in flight isn't re-enqueued, and a file whose
/// import already produced a meeting is treated as done — the move-as-marker invariant).
///
/// The `DispatchSource` directory watch, the on-device import, and the iCloud
/// dataless-download hop are inherently async / need real I/O, so — per the playbook —
/// these exercise the decision functions, not the plumbing: `QuiescenceGate` runs against
/// synthetic size samples with an injected clock, and the selection logic runs against a
/// real temp directory (the only filesystem touch is creating a couple of files).
final class InboxWatcherTests: XCTestCase {

    // MARK: - Quiescence gate

    /// A file whose size keeps growing across polls is never considered settled — this is
    /// the whole point of the gate: a 200 MB screen recording still being copied in must
    /// not be transcribed from a truncated prefix.
    func testGrowingFileNeverSettles() {
        let gate = QuiescenceGate(settleInterval: 2)
        let url = URL(fileURLWithPath: "/tmp/inbox/growing.m4a")
        var now = Date(timeIntervalSince1970: 1_000)

        // First sighting: 1 KB. Unknown before — can't be settled on first look.
        XCTAssertFalse(gate.observe(url, size: 1_024, now: now),
                       "a file can never settle on its very first observation")
        // Keeps growing every poll; each poll is >= settleInterval apart.
        for kb in [4, 16, 64, 256] {
            now = now.addingTimeInterval(3)
            XCTAssertFalse(gate.observe(url, size: Int64(kb) * 1_024, now: now),
                           "a file whose size changed since the last poll is still in flight")
        }
    }

    /// A file whose size is unchanged, but only for less than the settle interval, is not
    /// yet trusted — the gate requires the size to hold *across* an interval, not merely to
    /// repeat back-to-back (rapid double-fires of the vnode source shouldn't shortcut it).
    func testStableButTooRecentDoesNotSettle() {
        let gate = QuiescenceGate(settleInterval: 2)
        let url = URL(fileURLWithPath: "/tmp/inbox/quick.wav")
        let t0 = Date(timeIntervalSince1970: 5_000)

        XCTAssertFalse(gate.observe(url, size: 50_000, now: t0),
                       "first observation is never settled")
        // Same size, but only 0.5s later — below the 2s settle window.
        XCTAssertFalse(gate.observe(url, size: 50_000, now: t0.addingTimeInterval(0.5)),
                       "same size for < settleInterval is not yet quiescent")
    }

    /// The success path: a file that arrives, then holds the same size across a full settle
    /// interval, qualifies exactly once. A subsequent observation does NOT re-qualify it
    /// (so the watcher enqueues it a single time, not on every later vnode event).
    func testStableAcrossIntervalSettlesExactlyOnce() {
        let gate = QuiescenceGate(settleInterval: 2)
        let url = URL(fileURLWithPath: "/tmp/inbox/done.mp3")
        let t0 = Date(timeIntervalSince1970: 9_000)

        XCTAssertFalse(gate.observe(url, size: 128_000, now: t0),
                       "first sighting records the size but can't settle yet")
        XCTAssertTrue(gate.observe(url, size: 128_000, now: t0.addingTimeInterval(2.5)),
                      "unchanged size held across the settle interval qualifies the file")
        XCTAssertFalse(gate.observe(url, size: 128_000, now: t0.addingTimeInterval(5)),
                       "an already-qualified file must not qualify a second time")
    }

    /// A file that grows, briefly holds, then grows again resets its settle clock each time
    /// the size changes — it only qualifies once it has truly stopped for a full interval.
    func testResumedCopyResetsTheClock() {
        let gate = QuiescenceGate(settleInterval: 2)
        let url = URL(fileURLWithPath: "/tmp/inbox/resumed.m4a")
        let t0 = Date(timeIntervalSince1970: 12_000)

        XCTAssertFalse(gate.observe(url, size: 10_000, now: t0), "first sighting")
        // Held for 3s at 10 KB — would settle now…
        // …but a poll at +1s shows it grew again, resetting the clock.
        XCTAssertFalse(gate.observe(url, size: 20_000, now: t0.addingTimeInterval(1)),
                       "growth resets the settle clock")
        XCTAssertFalse(gate.observe(url, size: 20_000, now: t0.addingTimeInterval(2)),
                       "only 1s of stability at the new size — not enough")
        XCTAssertTrue(gate.observe(url, size: 20_000, now: t0.addingTimeInterval(3.5)),
                      "2.5s of stability at the final size finally qualifies it")
    }

    /// Forgetting a file (done: moved to Transcribed/, or vanished) clears its state so a
    /// brand-new file that later reuses the same name starts its own settle cycle rather
    /// than inheriting the old one's "already settled" flag.
    func testForgetResetsState() {
        let gate = QuiescenceGate(settleInterval: 2)
        let url = URL(fileURLWithPath: "/tmp/inbox/reused.wav")
        let t0 = Date(timeIntervalSince1970: 15_000)

        XCTAssertFalse(gate.observe(url, size: 5_000, now: t0))
        XCTAssertTrue(gate.observe(url, size: 5_000, now: t0.addingTimeInterval(3)),
                      "qualifies the first time")
        gate.forget(url)
        // A new file at the same path: must not be instantly "settled" from stale state.
        XCTAssertFalse(gate.observe(url, size: 99_000, now: t0.addingTimeInterval(4)),
                       "after forget, the reused name is a fresh file — first sighting again")
    }

    // MARK: - Candidate selection / dedup / exclusion

    /// The watcher enumerates only top-level supported media, and NEVER descends into the
    /// `Transcribed/` done-marker subfolder — a file that has already been transcribed and
    /// moved there must not be picked up again (that would be an infinite re-import loop).
    func testTranscribedSubfolderIsExcluded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try write(dir.appendingPathComponent("fresh.m4a"))
        try write(dir.appendingPathComponent("notes.txt"))            // unsupported → ignored
        let transcribed = dir.appendingPathComponent("Transcribed", isDirectory: true)
        try FileManager.default.createDirectory(at: transcribed, withIntermediateDirectories: true)
        try write(transcribed.appendingPathComponent("already-done.m4a"))  // inside marker dir

        let names = InboxWatcher.topLevelMediaFiles(in: dir).map(\.lastPathComponent)
        XCTAssertEqual(names, ["fresh.m4a"],
                       "only top-level supported media is a candidate; Transcribed/ and non-media are excluded")
    }

    /// A file that qualifies for import is filtered out of future candidate batches while
    /// it is in flight (already enqueued) or after its import has produced a meeting — the
    /// move to Transcribed/ is the durable marker, but the in-memory guards prevent a
    /// double-enqueue in the window before the move lands.
    func testSelectionExcludesInFlightImportedAndFailed() {
        let a = URL(fileURLWithPath: "/inbox/a.m4a")
        let b = URL(fileURLWithPath: "/inbox/b.m4a")
        let c = URL(fileURLWithPath: "/inbox/c.m4a")
        let d = URL(fileURLWithPath: "/inbox/d.m4a")
        let all = [a, b, c, d]

        let selected = InboxWatcher.selectForEnqueue(
            candidates: all,
            inFlight: [b.standardizedFileURL.path],
            failed: [c.standardizedFileURL.path],
            isAlreadyImported: { $0 == d })   // d already has a persisted meeting

        XCTAssertEqual(selected, [a],
                       "b is in flight, c failed (retry next launch), d already imported — only a is new")
    }

    /// The dedup marker the watcher matches against persisted meetings is D1's exact
    /// `source` fragment, so a meeting the drop-to-transcribe path or a previous watcher
    /// run created is recognized as "this file is already imported".
    func testImportedMarkerMatchesD1SourceFormat() {
        let url = URL(fileURLWithPath: "/inbox/Weekly Sync.m4a")
        let marker = InboxWatcher.importedMarker(for: url)
        XCTAssertEqual(marker, "(imported: Weekly Sync.m4a)",
                       "must match FileImportCoordinator's `talkie (imported: <filename>)` source fragment")
        // A meeting whose source embeds that fragment is a match; an unrelated one isn't.
        XCTAssertTrue("talkie (imported: Weekly Sync.m4a)".contains(marker))
        XCTAssertFalse("talkie (imported: Other.m4a)".contains(marker))
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-watch-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ url: URL, bytes: Int = 8) throws {
        try Data(repeating: 0, count: bytes).write(to: url)
    }
}
