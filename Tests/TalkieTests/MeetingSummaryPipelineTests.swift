import XCTest
@testable import Talkie

/// W1: the meeting summary pipeline's pure parts (units, chunking, echo de-dup,
/// grounding, merge, language, rendering) and its orchestration with a fake model
/// (short-meeting rule, failure honesty, partial results, overflow splitting).
final class MeetingSummaryPipelineTests: XCTestCase {
    private let de = SummaryLanguage(code: "de")
    private let en = SummaryLanguage(code: "en")

    // MARK: Fixtures

    private static let germanLines = [
        "Wir müssen das Budget für das zweite Quartal bis Freitag festlegen.",
        "Ich schlage vor, dass Anna die Kalkulation für den Messestand übernimmt.",
        "Gut, dann entscheiden wir uns für den kleineren Stand in Halle drei.",
        "Offen bleibt noch, ob der Lieferant die Prospekte rechtzeitig druckt.",
        "Thomas schickt bis Mittwoch die aktualisierte Terminplanung an alle.",
        "Die Reisekosten liegen aktuell bei ungefähr viertausend Euro.",
    ]

    private func segments(_ n: Int, speakers: [String] = ["Speaker 1", "Speaker 2"]) -> [MeetingSegment] {
        (0..<n).map { i in
            MeetingSegment(speaker: speakers[i % speakers.count], start: Double(i) * 30,
                           end: Double(i) * 30 + 25, text: Self.germanLines[i % Self.germanLines.count])
        }
    }

