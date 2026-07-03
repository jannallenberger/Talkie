import XCTest
@testable import Talkie

/// D9 — keep-audio meetings + click-to-play. Covers the pure resolution/highlight
/// helpers, the back-compatible `audioFiles` decode, and `MeetingStore.delete`
/// removing the kept audio alongside the `.md`. No Core Audio / AVAudioPlayer here —
/// the timer-driven UI is out of scope for pure tests, but every decision it makes
/// (which file plays a speaker, which segment is active at time t) lives in the pure
/// `Meeting` helpers exercised below.
final class MeetingAudioTests: XCTestCase {

    private func seg(_ speaker: String, _ start: Double, _ text: String) -> MeetingSegment {
        MeetingSegment(speaker: speaker, start: start, end: start + 1, text: text)
    }

    // MARK: audioFileName(forSpeaker:in:)

    func testAudioFileNameExactSpeakerMatchInTwoStream() {
        let files = ["Me": "m-me.m4a", "Them": "m-them.m4a"]
        XCTAssertEqual(Meeting.audioFileName(forSpeaker: "Me", in: files), "m-me.m4a",
                       "a Me segment resolves to the -me file")
        XCTAssertEqual(Meeting.audioFileName(forSpeaker: "Them", in: files), "m-them.m4a",
                       "a Them segment resolves to the -them file")
    }

    func testAudioFileNameSingleFileFallbackIgnoresSpeaker() {
        // A solo import: one file, every segment plays it regardless of its label.
        let files = ["Imported": "m.mp3"]
        XCTAssertEqual(Meeting.audioFileName(forSpeaker: "Imported", in: files), "m.mp3")
        XCTAssertEqual(Meeting.audioFileName(forSpeaker: "Me", in: files), "m.mp3",
                       "with exactly one file, an unmatched speaker still plays that file")
    }

    func testAudioFileNameNilWhenAmbiguousUnmatched() {
        // Two files, but the speaker matches neither and there's no single unambiguous
        // file → nil, so the row disables that segment rather than seek the wrong stream.
        let files = ["Me": "m-me.m4a", "Them": "m-them.m4a"]
        XCTAssertNil(Meeting.audioFileName(forSpeaker: "Guest", in: files))
        XCTAssertNil(Meeting.audioFileName(forSpeaker: "Me", in: nil), "nil map → nil")
        XCTAssertNil(Meeting.audioFileName(forSpeaker: "Me", in: [:]), "empty map → nil")
    }

    // MARK: activeSegmentIndex(at:segments:fileName:audioFiles:)

    func testActiveSegmentTracksTimeForSingleFile() {
        let files = ["Imported": "m.mp3"]
        let segs = [seg("Imported", 0, "a"), seg("Imported", 5, "b"), seg("Imported", 10, "c")]
        let idx = { (t: Double) in
            Meeting.activeSegmentIndex(at: t, segments: segs, fileName: "m.mp3", audioFiles: files)
        }
        XCTAssertEqual(idx(0), 0, "at the very start, the first segment is active")
        XCTAssertEqual(idx(4.9), 0, "still in the first segment's span up to the next start")
        XCTAssertEqual(idx(5), 1, "reaching a segment's start makes it active")
        XCTAssertEqual(idx(9.9), 1, "gaps are covered: active until the next segment begins")
        XCTAssertEqual(idx(1000), 2, "past the last start, the last segment stays active")
    }

    func testActiveSegmentBeforeFirstStartIsNil() {
        // A file whose first segment doesn't begin at 0 (e.g. the far-end started
        // speaking later) → nothing highlighted before that first start.
        let files = ["Them": "m-them.m4a"]
        let segs = [seg("Them", 3, "hi")]
        XCTAssertNil(Meeting.activeSegmentIndex(at: 0, segments: segs,
                                                fileName: "m-them.m4a", audioFiles: files))
        XCTAssertEqual(Meeting.activeSegmentIndex(at: 3, segments: segs,
                                                  fileName: "m-them.m4a", audioFiles: files), 0)
    }

    func testActiveSegmentOnlyConsidersMatchingFileInTwoStream() {
        // Interleaved Me/Them, separate files. Playing the -them file must only ever
        // highlight Them turns (index 1), never the Me turn between them, and it maps
        // back onto the ORIGINAL segment indices.
        let files = ["Me": "m-me.m4a", "Them": "m-them.m4a"]
        let segs = [seg("Me", 0, "me1"), seg("Them", 2, "them1"), seg("Me", 4, "me2")]
        XCTAssertEqual(
            Meeting.activeSegmentIndex(at: 3, segments: segs, fileName: "m-them.m4a", audioFiles: files),
            1, "the them file highlights only the Them segment, by its real index")
        // The me file, at the same time, is between its own two turns → the first Me turn.
        XCTAssertEqual(
            Meeting.activeSegmentIndex(at: 3, segments: segs, fileName: "m-me.m4a", audioFiles: files),
            0, "the me file highlights only Me segments")
        // Past the last Me turn, the me file lands on index 2 (skipping the Them turn).
        XCTAssertEqual(
            Meeting.activeSegmentIndex(at: 5, segments: segs, fileName: "m-me.m4a", audioFiles: files),
            2, "highlight skips the other stream's turns")
    }

