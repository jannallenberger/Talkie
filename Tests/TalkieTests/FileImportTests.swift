import XCTest
@testable import Talkie

/// Pure-logic tests for the drop-to-transcribe import (D1) and the batch folder queue
/// (D5). The decode + recognition path needs Core Audio / the on-device model and is out
/// of scope for unit tests (the playbook: test the decision function, not the I/O); these
/// cover the media classification, folder enumeration, the error surface, and the
/// coordinator's FIFO queue, "N of M" progress, cancellation, per-file failure collection,
/// and duplicate guard — the last group driven through an injected fake importer that never
/// touches Speech.
final class FileImportTests: XCTestCase {

    // MARK: ImportableMedia classification

    func testAudioExtensionsAreRecognized() {
        for ext in ["m4a", "mp3", "wav", "aiff", "flac", "caf"] {
            let url = URL(fileURLWithPath: "/tmp/sample.\(ext)")
            XCTAssertTrue(ImportableMedia.isAudio(url), "\(ext) should be treated as audio")
            XCTAssertTrue(ImportableMedia.isSupported(url), "\(ext) should be importable")
            XCTAssertFalse(ImportableMedia.isVideo(url), "\(ext) is audio, not video")
        }
    }

    func testVideoExtensionsAreRecognized() {
        for ext in ["mp4", "mov"] {
            let url = URL(fileURLWithPath: "/tmp/clip.\(ext)")
            XCTAssertTrue(ImportableMedia.isVideo(url), "\(ext) should be treated as video")
            XCTAssertTrue(ImportableMedia.isSupported(url), "\(ext) should be importable")
            XCTAssertFalse(ImportableMedia.isAudio(url), "\(ext) is video, not audio")
        }
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertTrue(ImportableMedia.isSupported(URL(fileURLWithPath: "/tmp/A.M4A")),
                      "extension match must be case-insensitive")
        XCTAssertTrue(ImportableMedia.isVideo(URL(fileURLWithPath: "/tmp/B.MP4")),
                      "extension match must be case-insensitive")
    }

    func testUnsupportedTypesAreRejected() {
        for ext in ["txt", "pdf", "png", "docx", "zip", ""] {
            let url = URL(fileURLWithPath: "/tmp/thing.\(ext)")
            XCTAssertFalse(ImportableMedia.isSupported(url), "\(ext) must not be importable")
        }
    }

    func testSupportedFiltersOutTheJunkAndKeepsOrder() {
        let dropped = [
            URL(fileURLWithPath: "/tmp/one.m4a"),
            URL(fileURLWithPath: "/tmp/readme.txt"),
            URL(fileURLWithPath: "/tmp/two.mp4"),
            URL(fileURLWithPath: "/tmp/icon.png"),
            URL(fileURLWithPath: "/tmp/three.wav"),
        ]
        let kept = ImportableMedia.supported(in: dropped)
        XCTAssertEqual(kept.map { $0.lastPathComponent }, ["one.m4a", "two.mp4", "three.wav"],
                       "only supported files survive, in drop order")
    }

    func testSupportedOnAllJunkIsEmpty() {
        let kept = ImportableMedia.supported(in: [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.json"),
        ])
        XCTAssertTrue(kept.isEmpty, "a batch with no media yields nothing to import")
    }

    // MARK: Folder enumeration (D5) — shallow, hidden-skipping, name-sorted

    /// A dropped folder is shallow-enumerated: only its supported files, sorted by name,
    /// with hidden files and non-media dropped.
    func testMediaFilesInFolderIsShallowSortedAndFiltered() throws {
        let dir = try makeTempDir()
        // Deliberately out of alphabetical creation order to prove the sort.
        try writeFile(dir, "zebra.m4a")
        try writeFile(dir, "alpha.mp3")
        try writeFile(dir, "middle.wav")
        try writeFile(dir, "notes.txt")           // unsupported → dropped
        try writeFile(dir, ".hidden.m4a")          // dotfile → dropped
        let sub = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(sub, "deep.m4a")             // in a subfolder → dropped (no recursion)

        let files = ImportableMedia.mediaFiles(inFolderAt: dir)
        XCTAssertEqual(files.map { $0.lastPathComponent }, ["alpha.mp3", "middle.wav", "zebra.m4a"],
                       "shallow walk keeps only top-level media, sorted by name, no hidden, no recursion")
    }

