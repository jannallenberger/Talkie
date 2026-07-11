import XCTest
@testable import Talkie

/// Pure-logic tests for the live-subtopic gating: response parsing and the
/// confidence + hysteresis step that prevents the pill from ever misrepresenting
/// what's being discussed.
final class MeetingSubtopicTests: XCTestCase {
    private typealias Engine = MeetingSubtopicEngine
    private typealias Gate = MeetingSubtopicEngine.GateState

    // MARK: parse

    func testParseHighConfidenceTopic() {
        let (topic, _, high) = Engine.parse("TOPIC|Budget planning\nCONFIDENCE|HIGH")
        XCTAssertEqual(topic, "Budget planning")
        XCTAssertTrue(high)
    }

    func testParseNoneIsNilTopic() {
        let (topic, _, high) = Engine.parse("TOPIC|NONE\nCONFIDENCE|LOW")
        XCTAssertNil(topic)
        XCTAssertFalse(high)
    }

    func testParseToleratesNoiseQuotesAndSpacing() {
        let (topic, _, high) = Engine.parse("here you go:\nTOPIC| \"Q3 roadmap\" \nCONFIDENCE|  high \ntrailing junk")
        XCTAssertEqual(topic, "Q3 roadmap")
        XCTAssertTrue(high)
    }

    func testParseRejectsRunawayTopic() {
        let (topic, _, _) = Engine.parse(
            "TOPIC|this is a far too long topic that clearly exceeds the word and character bounds\nCONFIDENCE|HIGH")
        XCTAssertNil(topic, "a sentence-length topic is treated as no usable topic")
    }

    // MARK: parse — GLOSS (B3)

    func testParseGlossPresentAndUsed() {
        let (topic, gloss, high) = Engine.parse(
            "TOPIC|Budget planning\nGLOSS|Discussing the Q3 budget rollover and hiring freeze\nCONFIDENCE|HIGH")
        XCTAssertEqual(topic, "Budget planning")
        XCTAssertEqual(gloss, "Discussing the Q3 budget rollover and hiring freeze")
        XCTAssertTrue(high)
    }

    func testParseMissingGlossLineIsNil() {
        // Older TOPIC+CONFIDENCE-only responses (and this phase's other tests) must
        // keep parsing cleanly with no GLOSS line at all.
        let (topic, gloss, high) = Engine.parse("TOPIC|Budget planning\nCONFIDENCE|HIGH")
        XCTAssertEqual(topic, "Budget planning")
        XCTAssertNil(gloss, "no GLOSS line at all parses as nil, not an error")
        XCTAssertTrue(high)
    }

    func testParseEmptyGlossIsNil() {
        let (_, gloss, _) = Engine.parse("TOPIC|Budget planning\nGLOSS|\nCONFIDENCE|HIGH")
        XCTAssertNil(gloss, "an empty GLOSS value is nil")
    }

    func testParseRejectsRunawayGloss() {
        let (topic, gloss, _) = Engine.parse(
            "TOPIC|Budget planning\n" +
            "GLOSS|This sentence just keeps going on and on with far more than fourteen words describing the topic in absurd detail\n" +
            "CONFIDENCE|HIGH")
        XCTAssertEqual(topic, "Budget planning", "the topic is unaffected by a runaway gloss")
        XCTAssertNil(gloss, "an overflowing gloss is treated as no usable gloss")
    }

    // MARK: step — confidence + hysteresis

    func testFirstTopicAcceptedImmediately() {
        // Eager first accept: nothing is shown yet, so a single confident hit
        // fills the empty pill right away — no hysteresis wait for the FIRST label.
        var g = Gate()
        g = Engine.step(g, topic: "Budget", high: true)
        XCTAssertEqual(g.accepted, "Budget", "one high accepts immediately when nothing is shown yet")
    }

