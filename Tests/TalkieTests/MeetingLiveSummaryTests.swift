import XCTest
@testable import Talkie

/// W2: the summary built during the recording (live chunk extraction reused at Stop),
/// time-stamped notes, and the notes as first-class content of the final summary.
/// Everything runs against a fake model.
final class MeetingLiveSummaryTests: XCTestCase {
    private let de = SummaryLanguage(code: "de")

    // MARK: Fixtures

    private static let lines = [
        "Wir müssen das Budget für das zweite Quartal bis Freitag festlegen",
        "Ich schlage vor, dass Anna die Kalkulation für den Messestand übernimmt",
        "Gut, dann entscheiden wir uns für den kleineren Stand in Halle drei",
        "Offen bleibt noch, ob der Lieferant die Prospekte rechtzeitig druckt",
        "Thomas schickt bis Mittwoch die aktualisierte Terminplanung an alle",
        "Die Reisekosten liegen aktuell bei ungefähr viertausend Euro",
    ]

    /// `n` lane-labelled segments, alternating Me/Them, 30 s apart, each text distinct.
    private func segments(_ n: Int) -> [MeetingSegment] {
        (0..<n).map { i in
            MeetingSegment(speaker: i % 2 == 0 ? "Me" : "Them", start: Double(i) * 30, end: Double(i) * 30 + 25,
                           text: Self.lines[i % Self.lines.count] + ", Punkt \(i).")
        }
    }

    private func transcript(_ segs: [MeetingSegment]) -> String { MeetingTranscriptRenderer.render(segments: segs) }

    final class FakeModel: MeetingSummaryModel, @unchecked Sendable {
        private let lock = NSLock()
        var available = true
        var extractHandler: (String) throws -> ChunkNotes = { FakeModel.faithful($0) }
        var writeHandler: (String, String) throws -> String = { _, _ in
            "Das Budget für das zweite Quartal wird festgelegt. Thomas schickt die Terminplanung."
        }
        private(set) var extractPrompts: [String] = []
        var isAvailable: Bool { available }
        func extract(instructions: String, prompt: String) async throws -> ChunkNotes {
            lock.withLock { extractPrompts.append(prompt) }
            return try extractHandler(prompt)
        }
        func write(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
            try writeHandler(instructions, prompt)
        }
        func tokenCount(_ text: String) async -> Int? { nil }

        /// Cites every numbered line faithfully; an owner is the line's speaker label.
        static func faithful(_ prompt: String) -> ChunkNotes {
            var notes = ChunkNotes()
            for line in prompt.split(separator: "\n") {
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                      let n = Int(line[line.index(after: line.startIndex)..<close]) else { continue }
                let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                let speaker = rest.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                if rest.contains("entscheiden") { notes.decisions.append(.init(line: n, text: "Kleinerer Stand in Halle drei")) }
                if rest.contains("Thomas") {
                    notes.actionItems.append(.init(line: n, owner: speaker, task: "Terminplanung an alle schicken", due: "Mittwoch"))
                }
                if rest.contains("Budget") { notes.topics.append(.init(line: n, text: "Budget zweites Quartal")) }
            }
            return notes
        }
    }

    private func pipeline(_ model: FakeModel) -> MeetingSummaryPipeline { MeetingSummaryPipeline(model: model) }

    /// Run a live pass over the first `upTo` seconds of `segs` and return the cache.
    private func livePass(_ segs: [MeetingSegment], upTo: Double, notes: [MeetingNote] = [],
                          model: FakeModel = FakeModel()) async -> (LiveChunkCache, LiveSummarySnapshot?) {
        let engine = LiveSummaryEngine(pipeline: pipeline(model))
        let snap = await engine.pass(segments: segs, stableUntil: upTo, notes: notes, maxCalls: 100)
        return (await engine.results(), snap)
    }

    // MARK: Chunk-result reuse