    func testMediaFilesInMissingFolderIsEmpty() {
        let bogus = URL(fileURLWithPath: "/tmp/talkie-does-not-exist-\(UUID().uuidString)")
        XCTAssertTrue(ImportableMedia.mediaFiles(inFolderAt: bogus).isEmpty,
                      "an unreadable folder yields nothing, never a throw")
    }

    /// `expand` flattens a mixed drop (folders shallow-enumerated, loose files kept in
    /// order) and collapses duplicate paths.
    func testExpandFlattensFoldersAndDedupes() throws {
        let dir = try makeTempDir()
        try writeFile(dir, "b.m4a")
        try writeFile(dir, "a.m4a")
        let loose = try makeTempDir()
        let looseFile = try writeFile(loose, "loose.wav")

        // Drop: the folder, a loose file, then the SAME loose file again + a file already
        // inside the folder — duplicates must collapse.
        let dropped = [dir, looseFile, looseFile, dir.appendingPathComponent("a.m4a")]
        let expanded = ImportableMedia.expand(dropped)
        XCTAssertEqual(expanded.map { $0.lastPathComponent }, ["a.m4a", "b.m4a", "loose.wav"],
                       "folder files come sorted, then the loose file once; duplicates dropped")
    }

    // MARK: Error surface (every failure has a visible, friendly message)

    func testEveryErrorHasADescription() {
        let errors: [FileImportError] = [
            .unsupportedType("thing.txt"),
            .cannotOpen("a.m4a"),
            .noAudioTrack("silent.mp4"),
            .speechUnavailable,
            .emptyTranscript,
            .cancelled,
        ]
        for error in errors {
            let message = error.errorDescription
            XCTAssertNotNil(message, "\(error) must surface a message, never a silent failure")
            XCTAssertFalse(message?.isEmpty ?? true, "\(error) message must be non-empty")
        }
    }

    func testNoAudioTrackNamesTheFile() {
        let message = FileImportError.noAudioTrack("meeting.mp4").errorDescription ?? ""
        XCTAssertTrue(message.contains("meeting.mp4"),
                      "the no-audio-track error names the offending file so the user knows which one")
    }

    // MARK: Completion message (pure)

    @MainActor
    func testCompletionMessagePlainAllImported() {
        let msg = FileImportCoordinator.completionMessage(imported: 5, skipped: [], evicted: false)
        XCTAssertTrue(msg.contains("5"), "reports the imported count")
        XCTAssertFalse(msg.lowercased().contains("skipped"), "no skip clause when nothing was skipped")
    }

    @MainActor
    func testCompletionMessageListsSkippedNames() {
        let msg = FileImportCoordinator.completionMessage(
            imported: 11,
            skipped: [(name: "foo.mp3", reason: "undecodable")],
            evicted: false)
        XCTAssertTrue(msg.contains("11"), "reports the imported count")
        XCTAssertTrue(msg.contains("foo.mp3"), "names the skipped file so the user knows which one")
    }

    @MainActor
    func testCompletionMessageNotesEvictionWhenCapHit() {
        let msg = FileImportCoordinator.completionMessage(imported: 300, skipped: [], evicted: true)
        let cap = MeetingStore.maxRetainedMeetings
        XCTAssertTrue(msg.contains("\(cap)"),
                      "the eviction note surfaces the retention cap so the roll-off is explained")
    }

    // MARK: Coordinator — exclusivity gate + queueing

