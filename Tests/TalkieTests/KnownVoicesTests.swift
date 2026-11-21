import XCTest
import TalkieDiarization
@testable import Talkie

/// W2 part C: the strict known-voice matcher, the opt-in store (persistence, 0600,
/// deletion, epoch), recomputing a voice from kept audio, the per-label voices the
/// labeller exposes, and the recorder wiring (precedence, nothing stored without an
/// explicit opt-in). Embeddings are synthetic; names invented.
@MainActor
final class KnownVoicesTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("known-voices-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private let eA: [Float] = [1, 0, 0, 0]
    private let eB: [Float] = [0, 1, 0, 0]
    private let eC: [Float] = [0, 0, 1, 0]

    private func cand(_ e: [Float], _ secs: Double = 30) -> MicSpeakerCandidate {
        MicSpeakerCandidate(cluster: 0, embedding: e, speechSeconds: secs)
    }
    private func known(_ name: String, _ e: [Float]) -> KnownVoice {
        KnownVoice(name: name, embedding: e, speechSeconds: 30, createdUnix: 0)
    }
    /// A unit vector with cosine `c` to eA, in the eA/eB plane.
    private func at(_ c: Double) -> [Float] { [Float(c), Float((1 - c * c).squareRoot()), 0, 0] }

    // MARK: matcher

    func testThresholdIsStrict() {
        let k = [known("Anna", eA)]
        XCTAssertEqual(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand(at(0.7001))], known: k), ["Speaker 1": "Anna"])
        XCTAssertTrue(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand(at(0.6999))], known: k).isEmpty)
    }

    func testMarginOverTheNextBestKnownPerson() {
        // Candidate between Anna (eA) and Tom (at 0.6 from eA): close to both -> nobody.
        let tom: [Float] = at(0.6)
        let k = [known("Anna", eA), known("Tom", tom)]
        let c = OwnVoiceProfile.normalised([0.9, 0.35, 0, 0])!
        let simA = SpeakerLabelling.cosine(c, eA), simT = SpeakerLabelling.cosine(c, tom)
        XCTAssertGreaterThanOrEqual(simA, KnownVoiceMatcher.threshold)
        XCTAssertLessThan(abs(simA - simT), KnownVoiceMatcher.margin)
        XCTAssertTrue(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand(c)], known: k).isEmpty)
        // A clear winner passes.
        XCTAssertEqual(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand(eA)], known: [known("Anna", eA), known("Kai", eC)]),
                       ["Speaker 1": "Anna"])
    }

    func testSeveralSamplesOfOnePersonAreNotTheirOwnRunnerUp() {
        let k = [known("Anna", eA), known("anna", at(0.95))]
        XCTAssertEqual(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand(eA)], known: k), ["Speaker 1": "Anna"])
    }

    func testMinimumSpeech() {
        let k = [known("Anna", eA)]
        XCTAssertTrue(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand(eA, 19.9)], known: k).isEmpty)
        XCTAssertEqual(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand(eA, 20)], known: k).count, 1)
    }

    func testOnePersonMatchedByTwoLabelsNamesNeither() {
        let k = [known("Anna", eA)]
        XCTAssertTrue(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand(eA), "Speaker 2": cand(at(0.99))], known: k).isEmpty)
    }

    func testMeAndBadInputsNeverMatch() {
        let k = [known("Anna", eA)]
        XCTAssertTrue(KnownVoiceMatcher.match(candidates: ["Me": cand(eA)], known: k).isEmpty)
        XCTAssertTrue(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand([1, 0])], known: k).isEmpty, "dimension mismatch")
        XCTAssertTrue(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand([.nan, 0, 0, 0])], known: k).isEmpty)
        XCTAssertTrue(KnownVoiceMatcher.match(candidates: ["Speaker 1": cand(eA)], known: []).isEmpty)
    }

    // MARK: store

    func testStorePersistsOwnerOnlyAndDeletes() throws {
        let url = tmp.appendingPathComponent("known-voices.json")
        let store = KnownVoiceStore(url: url)
        let m = UUID()
        XCTAssertTrue(store.add(name: " Anna  Berg ", sample: cand([2, 0, 0, 0]), meetingID: m, label: "Speaker 1"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let reread = KnownVoiceStore(url: url).all()
        XCTAssertEqual(reread.count, 1)
        XCTAssertEqual(reread[0].name, "Anna Berg")
        XCTAssertEqual(reread[0].samples.map(\.embedding), [[1, 0, 0, 0]], "stored normalised")
        XCTAssertEqual(store.entry(meetingID: m, label: "Speaker 1")?.name, "Anna Berg")

        // Same meeting speaker again replaces, a rename follows the manual name.
        XCTAssertTrue(store.add(name: "Anna", sample: cand(eA), meetingID: m, label: "Speaker 1"))
        XCTAssertEqual(store.all().count, 1)
        store.rename(meetingID: m, label: "Speaker 1", to: "Annie")
        XCTAssertEqual(KnownVoiceStore(url: url).all().first?.name, "Annie")

        XCTAssertTrue(store.add(name: "Tom", sample: cand(eB), meetingID: UUID(), label: "Speaker 2"))
        let tomID = try XCTUnwrap(store.all().first { $0.name == "Tom" }?.id)
        store.remove(id: tomID)
        XCTAssertEqual(KnownVoiceStore(url: url).all().map(\.name), ["Annie"])
        store.remove(meetingID: m, label: "Speaker 1")
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "last entry gone -> file gone")

        XCTAssertTrue(store.add(name: "Kai", sample: cand(eC), meetingID: nil, label: nil))
        store.removeAll()
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.match(["Speaker 1": cand(eC)]).isEmpty, "a forgotten voice never matches again")
    }

    func testStoreRefusesUnusableSamplesAndStaleEpochs() {
        let store = KnownVoiceStore(url: tmp.appendingPathComponent("k.json"))
        XCTAssertFalse(store.add(name: "", sample: cand(eA), meetingID: nil, label: nil))
        XCTAssertFalse(store.add(name: "Anna", sample: cand(eA, 10), meetingID: nil, label: nil))
        XCTAssertFalse(store.add(name: "Anna", sample: cand([0, 0, 0, 0]), meetingID: nil, label: nil))
        let epoch = store.currentEpoch
        store.removeAll()
        XCTAssertFalse(store.add(name: "Anna", sample: cand(eA), meetingID: nil, label: nil, ifEpoch: epoch),
                       "a sample computed before a deletion is dropped")
        XCTAssertTrue(store.all().isEmpty)
    }

    func testRecorderUsesTheSharedStore() {
        let recorder = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"),
                                       store: MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp))
        XCTAssertTrue(recorder.knownVoiceStore === KnownVoiceStore.shared)
    }

    // MARK: kept audio

    func testPickFromKeptAudioRequiresAPureCluster() {
        let segs = [
            MeetingSegment(speaker: "Speaker 1", start: 0, end: 30, text: "a", lane: "Them"),
            MeetingSegment(speaker: "Speaker 2", start: 30, end: 60, text: "b", lane: "Them"),
            MeetingSegment(speaker: "Me", start: 0, end: 10, text: "c", lane: "Me"),
        ]
        let clean = DiarizationOutput(
            turns: [DiarizedTurn(speaker: 0, start: 0, end: 30), DiarizedTurn(speaker: 1, start: 30, end: 60)],
            speakers: [SpeakerProfile(speaker: 0, embedding: eA, speechSeconds: 30),
                       SpeakerProfile(speaker: 1, embedding: eB, speechSeconds: 30)])
        XCTAssertEqual(KeptAudioVoice.pick(output: clean, segments: segs, label: "Speaker 1", lane: "Them")?.embedding, eA)
        XCTAssertEqual(KeptAudioVoice.pick(output: clean, segments: segs, label: "Speaker 2", lane: "Them")?.embedding, eB)
        // One cluster covering both people: never stored as one person.
        let merged = DiarizationOutput(turns: [DiarizedTurn(speaker: 0, start: 0, end: 60)],
                                       speakers: [SpeakerProfile(speaker: 0, embedding: eA, speechSeconds: 60)])
        XCTAssertNil(KeptAudioVoice.pick(output: merged, segments: segs, label: "Speaker 1", lane: "Them"))
    }

    func testKeptAudioFileForLabel() {
        var m = Meeting(title: "T", startUnix: 0, durationSec: 60, transcript: "", summary: "", fileName: "f.md")
        m.segments = [MeetingSegment(speaker: "Speaker 1", start: 0, end: 30, text: "a", lane: "Them")]
        XCTAssertNil(KeptAudioVoice.audioFile(for: "Speaker 1", in: m))
        m.audioFiles = ["Me": "f-me.m4a", "Them": "f-them.m4a"]
        XCTAssertEqual(KeptAudioVoice.audioFile(for: "Speaker 1", in: m)?.file, "f-them.m4a")
        XCTAssertNil(KeptAudioVoice.audioFile(for: "Speaker 9", in: m))
    }

    // MARK: labeller voices

    private func out(_ turns: [(Int, Double, Double)], _ emb: [Int: [Float]]) -> DiarizationOutput {
        let t = turns.map { DiarizedTurn(speaker: $0.0, start: $0.1, end: $0.2) }
        let profiles = emb.keys.sorted().map { id in
            SpeakerProfile(speaker: id, embedding: emb[id]!,
                           speechSeconds: t.filter { $0.speaker == id }.reduce(0) { $0 + $1.duration })
        }
        return DiarizationOutput(turns: t, speakers: profiles)
    }

    private var callSegments: [MeetingSegment] {
        [MeetingSegment(speaker: "Them", start: 0, end: 30, text: "Hi, I'm Anna."),
         MeetingSegment(speaker: "Them", start: 30, end: 60, text: "Hello there."),
         MeetingSegment(speaker: "Them", start: 60, end: 90, text: "Tom, what do you think?"),
         MeetingSegment(speaker: "Them", start: 90, end: 120, text: "Good idea."),
         MeetingSegment(speaker: "Me", start: 130, end: 135, text: "Great.")]
    }
    private var sysOut: DiarizationOutput { out([(0, 0, 30), (1, 30, 60), (0, 60, 90), (1, 90, 120)], [0: eA, 1: eB]) }
    private var micOut: DiarizationOutput { out([(0, 130, 135)], [0: eC]) }

    func testLabellerExposesOneVoicePerNonMeLabel() {
        let r = SpeakerLabelling.label(segments: callSegments, mic: micOut, system: sysOut)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(Set(r.voices.keys), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(r.voices["Speaker 1"]?.embedding, eA)
        XCTAssertEqual(r.voices["Speaker 1"]?.speechSeconds, 60)
        XCTAssertNil(r.voices["Me"])
        // 1:1 call: "Them" is one person and carries its voice.
        let one = SpeakerLabelling.label(segments: [MeetingSegment(speaker: "Them", start: 0, end: 30, text: "x"),
                                                    MeetingSegment(speaker: "Me", start: 31, end: 40, text: "y")],
                                         mic: out([(0, 31, 40)], [0: eC]), system: out([(0, 0, 30)], [0: eB]))
        XCTAssertFalse(one.changed)
        XCTAssertEqual(one.voices["Them"]?.embedding, eB)
    }

    // MARK: recorder wiring

    private struct Tagger: PersonNameTagging {
        func isPersonalName(_ range: Range<String.Index>, in sentence: String) -> Bool {
            ["Anna", "Tom"].contains(String(sentence[range]))
        }
    }

    private func makeRecorder(_ store: MeetingStore, voices: KnownVoiceStore) -> MeetingRecorder {
        let r = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store)
        r.diarizationModelsDirectory = { self.tmp }
        r.ownVoiceStore = OwnVoiceProfileStore(url: tmp.appendingPathComponent("v.json"))
        r.knownVoiceStore = voices
        r.nameTagger = Tagger()
        let sys = sysOut, mic = micOut
        r.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: .perLane(["-mic.wav": mic, "-sys.wav": sys, "-them.m4a": sys])) }
        return r
    }

    private func inputs(_ id: UUID) throws -> [MeetingDiarizationPipeline.LaneInput] {
        let a = MeetingDiarizationTemp.url(meetingID: id, lane: "Me", in: tmp)
        let b = MeetingDiarizationTemp.url(meetingID: id, lane: "Them", in: tmp)
        try Data([0]).write(to: a); try Data([0]).write(to: b)
        return [.init(lane: "Me", fileURL: a), .init(lane: "Them", fileURL: b)]
    }

    func testDiarizationNamesFromConversationAndKnownVoiceButStoresNothingNew() async throws {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let voiceURL = tmp.appendingPathComponent("known-voices.json")
        let voices = KnownVoiceStore(url: voiceURL)
        XCTAssertTrue(voices.add(name: "Tom", sample: cand(eB), meetingID: UUID(), label: "Speaker 3"))
        let recorder = makeRecorder(store, voices: voices)
        let meeting = Meeting(title: "T", startUnix: 0, durationSec: 135, transcript: "t", summary: "",
                              fileName: "t.md", segments: callSegments)
        store.add(meeting)
        let step = await recorder.diarizationStep(id: meeting.id, inputs: try inputs(meeting.id), segments: callSegments,
                                                  transcript: "t", durationSec: 135, attendees: ["Anna Berg"])
        XCTAssertEqual(step.state, .applied)
        let saved = try XCTUnwrap(store.meetings.first)
        XCTAssertEqual(saved.speakerNames, ["Speaker 1": SpeakerName(name: "Anna", source: .conversation),
                                            "Speaker 2": SpeakerName(name: "Tom", source: .voice)])
        XCTAssertTrue(saved.transcript.contains("Speaker 1:"), "the stored transcript keeps raw labels")
        XCTAssertTrue(saved.namedTranscript.contains("Anna:"))
        XCTAssertEqual(voices.all().count, 1, "no voice is put in the library without the user's save")
        // But every diarized speaker's voice is kept with the meeting (owner-only sidecar).
        XCTAssertEqual(store.voiceSidecar.voice(meetingID: meeting.id, label: "Speaker 1")?.embedding, eA)
        XCTAssertNil(store.voiceSidecar.voice(meetingID: meeting.id, label: "Me"), "never the owner's own voice")
        let perms = try FileManager.default.attributesOfItem(atPath: store.voiceSidecar.url(for: meeting.id).path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        // Manual beats everything and survives a later automatic pass.
        recorder.setSpeakerName("Annie", label: "Speaker 1", meetingID: meeting.id)
        let again = recorder.automaticSpeakerNames(for: store.meetings[0], voices: ["Speaker 1": cand(eA)], attendees: ["Anna Berg"])
        XCTAssertEqual(again?["Speaker 1"], SpeakerName(name: "Annie", source: .manual))

        // Opt in for Speaker 1, even from a fresh recorder (app relaunch): the voice kept
        // with the meeting is used.
        let relaunched = makeRecorder(store, voices: voices)
        XCTAssertEqual(relaunched.voiceRememberAvailability(meetingID: meeting.id, label: "Speaker 1"), .stored)
        XCTAssertTrue(relaunched.defaultRecognise(meetingID: meeting.id, label: "Speaker 1"), "on by default when available")
        XCTAssertFalse(relaunched.defaultRecognise(meetingID: meeting.id, label: "Speaker 2"),
                       "a voice-recognised name never defaults to adding another sample")
        XCTAssertEqual(recorder.voiceRememberAvailability(meetingID: meeting.id, label: "Me"), .unavailable(.noVoice))
        let outcome = await relaunched.rememberVoice(meetingID: meeting.id, label: "Speaker 1", name: "Annie")
        XCTAssertEqual(outcome, .remembered)
        XCTAssertEqual(voices.entry(meetingID: meeting.id, label: "Speaker 1")?.samples.map(\.embedding), [eA])
        // Clearing the name forgets that voice too.
        recorder.setSpeakerName(nil, label: "Speaker 1", meetingID: meeting.id)
        XCTAssertNil(voices.entry(meetingID: meeting.id, label: "Speaker 1"))
        XCTAssertNil(store.meetings[0].speakerNames?["Speaker 1"])
    }

    func testRememberVoiceRecomputesFromKeptAudio() async throws {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let voices = KnownVoiceStore(url: tmp.appendingPathComponent("known-voices.json"))
        let recorder = makeRecorder(store, voices: voices)
        let labelled = SpeakerLabelling.label(segments: callSegments, mic: micOut, system: sysOut)
        var meeting = Meeting(title: "T", startUnix: 0, durationSec: 135, transcript: "t", summary: "",
                              fileName: "t.md", segments: labelled.segments)
        XCTAssertEqual(recorder.voiceRememberAvailability(meetingID: meeting.id, label: "Speaker 2"), .unavailable(.noVoice))
        meeting.audioFiles = ["Me": "t-me.m4a", "Them": "t-them.m4a"]
        store.add(meeting)
        try Data([0]).write(to: tmp.appendingPathComponent("t-them.m4a"))
        // Stand-in transcoder: a scratch copy whose name the fake diarizer keys on.
        recorder.keptAudioTranscoder = { src in
            let out = src.deletingLastPathComponent().appendingPathComponent("scratch-\(UUID().uuidString)-them.m4a")
            try FileManager.default.copyItem(at: src, to: out)
            return out
        }
        XCTAssertEqual(recorder.voiceRememberAvailability(meetingID: meeting.id, label: "Speaker 2"), .fromKeptAudio)
        let outcome = await recorder.rememberVoice(meetingID: meeting.id, label: "Speaker 2", name: "Tom")
        XCTAssertEqual(outcome, .remembered)
        XCTAssertEqual(voices.all().flatMap(\.samples).map(\.embedding), [eB])
        XCTAssertEqual(store.voiceSidecar.voice(meetingID: meeting.id, label: "Speaker 2")?.embedding, eB,
                       "the recomputed voice is kept with the meeting from then on")
        recorder.diarizationModelsDirectory = { nil }
        XCTAssertEqual(recorder.voiceRememberAvailability(meetingID: meeting.id, label: "Speaker 1"), .unavailable(.modelsMissing))
    }

    // MARK: Doctor report + copy

    func testDoctorReportListsTheStoreWithACountOnly() throws {
        let support = tmp.appendingPathComponent("Application Support/Talkie", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let paths = DoctorReport.Paths(support: support, meetings: tmp.appendingPathComponent("M", isDirectory: true))
        XCTAssertTrue(DoctorReport.generate(includeTCC: false, paths: paths).contains("known-voices.json"))
        let store = KnownVoiceStore(url: support.appendingPathComponent("known-voices.json"))
        XCTAssertTrue(store.add(name: "Zelda Q", sample: cand(eA), meetingID: nil, label: nil))
        XCTAssertTrue(store.add(name: "Yuri P", sample: cand(eB), meetingID: nil, label: nil))
        let report = DoctorReport.generate(includeTCC: false, paths: paths)
        XCTAssertTrue(report.contains("2 voice prints of people you chose to recognise"))
        XCTAssertFalse(report.contains("Zelda"), "never a name")
        XCTAssertFalse(report.contains("Yuri"))
    }

    func testPopoverCopyForEveryAvailabilityAndSource() {
        XCTAssertNil(SpeakerNamingCopy.unavailableReason(.stored))
        XCTAssertNil(SpeakerNamingCopy.unavailableReason(.fromKeptAudio))
        for r in [MeetingRecorder.VoiceRememberAvailability.Reason.notEnoughSpeech, .noVoice, .audioNotKept, .reimport, .modelsMissing] {
            XCTAssertNotNil(SpeakerNamingCopy.unavailableReason(.unavailable(r)))
        }
        XCTAssertNotNil(SpeakerNamingCopy.sourceNote(.voice))
        XCTAssertNotNil(SpeakerNamingCopy.sourceNote(.conversation))
        XCTAssertNil(SpeakerNamingCopy.sourceNote(.manual))
        XCTAssertNil(SpeakerNamingCopy.outcomeMessage(.remembered))
        XCTAssertNotNil(SpeakerNamingCopy.outcomeMessage(.audioUnreadable))
        XCTAssertNotNil(SpeakerNamingCopy.outcomeMessage(.notSaved))
    }
}
