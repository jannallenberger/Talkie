@preconcurrency import AVFoundation
import XCTest
import TalkieDiarization
@testable import Talkie

/// WP-S: transcript segments are split where the diarized speaker changes, using
/// word-level audio times carried (in memory) from the recognizer to the labeller.
@MainActor
final class SegmentSplittingTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        XCTAssertNotNil(AppPaths.testSandboxRoot, "tests must be sandboxed")
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentSplitting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private let eA: [Float] = [1, 0, 0], eB: [Float] = [0, 1, 0]

    /// `n` words "w0 w1 …" of `step` seconds each from `start`; raw text with a leading space on all but the first.
    private func words(_ n: Int, start: Double = 0, step: Double = 0.5, prefix: String = "w") -> [SegmentWord] {
        var result: [SegmentWord] = []
        for i in 0..<n {
            let lead: String = i == 0 ? "" : " "
            let s0: Double = start + Double(i) * step
            let e0: Double = start + Double(i + 1) * step - 0.05
            result.append(SegmentWord(text: lead + prefix + String(i), start: s0, end: e0))
        }
        return result
    }
    private func text(_ ws: [SegmentWord]) -> String { ws.map(\.text).joined() }
    private func seg(_ ws: [SegmentWord], lane: String = "Me", start: Double? = nil, end: Double? = nil) -> MeetingSegment {
        MeetingSegment(speaker: lane, start: start ?? ws.first!.start, end: end ?? ws.last!.end, text: text(ws))
    }
    private func out(_ turns: [(Int, Double, Double)]) -> DiarizationOutput {
        let t = turns.map { DiarizedTurn(speaker: $0.0, start: $0.1, end: $0.2) }
        let ids = Set(t.map(\.speaker)).sorted()
        return DiarizationOutput(turns: t, speakers: ids.map {
            SpeakerProfile(speaker: $0, embedding: $0 == 0 ? eA : eB, speechSeconds: 10)
        })
    }

    // MARK: SegmentSplitter (pure)

    func testSplitsWhereTheSpeakerChanges() {
        let ws = words(6)
        let p = SegmentSplitter.split(words: ws, speakers: [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(p, [.init(words: 0..<3, speaker: 0), .init(words: 3..<6, speaker: 1)])
    }

    func testIslandIsAbsorbedIntoItsNeighbours() {
        let ws = words(9)
        // one word (0.45 s) of speaker 1 inside speaker 0: flicker, absorbed, neighbours merge
        XCTAssertEqual(SegmentSplitter.split(words: ws, speakers: [0, 0, 0, 0, 1, 0, 0, 0, 0]),
                       [.init(words: 0..<9, speaker: 0)])
    }

    func testEdgeFlickerIsAbsorbed() {
        let ws = words(6)
        XCTAssertEqual(SegmentSplitter.split(words: ws, speakers: [1, 0, 0, 0, 0, 0]),
                       [.init(words: 0..<6, speaker: 0)])
        XCTAssertEqual(SegmentSplitter.split(words: ws, speakers: [0, 0, 0, 0, 0, 1]),
                       [.init(words: 0..<6, speaker: 0)])
    }

    func testRealInterjectionSurvives() {
        // 3 words (a sentence fragment) or >= 0.8 s are NOT flicker: kept as its own piece.
        let three = SegmentSplitter.split(words: words(9, step: 0.25), speakers: [0, 0, 0, 1, 1, 1, 0, 0, 0])
        XCTAssertEqual(three.map(\.speaker), [0, 1, 0])
        let slow = SegmentSplitter.split(words: words(6, step: 1.0), speakers: [0, 0, 0, 0, 1, 1])
        XCTAssertEqual(slow.map(\.speaker), [0, 1], "2 words but 2 s long")
    }

    func testAbsorbingChainsAndMergesAdjacentSameSpeakerPieces() {
        // 0 0 0 0 | 1 | 0 | 1 | 0 0 0 0: both single-word islands vanish, leaving one piece.
        let ws = words(11)
        XCTAssertEqual(SegmentSplitter.split(words: ws, speakers: [0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0]),
                       [.init(words: 0..<11, speaker: 0)])
    }

    func testUnknownWordsTakeTheirNeighbourAndAllUnknownIsOnePiece() {
        let ws = words(8)
        XCTAssertEqual(SegmentSplitter.split(words: ws, speakers: [nil, 0, 0, nil, nil, 1, 1, 1]).map(\.speaker), [0, 1])
        XCTAssertEqual(SegmentSplitter.split(words: ws, speakers: [nil, 0, 0, nil, nil, 1, 1, 1]).map(\.words),
                       [0..<5, 5..<8], "unknown words go to the previous labelled word")
        XCTAssertEqual(SegmentSplitter.split(words: ws, speakers: Array(repeating: nil, count: 8)),
                       [.init(words: 0..<8, speaker: nil)])
    }

    func testWordSpeakerIndexOverlapNearestAndNone() {
        let idx = WordSpeakerIndex(turns: [DiarizedTurn(speaker: 0, start: 0, end: 5), DiarizedTurn(speaker: 1, start: 5.2, end: 10)])
        XCTAssertEqual(idx.speaker(start: 4.8, end: 5.5), 1, "0.2 s vs 0.3 s overlap")
        XCTAssertEqual(idx.speaker(start: 5.12, end: 5.18), 1, "in the gap: nearest turn within slack (0.15 vs 0.05)")
        XCTAssertEqual(idx.speaker(start: 5.0, end: 5.1), 0)
        XCTAssertNil(idx.speaker(start: 20, end: 20.3), "no turn within the slack")
        XCTAssertEqual(idx.speaker(start: 3, end: 3), 0, "zero-length word is placed by its instant")
    }

    // MARK: Labelling with word timings

    func testLabelSplitsSegmentSnapsToWordBoundariesAndKeepsLane() {
        let ws = words(20) // 0 ... 10 s
        let s = seg(ws, start: 0, end: 10)
        // The boundary (5.2 s) falls inside word 10 (5.0-5.45): max overlap puts it with speaker 1.
        let r = SpeakerLabelling.label(segments: [s], words: [ws], mic: out([(0, 0, 5.2), (1, 5.2, 10)]), system: nil)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.segments.count, 2)
        XCTAssertEqual(r.sourceIndex, [0, 0])
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(r.segments.map(\.lane), ["Me", "Me"], "lane preserved so click-to-play finds the file")
        XCTAssertEqual(r.segments.map(\.audioKey), ["Me", "Me"])
        // Pieces partition the words: no word lost, none duplicated, boundary on a word edge.
        XCTAssertEqual(r.segments.map(\.text).joined(separator: " "), SegmentWord.normalized(s.text))
        XCTAssertEqual(r.segments[0].text, ws[0..<10].map(\.text).joined().trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(r.segments[0].start, 0)
        XCTAssertEqual(r.segments[0].end, ws[9].end, accuracy: 1e-9)
        XCTAssertEqual(r.segments[1].start, ws[10].start, accuracy: 1e-9)
        XCTAssertEqual(r.segments[1].end, 10, "outer bounds stay the source segment's")
        XCTAssertEqual(r.participants, ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(r.speakerCount, 2)
    }

    func testSegmentWithoutWordTimingsKeepsMajorityLabel() {
        let ws = words(20)
        let s = seg(ws, start: 0, end: 10)
        let r = SpeakerLabelling.label(segments: [s, seg(words(4, start: 10), start: 10, end: 12)],
                                       words: nil, mic: out([(0, 0, 6), (1, 6, 12)]), system: nil)
        XCTAssertEqual(r.segments.count, 2, "nothing split")
        XCTAssertEqual(r.segments[0].speaker, "Speaker 1", "first appearance numbering")
        XCTAssertEqual(r.segments[0].text, s.text)
        XCTAssertEqual(r.segments[0].start, 0); XCTAssertEqual(r.segments[0].end, 10)
        // mixed: the first has words, the second does not
        let mixed = SpeakerLabelling.label(segments: [s, seg(words(4, start: 10), start: 10, end: 12)],
                                           words: [ws, nil], mic: out([(0, 0, 5), (1, 5, 12)]), system: nil)
        XCTAssertEqual(mixed.segments.count, 3)
        XCTAssertEqual(mixed.sourceIndex, [0, 0, 1])
        XCTAssertEqual(mixed.segments[2].speaker, "Speaker 2")
    }

    func testWordsThatDoNotReproduceTheTextAreIgnored() {
        let ws = words(20)
        var s = seg(ws, start: 0, end: 10)
        s.text = "something else entirely"
        let r = SpeakerLabelling.label(segments: [s], words: [ws], mic: out([(0, 0, 5), (1, 5, 10)]), system: nil)
        XCTAssertEqual(r.segments.count, 1, "unvalidated words never split")
        XCTAssertEqual(r.segments[0].text, "something else entirely")
        XCTAssertNil(SegmentWord.validated([SegmentWord(text: "a", start: 2, end: 1)], for: "a"), "end before start")
        XCTAssertNil(SegmentWord.validated([SegmentWord(text: "a", start: 1, end: 2),
                                            SegmentWord(text: " b", start: 0.5, end: 2)], for: "a b"), "starts go backwards")
        XCTAssertNil(SegmentWord.validated([SegmentWord(text: "a", start: .nan, end: 2)], for: "a"))
    }

    func testLegacyOutcomeStaysUntouchedEvenWithWords() {
        let ws = words(20)
        let s = seg(ws, start: 0, end: 10)
        let r = SpeakerLabelling.label(segments: [s], words: [ws], mic: out([(0, 0, 10)]), system: nil)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.segments, [s], "one person: byte-identical, not split")
        XCTAssertEqual(r.sourceIndex, [0])
    }

    func testAntiFlickerIsAppliedInsideLabelling() {
        let ws = words(20)
        let s = seg(ws, start: 0, end: 10)
        // speaker 1 owns 0.45 s (one word) inside speaker 0's turn: no piece for it
        let r = SpeakerLabelling.label(
            segments: [s, seg(words(10, start: 10), start: 10, end: 15)], words: [ws, words(10, start: 10)],
            mic: out([(0, 0, 4.9), (1, 4.9, 5.35), (0, 5.35, 10), (1, 10, 15)]), system: nil)
        XCTAssertEqual(r.sourceIndex, [0, 1])
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    func testSplitMeetingRendersFromPiecesAndStillShowsTurns() {
        let ws = words(20)
        let s = seg(ws, start: 0, end: 10)
        let r = SpeakerLabelling.label(segments: [s], words: [ws], mic: out([(0, 0, 5), (1, 5, 10)]), system: nil)
        let original = Meeting(title: "T", startUnix: 1, durationSec: 10, transcript: s.text, summary: "",
                               participants: ["Me"], source: "s", fileName: "f.md", segments: [s],
                               audioFiles: ["Me": "x-me.m4a"])
        let m = MeetingDiarizationPipeline.apply(r, to: original)
        XCTAssertEqual(m.segments?.count, 2)
        XCTAssertEqual(m.transcript, MeetingTranscriptRenderer.render(segments: r.segments))
        XCTAssertTrue(m.transcript.contains("] Speaker 1: ") && m.transcript.contains("] Speaker 2: "))
        XCTAssertEqual(m.participants, ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(m.diarization, .applied)
        XCTAssertTrue(SpeakerPresentation.showsTurns(for: m), "an unedited diarized meeting renders turns")
        for piece in m.segments ?? [] {
            XCTAssertNotNil(m.audioFiles?[piece.audioKey], "click-to-play key resolves after a split")
        }
        // JSON round trip: pieces persist, the transient words never do.
        let data = try! JSONEncoder().encode(m)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"words\""))
        XCTAssertEqual(try! JSONDecoder().decode(Meeting.self, from: data).segments, m.segments)
    }

    // MARK: Digest remap

    func testDigestRemapMajorityRule() {
        let src = [MeetingSegment(speaker: "Me", start: 0, end: 10, text: "x")]
        func pieces(_ a: String, _ b: String) -> [MeetingSegment] {
            [MeetingSegment(speaker: "Speaker 1", start: 0, end: 5, text: a, lane: "Me"),
             MeetingSegment(speaker: "Speaker 2", start: 5, end: 10, text: b, lane: "Me")]
        }
        let ten = String(repeating: "a", count: 90), one = String(repeating: "b", count: 10)
        let hi = DigestSpeakerRemap(segments: pieces(ten, one), source: src, sourceIndex: [0, 0])
        XCTAssertEqual(hi.label(lane: .me, at: 0), "Speaker 1", "90 % holds the 80 % bar")
        let edge = DigestSpeakerRemap(segments: pieces(String(repeating: "a", count: 80), String(repeating: "b", count: 20)),
                                      source: src, sourceIndex: [0, 0])
        XCTAssertEqual(edge.label(lane: .me, at: 0), "Speaker 1", "exactly 80 % qualifies")
        let low = DigestSpeakerRemap(segments: pieces(String(repeating: "a", count: 70), String(repeating: "b", count: 30)),
                                     source: src, sourceIndex: [0, 0])
        XCTAssertNil(low.label(lane: .me, at: 0), "70/30 has no honest single speaker")
        XCTAssertNil(low.label(lane: .me, at: 5), "a piece start is not a digest line start")
        XCTAssertEqual(low.distinctLabels, 2)
        XCTAssertNil(low.laneWideLabel(.me))
    }

    func testDigestRemapUnsplitBehaviourIsUnchanged() {
        let segs = [MeetingSegment(speaker: "Speaker 1", start: 0, end: 4, text: "a", lane: "Me"),
                    MeetingSegment(speaker: "Speaker 2", start: 6, end: 9, text: "b", lane: "Me")]
        let r = DigestSpeakerRemap(segments: segs)
        XCTAssertEqual(r.label(lane: .me, at: 0), "Speaker 1")
        XCTAssertEqual(r.label(lane: .me, at: 6.03), "Speaker 2")
        XCTAssertNil(r.label(lane: .me, at: 3))
        XCTAssertNil(r.label(lane: .them, at: 0))
    }

    // MARK: Recorder step

    private func makeRecorder(_ segs: [MeetingSegment]) -> (MeetingRecorder, MeetingStore, Meeting) {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let recorder = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store)
        recorder.diarizationModelsDirectory = { self.tmp }
        recorder.ownVoiceStore = OwnVoiceProfileStore(url: tmp.appendingPathComponent("own-voice.json"))
        let m = Meeting(title: "T", startUnix: 1_700_000_000, durationSec: 10,
                        transcript: MeetingTranscriptRenderer.render(segments: segs), summary: "",
                        participants: ["Me"], source: "talkie (mic-only)", fileName: "t-meeting.md", segments: segs,
                        audioFiles: ["Me": "t-me.m4a"])
        store.add(m)
        return (recorder, store, m)
    }

    private func micInput(_ id: UUID) throws -> [MeetingDiarizationPipeline.LaneInput] {
        let mic = MeetingDiarizationTemp.url(meetingID: id, lane: "Me", in: tmp)
        try Data([0]).write(to: mic)
        return [.init(lane: "Me", fileURL: mic)]
    }

    private func perLane(_ o: DiarizationOutput) -> FakeLaneDiarizer { FakeLaneDiarizer(behavior: .perLane(["-mic.wav": o])) }

    func testStepSplitsPersistsAndRemapsDigestByMajority() async throws {
        let ws = words(20)
        let s = seg(ws, start: 0, end: 10)
        let (recorder, store, original) = makeRecorder([s])
        // Speaker 1 speaks words 0-17 (9 s), speaker 2 the last two words (1 s): 90 / 10.
        let fake = perLane(out([(0, 0, 9), (1, 9, 10)]))
        recorder.laneDiarizerFactory = { _ in fake }
        let digest = MeetingDigestBuilder(summarizer: MeetingSummarizer(), graphExtractor: nil)
        digest.ingest(.me, s.text, at: 0)
        let step = await recorder.diarizationStep(
            id: original.id, inputs: try micInput(original.id), segments: [s], words: [ws],
            transcript: original.transcript, durationSec: 10)
        XCTAssertTrue(step.relabelled)
        XCTAssertEqual(step.segments?.count, 2)
        XCTAssertEqual(step.sourceIndex, [0, 0])
        let stored = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(stored.segments?.count, 2, "the split segments are what is persisted")
        XCTAssertEqual(stored.transcript, step.transcript)
        XCTAssertTrue(SpeakerPresentation.showsTurns(for: stored))
        let kept = await recorder.remapDigest(digest, segments: step.segments, source: [s], sourceIndex: step.sourceIndex)
        XCTAssertTrue(kept, "one speaker holds >= 80 % of the line")
        XCTAssertTrue(digest.pendingTextForTesting().hasPrefix("Speaker 1: "))
    }

    func testStepFailsTheDigestRemapWhenNoSpeakerHoldsEightyPercent() async throws {
        let ws = words(20)
        let s = seg(ws, start: 0, end: 10)
        let (recorder, _, original) = makeRecorder([s])
        let fake = perLane(out([(0, 0, 6), (1, 6, 10)])) // 60 / 40
        recorder.laneDiarizerFactory = { _ in fake }
        let digest = MeetingDigestBuilder(summarizer: MeetingSummarizer(), graphExtractor: nil)
        digest.ingest(.me, s.text, at: 0)
        let step = await recorder.diarizationStep(
            id: original.id, inputs: try micInput(original.id), segments: [s], words: [ws],
            transcript: original.transcript, durationSec: 10)
        XCTAssertTrue(step.relabelled)
        let kept = await recorder.remapDigest(digest, segments: step.segments, source: [s], sourceIndex: step.sourceIndex)
        XCTAssertFalse(kept, "remap fails, so the caller rebuilds the digest from the transcript")
    }

    func testFailureAndTimeoutPathIsUnchangedWithWords() async throws {
        let ws = words(20)
        let s = seg(ws, start: 0, end: 10)
        for behavior in [FakeLaneDiarizer.Behavior.throwError, .hangNonCooperatively(seconds: 4)] {
            let (recorder, store, original) = makeRecorder([s])
            recorder.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: behavior) }
            recorder.diarizationBudget = { _ in 0.3 }
            let before = try XCTUnwrap(store.meetings.first)
            let step = await recorder.diarizationStep(
                id: original.id, inputs: try micInput(original.id), segments: [s], words: [ws],
                transcript: original.transcript, durationSec: 10)
            XCTAssertFalse(step.relabelled)
            XCTAssertNil(step.sourceIndex)
            XCTAssertEqual(step.transcript, original.transcript)
            let after = try XCTUnwrap(store.meetings.first)
            XCTAssertEqual(after.segments, before.segments, "Me/Them segments untouched")
            XCTAssertEqual(after.transcript, before.transcript)
            XCTAssertEqual(after.participants, before.participants)
            XCTAssertEqual(after, original, "stored meeting byte-identical")
        }
        // models absent: skipped silently, still unchanged
        let (recorder, store, original) = makeRecorder([s])
        recorder.diarizationModelsDirectory = { nil }
        let step = await recorder.diarizationStep(
            id: original.id, inputs: try micInput(original.id), segments: [s], words: [ws],
            transcript: original.transcript, durationSec: 10)
        XCTAssertNil(step.state)
        XCTAssertFalse(step.relabelled)
        XCTAssertEqual(store.meetings.first, original)
        // and the pipeline reports the same outcome with or without words
        let id = UUID()
        let ins = try micInput(id)
        for w in [[ws], nil] as [[[SegmentWord]?]?] {
            let o = await MeetingDiarizationPipeline.run(
                inputs: ins, segments: [s], words: w,
                diarizer: FakeLaneDiarizer(behavior: .throwError), budgetSeconds: 5)
            guard case .failed = o else { return XCTFail("\(o)") }
        }
    }

    // MARK: Words carried from the recognizer to the labelling step

    func testTurnLogCarriesWordsIntoSegments() throws {
        let ws = words(4)
        let log = TurnLog(startedAt: Date())
        log.add(.me, text(ws), at: 0, end: 2, words: ws)
        log.add(.me, "plain", at: 3, end: 4)
        let r = try XCTUnwrap(MeetingTranscriptRenderer.segmentsWithWords(from: log.snapshot()))
        XCTAssertEqual(r.segments.count, 2)
        XCTAssertEqual(r.words[0], ws)
        XCTAssertNil(r.words[1])
        XCTAssertEqual(r.segments, MeetingTranscriptRenderer.segments(from: log.snapshot()),
                       "segments(from:) is unchanged by the words")
    }

    func testDecollapsedPiecesDropWordTimings() throws {
        // A frozen run (stalled recognizer) is re-chunked and re-timed: its word times are stale.
        let big = words(200, start: 0, step: 0.001)
        let log = TurnLog(startedAt: Date())
        log.add(.me, text(big), at: 0, end: 0.2, words: big)
        let r = try XCTUnwrap(MeetingTranscriptRenderer.segmentsWithWords(from: log.snapshot(), duration: 600))
        XCTAssertGreaterThan(r.segments.count, 1)
        XCTAssertTrue(r.words.allSatisfy { $0 == nil })
    }

    func testMultilingualTimedTurnsKeepWords() throws {
        let ws = words(3)
        let log = TurnLog(startedAt: Date())
        log.add(.me, "placeholder", at: 99, end: 100)
        log.replace(.me, withTimedTurns: [(elapsed: 0, text: text(ws), end: 1.4, words: ws)])
        let r = try XCTUnwrap(MeetingTranscriptRenderer.segmentsWithWords(from: log.snapshot()))
        XCTAssertEqual(r.words, [ws])
    }

    func testMergedSpansCarryRotationShiftedWordsThatReproduceTheText() {
        let words: [StreamLanguageVoter.TimedWord] = [
            .init(localeID: "de-DE", text: "Hallo", start: 100.0, end: 100.4, confidence: 0.9),
            .init(localeID: "de-DE", text: "Welt", start: 100.5, end: 100.9, confidence: 0.9),
        ]
        let spans = StreamLanguageVoter.mergeWords(words)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].text, "Hallo Welt")
        XCTAssertEqual(spans[0].words.map(\.start), [100.0, 100.5], "times stay in the (offset-corrected) meeting clock")
        XCTAssertNotNil(SegmentWord.validated(spans[0].words, for: spans[0].text))
    }
}