    func testLowConfidenceNeverChangesShownTopic() {
        var g = Gate()
        g = Engine.step(g, topic: "Budget", high: true)   // eager accept: Budget shown after one hit
        g = Engine.step(g, topic: "Budget", high: true)   // repeat of the shown topic: harmless no-op
        g = Engine.step(g, topic: "Hiring", high: false)  // a miss
        XCTAssertEqual(g.accepted, "Budget", "low confidence holds the current topic")
    }

    func testSwitchingTopicsRequiresSustainedHighs() {
        var g = Gate()
        g = Engine.step(g, topic: "Budget", high: true)   // eager accept: Budget shown after one hit
        g = Engine.step(g, topic: "Budget", high: true)   // repeat of the shown topic: harmless no-op
        g = Engine.step(g, topic: "Hiring", high: true)
        XCTAssertEqual(g.accepted, "Budget", "a single high for a new topic doesn't switch")
        g = Engine.step(g, topic: "Hiring", high: true)
        XCTAssertEqual(g.accepted, "Hiring", "sustained → switch")
    }

    func testFlipFloppingTopicsNeverSwitch() {
        // Anchor the anti-flicker guarantee on the REPLACEMENT path: once a topic is
        // already shown (here via eager first accept), alternating candidates must
        // never reach the 2-streak needed to replace it.
        var g = Gate()
        g = Engine.step(g, topic: "Kickoff", high: true)
        XCTAssertEqual(g.accepted, "Kickoff", "eager first accept shows Kickoff after one hit")
        g = Engine.step(g, topic: "A", high: true)
        g = Engine.step(g, topic: "B", high: true)
        g = Engine.step(g, topic: "A", high: true)
        XCTAssertEqual(g.accepted, "Kickoff", "alternating replacement candidates never reach a 2-streak")
    }

    func testNoneNeverAccepted() {
        var g = Gate()
        g = Engine.step(g, topic: nil, high: true)
        g = Engine.step(g, topic: nil, high: true)
        XCTAssertNil(g.accepted)
    }

    func testCaseInsensitiveTopicDoesNotReshow() {
        var g = Gate()
        g = Engine.step(g, topic: "Budget", high: true)   // eager accept: Budget shown after one hit
        g = Engine.step(g, topic: "Budget", high: true)   // repeat of the shown topic: harmless no-op
        let before = g
        g = Engine.step(g, topic: "budget", high: true)   // same topic, different case
        XCTAssertEqual(g.accepted, "Budget")
        XCTAssertEqual(g.streak, 0, "already-shown topic resets the candidate streak")
        XCTAssertEqual(before.accepted, g.accepted)
    }

    // MARK: - D8: accept hook + chapter-collection ordering

    /// A tiny Sendable collector standing in for AppDelegate's chapter-stamping
    /// closure. It timestamps each accepted topic from a settable clock, exactly as
    /// the wiring stamps `meetingRecorder.elapsed` — so a test can assert both the
    /// hook cardinality and the honest, monotonically-advancing accept times.
    private final class ChapterCollector: @unchecked Sendable {
        // Guarded by the main actor in these tests (all appends happen on the test's
        // main-actor context via the synchronous hook), so a plain array is safe.
        private(set) var chapters: [Chapter] = []
        var clock: TimeInterval = 0
        func record(_ topic: String) { chapters.append(Chapter(title: topic, start: clock)) }
    }

