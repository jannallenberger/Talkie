import XCTest
import TalkieDiarization
@testable import Talkie

/// Pure labelling logic: overlap assignment, global numbering, bleed guard, the
/// Me/Them/Speaker-N rules table, the own-voice seam, and transcript re-rendering.
final class SpeakerLabellingTests: XCTestCase {
    // Unit-ish embeddings: distinct people are orthogonal; "bleed" is a near-copy.
    private let eA: [Float] = [1, 0, 0, 0]
    private let eB: [Float] = [0, 1, 0, 0]
    private let eC: [Float] = [0, 0, 1, 0]
    private let eABleed: [Float] = [0.95, 0.1, 0.05, 0]

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

    // MARK: overlap

    func testOverlapPicksMaxOverlapSpeaker() {
        let turns = [DiarizedTurn(speaker: 0, start: 0, end: 5), DiarizedTurn(speaker: 1, start: 5, end: 10)]
        XCTAssertEqual(SpeakerLabelling.dominantSpeaker(start: 4, end: 7, turns: turns), 1) // 1s vs 2s
        XCTAssertEqual(SpeakerLabelling.dominantSpeaker(start: 3, end: 6, turns: turns), 0) // 2s vs 1s
        XCTAssertEqual(SpeakerLabelling.dominantSpeaker(start: 4, end: 6, turns: turns), 0) // tie -> lower id
        XCTAssertNil(SpeakerLabelling.dominantSpeaker(start: 20, end: 21, turns: turns))
        XCTAssertEqual(SpeakerLabelling.dominantSpeaker(start: 6, end: 6, turns: turns), 1) // zero-length cue
        XCTAssertNil(SpeakerLabelling.dominantSpeaker(start: 11, end: 11, turns: turns))
    }

    func testOverlapSumsAcrossSeveralTurnsOfOneSpeaker() {
        let turns = [DiarizedTurn(speaker: 0, start: 0, end: 2), DiarizedTurn(speaker: 1, start: 2, end: 5),
                     DiarizedTurn(speaker: 0, start: 5, end: 9)]
        // S0: 2 + 3 = 5s, S1: 3s
        XCTAssertEqual(SpeakerLabelling.dominantSpeaker(start: 0, end: 8, turns: turns), 0)
    }

    // MARK: rules table

