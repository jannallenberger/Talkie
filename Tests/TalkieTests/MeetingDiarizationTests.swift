@preconcurrency import AVFoundation
import XCTest
import TalkieDiarization
@testable import Talkie

/// Fake diarizers + helpers shared by the diarization plumbing tests.
struct FakeLaneDiarizer: LaneDiarizing {
    enum Behavior: Sendable {
        case output(DiarizationOutput)
        case perLane([String: DiarizationOutput])   // keyed by file name suffix ("-mic.wav"/"-sys.wav")
        case throwError
        case hangNonCooperatively(seconds: Double)
    }
    let behavior: Behavior
    func diarize(fileURL: URL) async throws -> DiarizationOutput {
        switch behavior {
        case .output(let o): return o
        case .perLane(let m):
            for (suffix, o) in m where fileURL.lastPathComponent.hasSuffix(suffix) { return o }
            return .empty
        case .throwError: throw DiarizationError.processingFailed("boom")
        case .hangNonCooperatively(let s):
            // Blocks a thread and ignores cancellation, like a CoreML prediction.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { Thread.sleep(forTimeInterval: s); c.resume() }
            }
            return .empty
        }
    }
}

/// Meeting JSON compatibility.
final class MeetingDiarizationCodableTests: XCTestCase {
    /// A meetings.json entry exactly as written before diarization existed.
    private let oldEntry = """
    [{"id":"6F1B5C52-0A5E-4B4F-9D0B-2B7C9F3B1A11","title":"Old","startUnix":1700000000,"durationSec":120,
      "transcript":"[00:00] Me: hi\\n[00:03] Them: hello","summary":"s","participants":["Me","Them"],
      "source":"talkie (mic + system audio)","fileName":"2023-11-14-221320-6f1b-meeting.md",
      "segments":[{"speaker":"Me","start":0,"end":2,"text":"hi"},{"speaker":"Them","start":3,"end":4,"text":"hello"}],
      "audioFiles":{"Me":"a-me.m4a","Them":"a-them.m4a"}}]
    """

    func testOldEntryDecodesWithNewFieldsNil() throws {
        let meetings = try JSONDecoder().decode([Meeting].self, from: Data(oldEntry.utf8))
        let m = try XCTUnwrap(meetings.first)
        XCTAssertNil(m.speakerCount)
        XCTAssertNil(m.diarizationState)
        XCTAssertNil(m.diarization)
        XCTAssertEqual(m.segments?.map(\.speaker), ["Me", "Them"])
        XCTAssertEqual(m.segments?.map(\.lane), [nil, nil])
        XCTAssertEqual(m.segments?[0].audioKey, "Me")
        XCTAssertEqual(m.participants, ["Me", "Them"])
        // Re-encoding an untouched old meeting adds no new keys for the new optionals.
        let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        XCTAssertFalse(json.contains("\"lane\""))
    }

    func testNewFieldsRoundTripAndUnknownStateIsTolerated() throws {
        var m = try JSONDecoder().decode([Meeting].self, from: Data(oldEntry.utf8))[0]
        m.speakerCount = 3
        m.diarizationState = DiarizationState.applied.rawValue
        m.segments?[1].lane = "Them"
        m.segments?[1].speaker = "Speaker 2"
        let back = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.speakerCount, 3)
        XCTAssertEqual(back.diarization, .applied)
        XCTAssertEqual(back.segments?[1].speaker, "Speaker 2")
        XCTAssertEqual(back.segments?[1].audioKey, "Them")