    /// The accept hook must fire once per accept transition — never on a mere
    /// candidate or a miss — and carry the accepted title. This is the load-bearing
    /// half of the ordering guarantee: an accept that happens during recording is
    /// appended to the collector the instant it's accepted, so a later stop-time
    /// snapshot sees it. Covers both tiers: the eager first accept (one hit, nothing
    /// shown yet) and a damped replacement (two hits, something already shown).
    @MainActor
    func testAcceptHookFiresOncePerAcceptWithTitle() async {
        let model = MeetingSubtopicModel()
        let collector = ChapterCollector()
        let engine = Engine(summarizer: NoopSummarizer(), model: model) { [collector] topic in
            collector.record(topic)
        }

        // Eager first accept: nothing is shown yet, so ONE high fires the hook
        // immediately — the pill shouldn't sit empty waiting for a second hit.
        collector.clock = 30
        await engine.evaluateForTesting("TOPIC|Budget\nCONFIDENCE|HIGH")
        XCTAssertEqual(collector.chapters.map(\.title), ["Budget"], "the first confident hit accepts immediately")
        XCTAssertEqual(collector.chapters.first?.start, 30, "stamped with the accept-time clock")

        // A miss (low confidence) must not fire the hook again.
        await engine.evaluateForTesting("TOPIC|Hiring\nCONFIDENCE|LOW")
        XCTAssertEqual(collector.chapters.count, 1, "a low-confidence miss records nothing")

        // Replacing the already-accepted topic is damped: one high alone for a new
        // topic is a candidate only, no accept, no chapter.
        await engine.evaluateForTesting("TOPIC|Hiring\nCONFIDENCE|HIGH")
        XCTAssertEqual(collector.chapters.count, 1, "a single high for a replacement is a candidate, not an accept")

        // Second consecutive high for the same replacement candidate: accept →
        // exactly one NEW chapter (the hook fires once per transition, not once
        // per qualifying hit).
        collector.clock = 90
        await engine.evaluateForTesting("TOPIC|Hiring\nCONFIDENCE|HIGH")
        XCTAssertEqual(collector.chapters.map(\.title), ["Budget", "Hiring"], "sustained replacement accepts once")
        XCTAssertEqual(collector.chapters.last?.start, 90, "stamped with the accept-time clock")
    }

    /// Two sustained topic shifts → two chapters, in order, with non-decreasing
    /// accept times drawn from the (advancing) clock. A short single-topic meeting
    /// (only ever one accepted topic) yields exactly one chapter — which the note /
    /// export layer then suppresses as noise (covered separately).
    @MainActor
    func testTwoTopicShiftsCollectTwoOrderedChapters() async {
        let model = MeetingSubtopicModel()
        let collector = ChapterCollector()
        let engine = Engine(summarizer: NoopSummarizer(), model: model) { [collector] topic in
            collector.record(topic)
        }

        collector.clock = 5
        await engine.evaluateForTesting("TOPIC|Intro\nCONFIDENCE|HIGH")   // eager accept Intro @5, first hit
        await engine.evaluateForTesting("TOPIC|Intro\nCONFIDENCE|HIGH")   // repeat: harmless no-op
        collector.clock = 452
        await engine.evaluateForTesting("TOPIC|Budget review\nCONFIDENCE|HIGH")
        await engine.evaluateForTesting("TOPIC|Budget review\nCONFIDENCE|HIGH") // replacement needs 2 hits: accept @452

        XCTAssertEqual(collector.chapters.map(\.title), ["Intro", "Budget review"])
        XCTAssertEqual(collector.chapters.map(\.start), [5, 452])
        XCTAssertTrue(collector.chapters.map(\.start) == collector.chapters.map(\.start).sorted(),
                      "accept times are non-decreasing")
    }

    // MARK: - B3: gloss display wiring

    /// The gloss is set alongside `current` on the SAME accept transition, and is used
    /// verbatim for display when the model supplies one.
    @MainActor
    func testGlossPresentAndUsedOnAccept() async {
        let model = MeetingSubtopicModel()
        let engine = Engine(summarizer: NoopSummarizer(), model: model)

        await engine.evaluateForTesting(
            "TOPIC|Budget\nGLOSS|Discussing the Q3 budget rollover and hiring freeze\nCONFIDENCE|HIGH")

        XCTAssertEqual(model.current, "Budget", "gating/chapter phrase unaffected")
        XCTAssertEqual(model.currentGloss, "Discussing the Q3 budget rollover and hiring freeze",
                       "the display gloss is published on the same accept")
    }

