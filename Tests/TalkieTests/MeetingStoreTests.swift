import XCTest
@testable import Talkie

/// Persistence/retention tests for `MeetingStore`. Every store is pointed at a
/// fresh temp directory (injected via `init`), so these never touch the
/// developer's real ~/Talkie Meetings or ~/Library/Application Support/Talkie.
@MainActor
final class MeetingStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func makeStore() -> MeetingStore {
        // One temp dir serves as both the support dir (meetings.json) and the
        // meetings folder; keeps the two artifacts isolated from the real paths.
        MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
    }

    private func meeting(title: String, startUnix: Double) -> Meeting {
        Meeting(
            title: title,
            startUnix: startUnix,
            durationSec: 60,
            transcript: "transcript for \(title)",
            summary: "summary for \(title)",
            fileName: "\(Int(startUnix))-meeting.md"
        )
    }

    // MARK: P2-08 — hard retention cap

    func testRetentionCapKeepsOnlyMostRecentN() {
        let store = makeStore()
        let cap = MeetingStore.maxRetainedMeetings
        let total = cap + 25

        // Insert oldest → newest. startUnix encodes recency directly.
        for i in 0..<total {
            store.add(meeting(title: "m\(i)", startUnix: Double(i)))
        }

        XCTAssertEqual(store.meetings.count, cap, "index must be capped at N")

        // The N most-recent (largest startUnix) survive; the oldest are evicted.
        let kept = Set(store.meetings.map { $0.startUnix })
        XCTAssertTrue(kept.contains(Double(total - 1)), "newest must be retained")
        XCTAssertFalse(kept.contains(0), "oldest must be evicted")
        let minKept = store.meetings.map { $0.startUnix }.min()!
        XCTAssertEqual(minKept, Double(total - cap), "kept set is exactly the most-recent N")

        // Newest-first ordering is maintained.
        XCTAssertEqual(store.meetings.first?.startUnix, Double(total - 1))
    }

    func testUnderCapIsUnchanged() {
        let store = makeStore()
        let count = 10
        for i in 0..<count {
            store.add(meeting(title: "m\(i)", startUnix: Double(i)))
        }
        XCTAssertEqual(store.meetings.count, count, "under N: nothing is evicted")
        XCTAssertEqual(store.meetings.first?.startUnix, Double(count - 1), "newest first")
        XCTAssertEqual(store.meetings.last?.startUnix, 0, "oldest still present")
    }

    func testCapEnforcedOnLoad() throws {
        // Hand-write an oversized index to disk, then load it.
        let cap = MeetingStore.maxRetainedMeetings
        let many = (0..<(cap + 5)).map { meeting(title: "m\($0)", startUnix: Double($0)) }
        let data = try JSONEncoder().encode(many)
        try data.write(to: tmp.appendingPathComponent("meetings.json"), options: .atomic)

        let store = makeStore() // load() runs in init
        XCTAssertEqual(store.meetings.count, cap, "oversized index is capped on load")
        XCTAssertFalse(store.meetings.contains { $0.startUnix == 0 }, "oldest dropped on load")
    }

    // MARK: P2-23 — self-heal from durable .md files

    func testCorruptIndexRebuildsFromMarkdownFolder() throws {
        // A first store writes real .md files for a couple of meetings.
        let seed = makeStore()
        seed.add(meeting(title: "Standup", startUnix: 1_700_000_000))
        seed.add(meeting(title: "Retro", startUnix: 1_700_100_000))
        XCTAssertEqual(seed.meetings.count, 2)

        // Corrupt the on-disk index.
        try Data("{ not json".utf8)
            .write(to: tmp.appendingPathComponent("meetings.json"), options: .atomic)

        // A fresh store must recover from the .md files rather than start empty.
        let recovered = makeStore()
        XCTAssertGreaterThan(recovered.meetings.count, 0, "must rebuild from the folder")
        XCTAssertEqual(recovered.meetings.count, 2)
        let titles = Set(recovered.meetings.map { $0.title })
        XCTAssertTrue(titles.contains("Standup"))
        XCTAssertTrue(titles.contains("Retro"))
        // Dates were parsed from the front-matter (newest first).
        XCTAssertEqual(recovered.meetings.first?.title, "Retro")
    }

    func testEmptyIndexWithMarkdownPresentRecovers() throws {
        // Drop a minimal .md note directly into the folder, no index at all.
        let md = """
        ---
        title: Ad-hoc call
        date: 2026-01-02T15:04:00Z
        ---

        ## Summary

        notes
        """
        try Data(md.utf8).write(
            to: tmp.appendingPathComponent("2026-01-02-1504-meeting.md"), options: .atomic)

        let store = makeStore()
        XCTAssertEqual(store.meetings.count, 1, "recovers a folder note with no index")
        XCTAssertEqual(store.meetings.first?.title, "Ad-hoc call")
        XCTAssertEqual(store.meetings.first?.fileName, "2026-01-02-1504-meeting.md")
    }

    func testRecoveryFallsBackToFilenameWhenFrontMatterMissing() throws {
        // No front-matter at all — date must come from the filename, title from the stem.
        try Data("just some body text".utf8).write(
            to: tmp.appendingPathComponent("2025-12-31-0900-meeting.md"), options: .atomic)

        let recovered = MeetingStore.recoverFromMarkdown(in: tmp)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.fileName, "2025-12-31-0900-meeting.md")
        XCTAssertEqual(recovered.first?.title, "2025-12-31-0900-meeting")
        // Filename-derived date is non-zero (not the epoch fallback).
        XCTAssertGreaterThan(recovered.first?.startUnix ?? 0, 0)
    }

    // MARK: A8 — transcript edit update round-trip

    /// Editing a transcript via `update` replaces the entry in place (same id and
    /// position) and rewrites the durable `.md` file, so the JSON index AND the note
    /// on disk both serve the edited text. This is the persistence backbone of the
    /// transcript editor.
    func testUpdatePersistsEditedTranscriptToIndexAndMarkdown() async throws {
        let store = makeStore()
        var m = meeting(title: "Sync", startUnix: 1_700_000_000)
        m.transcript = "we discussed the cloud MD rollout"
        m.fileName = MeetingStore.fileName(for: m.date, id: m.id)
        store.add(m)

        // Sanity: the original text is in both the index and the .md on disk.
        let mdURL = tmp.appendingPathComponent(m.fileName)
        let originalMD = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(originalMD.contains("cloud MD"), "original transcript is in the .md")

        // Edit and persist.
        var edited = m
        edited.transcript = "we discussed the claude.md rollout"
        store.update(edited)

        // The in-memory index now holds the edit, same id, still one entry.
        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertEqual(store.meetings.first?.id, m.id, "same meeting, replaced in place")
        XCTAssertEqual(store.meetings.first?.transcript, "we discussed the claude.md rollout")

        // The .md file was rewritten to match (same filename), and the stale text is gone.
        let rewrittenMD = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(rewrittenMD.contains("claude.md"), "edited transcript rewrites the .md")
        XCTAssertFalse(rewrittenMD.contains("cloud MD"), "stale transcript is replaced, not appended")

        // And it survives a reload from disk (the index is the authority the UI reads).
        // The index write is now debounced+off-main, so drain it before reloading.
        await store.flush()
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.meetings.first?.transcript, "we discussed the claude.md rollout",
                       "the edit is durable across a reload of meetings.json")
    }

    /// `update` on a meeting that isn't in the store (e.g. evicted by the retention
    /// cap, or a stale reference) is a graceful no-op — it must not insert a phantom
    /// entry or throw. The `.md` on disk remains the durable copy for evicted notes.
    func testUpdateNoOpsOnUnknownMeeting() {
        let store = makeStore()
        store.add(meeting(title: "Present", startUnix: 1_700_000_000))
        XCTAssertEqual(store.meetings.count, 1)

        // A meeting the store has never seen (fresh id).
        let ghost = meeting(title: "Evicted", startUnix: 1_600_000_000)
        store.update(ghost)

        XCTAssertEqual(store.meetings.count, 1, "update must not resurrect an unknown meeting")
        XCTAssertFalse(store.meetings.contains { $0.title == "Evicted" })
    }

    /// A no-op edit (transcript unchanged) still round-trips safely through `update`
    /// — same count, same content — matching the view's guard that skips a no-change
    /// save but must not misbehave if called anyway.
    func testUpdateWithUnchangedTranscriptKeepsEntry() {
        let store = makeStore()
        let m = meeting(title: "Steady", startUnix: 1_700_000_000)
        store.add(m)
        store.update(m)
        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertEqual(store.meetings.first?.transcript, m.transcript)
    }
}