    func testOnePlusOneKeepsMeThemExactly() {
        let segments = [seg("Me", 0, 5), seg("Them", 6, 10), seg("Me", 11, 15)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 20)], [0: eA]),
            system: out([(0, 0, 20)], [0: eB]))
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.segments, segments, "byte-identical: labels, times, text and no lane tag")
        XCTAssertEqual(r.participants, ["Me", "Them"])
        XCTAssertEqual(r.speakerCount, 2)
    }

    func testOnePlusOneEvenWhenMicLooksLikeSystem() {
        // Legacy rule wins over the bleed guard: 1+1 is Me/Them no matter what.
        let segments = [seg("Me", 0, 5), seg("Them", 6, 10)]
        let r = SpeakerLabelling.label(segments: segments,
                                       mic: out([(0, 0, 20)], [0: eABleed]), system: out([(0, 0, 20)], [0: eA]))
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.segments, segments)
    }

    func testMicOnlySingleSpeakerIsMe() {
        let segments = [seg("Me", 0, 5), seg("Me", 6, 10)]
        let r = SpeakerLabelling.label(segments: segments, mic: out([(0, 0, 20)], [0: eA]), system: nil)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.segments, segments)
    }

    func testMicOnlyMultiSpeakerEveryoneIsNumbered_NoMeGuess() {
        // Speaker 1 talks far more than speaker 2; dominance must NOT make anyone "Me".
        let segments = [seg("Me", 0, 30), seg("Me", 31, 36), seg("Me", 37, 60)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 30), (1, 31, 36), (0, 37, 60)], [0: eA, 1: eB]), system: nil)
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(r.segments.map(\.lane), ["Me", "Me", "Me"])
        XCTAssertEqual(r.participants, ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(r.speakerCount, 2)
    }

    func testCallWithMultiSpeakerMic_AllDistinctPeopleNumbered() {
        // Two people share the laptop mic; one person on the far end.
        let segments = [seg("Me", 0, 10), seg("Them", 12, 20), seg("Me", 22, 30), seg("Them", 31, 40)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 10), (1, 22, 30)], [0: eA, 1: eB]),
            system: out([(0, 12, 20), (0, 31, 40)], [0: eC]))
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 2"])
        XCTAssertEqual(r.segments.map(\.lane), ["Me", "Them", "Me", "Them"])
        XCTAssertEqual(r.speakerCount, 3)
        XCTAssertFalse(r.participants.contains("Me"))
        XCTAssertFalse(r.participants.contains("Them"))
    }

    func testMultiSpeakerFarEndWithOneMicVoiceKeepsMe() {
        let segments = [seg("Them", 0, 10), seg("Me", 11, 15), seg("Them", 16, 25)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 11, 15)], [0: eA]),
            system: out([(0, 0, 10), (1, 16, 25)], [0: eB, 1: eC]))
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Me", "Speaker 2"])
        XCTAssertEqual(r.participants, ["Me", "Speaker 1", "Speaker 2"])
    }

    // MARK: numbering

    func testNumberingIsByFirstAppearanceNotClusterIndex() {
        // Cluster ids are reversed relative to appearance on both lanes.
        let segments = [seg("Them", 0, 10), seg("Me", 12, 20), seg("Them", 22, 30), seg("Me", 32, 40)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(5, 12, 20), (2, 32, 40)], [5: eA, 2: eB]),
            system: out([(9, 0, 10), (1, 22, 30)], [9: eC, 1: [0, 0, 0, 1]]))
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4"])
    }

    func testNumberingUsesSegmentOrderAcrossLanesNotLaneClocks() {
        // Lane clocks have a skew: the far lane's timestamps run a few seconds ahead.
        // Numbering follows the (already interleaved) segment array, i.e. what the
        // transcript shows, never a comparison of the two raw clocks.
        let segments = [seg("Me", 0, 4), seg("Them", 5, 9), seg("Me", 10, 14)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 4), (1, 10, 14)], [0: eA, 1: eB]),
            system: out([(0, 0, 100)], [0: eC]))
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 3"])
    }

    // MARK: bleed guard

    func testBleedGuardMergesMicClusterIntoMatchingSystemSpeaker() {
        // Mic: Samantha (own) + the far speaker A leaking through the laptop speakers.
        // System: A and B.
        let segments = [seg("Them", 0, 10), seg("Me", 11, 15), seg("Me", 16, 20), seg("Them", 21, 30)]
        let mic = out([(0, 11, 15), (1, 16, 20)], [0: eC, 1: eABleed])
        let sys = out([(0, 0, 10), (1, 21, 30)], [0: eA, 1: eB])
        let r = SpeakerLabelling.label(segments: segments, mic: mic, system: sys)
        // F2: after the bleed guard the mic holds ONE own voice (Samantha), so she is Me
        // even with no profile; A heard through the mic is still just one person.
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Me", "Speaker 1", "Speaker 2"])
        XCTAssertEqual(r.speakerCount, 3, "Me + A + B")

        // Guard off (threshold above any cosine) -> the bleed becomes a 4th person.
        let off = SpeakerLabelling.label(segments: segments, mic: mic, system: sys, bleedThreshold: 1.5)
        XCTAssertEqual(off.speakerCount, 4)
    }

    func testBleedGuardLoneMicClusterThatIsTheFarSpeakerIsNotMe() {
        let segments = [seg("Them", 0, 10), seg("Me", 11, 15), seg("Them", 16, 25)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 11, 15)], [0: eABleed]),
            system: out([(0, 0, 10), (1, 16, 25)], [0: eA, 1: eB]))
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 1", "Speaker 2"])
        XCTAssertFalse(r.participants.contains("Me"))
    }

    func testBleedGuardDoesNotMergeDifferentVoices() {
        let segments = [seg("Them", 0, 10), seg("Me", 11, 15), seg("Them", 16, 25)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 11, 15)], [0: eC]),
            system: out([(0, 0, 10), (1, 16, 25)], [0: eA, 1: eB]))
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Me", "Speaker 2"])
    }

    func testBleedGuardRefusesAmbiguousMatch() {
        // The mic voice resembles BOTH far-end people equally: merging into either is a guess.
        let segments = [seg("Them", 0, 10), seg("Me", 11, 15), seg("Them", 16, 25)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 11, 15)], [0: [0.7, 0.7, 0, 0]]),
            system: out([(0, 0, 10), (1, 16, 25)], [0: eA, 1: eB]))
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Me", "Speaker 2"])
    }

    // MARK: fragments / no-overlap / own-voice seam

    func testFragmentClusterIsFoldedSoItCannotBreakOnePlusOne() {
        // A 1 s cough cluster on the mic must not turn a clean Me/Them call into "Speaker N".
        let segments = [seg("Me", 0, 30), seg("Me", 31, 32), seg("Them", 40, 60)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 30), (1, 31, 32)], [0: eA, 1: eABleed]),
            system: out([(0, 40, 60)], [0: eB]))
        XCTAssertFalse(r.changed)
        XCTAssertEqual(r.segments.map(\.speaker), ["Me", "Me", "Them"])
    }

    func testSegmentWithNoOverlapKeepsItsLaneLabel() {
        let segments = [seg("Me", 0, 10), seg("Me", 12, 20), seg("Them", 500, 510)]
        let r = SpeakerLabelling.label(
            segments: segments,
            mic: out([(0, 0, 10), (1, 12, 20)], [0: eA, 1: eB]),
            system: out([(0, 0, 10)], [0: eC]))
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Speaker 2", "Them"])
        XCTAssertNil(r.segments[2].lane)
        XCTAssertEqual(r.participants, ["Speaker 1", "Speaker 2", "Them"])
    }

    func testOwnVoiceResolverIsTheOnlyWayToGetMeFromAMultiSpeakerMic() {
        let segments = [seg("Me", 0, 10), seg("Me", 12, 20)]
        let mic = out([(0, 0, 10), (1, 12, 20)], [0: eA, 1: eB])
        var seen: [MicSpeakerCandidate] = []
        let box = Box()
        let r = SpeakerLabelling.label(segments: segments, mic: mic, system: nil) { cands in
            box.set(cands); return 1
        }
        seen = box.get()
        XCTAssertEqual(seen.map(\.cluster), [0, 1])
        XCTAssertEqual(seen.map(\.embedding), [eA, eB], "the seam receives per-speaker embeddings")
        XCTAssertEqual(r.segments.map(\.speaker), ["Speaker 1", "Me"])
        XCTAssertEqual(r.participants, ["Me", "Speaker 1"])

        // An out-of-range answer is ignored rather than trusted.
        let bad = SpeakerLabelling.label(segments: segments, mic: mic, system: nil) { _ in 99 }
        XCTAssertEqual(bad.segments.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    func testResolverNotConsultedForLoneMicVoiceOrWhenEveryMicVoiceIsBleed() {
        let box = Box()
        let segments = [seg("Me", 0, 10), seg("Them", 12, 20), seg("Them", 22, 30)]
        let r = SpeakerLabelling.label(
            segments: segments, mic: out([(0, 0, 10)], [0: eC]),
            system: out([(0, 12, 20), (1, 22, 30)], [0: eA, 1: eB])) { c in box.set(c); return 0 }
        XCTAssertTrue(box.get().isEmpty)
        XCTAssertEqual(r.segments.map(\.speaker), ["Me", "Speaker 1", "Speaker 2"])
    }

    // MARK: rendering

    func testRenderFromSegmentsEqualsRenderFromTurnsForMeThem() {
        let turns: [TurnLog.Turn] = [
            .init(elapsed: 0, speaker: .me, text: "hello there", endSec: 2),
            .init(elapsed: 3, speaker: .them, text: "hi", endSec: 4),
            .init(elapsed: 5, speaker: .them, text: "how are you", endSec: 6),
            .init(elapsed: 40, speaker: .me, text: "fine", endSec: 41),
        ]
        let segments = MeetingTranscriptRenderer.segments(from: turns, duration: 60)!
        XCTAssertEqual(MeetingTranscriptRenderer.render(segments: segments),
                       MeetingTranscriptRenderer.render(turns, duration: 60))
        let solo = Array(turns.prefix(1))
        XCTAssertEqual(MeetingTranscriptRenderer.render(segments: MeetingTranscriptRenderer.segments(from: solo)!),
                       MeetingTranscriptRenderer.render(solo))
    }

    func testRelabelledTranscriptShowsPeople() {
        var segments = [seg("Speaker 1", 0, 3, "good morning"), seg("Speaker 2", 4, 6, "hi"),
                        seg("Speaker 2", 7, 9, "ready"), seg("Speaker 3", 10, 12, "yes")]
        XCTAssertEqual(MeetingTranscriptRenderer.render(segments: segments),
                       "[00:00] Speaker 1: good morning\n[00:04] Speaker 2: hi ready\n[00:10] Speaker 3: yes")
        // One distinct person -> plain prose, like any solo transcript.
        segments = [seg("Speaker 1", 0, 3, "a"), seg("Speaker 1", 4, 6, "b")]
        XCTAssertEqual(MeetingTranscriptRenderer.render(segments: segments), "a b")
    }

    /// A recorded meeting says who spoke even when only one person did.
    func testSoloTranscriptIsLabelledWhenAsked() {
        let turns: [TurnLog.Turn] = [
            .init(elapsed: 0.6, speaker: .me, text: "this is my voice", endSec: 9),
            .init(elapsed: 9, speaker: .me, text: "and still me", endSec: 26),
            .init(elapsed: 80, speaker: .me, text: "after a long pause", endSec: 84),
        ]
        XCTAssertEqual(MeetingTranscriptRenderer.render(turns), "this is my voice and still me after a long pause")
        let labelled = MeetingTranscriptRenderer.render(turns, labelSolo: true)
        XCTAssertEqual(labelled, "[00:00] Me: this is my voice and still me\n[01:20] Me: after a long pause")
        // Segments built from the same turns render to the same labelled text.
        let segments = MeetingTranscriptRenderer.segments(from: turns)!
        XCTAssertEqual(MeetingTranscriptRenderer.render(segments: segments, labelSolo: true), labelled)
        // Two speakers: the flag changes nothing.
        let both = turns + [.init(elapsed: 90, speaker: .them, text: "hi", endSec: 91)]
        XCTAssertEqual(MeetingTranscriptRenderer.render(both, labelSolo: true), MeetingTranscriptRenderer.render(both))
        XCTAssertEqual(MeetingTranscriptRenderer.render([], labelSolo: true), "")
    }

    func testLabelledLayoutDetection() {
        XCTAssertTrue(MeetingTranscriptRenderer.isLabelled("[00:00] Me: hello\n[00:09] Them: hi"))
        XCTAssertTrue(MeetingTranscriptRenderer.isLabelled("[1:02:03] Speaker 2: hello"))
        XCTAssertFalse(MeetingTranscriptRenderer.isLabelled("hello there. This is prose: with a colon"))
        XCTAssertFalse(MeetingTranscriptRenderer.isLabelled("[note] Me: hello"))
        XCTAssertFalse(MeetingTranscriptRenderer.isLabelled("[00:00] no label here"))
        XCTAssertFalse(MeetingTranscriptRenderer.isLabelled(""))
    }

    /// Relabelling keeps the layout the note was saved in.
    func testApplyKeepsALabelledSoloLayout() {
        let segments = [seg("Me", 0, 3, "a"), seg("Me", 4, 6, "b")]
        let labelled = Meeting(title: "t", startUnix: 1, durationSec: 10,
                               transcript: MeetingTranscriptRenderer.render(segments: segments, labelSolo: true),
                               summary: "", participants: ["Me"], source: "s", fileName: "f.md", segments: segments)
        let relabelled = [seg("Speaker 1", 0, 3, "a"), seg("Speaker 1", 4, 6, "b")]
        let result = SpeakerLabelling.Result(segments: relabelled, sourceIndex: [0, 1], participants: ["Speaker 1"],
                                            speakerCount: 1, changed: true)
        XCTAssertEqual(MeetingDiarizationPipeline.apply(result, to: labelled).transcript, "[00:00] Speaker 1: a b")
        var prose = labelled
        prose.transcript = "a b"
        XCTAssertEqual(MeetingDiarizationPipeline.apply(result, to: prose).transcript, "a b")
    }

    func testGenericLabelDetection() {
        for g in ["Me", "Them", "Speaker 1", "Speaker 12"] { XCTAssertTrue(SpeakerLabels.isGeneric(g), g) }
        for n in ["Alice", "Speaker", "Speaker X", "Speakers 1", "Me too"] { XCTAssertFalse(SpeakerLabels.isGeneric(n), n) }
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [MicSpeakerCandidate] = []
    func set(_ v: [MicSpeakerCandidate]) { lock.withLock { value = v } }
    func get() -> [MicSpeakerCandidate] { lock.withLock { value } }
}