    func testStopReusesLiveChunksAndExtractsOnlyTheTail() async {
        let segs = segments(60)
        let (cache, snap) = await livePass(segs, upTo: 1200) // first 40 segments are stable
        XCTAssertFalse(cache.isEmpty)
        XCTAssertNotNil(snap)
        XCTAssertFalse(snap!.decisions.isEmpty, "the So far view gets the provisional merge")

        let stopModel = FakeModel()
        let r = await pipeline(stopModel).run(transcript: transcript(segs), segments: segs,
                                             live: .init(cache: cache, laneSegments: segs))
        XCTAssertTrue(r.usedLive)
        XCTAssertEqual(r.reusedChunks, cache.entries.count)
        XCTAssertEqual(stopModel.extractPrompts.count, r.chunks - r.reusedChunks, "only the tail is extracted at Stop")

        let batchModel = FakeModel()
        let batch = await pipeline(batchModel).run(transcript: transcript(segs), segments: segs)
        XCTAssertLessThan(stopModel.extractPrompts.count, batchModel.extractPrompts.count)
        XCTAssertEqual(r.chunks, batch.chunks, "the live cut matches the batch cut")
        XCTAssertEqual(r.merged, batch.merged, "same items as the batch path")
        XCTAssertEqual(r.markdown, batch.markdown)
    }

    func testLivePassNeverExtractsTheOpenLastChunk() async {
        let segs = segments(40)
        let model = FakeModel()
        let (cache, _) = await livePass(segs, upTo: 1200, model: model)
        let units = SummaryUnits.dropEchoes(SummaryUnits.build(transcript: "", segments: segs), language: de)
        let chunks = SummaryChunker.chunk(units, budgetChars: 3000, speakers: true)
        XCTAssertEqual(cache.entries.count, chunks.count - 1)
        XCTAssertEqual(model.extractPrompts.count, chunks.count - 1)
    }

    func testLivePassWaitsForALongFormMeeting() async {
        let (cache, snap) = await livePass(segments(20), upTo: 10_000)
        XCTAssertTrue(cache.isEmpty, "under the long-form threshold the final note is prose: nothing to extract live")
        XCTAssertNil(snap)
    }

    func testAPassRepeatsNoCallsForUnchangedText() async {
        let segs = segments(60)
        let model = FakeModel()
        let engine = LiveSummaryEngine(pipeline: pipeline(model))
        _ = await engine.pass(segments: segs, stableUntil: 1200, notes: [], maxCalls: 100)
        let first = model.extractPrompts.count
        _ = await engine.pass(segments: segs, stableUntil: 1200, notes: [], maxCalls: 100)
        XCTAssertEqual(model.extractPrompts.count, first)
    }

    func testAStoppedEngineMakesNoCalls() async {
        let model = FakeModel()
        let engine = LiveSummaryEngine(pipeline: pipeline(model))
        await engine.stop()
        let snap = await engine.pass(segments: segments(60), stableUntil: 10_000, notes: [], maxCalls: 100)
        XCTAssertNil(snap)
        XCTAssertTrue(model.extractPrompts.isEmpty)
    }

    func testAFailingChunkIsLeftForStopAfterTwoTries() async {
        let model = FakeModel()
        model.extractHandler = { _ in throw SummaryModelError.refused }
        model.writeHandler = { _, _ in "I'm sorry, I cannot help with that." }
        let engine = LiveSummaryEngine(pipeline: pipeline(model))
        for _ in 0..<4 { _ = await engine.pass(segments: segments(60), stableUntil: 1200, notes: [], maxCalls: 1) }
        XCTAssertEqual(model.extractPrompts.count, 2 + 2, "two tries for the first chunk, then the next one")
        let cache = await engine.results()
        XCTAssertTrue(cache.isEmpty)
    }

    // MARK: Changed-chunk re-extraction

    func testAChunkWhoseTextChangedIsReExtracted() async {
        var segs = segments(60)
        let (cache, _) = await livePass(segs, upTo: 1200)
        segs[10].text += " Nachträglich geändert."
        let stopModel = FakeModel()
        let r = await pipeline(stopModel).run(transcript: transcript(segs), segments: segs,
                                             live: .init(cache: cache, laneSegments: segs))
        XCTAssertEqual(r.reusedChunks, cache.entries.count - 1)
        XCTAssertEqual(stopModel.extractPrompts.filter { $0.contains("Nachträglich geändert") }.count, 1)
        XCTAssertEqual(stopModel.extractPrompts.count, r.chunks - r.reusedChunks)
    }

    func testNoMatchingLiveChunkFallsBackToTheBatchPath() async {
        let segs = segments(60)
        let (cache, _) = await livePass(segs, upTo: 1200)
        let other = segs.map { s -> MeetingSegment in var s = s; s.text = "Anders: " + s.text; return s }
        let r = await pipeline(FakeModel()).run(transcript: transcript(other), segments: other,
                                               live: .init(cache: cache, laneSegments: other))
        XCTAssertFalse(r.usedLive)
        XCTAssertEqual(r.reusedChunks, 0)
        XCTAssertNotNil(r.markdown)
    }