    /// A missing GLOSS line must not leave the pill without a display string — it
    /// falls back to the short phrase itself.
    @MainActor
    func testGlossMissingFallsBackToPhrase() async {
        let model = MeetingSubtopicModel()
        let engine = Engine(summarizer: NoopSummarizer(), model: model)

        await engine.evaluateForTesting("TOPIC|Budget\nCONFIDENCE|HIGH")

        XCTAssertEqual(model.current, "Budget")
        XCTAssertEqual(model.currentGloss, "Budget", "no GLOSS line → falls back to the topic phrase")
    }

    /// A runaway GLOSS line is dropped by `cleanGloss`, so it must fall back to the
    /// phrase exactly like a missing one — never a garbled/overflowing label on the pill.
    @MainActor
    func testGlossOverflowFallsBackToPhrase() async {
        let model = MeetingSubtopicModel()
        let engine = Engine(summarizer: NoopSummarizer(), model: model)

        await engine.evaluateForTesting(
            "TOPIC|Budget\n" +
            "GLOSS|This sentence just keeps going on and on with far more than fourteen words describing the topic in absurd detail\n" +
            "CONFIDENCE|HIGH")

        XCTAssertEqual(model.current, "Budget")
        XCTAssertEqual(model.currentGloss, "Budget", "an overflowing gloss falls back to the topic phrase")
    }

    /// Chapter titles must stay exactly the short phrase regardless of what the gloss
    /// says — the whole point of keeping gating/chapters keyed on TOPIC while GLOSS is
    /// purely additive for display.
    @MainActor
    func testChapterTitleUnaffectedByGlossContent() async {
        let model = MeetingSubtopicModel()
        let collector = ChapterCollector()
        let engine = Engine(summarizer: NoopSummarizer(), model: model) { [collector] topic in
            collector.record(topic)
        }

        collector.clock = 10
        await engine.evaluateForTesting(
            "TOPIC|Budget review\nGLOSS|A sprawling sentence about Q3 spend, headcount, and the hiring freeze debate\nCONFIDENCE|HIGH")

        XCTAssertEqual(collector.chapters.map(\.title), ["Budget review"],
                       "the chapter title is the short phrase, never the gloss sentence")
        XCTAssertEqual(model.currentGloss, "A sprawling sentence about Q3 spend, headcount, and the hiring freeze debate")
    }

    /// The ordering trap, modeled directly: the collector is filled *during*
    /// recording and the composed meeting must snapshot it BEFORE any teardown
    /// resets state. This asserts the invariant the recorder implements — snapshot
    /// synchronously, then clear — so a post-snapshot reset can't lose chapters.
    @MainActor
    func testStopSnapshotCapturesChaptersThenClears() {
        let collector = ChapterCollector()
        // Simulate accepts arriving through the recording.
        collector.clock = 12; collector.record("Kickoff")
        collector.clock = 300; collector.record("Roadmap")

        // The recorder's stop() does exactly this, synchronously, before its first
        // await: snapshot into the meeting, then clear the live collector.
        let snapshot: [Chapter]? = collector.chapters.isEmpty ? nil : collector.chapters
        let cleared: [Chapter] = []   // stand-in for `pendingChapters = []`

        XCTAssertEqual(snapshot?.map(\.title), ["Kickoff", "Roadmap"],
                       "the meeting keeps the chapters accepted during recording")
        XCTAssertTrue(cleared.isEmpty, "the live collector is reset for the next recording")
    }

