import XCTest
@testable import Talkie

/// Pure-logic tests for the drop-to-transcribe import (D1). The decode + recognition
/// path needs Core Audio / the on-device model and is out of scope for unit tests (the
/// playbook: test the decision function, not the I/O); these cover the media
/// classification, the error surface, and the coordinator's queue + exclusivity gate.
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

    // MARK: Helpers

    @MainActor
    private func makeCoordinator(
        isDictating: @escaping () -> Bool = { false },
        isProcessing: @escaping () -> Bool = { false },
        isRecording: @escaping () -> Bool = { false }
    ) -> FileImportCoordinator {
        // A store + graph pointed at a scratch directory so the test never touches the
        // user's real meetings. They're only constructed, not exercised (no import runs
        // in these tests — the exclusivity gate keeps them queued).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-fileimport-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = MeetingStore(supportDirectory: scratch, meetingsDirectory: scratch)
        let graph = ContextGraphStore(directory: scratch)
        return FileImportCoordinator(
            meetingStore: store,
            contextGraph: graph,
            primaryLocale: { "en-US" },
            spokenLanguages: { ["en-US"] },
            isDictating: isDictating,
            isProcessing: isProcessing,
            isRecording: isRecording
        )
    }
}
