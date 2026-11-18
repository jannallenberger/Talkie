import XCTest
import TalkieDiarization
@testable import Talkie

/// WP-C: profile math, match decisions, learning guards, persistence/deletion, gap-free
/// numbering after a "Me" assignment, and the live-digest remap.
final class OwnVoiceProfileTests: XCTestCase {
    private typealias Policy = OwnVoiceProfile.Policy

    private func cand(_ cluster: Int, _ e: [Float], _ secs: Double = 30) -> MicSpeakerCandidate {
        MicSpeakerCandidate(cluster: cluster, embedding: e, speechSeconds: secs)
    }

    private func norm(_ v: [Float]) -> [Float] { OwnVoiceProfile.normalised(v)! }

    // MARK: profile math

    func testFirstSampleBecomesUnitProfileWithCappedWeight() throws {
        let p = try XCTUnwrap(OwnVoiceProfile.folding(cand(0, [3, 4, 0], 500), into: nil))
        XCTAssertEqual(p.embedding[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(p.embedding[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual(p.weight, Policy.maxSampleWeight, "one long meeting cannot freeze the mean")
        XCTAssertEqual(p.sampleCount, 1)
    }

    func testRunningMeanIsWeightedByCappedSpeechSeconds() throws {
        let a = norm([1, 0.2, 0]), b = norm([1, -0.2, 0])
        let p1 = try XCTUnwrap(OwnVoiceProfile.folding(cand(0, a, 30), into: nil))
        let p2 = try XCTUnwrap(OwnVoiceProfile.folding(cand(0, b, 90), into: p1))
        XCTAssertEqual(p2.weight, 120, accuracy: 1e-9)
        XCTAssertEqual(p2.sampleCount, 2)
        // Expected: (a*30 + b*90) / 120, renormalised.
        let expected = norm((0..<3).map { (a[$0] * 30 + b[$0] * 90) / 120 })
        for i in 0..<3 { XCTAssertEqual(p2.embedding[i], expected[i], accuracy: 1e-5) }
        XCTAssertLessThan(p2.embedding[1], 0, "pulled toward the heavier sample")
    }

    func testProfileWeightIsCappedSoItKeepsAdapting() throws {
        let old = OwnVoiceProfile(embedding: norm([1, 0, 0]), weight: 50_000, sampleCount: 400)
        let p = try XCTUnwrap(OwnVoiceProfile.folding(cand(0, [1, 0.5, 0], 120), into: old))
        XCTAssertEqual(p.weight, Policy.maxProfileWeight + 120, accuracy: 1e-9)
        XCTAssertGreaterThan(p.embedding[1], 0.02, "a new sample still moves a mature profile")
    }

    // MARK: minimum speech and learning guards

    func testMinimumSpeechRule() {
        XCTAssertNil(OwnVoiceProfile.folding(cand(0, [1, 0, 0], Policy.minSampleSeconds - 0.1), into: nil))
        XCTAssertNotNil(OwnVoiceProfile.folding(cand(0, [1, 0, 0], Policy.minSampleSeconds), into: nil))
        let old = OwnVoiceProfile(embedding: norm([1, 0, 0]), weight: 40, sampleCount: 1)
        XCTAssertEqual(OwnVoiceProfile.folding(cand(0, [1, 0.1, 0], 5), into: old), old, "short sample ignored")
    }

    func testDissimilarSampleDoesNotPoisonTheProfile() {
        let old = OwnVoiceProfile(embedding: norm([1, 0, 0]), weight: 40, sampleCount: 1)
        XCTAssertEqual(OwnVoiceProfile.folding(cand(0, [0, 1, 0], 60), into: old), old, "another person alone at the laptop")
    }

    func testBadEmbeddingsAreRejected() {
        XCTAssertNil(OwnVoiceProfile.folding(cand(0, [], 60), into: nil))
        XCTAssertNil(OwnVoiceProfile.folding(cand(0, [0, 0, 0], 60), into: nil))
        XCTAssertNil(OwnVoiceProfile.folding(cand(0, [.nan, 1, 0], 60), into: nil))
        // Dimension change (a different model) restarts the profile instead of mixing.
        let old = OwnVoiceProfile(embedding: norm([1, 0, 0]), weight: 40, sampleCount: 3)
        let p = OwnVoiceProfile.folding(cand(0, [1, 0, 0, 0], 60), into: old)
        XCTAssertEqual(p?.embedding.count, 4)
        XCTAssertEqual(p?.sampleCount, 1)
    }

    // MARK: threshold + margin

    func testMatchDecisions() {
        let profile = norm([1, 0, 0])
        func at(_ cos: Float) -> [Float] { [cos, (1 - cos * cos).squareRoot(), 0] }
        // Clears threshold with margin over the runner-up.
        XCTAssertEqual(OwnVoiceMatcher.decide(profile: profile, candidates: [cand(0, at(0.9)), cand(1, at(0.2))]), 0)
        // Best is below the threshold: nobody.
        XCTAssertNil(OwnVoiceMatcher.decide(profile: profile, candidates: [cand(0, at(0.6)), cand(1, at(0.2))]))
        // Just above the threshold passes; just below fails.
        XCTAssertEqual(OwnVoiceMatcher.decide(profile: profile, candidates: [cand(3, at(0.66)), cand(1, at(0.1))]), 3)
        XCTAssertNil(OwnVoiceMatcher.decide(profile: profile, candidates: [cand(3, at(0.64)), cand(1, at(0.1))]))
        // Two similar voices: margin fails -> nobody (no guessing).
        XCTAssertNil(OwnVoiceMatcher.decide(profile: profile, candidates: [cand(0, at(0.85)), cand(1, at(0.78))]))
        // Margin exactly satisfied.
        XCTAssertEqual(OwnVoiceMatcher.decide(profile: profile, candidates: [cand(0, at(0.9)), cand(1, at(0.7))]), 0)
        // A lone candidate (the other was bleed) needs only the threshold.
        XCTAssertEqual(OwnVoiceMatcher.decide(profile: profile, candidates: [cand(7, at(0.8))]), 7)
        // No profile / wrong dimension / no candidates.
        XCTAssertNil(OwnVoiceMatcher.decide(profile: nil, candidates: [cand(0, at(0.9))]))
        XCTAssertNil(OwnVoiceMatcher.decide(profile: profile, candidates: [cand(0, [1, 0, 0, 0])]))
        XCTAssertNil(OwnVoiceMatcher.decide(profile: profile, candidates: []))
    }

    // MARK: labelling: learning sample + gap-free numbering

    private let eA: [Float] = [1, 0, 0, 0], eB: [Float] = [0, 1, 0, 0], eC: [Float] = [0, 0, 1, 0]

    private func out(_ turns: [(Int, Double, Double)], _ emb: [Int: [Float]]) -> DiarizationOutput {
        let t = turns.map { DiarizedTurn(speaker: $0.0, start: $0.1, end: $0.2) }
        return DiarizationOutput(turns: t, speakers: emb.keys.sorted().map { id in
            SpeakerProfile(speaker: id, embedding: emb[id]!,
                           speechSeconds: t.filter { $0.speaker == id }.reduce(0) { $0 + $1.duration })
        })
    }

    private func seg(_ who: String, _ s: Double, _ e: Double, _ text: String = "x") -> MeetingSegment {
        MeetingSegment(speaker: who, start: s, end: e, text: text)
    }

    func testSingleMicSpeakerYieldsLearningSampleInLegacyAndMicOnlyCases() {
        let segs = [seg("Me", 0, 10), seg("Them", 12, 20), seg("Me", 22, 30)]
        let legacy = SpeakerLabelling.label(
            segments: segs, mic: out([(0, 0, 30)], [0: eA]), system: out([(0, 0, 30)], [0: eB]))
        XCTAssertFalse(legacy.changed)
        XCTAssertEqual(legacy.ownVoiceSample?.embedding, eA)
        XCTAssertEqual(legacy.ownVoiceSample?.speechSeconds ?? 0, 30, accuracy: 1e-9)

        let micOnly = SpeakerLabelling.label(
            segments: [seg("Me", 0, 10), seg("Me", 12, 20)], mic: out([(0, 0, 20)], [0: eA]), system: nil)
        XCTAssertEqual(micOnly.ownVoiceSample?.embedding, eA)
    }

    func testNeverLearnFromMultiSpeakerMicLane() {
        let segs = [seg("Me", 0, 30), seg("Me", 32, 62)]
        let r = SpeakerLabelling.label(
            segments: segs, mic: out([(0, 0, 30), (1, 32, 62)], [0: eA, 1: eB]), system: nil)
        XCTAssertTrue(r.changed)
        XCTAssertNil(r.ownVoiceSample, "two real people on the mic: nobody's voice is learned")
    }

    func testShortFragmentFoldsAwayAndSampleSumsFoldedSpeech() {
        // Cluster 1 is a 2 s cough/aside; it folds into cluster 0 -> one speaker.
        let segs = [seg("Me", 0, 30), seg("Me", 31, 33)]
        let mic = DiarizationOutput(
            turns: [DiarizedTurn(speaker: 0, start: 0, end: 30), DiarizedTurn(speaker: 1, start: 31, end: 33)],
            speakers: [SpeakerProfile(speaker: 0, embedding: eA, speechSeconds: 30),
                       SpeakerProfile(speaker: 1, embedding: [0.9, 0.3, 0, 0], speechSeconds: 2)])
        let r = SpeakerLabelling.label(segments: segs, mic: mic, system: nil)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.ownVoiceSample?.cluster, 0)
        XCTAssertEqual(r.ownVoiceSample?.speechSeconds ?? 0, 32, accuracy: 1e-9)
    }

    func testBleedOnlyMicLaneIsNotLearned() {
        // The mic holds only the far speaker's voice through the laptop speakers.
        let segs = [seg("Me", 0, 30), seg("Them", 32, 62)]
        let r = SpeakerLabelling.label(
            segments: segs, mic: out([(0, 0, 30)], [0: [0.95, 0.1, 0.05, 0]]), system: out([(0, 32, 62)], [0: eA]))
        XCTAssertNil(r.ownVoiceSample)
    }

    func testBleedClusterPlusOneRealMicSpeakerLearnsTheRealOne() {
        // Mic: cluster 0 = far speaker's bleed (matches system), cluster 1 = the owner.
        let segs = [seg("Me", 0, 20), seg("Me", 22, 52), seg("Them", 54, 80), seg("Them", 82, 100)]
        let r = SpeakerLabelling.label(
            segments: segs,
            mic: out([(0, 0, 20), (1, 22, 52)], [0: [0.95, 0.1, 0.05, 0], 1: eB]),
            system: out([(0, 54, 80), (1, 82, 100)], [0: eA, 1: eC]))
        XCTAssertEqual(r.ownVoiceSample?.cluster, 1)
        XCTAssertEqual(r.ownVoiceSample?.embedding, eB)
    }

    func testNumberingStaysGapFreeAndByFirstAppearanceAfterMeIsAssigned() {
        // Mic: A, B, C (C is Me, appearing in the middle); system: D.
        let segs = [seg("Me", 0, 10, "a"), seg("Them", 11, 20, "d"), seg("Me", 21, 30, "c"),
                    seg("Me", 31, 40, "b"), seg("Me", 41, 50, "c2")]
        let mic = out([(0, 0, 10), (2, 21, 30), (1, 31, 40), (2, 41, 50)], [0: eA, 1: eB, 2: eC])
        let sys = out([(0, 11, 20)], [0: [0, 0, 0, 1]])
        let me = SpeakerLabelling.label(segments: segs, mic: mic, system: sys, resolveMe: { _ in 2 })
        XCTAssertEqual(me.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Me", "Speaker 3", "Me"])
        XCTAssertEqual(me.participants, ["Me", "Speaker 1", "Speaker 2", "Speaker 3"])
        // The first-appearing person is Me: the others start at 1.
        let first = SpeakerLabelling.label(segments: segs, mic: mic, system: sys, resolveMe: { _ in 0 })
        XCTAssertEqual(first.segments.map(\.speaker), ["Me", "Speaker 1", "Speaker 2", "Speaker 3", "Speaker 2"])
        // Nobody identified: plain numbering.
        let none = SpeakerLabelling.label(segments: segs, mic: mic, system: sys, resolveMe: { _ in nil })
        XCTAssertEqual(none.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4", "Speaker 3"])
    }

    // MARK: persistence + deletion (inside the test sandbox)

    private var tmp: URL!
    override func setUpWithError() throws {
        XCTAssertNotNil(AppPaths.testSandboxRoot, "tests must be sandboxed from real Application Support")
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ovp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testDefaultLocationIsUnderApplicationSupportAndSandboxedInTests() {
        let root = AppPaths.testSandboxRoot!.path
        XCTAssertTrue(OwnVoiceProfileStore.defaultURL().path.hasPrefix(root))
        XCTAssertEqual(OwnVoiceProfileStore.defaultURL().deletingLastPathComponent().path,
                       AppPaths.supportDirectory().path)
    }

    func testPersistenceRoundTripAndPermissions() throws {
        let url = tmp.appendingPathComponent("p.json")
        let store = OwnVoiceProfileStore(url: url)
        XCTAssertNil(store.load())
        XCTAssertTrue(store.learn(cand(0, [1, 0.2, 0, 0], 40)))
        XCTAssertTrue(store.learn(cand(0, [1, -0.2, 0, 0], 40)))
        let reopened = OwnVoiceProfileStore(url: url) // fresh instance reads the file
        let p = try XCTUnwrap(reopened.load())
        XCTAssertEqual(p, store.load())
        XCTAssertEqual(p.sampleCount, 2)
        XCTAssertEqual(p.weight, 80, accuracy: 1e-9)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        XCTAssertFalse(store.learn(cand(0, [1, 0, 0, 0], 5)), "too little speech: no write")
    }

    func testResolverReadsTheStoredProfile() {
        let store = OwnVoiceProfileStore(url: tmp.appendingPathComponent("p.json"))
        XCTAssertNil(store.resolver([cand(0, eA)]), "no profile yet: nobody is Me")
        store.learn(cand(0, eA, 40))
        XCTAssertEqual(store.resolver([cand(4, eB), cand(5, [0.97, 0.1, 0, 0])]), 5)
    }

    func testDeleteRemovesFileAndProfile() {
        let url = tmp.appendingPathComponent("p.json")
        let store = OwnVoiceProfileStore(url: url)
        store.learn(cand(0, eA, 40))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.load())
        XCTAssertNil(OwnVoiceProfileStore(url: url).load())
        XCTAssertNil(store.resolver([cand(0, eA)]), "deleted profile identifies nobody")
    }

    func testCorruptFileIsIgnoredAndOverwrittenOnNextLearn() throws {
        let url = tmp.appendingPathComponent("p.json")
        try Data("{not json".utf8).write(to: url)
        let store = OwnVoiceProfileStore(url: url)
        XCTAssertNil(store.load())
        XCTAssertTrue(store.learn(cand(0, eA, 40)))
        XCTAssertNotNil(OwnVoiceProfileStore(url: url).load())
    }

    func testProfileIsNotPartOfAnyMeetingOrExportShape() throws {
        // Meeting (what exports, MCP and the graph read) has no voice-profile field.
        let m = Meeting(title: "T", startUnix: 1, durationSec: 1, transcript: "x", summary: "",
                        participants: ["Me"], source: "s", fileName: "f.md", segments: nil)
        let json = String(data: try JSONEncoder().encode(m), encoding: .utf8) ?? ""
        XCTAssertFalse(json.lowercased().contains("embedding"))
        XCTAssertFalse(json.lowercased().contains("voice"))
    }

    // MARK: digest remap

    func testRemapLooksUpLaneAndTimeExactlyAndFailsOnUnmatchedLines() {
        var segs = [seg("Speaker 1", 0, 5), seg("Speaker 2", 6, 9), seg("Me", 10, 14)]
        segs[0].lane = "Me"; segs[1].lane = "Them"; segs[2].lane = "Me"
        let r = DigestSpeakerRemap(segments: segs)
        XCTAssertEqual(r.label(lane: .me, at: 0), "Speaker 1")
        XCTAssertEqual(r.label(lane: .me, at: 0.03), "Speaker 1", "long-line pieces are stamped start + i*0.001")
        XCTAssertEqual(r.label(lane: .them, at: 6), "Speaker 2")
        XCTAssertEqual(r.label(lane: .me, at: 10), "Me")
        XCTAssertNil(r.label(lane: .me, at: 7.5), "no segment starts there: cannot map honestly")
        XCTAssertNil(r.label(lane: .them, at: 0), "right time, wrong lane")
        XCTAssertEqual(r.distinctLabels, 3)
        XCTAssertNil(r.laneWideLabel(.me), "the mic lane became two people")
        XCTAssertEqual(r.laneWideLabel(.them), "Speaker 2")
    }

    func testDigestPendingLinesAreRelabelledWithoutModelCalls() async {
        let digest = MeetingDigestBuilder(summarizer: MeetingSummarizer(), graphExtractor: nil)
        digest.ingest(.me, "hello there", at: 0)
        digest.ingest(.them, "hi", at: 6)
        digest.ingest(.me, "next point", at: 10)
        XCTAssertEqual(digest.pendingTextForTesting(), "Me: hello there Them: hi Me: next point")
        var segs = [seg("Speaker 1", 0, 5), seg("Speaker 2", 6, 9), seg("Me", 10, 14)]
        segs[0].lane = "Me"; segs[1].lane = "Them"; segs[2].lane = "Me"
        let ok = await digest.remapSpeakers(DigestSpeakerRemap(segments: segs))
        XCTAssertTrue(ok)
        XCTAssertEqual(digest.pendingTextForTesting(), "Speaker 1: hello there Speaker 2: hi Me: next point")
    }

    func testDigestRemapFailsWhenALineHasNoSegment() async {
        let digest = MeetingDigestBuilder(summarizer: MeetingSummarizer(), graphExtractor: nil)
        digest.ingest(.me, "a", at: 0)
        digest.ingest(.me, "merged window text", at: 3.3)
        var segs = [seg("Speaker 1", 0, 5), seg("Speaker 2", 6, 9)]
        segs[0].lane = "Me"; segs[1].lane = "Me"
        let ok = await digest.remapSpeakers(DigestSpeakerRemap(segments: segs))
        XCTAssertFalse(ok, "caller falls back to the transcript rebuild")
    }

    func testSealedFactLabelSubstitutionOnlyWhenUnambiguous() {
        let facts = "Excerpt 1: - Them to send the deck\n- Me will review. Tell me when; them too"
        XCTAssertTrue(MeetingDigestBuilder.mentions("Them", in: facts))
        XCTAssertTrue(MeetingDigestBuilder.mentions("Me", in: facts))
        XCTAssertFalse(MeetingDigestBuilder.mentions("Them", in: "no lane named; them lowercase"))
        XCTAssertEqual(
            MeetingDigestBuilder.substituteLabels(in: facts, with: ["Them": "Speaker 2"]),
            "Excerpt 1: - Speaker 2 to send the deck\n- Me will review. Tell me when; them too")
        XCTAssertEqual(MeetingDigestBuilder.substituteLabels(in: facts, with: [:]), facts, "no mapping: untouched")
        XCTAssertEqual(MeetingDigestBuilder.substituteLabels(in: "Me and Them", with: ["Me": "Them", "Them": "Me"]),
                       "Them and Me", "single pass: no double substitution")
    }
}