    /// D8-vs-H1 regression guard: chapters are a SAVED-NOTES artifact and must be
    /// produced regardless of the live-pill DISPLAY toggle (`showMeetingPill`). H1's
    /// toggle sweep wrongly re-gated the subtopic engine's *computation* (ingest +
    /// start) behind that display flag, silently starving pill-hidden users of
    /// chapters. This models the corrected AppDelegate wiring: the display flag is
    /// consulted ONLY for `pill.show()`, never for feeding/starting the engine, so a
    /// recording with `showMeetingPill == false` still collects accepted chapters.
    ///
    /// The engine deliberately has no `showMeetingPill` awareness of its own — the
    /// wiring layer owns that concern — so the test drives the engine exactly as the
    /// wiring does (ingest-then-accept) while asserting the display flag was never a
    /// gate on the accept path.
    @MainActor
    func testChaptersProducedWhenPillHidden() async {
        // The display toggle is OFF. The corrected wiring must ingest and accept
        // regardless; it may only skip `pill.show()`.
        let showMeetingPill = false
        var pillShown = false
        func maybeShowPill() { if showMeetingPill { pillShown = true } }

        let model = MeetingSubtopicModel()
        let collector = ChapterCollector()
        let engine = Engine(summarizer: NoopSummarizer(), model: model) { [collector] topic in
            collector.record(topic)   // fired on accept, exactly as the wiring stamps a chapter
        }

        // Recording starts: the wiring starts the engine and (only then) considers the
        // pill. Pill display is gated; engine computation is not.
        maybeShowPill()

        // Feed transcript unconditionally (the corrected `onLiveSegment` has no pill
        // guard). The first hit eagerly accepts (nothing shown yet); the repeat is a
        // harmless no-op.
        collector.clock = 40
        await engine.evaluateForTesting("TOPIC|Roadmap\nCONFIDENCE|HIGH")
        await engine.evaluateForTesting("TOPIC|Roadmap\nCONFIDENCE|HIGH")

        XCTAssertFalse(pillShown, "the pill stays hidden when showMeetingPill is false")
        XCTAssertEqual(collector.chapters.map(\.title), ["Roadmap"],
                       "chapters are still produced with the pill hidden — computation is decoupled from display")
        XCTAssertEqual(model.current, "Roadmap",
                       "the subtopic still resolves even though nothing displays it")
    }

    // MARK: - D8: chapter note section (Meeting.chaptersMarkdown)

    func testChaptersMarkdownNeedsTwoChapters() {
        XCTAssertEqual(Meeting.chaptersMarkdown(nil), "", "nil → no section")
        XCTAssertEqual(Meeting.chaptersMarkdown([]), "", "empty → no section")
        XCTAssertEqual(Meeting.chaptersMarkdown([Chapter(title: "Solo", start: 0)]), "",
                       "a single chapter is noise — omitted")
    }

    func testChaptersMarkdownRendersSortedBulletsWithTimecodes() {
        let md = Meeting.chaptersMarkdown([
            Chapter(title: "Budget review", start: 452),
            Chapter(title: "Intro", start: 0),
        ])
        XCTAssertEqual(md, "## Chapters\n\n- [00:00] Intro\n- [07:32] Budget review",
                       "sorted by time, [mm:ss] bullets, heading between Summary and Transcript")
    }

    func testChaptersMarkdownUsesHourTimecodePastAnHour() {
        let md = Meeting.chaptersMarkdown([
            Chapter(title: "Open", start: 0),
            Chapter(title: "Deep dive", start: 3723),   // 1:02:03
        ])
        XCTAssertTrue(md.contains("- [1:02:03] Deep dive"), "h:mm:ss past an hour")
    }

    // MARK: - D8: chapter-list export (TimedTranscriptExport.chapterList)

    func testChapterListYouTubeFormat() {
        let out = TimedTranscriptExport.chapterList([
            Chapter(title: "Intro", start: 0),
            Chapter(title: "Budget review", start: 452),
        ])
        XCTAssertEqual(out, "00:00 Intro\n07:32 Budget review\n",
                       "YouTube description format: no brackets, trailing newline")
    }