    func testPlannerReusesTheLongestMatchAndChunksTheGapsGreedily() {
        let units = SummaryUnits.build(transcript: "", segments: segments(24))
        let entry = LiveChunkCache.Entry(units: Array(units[6..<12]), pieces: [], language: "de", speakers: true, hint: "")
        let plan = SummaryChunkPlanner.plan(units, cache: [entry], budgetChars: 3000, speakers: true)
        XCTAssertEqual(plan.flatMap(\.units).map(\.index), units.map(\.index), "every unit once, in order")
        XCTAssertEqual(plan.filter { $0.cached != nil }.map { $0.units.map(\.index) }, [Array(6..<12)])
    }

    func testRemapMovesCitationsOntoTheFinalLines() {
        let live = SummaryUnits.build(transcript: "", segments: segments(6))
        var final = live
        for i in final.indices { final[i].index += 100 }
        let notes = ChunkNotes(decisions: [.init(line: 2, text: "x")], actionItems: [.init(line: 9, owner: "", task: "y", due: "")])
        let entry = LiveChunkCache.Entry(units: live, pieces: [(live, notes)], language: "de", speakers: true, hint: "")
        let moved = SummaryChunkPlanner.remap(entry, onto: final)
        XCTAssertEqual(moved[0].notes.decisions.first?.line, 102)
        XCTAssertEqual(moved[0].notes.actionItems.first?.line, -1, "a citation outside the chunk stays invalid")
        XCTAssertEqual(moved[0].chunk.map(\.index), final.map(\.index))
    }

    // MARK: Time-range speaker relabel

    func testSpeakerTimeMapTakesTheMajorityPersonWithinTheLane() {
        let diarized = [
            MeetingSegment(speaker: "Me", start: 0, end: 30, text: "a"),
            MeetingSegment(speaker: "Speaker 2", start: 0, end: 10, text: "b", lane: "Them"),
            MeetingSegment(speaker: "Speaker 3", start: 10, end: 30, text: "c", lane: "Them"),
        ]
        let map = SpeakerTimeMap(segments: diarized)
        XCTAssertEqual(map.label(lane: "Them", start: 0, end: 30), "Speaker 3", "20 of 30 s")
        XCTAssertNil(map.label(lane: "Them", start: 5, end: 15), "an even split has no honest single person")
        XCTAssertEqual(map.label(lane: "Me", start: 3, end: 4), "Me")
        XCTAssertEqual(map.label(lane: "Them", start: 12, end: 12), "Speaker 3", "a zero-length span takes its segment")
        XCTAssertTrue(SpeakerTimeMap.isDiarized(diarized))
        XCTAssertFalse(SpeakerTimeMap.isDiarized(segments(4)))
    }

    func testReusedChunksGetTheDiarizedSpeakersByTimeRange() async {
        let segs = segments(60)
        let (cache, _) = await livePass(segs, upTo: 1200)
        // Diarization split nothing here but named the far end "Speaker 2".
        let diarized = segs.map { s -> MeetingSegment in
            guard s.speaker == "Them" else { return s }
            var d = s; d.speaker = "Speaker 2"; d.lane = "Them"; return d
        }
        let r = await pipeline(FakeModel()).run(transcript: MeetingTranscriptRenderer.render(segments: diarized),
                                               segments: diarized, live: .init(cache: cache, laneSegments: segs))
        XCTAssertTrue(r.usedLive)
        XCTAssertFalse(r.merged.actionItems.isEmpty)
        // "Thomas" lines are at i % 6 == 4 → Me lanes; check all owners are people, never a lane name.
        XCTAssertFalse(r.merged.actionItems.contains { $0.owner == "Them" })
        XCTAssertTrue(r.markdown?.contains("Them:") == false)
    }

    func testLaneOwnerIsTranslatedToThePersonOnTheCitedLine() {
        let units = [
            SummaryUnit(index: 0, segment: 0, speaker: "Me", start: 0, end: 10, text: "a"),
            SummaryUnit(index: 1, segment: 1, speaker: "Them", start: 10, end: 20, text: "b"),
        ]
        let notes = ChunkNotes(actionItems: [.init(line: 1, owner: "Them", task: "t", due: ""),
                                             .init(line: 0, owner: "Them", task: "u", due: ""),
                                             .init(line: 0, owner: "Anna", task: "v", due: "")])
        let map = SpeakerTimeMap(segments: [
            MeetingSegment(speaker: "Me", start: 0, end: 10, text: "a"),
            MeetingSegment(speaker: "Speaker 2", start: 10, end: 20, text: "b", lane: "Them"),
        ])
        let out = map.apply((units, notes))
        XCTAssertEqual(out.chunk.map(\.speaker), ["Me", "Speaker 2"])
        XCTAssertEqual(out.notes.actionItems.map(\.owner), ["Speaker 2", "Speaker 2", "Anna"])
    }