        m.diarizationState = "some-future-state"
        let future = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(future.diarizationState, "some-future-state")
        XCTAssertNil(future.diarization)
    }

    func testClickToPlayResolvesAudioByLaneAfterRelabel() {
        let files = ["Me": "m.m4a", "Them": "t.m4a"]
        let segs = [
            MeetingSegment(speaker: "Speaker 1", start: 0, end: 2, text: "a", lane: "Me"),
            MeetingSegment(speaker: "Speaker 2", start: 3, end: 4, text: "b", lane: "Them"),
            MeetingSegment(speaker: "Speaker 3", start: 5, end: 6, text: "c", lane: "Me"),
        ]
        XCTAssertEqual(Meeting.audioFileName(forSpeaker: segs[1].audioKey, in: files), "t.m4a")
        XCTAssertEqual(Meeting.activeSegmentIndex(at: 5.5, segments: segs, fileName: "m.m4a", audioFiles: files), 2)
        XCTAssertEqual(Meeting.activeSegmentIndex(at: 3.5, segments: segs, fileName: "t.m4a", audioFiles: files), 1)
    }

    func testMCPSeesRelabelledTranscriptAndParticipantsUnchangedKeys() throws {
        // talkie-mcp decodes meetings.json with its own struct (id,title,startUnix,
        // durationSec,transcript,summary,participants,source,fileName) and ignores the
        // rest; get_meeting prints transcript + participants verbatim.
        var m = try JSONDecoder().decode([Meeting].self, from: Data(oldEntry.utf8))[0]
        let result = SpeakerLabelling.Result(
            segments: [MeetingSegment(speaker: "Speaker 1", start: 0, end: 2, text: "hi", lane: "Me"),
                       MeetingSegment(speaker: "Speaker 2", start: 3, end: 4, text: "hello", lane: "Them")],
            participants: ["Speaker 1", "Speaker 2"], speakerCount: 2, changed: true)
        m = MeetingDiarizationPipeline.apply(result, to: m)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        XCTAssertEqual(obj["transcript"] as? String, "[00:00] Speaker 1: hi\n[00:03] Speaker 2: hello")
        XCTAssertEqual(obj["participants"] as? [String], ["Speaker 1", "Speaker 2"])
        XCTAssertNotNil(obj["title"]); XCTAssertNotNil(obj["fileName"])
    }
}