    /// A live dictation must defer an import, not interleave: nothing goes active, the
    /// file stays queued, and the UI shows the waiting state.
    @MainActor
    func testImportDefersWhileDictating() {
        let coordinator = makeCoordinator(isDictating: { true })
        coordinator.enqueue([URL(fileURLWithPath: "/tmp/sample.m4a")])

        XCTAssertNil(coordinator.active, "no import may start over a live dictation")
        XCTAssertTrue(coordinator.waitingForSession, "the UI must show it's waiting for the session to end")
        XCTAssertEqual(coordinator.queued.count, 1, "the deferred file stays queued")
    }

    @MainActor
    func testImportDefersWhileProcessing() {
        let coordinator = makeCoordinator(isProcessing: { true })
        coordinator.enqueue([URL(fileURLWithPath: "/tmp/sample.wav")])
        XCTAssertNil(coordinator.active, "no import may start while a dictation is still being processed")
        XCTAssertTrue(coordinator.waitingForSession)
    }

    @MainActor
    func testImportDefersWhileRecording() {
        let coordinator = makeCoordinator(isRecording: { true })
        coordinator.enqueue([URL(fileURLWithPath: "/tmp/sample.mp4")])
        XCTAssertNil(coordinator.active, "no import may start over a live meeting recording")
        XCTAssertTrue(coordinator.waitingForSession)
    }

    /// Dropping a batch of unsupported files is a no-op — nothing queues, nothing runs.
    @MainActor
    func testEnqueueIgnoresUnsupportedFiles() {
        let coordinator = makeCoordinator()
        coordinator.enqueue([
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ])
        XCTAssertNil(coordinator.active, "unsupported files never start an import")
        XCTAssertTrue(coordinator.queued.isEmpty, "unsupported files are not queued")
        XCTAssertFalse(coordinator.waitingForSession)
    }

    /// Cancel clears the queue and the active slot, leaving the coordinator idle (and
    /// therefore no partial Meeting — persistence only happens after a full transcript).
    @MainActor
    func testCancelClearsQueueAndActive() {
        let coordinator = makeCoordinator(isDictating: { true }) // stays queued/waiting
        coordinator.enqueue([URL(fileURLWithPath: "/tmp/sample.m4a")])
        XCTAssertEqual(coordinator.queued.count, 1)

        coordinator.cancel()
        XCTAssertTrue(coordinator.queued.isEmpty, "cancel clears the queue")
        XCTAssertNil(coordinator.active, "cancel clears the active import")
        XCTAssertFalse(coordinator.waitingForSession, "cancel resets the waiting state")
    }

    // MARK: Coordinator — the batch queue (D5), driven by a fake importer

    /// A folder of 5 files yields 5 meetings in FIFO order; the fake sees them in order.
    @MainActor
    func testBatchProcessesFilesInOrderAndPersistsEach() async throws {
        let fake = FakeImporter()
        let (coordinator, store) = makeCoordinatorWithStore(importer: fake)
        let urls = (1...5).map { URL(fileURLWithPath: "/tmp/rec-\($0).m4a") }

        coordinator.enqueue(urls)
        await waitUntil("batch finishes") { coordinator.active == nil && coordinator.queued.isEmpty }

        XCTAssertEqual(store.meetings.count, 5, "each of the 5 files becomes a meeting")
        let seen = await fake.seenNames
        XCTAssertEqual(seen, ["rec-1.m4a", "rec-2.m4a", "rec-3.m4a", "rec-4.m4a", "rec-5.m4a"],
                       "the queue is FIFO — files import in drop order, one at a time")
    }

    /// "3 of 12"-style progress: batchTotal is set at enqueue and batchDone counts up as
    /// files finish, so the row can render the position.
    @MainActor
    func testBatchTotalAndDoneTrackProgress() async throws {
        let fake = FakeImporter()
        let (coordinator, _) = makeCoordinatorWithStore(importer: fake)
        coordinator.enqueue((1...4).map { URL(fileURLWithPath: "/tmp/f\($0).wav") })

        XCTAssertEqual(coordinator.batchTotal, 4, "the total is known as soon as the batch is queued")
        await waitUntil("batch finishes") { coordinator.active == nil && coordinator.queued.isEmpty }
        // After the batch drains, counters reset for the next drop.
        XCTAssertEqual(coordinator.batchTotal, 0, "counters reset once the batch is done")
        XCTAssertEqual(coordinator.batchDone, 0, "counters reset once the batch is done")
    }

