import XCTest
@testable import Talkie

/// Manually saved speaker names go into the custom vocabulary — safely, with Undo.
@MainActor
final class SpeakerVocabularyTests: XCTestCase {
    private var tmp: URL!
    private var dictionary: DictionaryStore!
    private var pills: [String] = []
    private var undo: (() -> Void)?
    private var reverted = 0

    override func setUpWithError() throws {
        XCTAssertNotNil(AppPaths.testSandboxRoot, "must never touch the real dictionary")
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spk-vocab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        dictionary = DictionaryStore()
        dictionary.vocabulary = []
        pills = []; undo = nil; reverted = 0
    }
    override func tearDownWithError() throws {
        dictionary.vocabulary = []
        dictionary.save()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Deterministic safeguards: "mark"/"will"/"rose" are ordinary words.
    private func adder() -> SpeakerVocabularyAdder {
        let a = SpeakerVocabularyAdder(dictionary: dictionary,
                                       presentPill: { [unowned self] m, u in pills.append(m); undo = u },
                                       presentReverted: { [unowned self] in reverted += 1 })
        a.isOrdinary = { ["mark", "will", "rose"].contains($0.lowercased()) }
        a.guardSafe = { _ in true }
        return a
    }

    private func recorder() -> (MeetingRecorder, MeetingStore, Meeting) {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        var m = Meeting(title: "T", startUnix: 0, durationSec: 60, transcript: "", summary: "", fileName: "t.md")
        m.segments = [MeetingSegment(speaker: "Speaker 1", start: 0, end: 1, text: "x"),
                      MeetingSegment(speaker: "Speaker 2", start: 1, end: 2, text: "y")]
        store.add(m)
        let r = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store)
        r.knownVoiceStore = KnownVoiceStore(url: tmp.appendingPathComponent("k.json"))
        r.speakerVocabulary = adder()
        return (r, store, m)
    }

    func testDecisionRules() {
        XCTAssertEqual(SpeakerVocabulary.decide("Annika Berg", vocabulary: [], isOrdinary: { _ in false }, guardSafe: { _ in true }),
                       .add("Annika Berg"), "full name as typed")
        XCTAssertEqual(SpeakerVocabulary.decide("annika", vocabulary: ["Annika"], isOrdinary: { _ in false }, guardSafe: { _ in true }),
                       .alreadyPresent)
        XCTAssertEqual(SpeakerVocabulary.decide("Kai", vocabulary: [], isOrdinary: { _ in false }, guardSafe: { _ in true }),
                       .skip(.tooShort))
        XCTAssertEqual(SpeakerVocabulary.decide("Mark", vocabulary: [], isOrdinary: { $0.lowercased() == "mark" }, guardSafe: { _ in true }),
                       .skip(.ordinaryWord))
        XCTAssertEqual(SpeakerVocabulary.decide("Anke", vocabulary: [], isOrdinary: { _ in false }, guardSafe: { _ in false }),
                       .skip(.ordinaryWord), "near a common word")
    }

    func testRealSafeguardsSkipEverydayWordNames() {
        for n in ["Mark", "Will", "Rose"] {
            XCTAssertEqual(SpeakerVocabulary.decide(n, vocabulary: []), .skip(.ordinaryWord), n)
        }
    }

    func testManualSaveAddsOnceWithPillAndUndoKeepsTheName() {
        let (r, store, m) = recorder()
        XCTAssertNil(r.saveManualSpeakerName("Annika Berg", label: "Speaker 1", meetingID: m.id))
        XCTAssertEqual(dictionary.vocabulary, ["Annika Berg"])
        XCTAssertEqual(pills.count, 1)
        // Same name again (other speaker / other case): no second add, no second pill.
        r.saveManualSpeakerName("annika berg", label: "Speaker 2", meetingID: m.id)
        XCTAssertEqual(dictionary.vocabulary, ["Annika Berg"])
        XCTAssertEqual(pills.count, 1)
        undo?()
        XCTAssertTrue(dictionary.vocabulary.isEmpty)
        XCTAssertEqual(reverted, 1)
        XCTAssertNotNil(store.meetings[0].speakerNames?.values.first { $0.source == .manual }, "name kept")
        // Clearing a speaker's name never removes a dictionary term.
        r.saveManualSpeakerName("Jolanda", label: "Speaker 1", meetingID: m.id)
        r.setSpeakerName(nil, label: "Speaker 1", meetingID: m.id)
        XCTAssertEqual(dictionary.vocabulary, ["Jolanda"])
    }

    func testRiskyNameIsSkippedWithAReasonButKept() {
        let (r, store, m) = recorder()
        let why = r.saveManualSpeakerName("Mark", label: "Speaker 1", meetingID: m.id)
        XCTAssertEqual(why, SpeakerVocabulary.message(.ordinaryWord))
        XCTAssertTrue(dictionary.vocabulary.isEmpty)
        XCTAssertTrue(pills.isEmpty)
        XCTAssertEqual(store.meetings[0].speakerNames?["Speaker 1"]?.name, "Mark")
        XCTAssertEqual(r.saveManualSpeakerName("Bo", label: "Speaker 2", meetingID: m.id), SpeakerVocabulary.message(.tooShort))
    }

    func testConversationAndVoiceNamesNeverReachTheDictionary() {
        let (r, store, m) = recorder()
        let voices = KnownVoiceStore(url: tmp.appendingPathComponent("k2.json"))
        XCTAssertTrue(voices.add(name: "Theodora", sample: MicSpeakerCandidate(cluster: 0, embedding: [0, 1, 0, 0], speechSeconds: 30),
                                 meetingID: UUID(), label: "Speaker 9"))
        r.knownVoiceStore = voices
        var mm = store.meetings[0]
        mm.segments = [MeetingSegment(speaker: "Speaker 1", start: 0, end: 2, text: "Hi, I'm Annika."),
                       MeetingSegment(speaker: "Speaker 2", start: 2, end: 4, text: "Hello.")]
        let names = r.automaticSpeakerNames(for: mm, voices: [
            "Speaker 1": MicSpeakerCandidate(cluster: 0, embedding: [1, 0, 0, 0], speechSeconds: 30),
            "Speaker 2": MicSpeakerCandidate(cluster: 1, embedding: [0, 1, 0, 0], speechSeconds: 30)],
                                             attendees: ["Annika Berg"])
        XCTAssertEqual(names?["Speaker 1"]?.source, .conversation)
        XCTAssertEqual(names?["Speaker 2"]?.source, .voice)
        XCTAssertTrue(dictionary.vocabulary.isEmpty)
        XCTAssertTrue(pills.isEmpty)
        _ = m
    }
}
