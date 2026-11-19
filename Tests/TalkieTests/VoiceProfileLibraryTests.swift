import AVFoundation
import XCTest
import TalkieDiarization
@testable import Talkie

/// Voice library follow-up: per-meeting voice sidecar (persistence, deletion with the
/// meeting, retention, sweep), legacy recompute paths and their specific reasons,
/// default-on switch, multi-sample profiles (merge, cap, matching), suggestions and the
/// deletion confirmations. Synthetic embeddings, invented names.
@MainActor
final class VoiceProfileLibraryTests: XCTestCase {
    private var tmp: URL!
    private let eA: [Float] = [1, 0, 0, 0]
    private let eB: [Float] = [0, 1, 0, 0]
    private let eC: [Float] = [0, 0, 1, 0]

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("voice-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func cand(_ e: [Float], _ secs: Double = 30) -> MicSpeakerCandidate {
        MicSpeakerCandidate(cluster: 0, embedding: e, speechSeconds: secs)
    }
    private func meeting(_ labels: [String] = ["Me", "Speaker 1", "Speaker 2"], start: Double = 0) -> Meeting {
        var m = Meeting(title: "T", startUnix: start, durationSec: 60, transcript: "", summary: "", fileName: "\(UUID().uuidString).md")
        m.segments = labels.enumerated().map {
            MeetingSegment(speaker: $0.element, start: Double($0.offset) * 30, end: Double($0.offset) * 30 + 30, text: "x", lane: "Them")
        }
        return m
    }
    private func recorder(_ store: MeetingStore, _ voices: KnownVoiceStore) -> MeetingRecorder {
        let r = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store)
        r.knownVoiceStore = voices
        r.diarizationModelsDirectory = { self.tmp }
        return r
    }

    // MARK: sidecar

    func testSidecarIsOwnerOnlyAndDeletedWithTheMeeting() throws {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let m = meeting()
        store.add(m)
        store.voiceSidecar.save(["Speaker 1": cand(eA), "Me": cand(eC)], for: m.id)
        let url = store.voiceSidecar.url(for: m.id)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(store.voiceSidecar.voice(meetingID: m.id, label: "Speaker 1")?.embedding, eA)
        XCTAssertNil(store.voiceSidecar.voice(meetingID: m.id, label: "Me"))
        store.delete(m)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSidecarFollowsTheRetentionCapAndIsSweptOnLoad() async throws {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let oldest = meeting(start: 1)
        store.add(oldest)
        store.voiceSidecar.save(["Speaker 1": cand(eA)], for: oldest.id)
        for i in 0..<MeetingStore.maxRetainedMeetings { store.add(meeting(start: Double(100 + i))) }
        XCTAssertFalse(store.meetings.contains { $0.id == oldest.id })
        XCTAssertNil(store.voiceSidecar.voice(meetingID: oldest.id, label: "Speaker 1"), "evicted with the meeting")

        // A sidecar whose meeting is gone from the index is swept at the next load.
        let orphan = UUID()
        store.voiceSidecar.save(["Speaker 1": cand(eB)], for: orphan)
        await store.flush()
        let reloaded = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        XCTAssertFalse(reloaded.voiceSidecar.storedIDs().contains(orphan))
    }

    func testDoctorReportCountsSidecarsOnly() throws {
        let support = tmp.appendingPathComponent("S", isDirectory: true)
        let sidecar = MeetingVoiceSidecar(directory: support.appendingPathComponent("meeting-voices", isDirectory: true))
        sidecar.save(["Speaker 1": cand(eA)], for: UUID())
        sidecar.save(["Speaker 2": cand(eB)], for: UUID())
        let report = DoctorReport.generate(includeTCC: false, paths: .init(support: support, meetings: tmp))
        XCTAssertTrue(report.contains("speaker voices of 2 meetings"))
    }

    // MARK: legacy recompute paths

    func testLegacyMeetingsGetASpecificReason() async {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let voices = KnownVoiceStore(url: tmp.appendingPathComponent("k.json"))
        let r = recorder(store, voices)
        let recorded = meeting()
        var imported = meeting()
        imported.participants = ["Imported"]
        imported.source = "talkie (imported: a.mp3)"
        store.add(recorded); store.add(imported)
        XCTAssertEqual(r.voiceRememberAvailability(meetingID: recorded.id, label: "Speaker 1"), .unavailable(.audioNotKept))
        XCTAssertEqual(r.voiceRememberAvailability(meetingID: imported.id, label: "Speaker 1"), .unavailable(.reimport))
        let outcome = await r.rememberVoice(meetingID: imported.id, label: "Speaker 1", name: "Anna")
        XCTAssertEqual(outcome, .unavailable(.reimport))
        XCTAssertTrue(SpeakerNamingCopy.outcomeMessage(outcome)!.contains("Import it again"))
        XCTAssertFalse(r.defaultRecognise(meetingID: recorded.id, label: "Speaker 1"), "off when unavailable")
    }

    func testUnreadableKeptAudioSaysSo() async throws {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let r = recorder(store, KnownVoiceStore(url: tmp.appendingPathComponent("k.json")))
        var m = meeting()
        m.audioFiles = ["Them": "x-them.m4a"]
        store.add(m)
        try Data("not audio".utf8).write(to: tmp.appendingPathComponent("x-them.m4a"))
        r.laneDiarizerFactory = { _ in FakeLaneDiarizer(behavior: .output(.empty)) }
        XCTAssertEqual(r.voiceRememberAvailability(meetingID: m.id, label: "Speaker 1"), .fromKeptAudio)
        // The real transcoder refuses a file that is not audio.
        let outcome = await r.rememberVoice(meetingID: m.id, label: "Speaker 1", name: "Anna")
        XCTAssertEqual(outcome, .audioUnreadable)
    }

    func testTranscoderWritesA16kMonoWavIntoTheScratchFolder() throws {
        let src = tmp.appendingPathComponent("a.wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        do { // the writer finalises the file when it goes away
            let file = try AVAudioFile(forWriting: src, settings: fmt.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48_000)!
            buf.frameLength = 48_000
            try file.write(from: buf)
        }
        let out = try KeptAudioVoice.transcodeTo16kMono(src, into: tmp.appendingPathComponent("scratch", isDirectory: true))
        let read = try AVAudioFile(forReading: out)
        XCTAssertEqual(read.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(read.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(read.length), 16_000, accuracy: 200)
    }

    // MARK: profiles

    func testSavingUnderAnExistingNameMergesAndCountsMeetings() async {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let voices = KnownVoiceStore(url: tmp.appendingPathComponent("k.json"))
        let r = recorder(store, voices)
        let m1 = meeting(), m2 = meeting()
        store.add(m1); store.add(m2)
        store.voiceSidecar.save(["Speaker 1": cand(eA)], for: m1.id)
        store.voiceSidecar.save(["Speaker 2": cand(OwnVoiceProfile.normalised([1, 0.1, 0, 0])!)], for: m2.id)
        let a = await r.saveSpeaker(name: "Anna", label: "Speaker 1", meetingID: m1.id, recognise: true)
        XCTAssertEqual(a.voice, .remembered)
        // In the next meeting the user picks the existing person (any case).
        let b = await r.saveSpeaker(name: "anna", label: "Speaker 2", meetingID: m2.id, recognise: true)
        XCTAssertEqual(b.voice, .remembered)
        XCTAssertEqual(voices.all().count, 1, "merged, not duplicated")
        XCTAssertEqual(voices.all()[0].samples.count, 2)
        XCTAssertEqual(voices.all()[0].meetingCount, 2)
        XCTAssertEqual(KnownVoicesCard.subtitle(voices.all()[0]), String(format: "Built from %d meetings".loc, 2))
        // Turning the switch off on save forgets only that meeting's sample.
        _ = await r.saveSpeaker(name: "anna", label: "Speaker 2", meetingID: m2.id, recognise: false)
        XCTAssertEqual(voices.all()[0].samples.count, 1)
        // Saving with the switch off never stores anything.
        let m3 = meeting(); store.add(m3)
        store.voiceSidecar.save(["Speaker 1": cand(eB)], for: m3.id)
        _ = await r.saveSpeaker(name: "Tom", label: "Speaker 1", meetingID: m3.id, recognise: false)
        XCTAssertNil(voices.person(named: "Tom"))
    }

    func testProfileKeepsTheEightSamplesWithTheMostSpeech() {
        let voices = KnownVoiceStore(url: tmp.appendingPathComponent("k.json"))
        for i in 0..<10 {
            XCTAssertTrue(voices.add(name: "Anna", sample: cand(eA, 20 + Double(i)), meetingID: UUID(), label: "Speaker 1"))
        }
        let p = voices.all()[0]
        XCTAssertEqual(p.samples.count, KnownVoice.maxSamples)
        XCTAssertEqual(p.samples.map(\.speechSeconds).min(), 22, "the two shortest were dropped")
    }

    func testRenameMovesTheSampleIntoAnExistingPerson() {
        let voices = KnownVoiceStore(url: tmp.appendingPathComponent("k.json"))
        let m = UUID()
        voices.add(name: "Anna", sample: cand(eA), meetingID: UUID(), label: "Speaker 1")
        voices.add(name: "Ann", sample: cand(eA), meetingID: m, label: "Speaker 2")
        voices.rename(meetingID: m, label: "Speaker 2", to: "anna")
        XCTAssertEqual(voices.all().count, 1)
        XCTAssertEqual(voices.all()[0].samples.count, 2)
    }

    func testFirstFileLayoutStillDecodes() throws {
        let url = tmp.appendingPathComponent("legacy.json")
        let json = #"[{"id":"00000000-0000-0000-0000-000000000009","name":"Anna","embedding":[1,0,0,0],"speechSeconds":30,"createdUnix":5}]"#
        try Data(json.utf8).write(to: url)
        let p = KnownVoiceStore(url: url).all()
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].samples.map(\.embedding), [eA])
    }

    func testMultiSampleMatchingMeanVersusBest() {
        // One person enrolled from two quite different channels.
        let anna = KnownVoice(name: "Anna", samples: [
            VoiceSample(embedding: eA, speechSeconds: 30, createdUnix: 0),
            VoiceSample(embedding: OwnVoiceProfile.normalised([0.8, 0.6, 0, 0])!, speechSeconds: 30, createdUnix: 0)])
        let probe = OwnVoiceProfile.normalised([0.95, 0.3, 0, 0])!
        XCTAssertEqual(KnownVoiceMatcher.match(candidates: ["S": cand(probe)], known: [anna], aggregation: .mean), ["S": "Anna"])
        XCTAssertEqual(KnownVoiceMatcher.match(candidates: ["S": cand(probe)], known: [anna], aggregation: .best), ["S": "Anna"])
        // A voice close to ONE sample only: best accepts it, mean (shipped) does not.
        let lookalike = OwnVoiceProfile.normalised([0.75, 0.0, 0.66, 0])!
        let other = KnownVoice(name: "Kai", embedding: [0, 0, 0, 1], speechSeconds: 30, createdUnix: 0)
        XCTAssertEqual(KnownVoiceMatcher.match(candidates: ["S": cand(lookalike)], known: [anna, other], aggregation: .best), ["S": "Anna"])
        XCTAssertTrue(KnownVoiceMatcher.match(candidates: ["S": cand(lookalike)], known: [anna, other], aggregation: .mean).isEmpty)
        XCTAssertEqual(KnownVoiceMatcher.aggregation, .mean)
    }

    // MARK: popover helpers + confirmations

    func testSuggestionsFilterWhileTyping() {
        let people = [KnownVoice(name: "Anna Berg", embedding: eA, speechSeconds: 30, createdUnix: 1),
                      KnownVoice(name: "Hanna", embedding: eB, speechSeconds: 30, createdUnix: 2),
                      KnownVoice(name: "Tom", embedding: eC, speechSeconds: 30, createdUnix: 3)]
        XCTAssertEqual(SpeakerNamingCopy.suggestions(people, typed: "").map(\.name), ["Tom", "Hanna", "Anna Berg"])
        XCTAssertEqual(SpeakerNamingCopy.suggestions(people, typed: "ann").map(\.name), ["Hanna", "Anna Berg"])
        XCTAssertEqual(SpeakerNamingCopy.suggestions(people, typed: "tom").map(\.name), [], "an exact match is not suggested again")
        XCTAssertNotNil(SpeakerNamingCopy.mergeNote(people, typed: "tom"))
        XCTAssertNil(SpeakerNamingCopy.mergeNote(people, typed: "Zed"))
    }

    func testEveryVoiceDeletionHasADestructiveConfirmation() {
        for c in [VoiceDeletionConfirm.ownVoice, .person(name: "Anna"), .allKnownVoices] {
            XCTAssertTrue(c.title.hasSuffix("?"), "the title is the question")
            XCTAssertFalse(c.message.isEmpty)
            XCTAssertFalse(c.verb.isEmpty)
        }
        XCTAssertTrue(VoiceDeletionConfirm.person(name: "Anna").title.contains("Anna"))
    }
}
