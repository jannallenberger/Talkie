@preconcurrency import AVFoundation
import XCTest
import TalkieDiarization
@testable import Talkie

/// Regression tests for the post-merge review fixes F1-F10 of the speaker-diarization
/// feature (see each test's name).
@MainActor
final class DiarizationReviewFixTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        // Hard guard: nothing here may touch the real Application Support.
        XCTAssertNotNil(AppPaths.testSandboxRoot, "tests must be sandboxed")
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiarizationReviewFix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private let eA: [Float] = [1, 0, 0, 0]
    private let eB: [Float] = [0, 1, 0, 0]
    private let eBBleed: [Float] = [0.05, 0.95, 0.1, 0]

    private func out(_ turns: [(Int, Double, Double)], _ emb: [Int: [Float]]) -> DiarizationOutput {
        let t = turns.map { DiarizedTurn(speaker: $0.0, start: $0.1, end: $0.2) }
        let profiles = emb.keys.sorted().map { id in
            SpeakerProfile(speaker: id, embedding: emb[id]!,
                           speechSeconds: t.filter { $0.speaker == id }.reduce(0) { $0 + $1.duration })
        }
        return DiarizationOutput(turns: t, speakers: profiles)
    }
    private func seg(_ who: String, _ s: Double, _ e: Double, _ text: String = "x") -> MeetingSegment {
        MeetingSegment(speaker: who, start: s, end: e, text: text)
    }

    // MARK: F1 - which meetings render as speaker turns

    func testF1TurnsViewOnlyForAppliedUneditedMeetings() {
        let segs = [seg("Speaker 1", 0, 4, "hello"), seg("Speaker 2", 5, 9, "hi")]
        let rendered = MeetingTranscriptRenderer.render(segments: segs)
        var m = Meeting(title: "t", startUnix: 1, durationSec: 10, transcript: rendered, summary: "",
                        participants: ["Speaker 1", "Speaker 2"], source: "s", fileName: "f.md", segments: segs)
        XCTAssertFalse(SpeakerPresentation.showsTurns(for: m), "no diarization state: legacy rendering")
        m.diarizationState = DiarizationState.applied.rawValue
        XCTAssertTrue(SpeakerPresentation.showsTurns(for: m))
        m.transcript = rendered + " (edited by hand)"
        XCTAssertFalse(SpeakerPresentation.showsTurns(for: m), "a hand-edited transcript shows the user's text")
        for state in [DiarizationState.unchanged, .failed, .timedOut] {
            m.transcript = rendered
            m.diarizationState = state.rawValue
            XCTAssertFalse(SpeakerPresentation.showsTurns(for: m), "\(state)")
        }
    }

    func testF1OldMeThemMeetingKeepsTimecodedTranscript() {
        let segs = [seg("Me", 0, 4, "hello"), seg("Them", 5, 9, "hi")]
        let m = Meeting(title: "t", startUnix: 1, durationSec: 10,
                        transcript: MeetingTranscriptRenderer.render(segments: segs), summary: "",
                        participants: ["Me", "Them"], source: "s", fileName: "f.md", segments: segs)
        XCTAssertFalse(SpeakerPresentation.showsTurns(for: m))
        XCTAssertTrue(m.transcript.contains("[00:00] Me:"), "legacy transcript keeps its timecodes")
    }

    // MARK: F2 - owner + bleed on a call

    func testF2CallWithBleedAndNoProfileOwnerIsMeAndProfileLearns() {
        // Mic hears the owner (cluster 0) AND the far speaker through the laptop speakers
        // (cluster 1, matches the system speaker); no profile exists.
        let segments = [seg("Me", 0, 10), seg("Them", 12, 20), seg("Me", 12, 20)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 10), (1, 12, 20)], [0: eA, 1: eBBleed]),
            system: out([(0, 12, 20)], [0: eB]),
            minSpeakerSeconds: 3)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.segments[0].speaker, "Me", "the lone own voice after the bleed guard is Me")
        XCTAssertEqual(r.segments[1].speaker, r.segments[2].speaker, "bleed is the same person as the far speaker")
        XCTAssertNotEqual(r.segments[1].speaker, "Me")
        XCTAssertEqual(r.speakerCount, 2)
        let sample = r.ownVoiceSample
        XCTAssertEqual(sample?.cluster, 0, "the profile learns from the owner, not the bleed")
        XCTAssertEqual(sample?.embedding, eA)
    }

    // MARK: F5 - unmatched segments never leave a stray lane label

    func testF5UnmatchedMicSegmentJoinsNearestSpeakerWhenNobodyIsMe() {
        let segments = [seg("Me", 0, 10), seg("Me", 20, 30), seg("Me", 42, 43)] // last overlaps no turn
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 10), (1, 20, 30)], [0: eA, 1: eB]),
            system: nil, minSpeakerSeconds: 3)
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 2"])
        XCTAssertFalse(r.participants.contains("Me"))
        XCTAssertEqual(r.speakerCount, 2)
        XCTAssertEqual(r.segments[2].lane, "Me", "audio still resolves through the lane")
    }

    func testF5UnmatchedSystemSegmentNeverStaysThemNextToSpeakerN() {
        let segments = [seg("Me", 0, 10), seg("Them", 12, 20), seg("Them", 22, 30), seg("Them", 60, 61)]
        let eC: [Float] = [0, 0, 1, 0]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 10)], [0: eA]),
            system: out([(0, 12, 20), (1, 22, 30)], [0: eB, 1: eC]), minSpeakerSeconds: 3)
        XCTAssertEqual(r.segments.map(\.speaker), ["Me", "Speaker 1", "Speaker 2", "Speaker 2"])
        XCTAssertFalse(r.participants.contains("Them"))
        XCTAssertEqual(r.speakerCount, 3)
    }

    func testF5LaneWithNothingResolvedKeepsItsLabel() {
        let segments = [seg("Me", 0, 10), seg("Me", 20, 30), seg("Them", 40, 41)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 10), (1, 20, 30)], [0: eA, 1: eB]),
            system: nil, minSpeakerSeconds: 3)
        XCTAssertEqual(r.segments[2].speaker, "Them")
    }

    // MARK: F6 - untimed lanes are skipped

    func testF6SkippedLaneIsNeitherDiarizedNorRelabelled() async throws {
        let id = UUID()
        let mic = MeetingDiarizationTemp.url(meetingID: id, lane: "Me", in: tmp)
        let sys = MeetingDiarizationTemp.url(meetingID: id, lane: "Them", in: tmp)
        try Data([0]).write(to: mic); try Data([0]).write(to: sys)
        // Mic lane was rebuilt as ONE untimed block (zero-length cue); system has 2 people.
        let segments = [seg("Me", 5, 5, "one big block"), seg("Them", 0, 10), seg("Them", 12, 20)]
        let outputs: [String: DiarizationOutput] = [
            "-mic.wav": out([(0, 0, 100)], [0: eA]),
            "-sys.wav": out([(0, 0, 10), (1, 12, 20)], [0: eB, 1: [0, 0, 1, 0]])]
        let o = await MeetingDiarizationPipeline.run(
            inputs: [.init(lane: "Me", fileURL: mic), .init(lane: "Them", fileURL: sys)],
            segments: segments, diarizer: FakeLaneDiarizer(behavior: .perLane(outputs)),
            budgetSeconds: 5, skipLanes: ["Me"])
        guard case .labelled(let r) = o else { return XCTFail("\(o)") }
        XCTAssertEqual(r.segments[0].speaker, "Me", "untimed lane keeps its lane label")
        XCTAssertEqual(r.segments[1...].map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    func testF6AllLanesSkippedIsUnavailable() async throws {
        let o = await MeetingDiarizationPipeline.run(
            inputs: [], segments: [seg("Me", 0, 0)], diarizer: FakeLaneDiarizer(behavior: .throwError),
            budgetSeconds: 1, skipLanes: ["Me"])
        guard case .unavailable = o else { return XCTFail("\(o)") }
    }

    // MARK: F7 - circuit breaker + vendored temp fallback

    func testF7TimeoutOpensCircuitBreakerThenItCloses() async throws {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let recorder = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store)
        recorder.diarizationModelsDirectory = { self.tmp }
        recorder.ownVoiceStore = OwnVoiceProfileStore(url: tmp.appendingPathComponent("v.json"))
        recorder.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: .hangNonCooperatively(seconds: 3)) }
        recorder.diarizationBudget = { _ in 0.2 }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let box = ClockBox(clock)
        recorder.diarizationNow = { box.now }
        recorder.diarizationCooldown = 600
        let segments = [seg("Me", 0, 5), seg("Them", 6, 9)]
        func input() throws -> [MeetingDiarizationPipeline.LaneInput] {
            let id = UUID()
            let a = MeetingDiarizationTemp.url(meetingID: id, lane: "Me", in: tmp)
            let b = MeetingDiarizationTemp.url(meetingID: id, lane: "Them", in: tmp)
            try Data([0]).write(to: a); try Data([0]).write(to: b)
            return [.init(lane: "Me", fileURL: a), .init(lane: "Them", fileURL: b)]
        }
        XCTAssertFalse(recorder.diarizationInCooldown)
        let first = await recorder.diarizationStep(id: UUID(), inputs: try input(), segments: segments,
                                                   transcript: "t", durationSec: 10)
        XCTAssertEqual(first.state, .timedOut)
        XCTAssertTrue(recorder.diarizationInCooldown)

        // During the cool-down the next meeting does not even start the pass.
        let started = Date()
        let ins = try input()
        let second = await recorder.diarizationStep(id: UUID(), inputs: ins, segments: segments,
                                                    transcript: "t", durationSec: 10)
        XCTAssertNil(second.state)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.15, "skipped, not waited out")
        for i in ins { XCTAssertFalse(FileManager.default.fileExists(atPath: i.fileURL.path), "temp audio still deleted") }

        clock = clock.addingTimeInterval(601); box.now = clock
        XCTAssertFalse(recorder.diarizationInCooldown, "breaker closes after the cool-down")
    }

    private final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ d: Date) { now = d }
    }

    // MARK: F3 - forget my voice

    func testF3ForgetMyVoiceDeletesFileAndInMemoryProfile() throws {
        let url = tmp.appendingPathComponent("own-voice-profile.json")
        let store = OwnVoiceProfileStore(url: url)
        XCTAssertFalse(store.exists)
        XCTAssertTrue(store.learn(MicSpeakerCandidate(cluster: 0, embedding: [1, 0.2, 0, 0], speechSeconds: 60)))
        XCTAssertTrue(store.exists)
        XCTAssertNotNil(store.resolver([MicSpeakerCandidate(cluster: 4, embedding: [1, 0.2, 0, 0], speechSeconds: 30)]))
        store.delete()
        XCTAssertFalse(store.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.resolver([MicSpeakerCandidate(cluster: 4, embedding: [1, 0.2, 0, 0], speechSeconds: 30)]),
                     "the labeller must not keep matching a forgotten voice")
        XCTAssertFalse(OwnVoiceProfileStore(url: url).exists)
    }

    func testF3RecorderUsesTheSharedStoreSoSettingsDeleteReachesIt() {
        let recorder = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"),
                                       store: MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp))
        XCTAssertTrue(recorder.ownVoiceStore === OwnVoiceProfileStore.shared)
    }

    func testF3DoctorReportDisclosesPresenceNeverTheEmbedding() throws {
        let support = tmp.appendingPathComponent("support"), meetings = tmp.appendingPathComponent("m")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        let paths = DoctorReport.Paths(support: support, meetings: meetings)
        XCTAssertTrue(DoctorReport.generate(includeTCC: false, paths: paths)
            .contains("`own-voice-profile.json` — not created yet"))
        let secret = "0.31415926"
        try Data("{\"embedding\":[\(secret)],\"weight\":30,\"sampleCount\":1}".utf8)
            .write(to: support.appendingPathComponent("own-voice-profile.json"))
        let report = DoctorReport.generate(includeTCC: false, paths: paths)
        XCTAssertTrue(report.contains("`own-voice-profile.json`"))
        XCTAssertTrue(report.contains("voice profile"))
        XCTAssertFalse(report.contains(secret), "the receipt never prints the profile")
    }

    func testF3StringsExistInAllTenLanguages() throws {
        let keys = ["Your voice", "Forget my voice",
                    "A small voice profile is kept on this Mac to recognise you in meetings. Forgetting it removes it; it is learned again from future meetings."]
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("Resources/Localizations")
        let langs = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".lproj") }
        XCTAssertEqual(langs.count, 10)
        for lang in langs {
            let text = try String(contentsOf: dir.appendingPathComponent("\(lang)/Localizable.strings"), encoding: .utf8)
            for k in keys { XCTAssertTrue(text.contains("\"\(k)\" = \""), "\(lang) is missing: \(k)") }
        }
    }

    // MARK: F4 - temp audio lifetime

    func testF4ProcessDirectoryIsPerPidPrivateAndExcludedFromBackup() throws {
        let dir = AppPaths.diarizationTempDirectory()
        XCTAssertEqual(dir.lastPathComponent, "pid-\(ProcessInfo.processInfo.processIdentifier)")
        XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL, AppPaths.diarizationTempRoot().standardizedFileURL)
        XCTAssertTrue(dir.path.hasPrefix(AppPaths.testSandboxRoot!.path))
        for u in [dir, AppPaths.diarizationTempRoot()] {
            XCTAssertEqual(try u.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            let perms = try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(perms?.intValue, 0o700)
        }
    }

    func testF4TerminationRemovesTheProcessDirectory() throws {
        let dir = tmp.appendingPathComponent("pid-self", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("a.wav"))
        MeetingDiarizationTemp.removeProcessDirectory(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        MeetingDiarizationTemp.removeProcessDirectory(dir) // idempotent
    }

    func testF4SweepSparesALiveSecondInstanceAndClearsDeadOnes() throws {
        let fm = FileManager.default
        func make(_ name: String) throws -> URL {
            let d = tmp.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data([1]).write(to: d.appendingPathComponent("x.wav"))
            return d
        }
        let mine = try make("pid-100"), alive = try make("pid-200"), dead = try make("pid-300")
        let freshLoose = tmp.appendingPathComponent("loose-fresh.wav")
        let oldLoose = tmp.appendingPathComponent("loose-old.wav")
        try Data([1]).write(to: freshLoose); try Data([1]).write(to: oldLoose)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: oldLoose.path)
        let removed = MeetingDiarizationTemp.sweepStale(in: tmp, pid: 100, isProcessAlive: { $0 == 200 })
        XCTAssertEqual(removed, 3)
        XCTAssertFalse(fm.fileExists(atPath: mine.path), "own stale folder (pid reuse) is cleared at launch")
        XCTAssertTrue(fm.fileExists(atPath: alive.path), "a running second instance's audio is never touched")
        XCTAssertFalse(fm.fileExists(atPath: dead.path))
        XCTAssertTrue(fm.fileExists(atPath: freshLoose.path), "a recent loose file could belong to a live process")
        XCTAssertFalse(fm.fileExists(atPath: oldLoose.path))
    }

    func testF4ProcessIsAliveProbe() {
        XCTAssertTrue(MeetingDiarizationTemp.processIsAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(MeetingDiarizationTemp.processIsAlive(Int32.max))
    }

    // MARK: F8 - label stripping before phrase mining

    func testF8StripLabelsRemovesPrefixesOnly() {
        let t = "[00:01] Speaker 2: Let me check the roadmap.\n[01:05:09] Me: fine\nThem: ok Speaker 3 said hi"
        XCTAssertEqual(SpeakerLabels.stripLabels(from: t),
                       "Let me check the roadmap.\nfine\nok Speaker 3 said hi")
        XCTAssertEqual(SpeakerLabels.stripLabels(from: "plain text"), "plain text")
    }

    func testF8BackfillDoesNotMineSpeakerAsATerm() {
        let transcript = (1...6).map { "[00:0\($0)] Speaker \($0 % 2 + 1): the quarterly roadmap review" }
            .joined(separator: "\n")
        let raw = ContextGraphExtractor.candidates(from: transcript).map { $0.displayName.lowercased() }
        XCTAssertTrue(raw.contains { $0.contains("speaker") }, "precondition: unstripped text does mine 'Speaker'")
        let store = ContextGraphStore(directory: tmp.appendingPathComponent("graph"))
        let m = Meeting(title: "t", startUnix: 5_000_000_000, durationSec: 60, transcript: transcript,
                        summary: "", participants: ["Speaker 1", "Speaker 2"], source: "s", fileName: "f.md")
        store.backfill(dictations: [], meetings: [m])
        let names = store.entities.values.map { $0.displayName.lowercased() }
        XCTAssertFalse(names.contains { $0.contains("speaker") }, "\(names)")
    }

    // MARK: F10 - store.add never alters the transcript

    func testF10StoreAddKeepsTranscriptByteIdenticalSoRelabellingGuardHolds() throws {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let awkward = "[00:00] Me: héllo \u{1F600}  two  spaces\n[00:03] Them: tab\there\r\nend "
        let m = Meeting(title: "t", startUnix: 1, durationSec: 5, transcript: awkward, summary: "",
                        fileName: "f.md")
        store.add(m)
        XCTAssertEqual(store.meetings.first?.transcript, awkward)
        // And through a persist/reload round trip, the other thing that could alter it.
        let index = tmp.appendingPathComponent("meetings.json")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: index.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path), "index persisted")
        let reloaded = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        XCTAssertEqual(reloaded.meetings.first?.transcript, awkward)
    }
}