    private func transcript(_ segs: [MeetingSegment]) -> String {
        segs.map { "[\(MeetingTranscriptRenderer.timecode($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Scriptable fake: `extract` answers per call from a closure that sees the prompt.
    final class FakeModel: MeetingSummaryModel, @unchecked Sendable {
        private let lock = NSLock()
        var available = true
        var extractHandler: (String) throws -> ChunkNotes = { _ in ChunkNotes() }
        var writeHandler: (String, String) throws -> String = { _, _ in "" }
        var tokenHandler: (String) -> Int? = { _ in nil }
        private(set) var extractPrompts: [String] = []
        private(set) var writeCalls = 0

        var isAvailable: Bool { available }
        func extract(instructions: String, prompt: String) async throws -> ChunkNotes {
            lock.withLock { extractPrompts.append(prompt) }
            return try extractHandler(prompt)
        }
        func write(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
            lock.withLock { writeCalls += 1 }
            return try writeHandler(instructions, prompt)
        }
        func tokenCount(_ text: String) async -> Int? { tokenHandler(text) }
    }

    /// Line numbers present in a numbered prompt.
    private static func lineNumbers(_ prompt: String) -> [Int] {
        prompt.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            return Int(line[line.index(after: line.startIndex)..<close])
        }
    }

    /// A fake extraction that cites each line of the prompt faithfully.
    private static func faithfulNotes(_ prompt: String) -> ChunkNotes {
        var notes = ChunkNotes()
        for line in prompt.split(separator: "\n") {
            guard let n = lineNumbers(String(line)).first else { continue }
            let text = String(line.split(separator: ":", maxSplits: 1).last ?? "")
            if text.contains("entscheiden") { notes.decisions.append(.init(line: n, text: "Kleinerer Stand in Halle drei")) }
            if text.contains("Thomas") {
                notes.actionItems.append(.init(line: n, owner: "Thomas", task: "Terminplanung an alle schicken", due: "Mittwoch"))
            }
            if text.contains("Lieferant") { notes.openQuestions.append(.init(line: n, text: "Druckt der Lieferant die Prospekte rechtzeitig?")) }
            if text.contains("Budget") { notes.topics.append(.init(line: n, text: "Budget zweites Quartal")) }
        }
        return notes
    }

    // MARK: Units + chunking

    func testUnitsFromSegmentsKeepSpeakerTimeAndSegmentIndex() {
        let segs = segments(4)
        let units = SummaryUnits.build(transcript: transcript(segs), segments: segs)
        XCTAssertEqual(units.count, 4)
        XCTAssertEqual(units.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(units[1].speaker, "Speaker 2")
        XCTAssertEqual(units[1].start, 30)
        XCTAssertEqual(units[3].segment, 3)
    }

    func testLongSegmentIsSplitIntoPiecesOfTheSameSegment() {
        let long = Array(repeating: Self.germanLines[0], count: 40).joined(separator: " ")
        let segs = [MeetingSegment(speaker: "Me", start: 0, end: 300, text: long)]
        let units = SummaryUnits.build(transcript: long, segments: segs)
        XCTAssertGreaterThan(units.count, 1)
        XCTAssertTrue(units.allSatisfy { $0.segment == 0 && $0.text.count <= SummaryUnits.maxUnitChars })
        XCTAssertEqual(units.map(\.text).joined(separator: " ").split(separator: " ").count,
                       long.split(separator: " ").count, "no words lost when splitting")
    }

    func testUnitsFromRenderedTranscriptWithoutSegments() {
        let text = "[01:05] Speaker 1: Hallo zusammen.\n[1:02:03] Them: Guten Morgen.\nNur Prosa ohne Label."
        let units = SummaryUnits.build(transcript: text, segments: nil)
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[0].speaker, "Speaker 1")
        XCTAssertEqual(units[0].start, 65)
        XCTAssertEqual(units[1].start, 3723)
        XCTAssertNil(units[2].speaker)
        XCTAssertNil(units[0].segment)
    }

    func testChunkerCoversEveryUnitInOrderWithinBudget() {
        let segs = segments(120)
        let units = SummaryUnits.build(transcript: transcript(segs), segments: segs)
        let chunks = SummaryChunker.chunk(units, budgetChars: 800, speakers: true)
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertEqual(chunks.flatMap { $0 }.map(\.index), units.map(\.index), "every unit once, in order")
        for c in chunks { XCTAssertLessThanOrEqual(SummaryChunker.render(c, speakers: true).count, 800) }
    }

    func testChunkPromptCarriesLineNumbersAndSpeakersOnlyWhenSeveral() {
        let multi = SummaryUnits.build(transcript: "", segments: segments(2))
        XCTAssertTrue(SummaryUnits.showsSpeakers(multi))
        XCTAssertTrue(SummaryChunker.render(multi, speakers: true).hasPrefix("[0] Speaker 1: "))
        let solo = SummaryUnits.build(transcript: "", segments: segments(2, speakers: ["Me"]))
        XCTAssertFalse(SummaryUnits.showsSpeakers(solo))
        XCTAssertTrue(SummaryChunker.render(solo, speakers: false).hasPrefix("[0] Wir"))
    }

    func testEchoOfTheOtherLaneIsDropped() {
        let original = "Thomas schickt bis Mittwoch die aktualisierte Terminplanung an alle Teilnehmer."
        let echo = "Thomas schickt bis Mittwoch die Terminplanung an alle."
        let segs = [
            MeetingSegment(speaker: "Them", start: 10, end: 20, text: original),
            MeetingSegment(speaker: "Me", start: 11, end: 19, text: echo),
            MeetingSegment(speaker: "Me", start: 40, end: 50, text: "Das Budget legen wir am Freitag fest."),
        ]
        let units = SummaryUnits.dropEchoes(SummaryUnits.build(transcript: "", segments: segs), language: de)
        XCTAssertEqual(units.map(\.text), [original, segs[2].text])
    }

    func testSameWordsFromTheSameSpeakerOrFarApartAreNotEchoes() {
        let line = "Thomas schickt bis Mittwoch die Terminplanung an alle."
        let segs = [
            MeetingSegment(speaker: "Me", start: 0, end: 5, text: line),
            MeetingSegment(speaker: "Me", start: 20, end: 23, text: line),
            MeetingSegment(speaker: "Them", start: 600, end: 605, text: line),
        ]
        XCTAssertEqual(SummaryUnits.dropEchoes(SummaryUnits.build(transcript: "", segments: segs), language: de).count, 3)
    }

    // MARK: Grounding

    func testGroundingNeedsTheCitedLineInThisChunkAndSharedWords() {
        let chunk = SummaryUnits.build(transcript: "", segments: segments(6))
        // Faithful, cites the right line.
        XCTAssertTrue(Grounding.isGrounded("Terminplanung bis Mittwoch an alle", line: 4, in: chunk, language: de))
        // One line off still counts (neighbour).
        XCTAssertTrue(Grounding.isGrounded("Terminplanung bis Mittwoch an alle", line: 3, in: chunk, language: de))
        // Cites a line that does not exist in this chunk.
        XCTAssertFalse(Grounding.isGrounded("Terminplanung bis Mittwoch", line: 99, in: chunk, language: de))
        // Invented: shares nothing with the cited line.
        XCTAssertFalse(Grounding.isGrounded("Marketingkampagne für Instagram starten", line: 4, in: chunk, language: de))
        // An English translation shares no content words with the German line.
        XCTAssertFalse(Grounding.isGrounded("Send the updated schedule to everyone", line: 4, in: chunk, language: de))
        // No content words at all.
        XCTAssertFalse(Grounding.isGrounded("Ja.", line: 4, in: chunk, language: de))
    }

    func testOwnerIsKeptOnlyWhenSaidElseSpeakerLabel() {
        let chunk = SummaryUnits.build(transcript: "", segments: segments(6))
        XCTAssertEqual(Grounding.resolveOwner("Thomas", line: 4, in: chunk, speakers: true), "Thomas")
        XCTAssertEqual(Grounding.resolveOwner("Speaker 2", line: 4, in: chunk, speakers: true), "Speaker 2")
        // Invented name → the cited line's speaker.
        XCTAssertEqual(Grounding.resolveOwner("Michael Schulz", line: 4, in: chunk, speakers: true), "Speaker 1")
        XCTAssertEqual(Grounding.resolveOwner("unbekannt", line: 1, in: chunk, speakers: true), "Speaker 2")
        // Single-speaker meeting: an invented owner is dropped, not replaced.
        XCTAssertNil(Grounding.resolveOwner("Michael Schulz", line: 4, in: chunk, speakers: false))
    }

    func testFillerItemsAreRecognised() {
        for f in ["No decisions were made.", "None", "Keine Entscheidungen getroffen", "nicht erwähnt", "Keine Aufgaben"] {
            XCTAssertTrue(Grounding.isFiller(f), f)
        }
        XCTAssertFalse(Grounding.isFiller("Kleinerer Stand in Halle drei"))
    }

    // MARK: Merge

    func testMergeDeduplicatesAcrossChunksAndFillsMissingOwner() {
        let units = SummaryUnits.build(transcript: "", segments: segments(12))
        let a = Array(units[0..<6]), b = Array(units[6..<12])
        var na = ChunkNotes()
        na.actionItems = [.init(line: 4, owner: "", task: "Terminplanung an alle schicken", due: "")]
        na.decisions = [.init(line: 2, text: "Kleinerer Stand in Halle drei")]
        var nb = ChunkNotes()
        nb.actionItems = [.init(line: 10, owner: "Thomas", task: "Aktualisierte Terminplanung an alle schicken", due: "Mittwoch")]
        nb.decisions = [.init(line: 8, text: "Entscheidung: kleinerer Stand in Halle drei"),
                        .init(line: 8, text: "Keine weiteren Entscheidungen")]
        let merged = SummaryMerger.merge([(a, na), (b, nb)], language: de, speakers: true)
        XCTAssertEqual(merged.decisions.count, 1, "the repeat in chunk 2 and the filler are dropped")
        XCTAssertEqual(merged.decisions[0].unit, 2, "first mention wins")
        XCTAssertEqual(merged.actionItems.count, 1)
        XCTAssertEqual(merged.actionItems[0].owner, "Speaker 1",
                       "no name said in chunk 1 → the speaker label, not the later duplicate's name")
        XCTAssertEqual(merged.actionItems[0].due, "Mittwoch", "a later duplicate fills the missing due date")
    }

    func testADecisionIsNotRepeatedAsActionOrQuestion() {
        let units = SummaryUnits.build(transcript: "", segments: segments(6))
        var n = ChunkNotes()
        n.decisions = [.init(line: 2, text: "Kleinerer Stand in Halle drei")]
        n.actionItems = [.init(line: 2, owner: "", task: "Kleineren Stand in Halle drei nehmen", due: "")]
        n.openQuestions = [.init(line: 2, text: "Stand in Halle drei kleiner?"),
                           .init(line: 3, text: "Druckt der Lieferant die Prospekte rechtzeitig?")]
        let merged = SummaryMerger.merge([(units, n)], language: de, speakers: true)
        XCTAssertEqual(merged.decisions.count, 1)
        XCTAssertTrue(merged.actionItems.isEmpty)
        XCTAssertEqual(merged.openQuestions.map(\.unit), [3])
    }

    func testOverviewKeepsOnlySentencesTheNotesSupport() {
        let notes = "- Budget zweites Quartal\n- Kleinerer Stand in Halle drei"
        let out = SummaryFailure.groundedSentences(
            "Das Budget für das zweite Quartal steht. Der Vorstand plant eine Fusion mit Siemens. Gewählt wurde der kleinere Stand in Halle drei.",
            language: de, source: notes)
        XCTAssertEqual(out, "Das Budget für das zweite Quartal steht. Gewählt wurde der kleinere Stand in Halle drei.")
        XCTAssertNil(SummaryFailure.groundedSentences("Völlig andere Geschichte über Urlaub.", language: de, source: notes))
    }

    func testCopiedConversationIsNotANote() {
        XCTAssertFalse(SummaryItemFilter.isUsable("Ja, ich habe Erfahrung damit.", kind: .decision, language: de))
        XCTAssertFalse(SummaryItemFilter.isUsable("Und dann warte mal kurz.", kind: .topic, language: de))
        XCTAssertFalse(SummaryItemFilter.isUsable("Wer trägt die Kosten?", kind: .action, language: de),
                       "a question is not an action item")
        XCTAssertFalse(SummaryItemFilter.isUsable("Wartungsvertrag monatlich", kind: .question, language: de),
                       "an open question is phrased as a question")
        XCTAssertFalse(SummaryItemFilter.isUsable(
            "Budget Messestand Halle drei Lieferant Prospekte Termin Planung Kosten", kind: .topic, language: de),
            "a topic is a short label")
        XCTAssertFalse(SummaryItemFilter.isUsable("Use an open source content management system", kind: .decision, language: de),
                       "an English item in a German meeting")
        XCTAssertTrue(SummaryItemFilter.isUsable("Start der Werbung um eine Woche verschoben", kind: .decision, language: de))
        XCTAssertTrue(SummaryItemFilter.isUsable("Wie wird der Wartungsvertrag bezahlt?", kind: .question, language: de))
        XCTAssertTrue(SummaryItemFilter.isUsable("Budget", kind: .topic, language: de))
        XCTAssertFalse(SummaryItemFilter.isUsable("Später", kind: .decision, language: de), "one word is not a decision")
    }

    func testPronounsAreNotOwners() {
        let chunk = SummaryUnits.build(transcript: "", segments: segments(6))
        XCTAssertEqual(Grounding.resolveOwner("Sie", line: 4, in: chunk, speakers: true), "Speaker 1")
        XCTAssertEqual(Grounding.resolveOwner("Bdy?", line: 4, in: chunk, speakers: true), "Speaker 1")
        XCTAssertTrue(Grounding.looksLikeName("Anna Schmidt"))
        XCTAssertFalse(Grounding.looksLikeName("checken noch mal"))
    }

    func testOverviewRepetitionLoopIsCutToDistinctSentences() {
        let notes = "- Budget zweites Quartal\n- Kleinerer Stand in Halle drei"
        let loop = Array(repeating: "Das Budget für das zweite Quartal steht. Gewählt wurde der kleinere Stand in Halle drei.",
                         count: 6).joined(separator: " ") + " Das Budget für das"
        XCTAssertEqual(SummaryFailure.groundedSentences(loop, language: de, source: notes, maxSentences: 3),
                       "Das Budget für das zweite Quartal steht. Gewählt wurde der kleinere Stand in Halle drei.")
    }

    func testMergeDropsItemsCitingAnotherChunksLine() {
        let units = SummaryUnits.build(transcript: "", segments: segments(12))
        var n = ChunkNotes()
        n.topics = [.init(line: 10, text: "Terminplanung Mittwoch")]
        let merged = SummaryMerger.merge([(Array(units[0..<6]), n)], language: de, speakers: true)
        XCTAssertTrue(merged.topics.isEmpty)
    }

    func testCleanStripsBulletsQuotesAndCitations() {
        XCTAssertEqual(SummaryMerger.clean("- \"Budget festlegen\" [3]"), "Budget festlegen")
        XCTAssertEqual(SummaryMerger.clean("[12] Budget festlegen"), "Budget festlegen")
    }

    // MARK: Language

    func testLanguageFollowsTheTranscriptAndTheHint() {
        let german = Array(repeating: Self.germanLines.joined(separator: " "), count: 3).joined(separator: " ")
        XCTAssertEqual(SummaryLanguage.detect(transcript: german).code, "de")
        XCTAssertEqual(SummaryLanguage.detect(transcript: german).titles.decisions, "Entscheidungen")
        let english = "We need to set the budget for the second quarter by Friday and decide on the booth."
        XCTAssertEqual(SummaryLanguage.detect(transcript: english).code, "en")
        XCTAssertEqual(SummaryLanguage.detect(transcript: english, localeHint: "de-DE").code, "de")
        XCTAssertEqual(SummaryLanguage(code: "xx").titles, SummaryLanguage.titleTable["en"])
        XCTAssertEqual(SummaryLanguage.normalize("zh-Hans"), "zh")
    }

    func testExtractionPromptIsInTheMeetingsLanguage() {
        XCTAssertTrue(SummaryPrompts.extraction(de).contains("Deutsch"))
        XCTAssertTrue(SummaryPrompts.extraction(SummaryLanguage(code: "fr")).contains("French"))
    }

    // MARK: Rendering

    func testRenderOmitsEmptySectionsAndUsesLocalizedTitles() {
        var notes = MergedNotes()
        notes.decisions = [SummaryItem(text: "Kleinerer Stand", unit: 2, segment: 2, start: 60)]
        notes.topics = [SummaryItem(text: "Budget", unit: 0, segment: 0, start: 0),
                        SummaryItem(text: "Messestand", unit: 3, segment: 3, start: 3700)]
        let md = SummaryRenderer.render(overview: "Ein Überblick.", notes: notes, language: de, words: 2000)!
        XCTAssertTrue(md.hasPrefix("Ein Überblick.\n\n**Entscheidungen:**\n- Kleinerer Stand"))
        XCTAssertTrue(md.contains("**Themen:**\n- [00:00] Budget\n- [1:01:40] Messestand"))
        XCTAssertFalse(md.contains("Aufgaben"), "empty action items section omitted")
        XCTAssertFalse(md.contains("Offene Fragen"))
        XCTAssertNil(SummaryRenderer.render(overview: nil, notes: MergedNotes(), language: de, words: 2000))
    }

    func testOutputCapsGrowWithTheMeeting() {
        let small = SummaryRenderer.caps(words: 500), big = SummaryRenderer.caps(words: 18_000)
        XCTAssertGreaterThan(big.topics, small.topics)
        XCTAssertGreaterThan(big.decisions, small.decisions)
        XCTAssertLessThan(SummaryRenderer.overviewSentences(words: 500), SummaryRenderer.overviewSentences(words: 18_000))
        let items = (0..<30).map { SummaryItem(text: "t\($0)", unit: $0, segment: $0, start: nil) }
        let spread = SummaryRenderer.spread(items, cap: 5)
        XCTAssertEqual(spread.map(\.unit), [0, 6, 12, 18, 24], "cap keeps items spread over the whole meeting")
    }

    // MARK: Failure detection

    func testRefusalsAndApologiesAreDetectedInEnglishAndGerman() {
        for r in ["I'm sorry, but I cannot summarize this transcript.",
                  "I apologize, the transcript is unclear.",
                  "Es tut mir leid, aber ich kann das nicht zusammenfassen.",
                  "Leider kann ich keine Zusammenfassung erstellen."] {
            XCTAssertTrue(SummaryFailure.isRefusalOrApology(r), r)
        }
        XCTAssertFalse(SummaryFailure.isRefusalOrApology("Das Team legt das Budget bis Freitag fest."))
    }

    func testProseInTheWrongLanguageIsRejected() {
        let source = Self.germanLines.joined(separator: " ")
        XCTAssertFalse(SummaryFailure.acceptsProse(
            "The team discussed the budget for the second quarter and decided on a smaller booth in hall three.",
            language: de, source: source))
        XCTAssertTrue(SummaryFailure.acceptsProse(
            "Das Team legt das Budget für das zweite Quartal fest und entscheidet sich für den kleineren Stand.",
            language: de, source: source))
    }

    func testAShortReplyThatInventsContentIsRejected() {
        let source = "Kannst du mir sagen, wie spät es ist und ob der Zug nach Berlin pünktlich fährt?"
        XCTAssertTrue(SummaryFailure.isMostlyInvented(
            "Der Regionalexpress verkehrt heute planmäßig, Abfahrt Gleis sieben, Ankunft vierzehn Uhr.",
            language: de, source: source))
        XCTAssertFalse(SummaryFailure.isMostlyInvented(
            "Jemand fragt nach der Uhrzeit und ob der Zug nach Berlin pünktlich fährt.",
            language: de, source: source))
    }

    func testShortSameSpeakerTurnsAreJoinedIntoOneLine() {
        let segs = [
            MeetingSegment(speaker: "Me", start: 0, end: 4, text: "Wir legen das Budget fest."),
            MeetingSegment(speaker: "Me", start: 5, end: 9, text: "Und zwar bis Freitag."),
            MeetingSegment(speaker: "Them", start: 10, end: 12, text: "Einverstanden."),
            MeetingSegment(speaker: "Them", start: 40, end: 44, text: "Neues Thema nach der Pause."),
        ]
        let units = SummaryUnits.build(transcript: "", segments: segs)
        XCTAssertEqual(units.map(\.text), ["Wir legen das Budget fest. Und zwar bis Freitag.", "Einverstanden.",
                                          "Neues Thema nach der Pause."])
        XCTAssertEqual(units[0].segment, 0)
        XCTAssertEqual(units[0].end, 9)
    }

    func testChunksHoldAtMostSixLines() {
        let units = (0..<20).map { SummaryUnit(index: $0, segment: $0, speaker: nil, start: nil, end: nil, text: "kurz") }
        let chunks = SummaryChunker.chunk(units, budgetChars: 10_000, speakers: false)
        XCTAssertEqual(chunks.map(\.count), [6, 6, 6, 2])
    }

    func testPlainTaggedLinesAreParsedLeniently() {
        let chunk = SummaryUnits.build(transcript: "", segments: segments(6))
        let text = """
        Here are the notes:
        - DECISION [2]: Kleinerer Stand in Halle drei
        **Aufgabe 4:** Thomas | Terminplanung an alle schicken | Mittwoch
        QUESTION: Druckt der Lieferant die Prospekte rechtzeitig?
        TOPIC [99]: Budget zweites Quartal
        random chatter line
        """
        let n = PlainNotesParser.parse(text, chunk: chunk, language: de)
        XCTAssertEqual(n.decisions, [.init(line: 2, text: "Kleinerer Stand in Halle drei")])
        XCTAssertEqual(n.actionItems, [.init(line: 4, owner: "Thomas", task: "Terminplanung an alle schicken", due: "Mittwoch")])
        XCTAssertEqual(n.openQuestions.map(\.line), [3], "no number → the line it shares most words with")
        XCTAssertEqual(n.topics.map(\.line), [0], "a number outside the chunk → best matching line")
    }

    func testShortSummarySentencesMustShareWordsWithTheTranscript() {
        let source = Self.germanLines.joined(separator: " ")
        let out = SummaryFailure.sentencesSharingWords(
            "Es ging um das Budget für das zweite Quartal. Danach wurde über Urlaub auf Mallorca geplaudert. Thomas schickt die Terminplanung.",
            language: de, source: source, max: 3)
        XCTAssertEqual(out, "Es ging um das Budget für das zweite Quartal. Thomas schickt die Terminplanung.")
    }

    // MARK: Pipeline with a fake model

    func testShortMeetingIsOneOrTwoSentencesWithoutSections() async {
        let segs = segments(3)
        let model = FakeModel()
        model.writeHandler = { _, _ in "Das Budget für das zweite Quartal wird bis Freitag festgelegt." }
        let r = await MeetingSummaryPipeline(model: model).run(transcript: transcript(segs), segments: segs)
        XCTAssertEqual(r.markdown, "Das Budget für das zweite Quartal wird bis Freitag festgelegt.")
        XCTAssertTrue(model.extractPrompts.isEmpty, "no structured extraction for a short meeting")
        XCTAssertFalse(r.markdown!.contains("**"))
    }

    func testShortMeetingRefusalLeavesTheSummaryEmpty() async {
        let segs = segments(3)
        let model = FakeModel()
        model.writeHandler = { _, _ in "I'm sorry, but I cannot help with that request." }
        let r = await MeetingSummaryPipeline(model: model).run(transcript: transcript(segs), segments: segs)
        XCTAssertNil(r.markdown)
        XCTAssertEqual(r.failedChunks, 1)
    }

    func testLongMeetingReadsEveryChunkAndWritesGermanSections() async {
        let segs = segments(60)
        let model = FakeModel()
        model.extractHandler = { Self.faithfulNotes($0) }
        model.writeHandler = { _, _ in "Das Team plant das Budget und den Messestand in Halle drei." }
        var p = MeetingSummaryPipeline(model: model)
        p.chunkBudgetChars = 900
        let r = await p.run(transcript: transcript(segs), segments: segs)
        let seen = Set(model.extractPrompts.flatMap(Self.lineNumbers))
        XCTAssertEqual(seen, Set(0..<60), "every line reached the model")
        XCTAssertEqual(r.language.code, "de")
        let md = try! XCTUnwrap(r.markdown)
        XCTAssertTrue(md.hasPrefix("Das Team plant"))
        XCTAssertTrue(md.contains("**Entscheidungen:**"))
        XCTAssertTrue(md.contains("**Aufgaben:**\n- Thomas: Terminplanung an alle schicken (Mittwoch)"))
        XCTAssertTrue(md.contains("**Offene Fragen:**"))
        XCTAssertTrue(md.contains("**Themen:**\n- [00:00] Budget zweites Quartal"))
        XCTAssertEqual(md.components(separatedBy: "Terminplanung").count - 1, 1, "duplicates merged in code")
        XCTAssertEqual(model.writeCalls, 1, "exactly one free-form call: the overview")
    }

    func testEveryChunkFailingLeavesTheSummaryEmpty() async {
        let segs = segments(60)
        let model = FakeModel()
        model.extractHandler = { _ in throw SummaryModelError.refused }
        model.writeHandler = { _, _ in "I'm sorry, but I cannot help with that." }
        var p = MeetingSummaryPipeline(model: model)
        p.chunkBudgetChars = 900
        let r = await p.run(transcript: transcript(segs), segments: segs)
        XCTAssertNil(r.markdown)
        XCTAssertEqual(r.failedChunks, r.chunks)
    }

    func testRefusedGuidedChunkIsRetriedWithAPlainPrompt() async {
        let segs = segments(60)
        let model = FakeModel()
        model.extractHandler = { _ in throw SummaryModelError.refused }
        model.writeHandler = { instructions, prompt in
            if instructions.contains("TOPIC [n]") {
                // Cite the first line of the chunk this prompt holds.
                let n = Self.lineNumbers(prompt).first(where: { Self.germanLines[$0 % 6].contains("Budget") }) ?? -1
                return n < 0 ? "nothing" : "DECISION [\(n)]: Budget für das zweite Quartal bis Freitag festlegen"
            }
            return "Das Team legt das Budget für das zweite Quartal fest."
        }
        var p = MeetingSummaryPipeline(model: model)
        p.chunkBudgetChars = 900
        let r = await p.run(transcript: transcript(segs), segments: segs)
        let md = try! XCTUnwrap(r.markdown)
        XCTAssertTrue(md.contains("**Entscheidungen:**\n- Budget für das zweite Quartal bis Freitag festlegen"))
        XCTAssertTrue(r.errors.contains("refused→plain"))
    }

    func testWhenEveryExtractionFailsAPlainGroundedOverviewIsWritten() async {
        let segs = segments(60)
        let model = FakeModel()
        model.extractHandler = { _ in throw SummaryModelError.other("decodingFailure") }
        model.writeHandler = { instructions, _ in
            if instructions.contains("TOPIC [n]") { return "I'm sorry, but I cannot help with that." }
            return "Es ging um das Budget für das zweite Quartal. Außerdem um Urlaubspläne in Spanien."
        }
        var p = MeetingSummaryPipeline(model: model)
        p.chunkBudgetChars = 900
        let r = await p.run(transcript: transcript(segs), segments: segs)
        XCTAssertEqual(r.markdown, "Es ging um das Budget für das zweite Quartal.", "the unsupported sentence is dropped")
        XCTAssertEqual(r.failedChunks, r.chunks)
    }

    func testPartialResultsFromSuccessfulChunksAreKept() async {
        let segs = segments(60)
        let model = FakeModel()
        var calls = 0
        model.extractHandler = { prompt in
            calls += 1
            if calls % 2 == 0 { throw SummaryModelError.other("boom") }
            return Self.faithfulNotes(prompt)
        }
        model.writeHandler = { _, _ in "I apologize, but I cannot provide an overview." }
        var p = MeetingSummaryPipeline(model: model)
        p.chunkBudgetChars = 900
        let r = await p.run(transcript: transcript(segs), segments: segs)
        XCTAssertGreaterThan(r.failedChunks, 0)
        let md = try! XCTUnwrap(r.markdown, "half the chunks succeeded")
        XCTAssertTrue(md.hasPrefix("**"), "the refused overview is dropped, the sections stay")
        XCTAssertFalse(md.lowercased().contains("apologize"))
    }

    func testOverflowingChunkIsSplitAndRetried() async {
        let segs = segments(60)
        let model = FakeModel()
        model.extractHandler = { prompt in
            if prompt.count > 600 { throw SummaryModelError.contextOverflow }
            return Self.faithfulNotes(prompt)
        }
        model.writeHandler = { _, _ in "Das Team plant das Budget und den Messestand in Halle drei." }
        var p = MeetingSummaryPipeline(model: model)
        p.chunkBudgetChars = 1000
        let r = await p.run(transcript: transcript(segs), segments: segs)
        XCTAssertEqual(r.failedChunks, 0)
        XCTAssertNotNil(r.markdown)
        XCTAssertEqual(Set(model.extractPrompts.filter { $0.count <= 600 }.flatMap(Self.lineNumbers)), Set(0..<60))
    }

    func testCountedTokensOverBudgetSplitBeforeCalling() async {
        let segs = segments(60)
        let model = FakeModel()
        model.tokenHandler = { $0.count / 2 }
        model.extractHandler = { Self.faithfulNotes($0) }
        model.writeHandler = { _, _ in "Das Team plant das Budget." }
        var p = MeetingSummaryPipeline(model: model)
        p.chunkBudgetChars = 1000
        p.chunkBudgetTokens = 300
        _ = await p.run(transcript: transcript(segs), segments: segs)
        XCTAssertTrue(model.extractPrompts.allSatisfy { $0.count / 2 <= 300 })
    }

    func testUnavailableModelOrEmptyTranscriptDoesNothing() async {
        let model = FakeModel()
        model.available = false
        let r = await MeetingSummaryPipeline(model: model).run(transcript: "Hallo", segments: nil)
        XCTAssertNil(r.markdown)
        XCTAssertEqual(r.chunks, 0)
        let empty = await MeetingSummaryPipeline(model: FakeModel()).run(transcript: "  ", segments: nil)
        XCTAssertNil(empty.markdown)
    }

    func testAWedgedCallIsAbandonedAtThePerCallBound() async {
        final class Slow: MeetingSummaryModel, @unchecked Sendable {
            var isAvailable: Bool { true }
            func extract(instructions: String, prompt: String) async throws -> ChunkNotes {
                try? await Task.sleep(for: .seconds(30)); return ChunkNotes()
            }
            func write(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
                try? await Task.sleep(for: .seconds(30)); return ""
            }
            func tokenCount(_ text: String) async -> Int? { nil }
        }
        let segs = segments(3)
        var p = MeetingSummaryPipeline(model: Slow())
        p.perCallSeconds = 0.2
        let started = Date()
        let r = await p.run(transcript: transcript(segs), segments: segs)
        XCTAssertNil(r.markdown)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Consumers

    func testRecorderComposesAnEmptySummaryOnFailureButKeepsNotes() {
        XCTAssertEqual(MeetingRecorder.composeSummary(userNotes: "", transcriptSummary: "", fused: nil), "")
        XCTAssertTrue(MeetingRecorder.composeSummary(userNotes: "meine Notiz", transcriptSummary: "", fused: nil)
            .contains("meine Notiz"))
    }
}