/// The tee: alignment with the recognizer clock, resampling, cleanup.
final class MeetingDiarizationTeeTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        XCTAssertNotNil(AppPaths.testSandboxRoot, "tests must be sandboxed from real Application Support")
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tee-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func floatMono(_ rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    /// Feed `totalFrames` of silence with one full-scale impulse at `impulseFrame`, in
    /// capture-sized chunks (the last one short), advancing a simulated ANALYZER CLOCK
    /// by exactly the frames of each buffer — the way `SpeechAnalyzer` / `audioSecondsFed`
    /// derive time. Returns that clock's value at the impulse.
    private func feed(_ tee: MeetingDiarizationTee, format: AVAudioFormat, totalFrames: Int,
                      impulseFrame: Int, chunk: Int = 4096) -> Double {
        var analyzerSeconds = 0.0, atImpulse = -1.0, pos = 0
        while pos < totalFrames {
            let n = min(chunk, totalFrames - pos)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            if let p = buf.floatChannelData?[0] {
                for i in 0..<n { p[i] = 0 }
                if impulseFrame >= pos, impulseFrame < pos + n { p[impulseFrame - pos] = 1 }
            } else if let p = buf.int16ChannelData?[0] {
                for i in 0..<n { p[i] = 0 }
                if impulseFrame >= pos, impulseFrame < pos + n { p[impulseFrame - pos] = 32_000 }
            }
            if impulseFrame >= pos, impulseFrame < pos + n {
                atImpulse = analyzerSeconds + Double(impulseFrame - pos) / format.sampleRate
            }
            analyzerSeconds += Double(n) / format.sampleRate
            tee.append(buf)
            pos += n
        }
        return atImpulse
    }

    private func readBack(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        XCTAssertEqual(f.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(f.processingFormat.channelCount, 1)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    private func peakTime(_ samples: [Float]) -> Double {
        let i = samples.indices.max { abs(samples[$0]) < abs(samples[$1]) }!
        return Double(i) / 16_000
    }

    func testAlignmentAt16kFloatIsSampleExact() throws {
        let tee = MeetingDiarizationTee(url: tmp.appendingPathComponent("a.wav"))
        let analyzerT = feed(tee, format: floatMono(16_000), totalFrames: 16_000 * 30 + 77, impulseFrame: 16_000 * 12 + 5)
        let summary = try XCTUnwrap(tee.close())
        let samples = try readBack(summary.url)
        XCTAssertEqual(samples.count, 16_000 * 30 + 77, "no gaps, padding or trimming")
        XCTAssertEqual(peakTime(samples), analyzerT, accuracy: 1.0 / 16_000)
    }

    func testAlignmentAt16kInt16() throws {
        // SpeechAnalyzer's usual format is Int16 mono 16 kHz.
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let tee = MeetingDiarizationTee(url: tmp.appendingPathComponent("b.wav"))
        let analyzerT = feed(tee, format: fmt, totalFrames: 16_000 * 20, impulseFrame: 16_000 * 7 + 123)
        let samples = try readBack(try XCTUnwrap(tee.close()).url)
        XCTAssertEqual(samples.count, 16_000 * 20)
        XCTAssertEqual(peakTime(samples), analyzerT, accuracy: 1.0 / 16_000)
    }

    func testAlignmentWhenResamplingFrom48k() throws {
        let tee = MeetingDiarizationTee(url: tmp.appendingPathComponent("c.wav"))
        // 90 s at 48 kHz in odd-sized chunks; impulse at 61.25 s analyzer time.
        let analyzerT = feed(tee, format: floatMono(48_000), totalFrames: 48_000 * 90,
                             impulseFrame: Int(48_000 * 61.25), chunk: 4800)
        let summary = try XCTUnwrap(tee.close())
        let samples = try readBack(summary.url)
        XCTAssertEqual(analyzerT, 61.25, accuracy: 1e-9)
        // Impulse lands within 1 ms of the analyzer clock after a 61 s streamed resample.
        XCTAssertEqual(peakTime(samples), analyzerT, accuracy: 0.001)
        // No cumulative drift: file length matches source duration to a few samples.
        XCTAssertEqual(Double(samples.count) / 16_000, 90, accuracy: 0.01)
        XCTAssertEqual(summary.sourceFrames, 48_000 * 90)
    }

    func testUnusedTeeProducesNoFileAndCloseIsIdempotent() {
        let url = tmp.appendingPathComponent("empty.wav")
        let tee = MeetingDiarizationTee(url: url)
        XCTAssertNil(tee.close())
        XCTAssertNil(tee.close())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLateBufferAfterCloseDoesNotResurrectTheFile() throws {
        let url = tmp.appendingPathComponent("late.wav")
        let tee = MeetingDiarizationTee(url: url)
        _ = feed(tee, format: floatMono(16_000), totalFrames: 16_000, impulseFrame: 10)
        XCTAssertNotNil(tee.close())
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        _ = feed(tee, format: floatMono(16_000), totalFrames: 16_000, impulseFrame: 10)
        tee.close()
        let size2 = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        XCTAssertEqual(size, size2)
    }

    func testTempHelpersAndStaleSweep() throws {
        let id = UUID()
        let mic = MeetingDiarizationTemp.url(meetingID: id, lane: "Me", in: tmp)
        let sys = MeetingDiarizationTemp.url(meetingID: id, lane: "Them", in: tmp)
        XCTAssertNotEqual(mic, sys)
        XCTAssertTrue(mic.path.hasPrefix(tmp.path))
        try Data([1]).write(to: mic); try Data([2]).write(to: sys)
        // A "crashed run" left both behind; the next-start sweep clears them.
        XCTAssertEqual(MeetingDiarizationTemp.sweepStale(in: tmp), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
        try Data([1]).write(to: mic)
        MeetingDiarizationTemp.remove([mic, sys])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mic.path))
    }

    func testRealTempDirectoryIsInsideTheTestSandbox() {
        let dir = AppPaths.diarizationTempDirectory()
        XCTAssertTrue(dir.path.hasPrefix(AppPaths.testSandboxRoot!.path), dir.path)
    }
}

final class TimeBoxTests: XCTestCase {
    func testReturnsValueWhenFast() async {
        let v = await TimeBox.run(seconds: 5) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testReturnsNilPromptlyEvenWhenOperationNeverCooperates() async {
        let start = Date()
        let v: Int? = await TimeBox.run(seconds: 0.3) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { Thread.sleep(forTimeInterval: 4); c.resume() }
            }
            return 1
        }
        XCTAssertNil(v)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "must not wait for the hung operation")
    }
}