    /// Cancel mid-file-3 of a 5-file batch leaves exactly the meetings that already
    /// finished (2), discards the in-flight file, and drops the rest of the queue.
    @MainActor
    func testCancelMidBatchKeepsCompletedDiscardsRest() async throws {
        // Files 1 and 2 import instantly; file 3 blocks until we release it, giving a
        // deterministic window to cancel while it is the active, in-flight file.
        let fake = FakeImporter()
        await fake.setBlocking(fileName: "c.m4a")
        let (coordinator, store) = makeCoordinatorWithStore(importer: fake)

        let urls = ["a.m4a", "b.m4a", "c.m4a", "d.m4a", "e.m4a"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        coordinator.enqueue(urls)

        // Wait until the first two have persisted and file 3 is the blocked active import.
        await waitUntil("file 3 is active and blocked") {
            coordinator.active?.fileName == "c.m4a" && store.meetings.count == 2
        }

        coordinator.cancel()
        // Release the blocked importer; its result must be discarded (batch superseded).
        await fake.release()

        // Give any late callback a chance to (wrongly) land, then assert nothing changed.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(store.meetings.count, 2, "cancel mid-file-3 leaves exactly the 2 completed meetings")
        XCTAssertNil(coordinator.active, "cancel clears the active import")
        XCTAssertTrue(coordinator.queued.isEmpty, "cancel drops the rest of the queue (files 4 and 5)")
    }

    /// A per-file failure (undecodable/zero-length) is collected, not fatal: the rest of
    /// the batch still imports, and the failure shows up once in the completion summary.
    @MainActor
    func testPerFileFailureDoesNotAbortBatch() async throws {
        let fake = FakeImporter()
        await fake.setFailing(fileName: "bad.m4a", error: .emptyTranscript)
        let (coordinator, store) = makeCoordinatorWithStore(importer: fake)

        let urls = ["ok1.m4a", "bad.m4a", "ok2.m4a"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        coordinator.enqueue(urls)
        await waitUntil("batch finishes") { coordinator.active == nil && coordinator.queued.isEmpty }

        XCTAssertEqual(store.meetings.count, 2, "the two good files import despite the one failure")
        let completion = coordinator.lastCompletion ?? ""
        XCTAssertTrue(completion.contains("bad.m4a"),
                      "the skipped file is named once in the batch summary, not shown as a modal per-file")
        XCTAssertTrue(completion.contains("2"), "the summary reports the 2 successful imports")
    }

    /// Duplicate guard: a file whose name already appears in an existing meeting's
    /// `source` (D1's `talkie (imported: <name>)`) is skipped, best-effort.
    @MainActor
    func testDuplicateGuardSkipsAlreadyImportedFilename() async throws {
        let fake = FakeImporter()
        let (coordinator, store) = makeCoordinatorWithStore(importer: fake)

        // Seed a meeting that looks like a prior import of "dup.m4a".
        store.add(Meeting(
            id: UUID(),
            title: "dup",
            startUnix: Date().timeIntervalSince1970,
            durationSec: 1,
            transcript: "hello",
            summary: "",
            participants: ["Imported"],
            source: "talkie (imported: dup.m4a)",
            fileName: MeetingStore.fileName(for: Date(), id: UUID())))
        XCTAssertEqual(store.meetings.count, 1)

        coordinator.enqueue([URL(fileURLWithPath: "/tmp/dup.m4a"),
                             URL(fileURLWithPath: "/tmp/fresh.m4a")])
        await waitUntil("batch finishes") { coordinator.active == nil && coordinator.queued.isEmpty }

        XCTAssertEqual(store.meetings.count, 2,
                       "the duplicate is skipped; only the fresh file adds a meeting (1 seed + 1 fresh)")
        let seen = await fake.seenNames
        XCTAssertFalse(seen.contains("dup.m4a"),
                       "the guard skips before the importer even runs on the duplicate")
        XCTAssertTrue(seen.contains("fresh.m4a"), "the non-duplicate still imports")
        XCTAssertTrue((coordinator.lastCompletion ?? "").contains("dup.m4a"),
                      "the skipped duplicate is reported in the summary")
    }

    // MARK: Helpers

    @MainActor
    private func makeCoordinator(
        isDictating: @escaping () -> Bool = { false },
        isProcessing: @escaping () -> Bool = { false },
        isRecording: @escaping () -> Bool = { false }
    ) -> FileImportCoordinator {
        makeCoordinatorWithStore(
            isDictating: isDictating, isProcessing: isProcessing, isRecording: isRecording,
            importer: FakeImporter()).0
    }

    /// Build a coordinator backed by a scratch store/graph (never the user's real data) and
    /// an injected importer, returning the store so tests can assert on persisted meetings.
    @MainActor
    private func makeCoordinatorWithStore(
        isDictating: @escaping () -> Bool = { false },
        isProcessing: @escaping () -> Bool = { false },
        isRecording: @escaping () -> Bool = { false },
        importer: FileImporting
    ) -> (FileImportCoordinator, MeetingStore) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-fileimport-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = MeetingStore(supportDirectory: scratch, meetingsDirectory: scratch)
        let graph = ContextGraphStore(directory: scratch)
        let coordinator = FileImportCoordinator(
            meetingStore: store,
            contextGraph: graph,
            primaryLocale: { "en-US" },
            spokenLanguages: { ["en-US"] },
            isDictating: isDictating,
            isProcessing: isProcessing,
            isRecording: isRecording,
            importer: importer,
            // Inject a synchronous no-op summarizer so the queue tests never touch the
            // on-device model (machine-dependent + slow) — we test the queue, not the LLM.
            summarize: { _ in "" })
        return (coordinator, store)
    }

    /// Poll `condition` on the main actor until true or the timeout elapses. The coordinator
    /// drives its queue with detached `Task`s, so tests await state transitions rather than
    /// assuming synchronous completion.
    @MainActor
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for: \(what)", file: file, line: line)
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-folder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeFile(_ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }
}

// MARK: - Fake importer

/// A stand-in for `FileImportEngine` that returns a canned `FileImportResult` without any
/// Core Audio / Speech, so the coordinator's queue logic can be exercised deterministically.
/// An `actor` (it's `Sendable`, crosses into the coordinator, and records call order under
/// isolation); one file name can be marked to fail, and one to block until `release()` so a
/// test can cancel while a specific file is the in-flight import.
actor FakeImporter: FileImporting {
    private(set) var seenNames: [String] = []
    private var failing: [String: FileImportError] = [:]
    private var blockingName: String?
    private var gate: CheckedContinuation<Void, Never>?

    func setFailing(fileName: String, error: FileImportError) { failing[fileName] = error }
    func setBlocking(fileName: String) { blockingName = fileName }

    /// Release a blocked import so it can return its (to-be-discarded, if cancelled) result.
    func release() {
        gate?.resume()
        gate = nil
    }

    func importFile(
        url: URL,
        primaryLocale: String,
        localeIDs: [String],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> FileImportResult {
        let name = url.lastPathComponent
        seenNames.append(name)
        onProgress(0)

        if name == blockingName {
            // Suspend here until the test releases us, so the file stays "active".
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                gate = cont
            }
            try Task.checkCancellation() // a cancel during the block surfaces as cancellation
        }

        if let error = failing[name] { throw error }

        onProgress(1)
        return FileImportResult(transcript: "transcript of \(name)", durationSec: 1)
    }
}