    // MARK: hasPlayableAudio

    func testHasPlayableAudioRequiresBothSegmentsAndAudio() {
        let base = Meeting(title: "m", startUnix: 1, durationSec: 1, transcript: "t",
                           summary: "s", fileName: "m.md")
        XCTAssertFalse(base.hasPlayableAudio, "no segments, no audio → false")

        var segsOnly = base
        segsOnly.segments = [seg("Me", 0, "a")]
        XCTAssertFalse(segsOnly.hasPlayableAudio, "segments but no audio → false (pre-D9 note)")

        var audioOnly = base
        audioOnly.audioFiles = ["Me": "m-me.m4a"]
        XCTAssertFalse(audioOnly.hasPlayableAudio, "audio but no segments → false")

        var both = base
        both.segments = [seg("Me", 0, "a")]
        both.audioFiles = ["Me": "m-me.m4a"]
        XCTAssertTrue(both.hasPlayableAudio, "segments AND audio → playable")

        var emptyBoth = base
        emptyBoth.segments = []
        emptyBoth.audioFiles = [:]
        XCTAssertFalse(emptyBoth.hasPlayableAudio, "empty collections don't count")
    }

    // MARK: Codable back-compat

    func testAudioFilesDecodeIsOptionalAndRoundTrips() throws {
        // A pre-D9 note (no `audioFiles` key at all) must decode with nil.
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"old","startUnix":1,"durationSec":1,
         "transcript":"t","summary":"s","fileName":"old.md"}
        """
        let decoded = try JSONDecoder().decode(Meeting.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.audioFiles, "missing key decodes to nil, not a crash")

        // And a D9 note round-trips its map intact.
        var m = Meeting(title: "new", startUnix: 1, durationSec: 1, transcript: "t",
                        summary: "s", fileName: "new.md")
        m.audioFiles = ["Me": "new-me.m4a", "Them": "new-them.m4a"]
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(Meeting.self, from: data)
        XCTAssertEqual(back.audioFiles, m.audioFiles, "audioFiles survives an encode/decode round-trip")
    }

    // MARK: delete removes the kept audio

    @MainActor
    func testDeleteRemovesKeptAudioFilesAlongsideMarkdown() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fileName = MeetingStore.fileName(for: start, id: id)
        let stem = (fileName as NSString).deletingPathExtension
        let meName = "\(stem)-me.m4a"
        let themName = "\(stem)-them.m4a"

        // Stand in real (non-empty) audio files so the shredder's overwrite path runs.
        try Data(repeating: 0xAB, count: 2048).write(to: tmp.appendingPathComponent(meName))
        try Data(repeating: 0xCD, count: 2048).write(to: tmp.appendingPathComponent(themName))

        var meeting = Meeting(
            id: id, title: "Call", startUnix: start.timeIntervalSince1970, durationSec: 60,
            transcript: "hello", summary: "s", participants: ["Me", "Them"],
            source: "talkie (mic + system audio)", fileName: fileName)
        meeting.segments = [seg("Me", 0, "hello")]
        meeting.audioFiles = ["Me": meName, "Them": themName]
        store.add(meeting)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(fileName).path),
                      "the .md was written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(meName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(themName).path))

        store.delete(meeting)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(fileName).path),
                       "delete removes the .md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(meName).path),
                       "delete removes the -me audio (delete honesty)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(themName).path),
                       "delete removes the -them audio (delete honesty)")
    }

    @MainActor
    func testDeleteWithoutAudioFilesStillDeletesMarkdown() throws {
        // A pre-D9 / no-audio meeting: delete must behave exactly as before (remove the
        // .md), and the nil audioFiles path must not throw.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = Meeting(
            id: id, title: "Solo", startUnix: start.timeIntervalSince1970, durationSec: 30,
            transcript: "notes", summary: "s", fileName: MeetingStore.fileName(for: start, id: id))
        store.add(meeting)
        let mdPath = tmp.appendingPathComponent(meeting.fileName).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: mdPath))
        store.delete(meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mdPath), "delete still removes the .md")
    }
}