/// Pipeline + recorder step with fakes: every failure leaves Me/Them byte-identical
/// and temp audio deleted.
@MainActor
final class MeetingDiarizationPipelineTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private let segs = [
        MeetingSegment(speaker: "Me", start: 0, end: 10, text: "hello"),
        MeetingSegment(speaker: "Them", start: 12, end: 20, text: "hi"),
        MeetingSegment(speaker: "Me", start: 22, end: 30, text: "yes"),
    ]
    private let eA: [Float] = [1, 0, 0], eB: [Float] = [0, 1, 0], eC: [Float] = [0, 0, 1]

    private func twoOnMic() -> [String: DiarizationOutput] {
        ["-mic.wav": DiarizationOutput(
            turns: [DiarizedTurn(speaker: 0, start: 0, end: 10), DiarizedTurn(speaker: 1, start: 22, end: 30)],
            speakers: [SpeakerProfile(speaker: 0, embedding: eA, speechSeconds: 10),
                       SpeakerProfile(speaker: 1, embedding: eB, speechSeconds: 8)]),
         "-sys.wav": DiarizationOutput(
            turns: [DiarizedTurn(speaker: 0, start: 12, end: 20)],
            speakers: [SpeakerProfile(speaker: 0, embedding: eC, speechSeconds: 8)])]
    }

    private func inputs(_ id: UUID) throws -> [MeetingDiarizationPipeline.LaneInput] {
        let mic = MeetingDiarizationTemp.url(meetingID: id, lane: "Me", in: tmp)
        let sys = MeetingDiarizationTemp.url(meetingID: id, lane: "Them", in: tmp)
        try Data([0]).write(to: mic); try Data([0]).write(to: sys)
        return [.init(lane: "Me", fileURL: mic), .init(lane: "Them", fileURL: sys)]
    }

    func testPipelineOutcomes() async throws {
        let id = UUID()
        let ins = try inputs(id)
        let ok = await MeetingDiarizationPipeline.run(
            inputs: ins, segments: segs, diarizer: FakeLaneDiarizer(behavior: .perLane(twoOnMic())), budgetSeconds: 5)
        guard case .labelled(let r) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 3"])

        let thrown = await MeetingDiarizationPipeline.run(
            inputs: ins, segments: segs, diarizer: FakeLaneDiarizer(behavior: .throwError), budgetSeconds: 5)
        guard case .failed = thrown else { return XCTFail("\(thrown)") }

        let start = Date()
        let hung = await MeetingDiarizationPipeline.run(
            inputs: ins, segments: segs, diarizer: FakeLaneDiarizer(behavior: .hangNonCooperatively(seconds: 5)),
            budgetSeconds: 0.3)
        guard case .timedOut = hung else { return XCTFail("\(hung)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)

        let missing = await MeetingDiarizationPipeline.run(
            inputs: [ins[0]], segments: segs, diarizer: FakeLaneDiarizer(behavior: .perLane(twoOnMic())), budgetSeconds: 5)
        guard case .failed = missing else { return XCTFail("a lane with speech but no audio must not half-label: \(missing)") }

        let none = await MeetingDiarizationPipeline.run(
            inputs: ins, segments: [], diarizer: FakeLaneDiarizer(behavior: .throwError), budgetSeconds: 5)
        guard case .unavailable = none else { return XCTFail("\(none)") }
    }

    func testBudgetScalesWithDurationAndIsBounded() {
        XCTAssertEqual(MeetingDiarizationPipeline.budget(audioSeconds: 0), 60)
        XCTAssertEqual(MeetingDiarizationPipeline.budget(audioSeconds: 600), 180)
        XCTAssertEqual(MeetingDiarizationPipeline.budget(audioSeconds: 100_000), 900)
    }

    // MARK: recorder step (diarizationStep)

    private func makeRecorder() -> (MeetingRecorder, MeetingStore, Meeting) {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let recorder = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store)
        recorder.diarizationModelsDirectory = { self.tmp }   // any non-nil: the fake ignores it
        recorder.ownVoiceStore = OwnVoiceProfileStore(url: tmp.appendingPathComponent("own-voice.json"))
        let transcript = MeetingTranscriptRenderer.render(segments: segs)
        let m = Meeting(title: "T", startUnix: 1_700_000_000, durationSec: 40, transcript: transcript, summary: "",
                        participants: ["Me", "Them"], source: "talkie (mic + system audio)",
                        fileName: "t-meeting.md", segments: segs)
        store.add(m)
        return (recorder, store, m)
    }

    func testStepFailureAndTimeoutLeaveMeetingByteIdenticalAndDeleteTempAudio() async throws {
        for behavior in [FakeLaneDiarizer.Behavior.throwError, .hangNonCooperatively(seconds: 4)] {
            let (recorder, store, original) = makeRecorder()
            recorder.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: behavior) }
            recorder.diarizationBudget = { _ in 0.3 }
            let ins = try inputs(original.id)
            let step = await recorder.diarizationStep(
                id: original.id, inputs: ins, segments: original.segments,
                transcript: original.transcript, durationSec: 40)
            XCTAssertEqual(step.transcript, original.transcript)
            XCTAssertFalse(step.relabelled)
            XCTAssertNotNil(step.state)
            XCTAssertEqual(store.meetings.first, original, "stored meeting untouched (labels byte-identical)")
            for i in ins { XCTAssertFalse(FileManager.default.fileExists(atPath: i.fileURL.path), "temp audio deleted") }
            XCTAssertTrue(recorder.diarizingMeetingIDs.isEmpty)
        }
    }

    func testStepModelsAbsentSkipsSilentlyAndStillDeletesAudio() async throws {
        let (recorder, store, original) = makeRecorder()
        recorder.diarizationModelsDirectory = { nil }
        let ins = try inputs(original.id)
        let step = await recorder.diarizationStep(
            id: original.id, inputs: ins, segments: original.segments, transcript: original.transcript, durationSec: 40)
        XCTAssertNil(step.state)
        XCTAssertEqual(store.meetings.first, original)
        for i in ins { XCTAssertFalse(FileManager.default.fileExists(atPath: i.fileURL.path)) }
    }

    func testStepRelabelsStoredMeetingAndMarkdown() async throws {
        let (recorder, store, original) = makeRecorder()
        let two = twoOnMic()
        recorder.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: .perLane(two)) }
        let ins = try inputs(original.id)
        let step = await recorder.diarizationStep(
            id: original.id, inputs: ins, segments: original.segments,
            transcript: original.transcript, durationSec: 40)
        XCTAssertTrue(step.relabelled)
        XCTAssertEqual(step.state, .applied)
        let m = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(m.participants, ["Speaker 1", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(m.speakerCount, 3)
        XCTAssertEqual(m.diarization, .applied)
        XCTAssertEqual(m.transcript, "[00:00] Speaker 1: hello\n[00:12] Speaker 2: hi\n[00:22] Speaker 3: yes")
        XCTAssertEqual(step.transcript, m.transcript, "the summary is fed the relabelled transcript")
        let md = try String(contentsOf: tmp.appendingPathComponent("t-meeting.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("[00:12] Speaker 2: hi"))
        XCTAssertTrue(md.contains("Speaker 1, Speaker 2, Speaker 3"), "front-matter participants re-rendered")
        for i in ins { XCTAssertFalse(FileManager.default.fileExists(atPath: i.fileURL.path)) }
    }

    func testStepDoesNotClobberAnEditedTranscript() async throws {
        let (recorder, store, original) = makeRecorder()
        let two = twoOnMic()
        recorder.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: .perLane(two)) }
        var edited = original
        edited.transcript = "user edited this"
        store.update(edited)
        let step = await recorder.diarizationStep(
            id: original.id, inputs: try inputs(original.id), segments: original.segments,
            transcript: original.transcript, durationSec: 40)
        XCTAssertFalse(step.relabelled)
        XCTAssertEqual(store.meetings.first?.transcript, "user edited this")
    }

    func testStepLearnsOwnVoiceFromSingleMicSpeakerButNotFromTwo() async throws {
        let (recorder, _, original) = makeRecorder()
        let two = twoOnMic()
        recorder.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: .perLane(two)) }
        _ = await recorder.diarizationStep(
            id: original.id, inputs: try inputs(original.id), segments: original.segments,
            transcript: original.transcript, durationSec: 40)
        XCTAssertNil(recorder.ownVoiceStore.load(), "two mic speakers: nothing learned")

        let (recorder2, _, original2) = makeRecorder()
        let oneEach: [String: DiarizationOutput] = [
            "-mic.wav": DiarizationOutput(
                turns: [DiarizedTurn(speaker: 0, start: 0, end: 40)],
                speakers: [SpeakerProfile(speaker: 0, embedding: eA, speechSeconds: 40)]),
            "-sys.wav": DiarizationOutput(
                turns: [DiarizedTurn(speaker: 0, start: 0, end: 40)],
                speakers: [SpeakerProfile(speaker: 0, embedding: eB, speechSeconds: 40)])]
        recorder2.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: .perLane(oneEach)) }
        _ = await recorder2.diarizationStep(
            id: original2.id, inputs: try inputs(original2.id), segments: original2.segments,
            transcript: original2.transcript, durationSec: 40)
        XCTAssertEqual(recorder2.ownVoiceStore.load()?.sampleCount, 1, "single mic speaker: learned")
    }

    func testStepKeepsAndRemapsTheLiveDigest() async throws {
        let (recorder, _, original) = makeRecorder()
        let two = twoOnMic()
        recorder.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: .perLane(two)) }
        let digest = MeetingDigestBuilder(summarizer: MeetingSummarizer(), graphExtractor: nil)
        digest.ingest(.me, "hello", at: 0)
        digest.ingest(.them, "hi", at: 12)
        digest.ingest(.me, "yes", at: 22)
        let step = await recorder.diarizationStep(
            id: original.id, inputs: try inputs(original.id), segments: original.segments,
            transcript: original.transcript, durationSec: 40)
        XCTAssertTrue(step.relabelled)
        let kept = await recorder.remapDigest(digest, segments: step.segments)
        XCTAssertTrue(kept, "digest stays usable: no transcript rebuild")
        XCTAssertEqual(digest.pendingTextForTesting(), "Speaker 1: hello Speaker 2: hi Speaker 3: yes")
        // Impossible remap (a line with no matching segment) reports false -> rebuild.
        let stray = MeetingDigestBuilder(summarizer: MeetingSummarizer(), graphExtractor: nil)
        stray.ingest(.me, "x", at: 5)
        let rebuilt = await recorder.remapDigest(stray, segments: step.segments)
        XCTAssertFalse(rebuilt)
        let none = await recorder.remapDigest(digest, segments: nil)
        XCTAssertFalse(none)
    }

    func testStepOnePlusOneKeepsLabelsAndRecordsMetadataOnly() async throws {
        let (recorder, store, original) = makeRecorder()
        let oneEach: [String: DiarizationOutput] = [
            "-mic.wav": DiarizationOutput(
                turns: [DiarizedTurn(speaker: 0, start: 0, end: 40)],
                speakers: [SpeakerProfile(speaker: 0, embedding: eA, speechSeconds: 40)]),
            "-sys.wav": DiarizationOutput(
                turns: [DiarizedTurn(speaker: 0, start: 0, end: 40)],
                speakers: [SpeakerProfile(speaker: 0, embedding: eB, speechSeconds: 40)])]
        recorder.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: .perLane(oneEach)) }
        let step = await recorder.diarizationStep(
            id: original.id, inputs: try inputs(original.id), segments: original.segments,
            transcript: original.transcript, durationSec: 40)
        XCTAssertFalse(step.relabelled)
        XCTAssertEqual(step.state, .unchanged)
        XCTAssertEqual(step.speakerCount, 2)
        XCTAssertEqual(store.meetings.first, original, "no store write, labels identical")
    }
}