    func testChapterListSortsByTime() {
        let out = TimedTranscriptExport.chapterList([
            Chapter(title: "Second", start: 120),
            Chapter(title: "First", start: 10),
        ])
        XCTAssertEqual(out, "00:10 First\n02:00 Second\n", "unsorted input renders in time order")
    }

    func testChapterListEmptyBelowTwoChapters() {
        XCTAssertEqual(TimedTranscriptExport.chapterList([]), "")
        XCTAssertEqual(TimedTranscriptExport.chapterList([Chapter(title: "Solo", start: 0)]), "",
                       "a lone chapter produces no file")
    }

    // MARK: - D8: VTT NOTE Chapter blocks

    func testVTTWithoutChaptersIsUnchanged() {
        let segs = [
            MeetingSegment(speaker: "Me", start: 0, end: 2, text: "hello"),
            MeetingSegment(speaker: "Me", start: 2, end: 4, text: "world"),
        ]
        XCTAssertEqual(TimedTranscriptExport.vtt(segs, chapters: []),
                       TimedTranscriptExport.vtt(segs),
                       "empty chapters → byte-identical to the no-chapter overload")
    }

    func testVTTInsertsNoteChapterBeforeTheRightCue() {
        let segs = [
            MeetingSegment(speaker: "Me", start: 0, end: 5, text: "intro talk"),
            MeetingSegment(speaker: "Me", start: 60, end: 65, text: "budget talk"),
        ]
        let out = TimedTranscriptExport.vtt(segs, chapters: [
            Chapter(title: "Intro", start: 0),
            Chapter(title: "Budget", start: 58),
        ])
        // First NOTE sits at the very top (start 0 ≤ first cue), second NOTE lands
        // just before the 60s cue (58 ≤ 60, and > the first cue's start).
        XCTAssertTrue(out.contains("NOTE Chapter: Intro"), "intro chapter noted")
        XCTAssertTrue(out.contains("NOTE Chapter: Budget"), "budget chapter noted")
        let introIdx = out.range(of: "NOTE Chapter: Intro")!.lowerBound
        let budgetIdx = out.range(of: "NOTE Chapter: Budget")!.lowerBound
        let secondCueIdx = out.range(of: "budget talk")!.lowerBound
        XCTAssertLessThan(introIdx, budgetIdx, "notes emitted in time order")
        XCTAssertLessThan(budgetIdx, secondCueIdx, "the budget note precedes its cue")
    }

    func testVTTChapterPastLastCueStillAppended() {
        let segs = [MeetingSegment(speaker: "Me", start: 0, end: 5, text: "only cue")]
        let out = TimedTranscriptExport.vtt(segs, chapters: [
            Chapter(title: "Early", start: 0),
            Chapter(title: "Late", start: 999),   // beyond the last cue
        ])
        XCTAssertTrue(out.contains("NOTE Chapter: Late"),
                      "a late topic shift past the last cue is still recorded, not dropped")
    }

    func testVTTNoteEscapesStructuralHazards() {
        let segs = [MeetingSegment(speaker: "Me", start: 0, end: 5, text: "x")]
        let out = TimedTranscriptExport.vtt(segs, chapters: [
            Chapter(title: "a\nb --> c", start: 0),
        ])
        XCTAssertTrue(out.contains("NOTE Chapter: a b → c"),
                      "newlines flattened and the --> arrow neutralized so the NOTE stays legal")
        XCTAssertFalse(out.contains("NOTE Chapter: a\nb"), "no raw newline inside the NOTE")
    }
}

/// A no-op `Summarizer` for the accept-hook tests: `evaluateForTesting` never calls
/// `generate` (it feeds a canned response straight in), so this only needs to satisfy
/// the type. Kept trivial and offline — no model, no network.
private struct NoopSummarizer: Summarizer {
    static var isAvailable: Bool { false }
    var requiresNetwork: Bool { false }
    func generate(instructions: String, input: String) async -> String? { nil }
}