    // MARK: Legacy notes decoding

    private func meetingJSON(notes: String?) -> Data {
        var json = #"{"title":"t","startUnix":0,"durationSec":1,"transcript":"x","summary":"s","fileName":"f.md""#
        if let notes { json += #","notes":"# + notes }
        return Data((json + "}").utf8)
    }

    func testMeetingWithoutNotesDecodes() throws {
        XCTAssertNil(try JSONDecoder().decode(Meeting.self, from: meetingJSON(notes: nil)).notes)
    }

    func testMeetingWithAPlainNotesStringDecodesToUntimedItems() throws {
        let m = try JSONDecoder().decode(Meeting.self, from: meetingJSON(notes: #""- erste Zeile\n\nzweite  Zeile""#))
        XCTAssertEqual(m.notes?.map(\.text), ["erste Zeile", "zweite Zeile"])
        XCTAssertEqual(m.notes?.compactMap(\.secondsIntoMeeting), [])
    }

    func testMeetingNotesRoundTrip() throws {
        var m = try JSONDecoder().decode(Meeting.self, from: meetingJSON(notes: nil))
        m.notes = [MeetingNote(text: "a", secondsIntoMeeting: 12), MeetingNote(text: "", secondsIntoMeeting: 40)]
        let back = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.notes, m.notes)
    }

    func testPartialWithoutNoteItemsRecoversThePlainNotes() throws {
        let old = #"{"version":1,"startedAt":1,"farEnd":false,"notes":"eins\nzwei","transcript":""}"#
        let p = try XCTUnwrap(MeetingRecorder.decodePartial(Data(old.utf8)))
        XCTAssertNil(p.noteItems)
        XCTAssertEqual(p.recoveredNotes.map(\.text), ["eins", "zwei"])
        let new = MeetingRecorder.RecordingPartial(startedAt: 1, farEnd: false, notes: "eins", transcript: "",
                                                   noteItems: [MeetingNote(text: "eins", secondsIntoMeeting: 5)])
        let decoded = try XCTUnwrap(MeetingRecorder.decodePartial(XCTUnwrap(MeetingRecorder.encodePartial(new))))
        XCTAssertEqual(decoded.recoveredNotes.first?.secondsIntoMeeting, 5)
    }

    // MARK: Time stamps while typing

    func testANewLineGetsTheTimeItWasStartedAndKeepsItWhileEdited() {
        var lines = MeetingNoteStamper.restamp([], text: "B", now: 10)
        XCTAssertEqual(lines.map(\.seconds), [10])
        lines = MeetingNoteStamper.restamp(lines, text: "Bu", now: 11)
        lines = MeetingNoteStamper.restamp(lines, text: "Budget\n", now: 14)
        XCTAssertEqual(lines.map(\.seconds), [10, nil], "an empty new line has no time yet")
        lines = MeetingNoteStamper.restamp(lines, text: "Budget\nA", now: 30)
        lines = MeetingNoteStamper.restamp(lines, text: "Budget\nAnna rechnet", now: 35)
        XCTAssertEqual(lines.map(\.seconds), [10, 30])
        lines = MeetingNoteStamper.restamp(lines, text: "Vorab\nBudget!\nAnna rechnet", now: 50)
        XCTAssertEqual(lines.map(\.seconds), [50, 10, 30], "a line inserted above doesn't move the others' times")
        let notes = MeetingNoteStamper.notes(from: lines)
        XCTAssertEqual(notes.map(\.text), ["Vorab", "Budget!", "Anna rechnet"])
        XCTAssertEqual(Set(notes.map(\.id)).count, 3)
    }

    func testMarkThisMomentAddsAStampedLineThatCanGetTextLater() {
        var text = MeetingNoteStamper.appendingMarker(to: "Budget", at: 754)
        XCTAssertEqual(text, "Budget\n[12:34] ")
        var lines = MeetingNoteStamper.restamp([], text: text, now: 800)
        var notes = MeetingNoteStamper.notes(from: lines)
        XCTAssertEqual(notes.last?.secondsIntoMeeting, 754, "the stamp wins over the typing time")
        XCTAssertTrue(notes.last?.isMarker == true)
        text += "Preis klären"
        lines = MeetingNoteStamper.restamp(lines, text: text, now: 900)
        notes = MeetingNoteStamper.notes(from: lines)
        XCTAssertEqual(notes.last, MeetingNote(id: notes.last!.id, text: "Preis klären", secondsIntoMeeting: 754))
        XCTAssertEqual(MeetingNoteStamper.parseStamp("[1:02:03] x").seconds, 3723)
        XCTAssertNil(MeetingNoteStamper.parseStamp("[a:b] x").seconds)
    }

    // MARK: Note-hint placement

    func testNoteHintGoesToTheChunkAroundTheNotesMoment() {
        let units = SummaryUnits.build(transcript: "", segments: segments(24))
        let chunks = SummaryChunker.chunk(units, budgetChars: 3000, speakers: true) // 6 units = 180 s each
        let at200 = MeetingNote(text: "a", secondsIntoMeeting: 200)
        let atStart = MeetingNote(text: "b", secondsIntoMeeting: 3)
        let afterEnd = MeetingNote(text: "c", secondsIntoMeeting: 9_000)
        let inGap = MeetingNote(text: "d", secondsIntoMeeting: 188) // 178 s: between 175 (end) and 180
        let untimed = MeetingNote(text: "e", secondsIntoMeeting: nil)
        let hints = NoteHints.assign([at200, atStart, afterEnd, inGap, untimed], chunks: chunks)
        XCTAssertEqual(hints[1]?.map(\.text), ["a"], "200 s minus the writing lag is in the second chunk")
        XCTAssertEqual(hints[0]?.map(\.text), ["b", "d"], "before everything → first; a gap → the chunk before it")
        XCTAssertEqual(hints[chunks.count - 1]?.map(\.text), ["c"])
        XCTAssertFalse(hints.values.joined().contains { $0.text == "e" }, "an untimed note has no place")
    }

    func testTheNoteHintReachesOnlyItsChunkAndItsItemsAreListedFirstAndLinked() async {
        let segs = segments(60)
        // A decision sits at segment 32 (i % 6 == 2) → 960 s. The note is written at 975 s.
        let note = MeetingNote(text: "Stand Halle drei!", secondsIntoMeeting: 975)
        let model = FakeModel()
        let r = await pipeline(model).run(transcript: transcript(segs), segments: segs, notes: [note])
        let hinted = model.extractPrompts.filter { $0.contains("Stand Halle drei!") }
        XCTAssertEqual(hinted.count, 1)
        XCTAssertTrue(hinted[0].contains("Punkt 32."))
        let md = try! XCTUnwrap(r.markdown)
        XCTAssertEqual(r.merged.decisions.filter { $0.noteID == note.id }.count, 1)
        let decisions = md.components(separatedBy: "**Entscheidungen:**\n").last!.components(separatedBy: "\n\n").first!
        XCTAssertTrue(decisions.hasPrefix("- Kleinerer Stand in Halle drei (Notiz 16:15)"), decisions)
    }

    func testANoteAddedAfterTheLivePassReExtractsItsChunkAtStop() async {
        let segs = segments(60)
        let (cache, _) = await livePass(segs, upTo: 1200)
        let stopModel = FakeModel()
        let note = MeetingNote(text: "Wichtig", secondsIntoMeeting: 400)
        let r = await pipeline(stopModel).run(transcript: transcript(segs), segments: segs, notes: [note],
                                             live: .init(cache: cache, laneSegments: segs))
        XCTAssertEqual(r.reusedChunks, cache.entries.count - 1, "the hinted chunk's prompt changed")
        XCTAssertEqual(stopModel.extractPrompts.filter { $0.contains("Wichtig") }.count, 1)
    }

    // MARK: Notes are never dropped

    private let unrelated = [
        MeetingNote(text: "Mallorca Urlaub buchen", secondsIntoMeeting: 61),
        MeetingNote(text: "", secondsIntoMeeting: 1500),
        MeetingNote(text: "  - ohne Zeit  ", secondsIntoMeeting: nil),
    ]

    private func assertNotesKept(_ md: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let md else { return XCTFail("no markdown", file: file, line: line) }
        XCTAssertTrue(md.contains("**Deine Notizen:**\n- [01:01] Mallorca Urlaub buchen\n- [25:00] Markierter Moment\n- ohne Zeit"),
                      md, file: file, line: line)
    }

    func testNotesSurviveALongMeetingEvenWhenUnrelatedToTheTranscript() async {
        let segs = segments(60)
        assertNotesKept(await pipeline(FakeModel()).run(transcript: transcript(segs), segments: segs, notes: unrelated).markdown)
    }

    func testNotesSurviveEveryModelFailure() async {
        let segs = segments(60)
        let model = FakeModel()
        model.extractHandler = { _ in throw SummaryModelError.refused }
        model.writeHandler = { _, _ in "I'm sorry, but I cannot help with that request." }
        let r = await pipeline(model).run(transcript: transcript(segs), segments: segs, notes: unrelated)
        assertNotesKept(r.markdown)
    }

    func testNotesSurviveAnUnavailableModelAndAShortMeeting() async {
        let segs = segments(60)
        let off = FakeModel()
        off.available = false
        assertNotesKept(await pipeline(off).run(transcript: transcript(segs), segments: segs, notes: unrelated).markdown)
        let short = segments(3)
        let r = await pipeline(FakeModel()).run(transcript: transcript(short), segments: short, notes: unrelated)
        assertNotesKept(r.markdown)
        XCTAssertTrue(r.markdown!.hasPrefix("Das Budget"), "the short prose leads, the notes follow")
    }

    func testNotesSectionFollowsTheOverviewAndKeepsTimeOrder() {
        let notes = [MeetingNote(text: "später", secondsIntoMeeting: 90), MeetingNote(text: "früher", secondsIntoMeeting: 30)]
        let md = SummaryRenderer.render(overview: "Kurz gesagt.", notes: MergedNotes(), language: de, words: 900,
                                        userNotes: notes)
        XCTAssertEqual(md, "Kurz gesagt.\n\n**Deine Notizen:**\n- [00:30] früher\n- [01:30] später")
    }
}

/// Regenerate is owned by the recorder: queued, de-duplicated, and written to the
/// store without any view.
@MainActor
final class MeetingRegenerateQueueTests: XCTestCase {
    private func makeRecorder() -> (MeetingRecorder, MeetingStore, UUID) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("regen-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let id = UUID()
        store.add(Meeting(id: id, title: "t", startUnix: 0, durationSec: 60, transcript: "Hallo zusammen",
                          summary: "alt", fileName: "regen-\(id).md",
                          notes: [MeetingNote(text: "meine Notiz", secondsIntoMeeting: 5)]))
        return (MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store), store, id)
    }

    func testRegenerateIsQueuedDeduplicatedAndWrittenWithoutAView() async {
        let (recorder, store, id) = makeRecorder()
        var calls = 0
        var seenNotes: [MeetingNote] = []
        recorder.regenerationWriter = { _, _, notes in
            calls += 1
            seenNotes = notes
            try? await Task.sleep(for: .milliseconds(50))
            return "neu"
        }
        XCTAssertTrue(recorder.regenerateSummary(id: id))
        XCTAssertTrue(recorder.summarizingMeetingIDs.contains(id), "shows Writing the summary… at once")
        XCTAssertFalse(recorder.regenerateSummary(id: id), "a second start for the same meeting is refused")
        await recorder.waitForSummaryQueue()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(seenNotes.map(\.text), ["meine Notiz"], "stored notes go into the new summary")
        XCTAssertEqual(store.meetings.first { $0.id == id }?.summary, "neu")
        XCTAssertFalse(recorder.summarizingMeetingIDs.contains(id))
        XCTAssertTrue(recorder.regenerateSummary(id: id), "can run again once finished")
        await recorder.waitForSummaryQueue()
        XCTAssertEqual(calls, 2)
    }

    func testAFailedRegenerateKeepsTheOldSummaryAndADeletedMeetingIsLeftAlone() async {
        let (recorder, store, id) = makeRecorder()
        recorder.regenerationWriter = { _, _, _ in nil }
        recorder.regenerateSummary(id: id)
        await recorder.waitForSummaryQueue()
        XCTAssertEqual(store.meetings.first { $0.id == id }?.summary, "alt")
        recorder.regenerationWriter = { _, _, _ in "neu" }
        recorder.regenerateSummary(id: id)
        store.delete(store.meetings.first { $0.id == id }!)
        await recorder.waitForSummaryQueue()
        XCTAssertNil(store.meetings.first { $0.id == id })
        XCTAssertFalse(recorder.regenerateSummary(id: UUID()), "unknown meeting")
    }
}
