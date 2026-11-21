import XCTest
@testable import Talkie

/// The "commands made understandable" work: tolerant matching of natural wordings
/// inside a command span, nothing lost when no format is heard, the pill's status
/// line, and the wordings the Commands page lists.
final class FormatWordingToleranceTests: XCTestCase {
    private let book = FormatPhraseBook.builtIn

    private func match(_ s: String) -> FormatCommand? { FormatPhraseMatcher.match(s, book: book) }

    /// What a normal person would try, per preset, German and English.
    private let wordings: [(FormatPreset, de: [String], en: [String])] = [
        (.bulletList, ["Liste", "Punkte", "Bulletpoints", "Spiegelstrichliste", "als Liste", "in Stichpunkten"],
         ["bullet point list", "bullet points", "list", "dot points", "as a list"]),
        (.numberedList, ["nummerierte Liste", "Nummernliste", "durchnummeriert", "nummerierte Punkte"],
         ["numbered list", "ordered list", "number list", "numbered points"]),
        (.todoList, ["To-do-Liste", "todo liste", "Aufgabenliste", "Checkliste", "Abhakliste"],
         ["to-do list", "todo list", "to do list", "task list", "checklist"]),
        (.allCaps, ["Großbuchstaben", "alles groß", "Versalien", "komplett groß"],
         ["all caps", "uppercase", "upper case", "all capitals", "capital letters"]),
        (.lowercase, ["alles klein", "Kleinbuchstaben", "kleingeschrieben", "keine Großbuchstaben"],
         ["lowercase", "all lower case", "no caps", "small letters"]),
        (.quotes, ["in Anführungszeichen", "Gänsefüßchen", "als Zitat", "Anführungsstriche"],
         ["in quotes", "quotation marks", "in double quotes", "speech marks"]),
        (.parentheses, ["in Klammern", "Klammer", "runde Klammern", "eingeklammert"],
         ["in parentheses", "round brackets", "in brackets", "parenthesis"]),
        (.heading, ["als Überschrift", "Titel", "Headline", "als Titel"],
         ["as a heading", "headline", "as a title", "header"]),
        (.verbatim, ["wörtlich", "Codeblock", "unverändert", "Wort für Wort"],
         ["verbatim", "code block", "unchanged", "word for word"]),
        (.email, ["als E-Mail", "E-Mail", "Email", "als Mail"],
         ["as an email", "e-mail", "email", "as e-mail"]),
        (.formal, ["formell", "förmlich", "höflich", "geschäftlich"],
         ["formal", "more formal", "polite", "business style"]),
        (.shorter, ["kürzer", "kurz und knapp", "kompakter", "gekürzt"],
         ["shorter", "make it shorter", "condense", "more concise"]),
        (.translateToEnglish, ["auf Englisch", "ins Englische", "nach Englisch", "englische Version"],
         ["in English", "to English", "into English", "English version"]),
        (.translateToGerman, ["auf Deutsch", "ins Deutsche", "nach Deutsch", "deutsche Version"],
         ["in German", "to German", "into German", "German version"]),
    ]

    func testEveryPresetUnderstandsNormalGermanAndEnglishWordings() {
        for (preset, de, en) in wordings {
            for phrase in de + en {
                XCTAssertEqual(match(phrase), .apply(preset), "\(preset): \"\(phrase)\"")
            }
        }
    }

    func testEveryPresetCoversAllItsWordingsInTheTable() {
        XCTAssertEqual(Set(wordings.map(\.0)), Set(FormatPreset.allCases))
    }

    func testNaturalWrappersAndPunctuationAreTolerated() {
        let leading = ["", "bitte ", "als ", "in ", "im ", "mach das ", "mach es ", "schreib das ", "jetzt ", "und jetzt ",
                       "as ", "as a ", "make it ", "make this ", "please ", "now ", "okay, "]
        let trailing = ["", " bitte", " please", " format", " formatieren", ".", ", bitte.", "!", " …"]
        for (preset, de, en) in wordings {
            // One German and one English wording per preset, in every wrapper.
            for phrase in [de[0], en[0]] {
                for l in leading {
                    for t in trailing {
                        let spoken = l + phrase + t
                        XCTAssertEqual(match(spoken), .apply(preset), "\(preset): \"\(spoken)\"")
                    }
                }
            }
        }
    }

    func testArticlesCaseAndHyphenVariants() {
        XCTAssertEqual(match("TO-DO-LISTE"), .apply(.todoList))
        XCTAssertEqual(match("to do liste"), .apply(.todoList))
        XCTAssertEqual(match("To-Do's"), .apply(.todoList))
        XCTAssertEqual(match("die Überschrift"), .apply(.heading))
        XCTAssertEqual(match("eine Aufzählung"), .apply(.bulletList))
        XCTAssertEqual(match("the numbered list"), .apply(.numberedList))
        XCTAssertEqual(match("a heading"), .apply(.heading))
        XCTAssertEqual(match("E Mail"), .apply(.email))
        XCTAssertEqual(match("alles GROß"), .apply(.allCaps))
        XCTAssertEqual(match("Anführungs-zeichen"), .apply(.quotes))
        XCTAssertEqual(match("Turn it into bullet points"), .apply(.bulletList))
        XCTAssertEqual(match("Formatiere das als Aufzählung bitte"), .apply(.bulletList))
    }

    /// A close wording of one preset must never be read as another one.
    func testNearMissesDoNotFireTheNeighbouringPreset() {
        XCTAssertEqual(match("numbered list"), .apply(.numberedList))      // contains "list"
        XCTAssertEqual(match("nummerierte Liste"), .apply(.numberedList))  // contains "Liste"
        XCTAssertEqual(match("to-do list"), .apply(.todoList))
        XCTAssertEqual(match("To-do-Liste"), .apply(.todoList))
        XCTAssertEqual(match("no caps"), .apply(.lowercase))               // contains "caps"
        XCTAssertEqual(match("keine Großbuchstaben"), .apply(.lowercase))
        XCTAssertEqual(match("all lower case"), .apply(.lowercase))
        XCTAssertEqual(match("in German"), .apply(.translateToGerman))
        XCTAssertEqual(match("in English"), .apply(.translateToEnglish))
        XCTAssertEqual(match("auf Englisch"), .apply(.translateToEnglish))
        XCTAssertEqual(match("Kleinbuchstaben"), .apply(.lowercase))
        XCTAssertEqual(match("Großbuchstaben"), .apply(.allCaps))
        XCTAssertEqual(match("more formal"), .apply(.formal))
        XCTAssertEqual(match("as a title"), .apply(.heading))
        XCTAssertEqual(match("bullet point list"), .apply(.bulletList))
        XCTAssertEqual(match("Spiegelstrichliste"), .apply(.bulletList))
        // Two different formats in one utterance: ambiguous, so none.
        XCTAssertNil(match("all caps bullet points yes"))
    }

    /// Ordinary sentences said by mistake while the key is held are not formats.
    func testOrdinaryTalkIsNotAFormat() {
        for spoken in ["Wir treffen uns morgen um neun", "the quick brown fox jumps", "ich muss noch einkaufen gehen",
                       "send it to Anna tomorrow", "das war ein langer Tag", "okay", "please", "bitte", "und jetzt"] {
            XCTAssertNil(match(spoken), "\"\(spoken)\"")
        }
    }

    func testNewWordingsAreSharedByNoOtherPreset() {
        // Every built-in phrase resolves to its own preset (also across the new ones).
        for preset in FormatPreset.allCases {
            for phrase in preset.allPhrases {
                XCTAssertEqual(match(phrase), .apply(preset), "\(preset): \"\(phrase)\"")
            }
        }
    }
}

final class FormatNothingIsLostTests: XCTestCase {
    private func w(_ t: String, _ s: Double, _ e: Double, seg: Int = 0) -> FormatWord {
        FormatWord(text: t, start: s, end: e, segment: seg)
    }

    func testUnrecognisedWordsStayInTheTextAndDictationContinues() {
        let words = [w("one", 0, 0.3), w(" banana", 1.0, 1.4), w(" split", 1.5, 1.8), w(" two", 2.5, 2.8)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0.9, end: 1.9)])
        XCTAssertEqual(layout.resolutions, [.notRecognised("banana split")])
        XCTAssertEqual(layout.regions.count, 1)
        XCTAssertNil(layout.regions[0].style)
        XCTAssertEqual(FormatTimeline.text(of: layout.regions[0].words), "one banana split two")
    }

    func testUnrecognisedWordsKeepTheActiveFormat() {
        // "caps" turns ALL CAPS on; a later unrecognised span's words are text inside it.
        let words = [w("caps", 0, 0.3), w(" hello", 1.0, 1.3), w(" banana", 2.0, 2.3), w(" bye", 3.0, 3.3)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0, end: 0.4), .span(start: 1.9, end: 2.4)])
        XCTAssertEqual(layout.resolutions, [.applied(.allCaps), .notRecognised("banana")])
        XCTAssertEqual(layout.regions.map(\.format), [.allCaps])
        XCTAssertEqual(FormatTimeline.text(of: layout.regions[0].words), "hello banana bye")
    }

    func testRecognisedSpanStillConsumesItsCommandWords() {
        let words = [w("one", 0, 0.3), w(" bullet", 1.0, 1.3), w(" points", 1.35, 1.7), w(" milk", 2.5, 2.8)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0.9, end: 1.8)])
        XCTAssertEqual(layout.resolutions, [.applied(.bulletList)])
        XCTAssertEqual(layout.regions.map { FormatTimeline.text(of: $0.words) }, ["one", "milk"])
    }

    func testEmptyHoldStillEndsTheFormatAndLosesNothing() {
        let words = [w("caps", 0, 0.3), w(" yes", 1.0, 1.3), w(" no", 3.0, 3.3)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0, end: 0.4), .span(start: 2.0, end: 2.5)])
        XCTAssertEqual(layout.resolutions, [.applied(.allCaps), .ended])
        XCTAssertEqual(layout.regions.map { FormatTimeline.text(of: $0.words) }, ["yes", "no"])
    }

    func testAssemblerPastesUnrecognisedWordsAsNormalText() async {
        let segments = [TimedSegment(text: "one banana two", start: 0, end: 3, words: [
            SegmentWord(text: "one", start: 0, end: 0.3),
            SegmentWord(text: " banana", start: 1.0, end: 1.4),
            SegmentWord(text: " two", start: 2.0, end: 2.3),
        ])]
        let plan = await FormatDictationAssembler.assemble(
            segments: segments, marks: [.span(start: 0.9, end: 1.5)], book: .builtIn,
            clean: nil, postProcessFormatted: { $0 }, languageCode: "en", userName: "")
        XCTAssertEqual(plan.resolutions, [.notRecognised("banana")])
        XCTAssertEqual(plan.plainRaw, "one banana two")
        XCTAssertTrue(plan.normalStream.contains("banana"), plan.normalStream)
    }
}

final class PillFormatStatusTests: XCTestCase {
    private func state(_ events: [PillFormatState.Event]) -> PillFormatState {
        var s = PillFormatState()
        for e in events { s.handle(e) }
        return s
    }

    func testNormalDictationShowsNothing() {
        XCTAssertNil(PillFormatState().statusLine)
    }

    func testFirstPressListensAndSecondPressChecks() {
        XCTAssertEqual(state([.keyDown]).statusLine, .listening)
        XCTAssertEqual(state([.keyDown, .spanReleased]).statusLine, .checking)
        XCTAssertTrue(state([.keyDown, .spanReleased]).textIsBlue)
    }

    func testCommandKeyShortNames() {
        XCTAssertEqual(FormatCommandKey.defaultKey.shortName, "⌃")
        XCTAssertEqual(ActivationKey.leftOption.shortName, "⌥")
        XCTAssertEqual(ActivationKey.rightControl.shortName, "⌃")
        XCTAssertEqual(ActivationKey(kind: .function, code: 96).shortName, "F5")
        XCTAssertEqual(ActivationKey.mouseButton4.shortName, ActivationKey.mouseButton4.displayName)
    }

    func testRecognisedConfirmsThenStaysActive() {
        var s = state([.keyDown, .spanReleased, .resolved(.format("Bullet list"))])
        XCTAssertEqual(s.statusLine, .confirmed("Bullet list"))
        XCTAssertTrue(s.waveformIsBlue)
        s.handle(.flashExpired)
        XCTAssertEqual(s.statusLine, .active("Bullet list"))   // persistent, still on
        XCTAssertTrue(s.waveformIsBlue)
        XCTAssertFalse(s.textIsBlue)
    }

    func testNotRecognisedSaysSoForTwoSecondsThenReturnsToNormal() {
        var s = state([.keyDown, .spanReleased, .resolved(.notRecognised)])
        XCTAssertEqual(s.statusLine, .notRecognised)
        XCTAssertEqual(s.flashSeconds, 2.0)
        XCTAssertFalse(s.waveformIsBlue)            // normal listening waveform keeps going
        s.handle(.flashExpired)
        XCTAssertNil(s.statusLine)
    }

    func testNotRecognisedKeepsTheActiveFormat() {
        var s = state([.resolved(.format("ALL CAPS")), .flashExpired, .keyDown, .spanReleased, .resolved(.notRecognised)])
        XCTAssertEqual(s.statusLine, .notRecognised)
        XCTAssertEqual(s.activeFormat, "ALL CAPS")
        s.handle(.flashExpired)
        XCTAssertEqual(s.statusLine, .active("ALL CAPS"))
    }

    func testEmptyHoldShowsNoFlashAndChangesNothing() {
        XCTAssertNil(state([.keyDown, .spanReleased, .resolved(.emptyHold)]).statusLine)
        var s = state([.resolved(.format("Heading")), .flashExpired])
        s.handle(.keyDown)
        XCTAssertEqual(s.statusLine, .listening)
        s.handle(.spanReleased)
        s.handle(.resolved(.emptyHold))
        XCTAssertEqual(s.flash, .none)
        XCTAssertNil(s.statusLine)                  // the held key without words ended it, quietly
    }

    func testEndingAnActiveFormatSaysSoAndThenClears() {
        var s = state([.resolved(.format("Heading")), .flashExpired, .keyDown, .spanReleased, .resolved(.ended)])
        XCTAssertEqual(s.statusLine, .ended)
        XCTAssertNil(s.activeFormat)
        s.handle(.flashExpired)
        XCTAssertNil(s.statusLine)
        // A tap ends it the same way.
        s = state([.resolved(.format("Heading")), .flashExpired, .tapped])
        XCTAssertEqual(s.statusLine, .ended)
        // Ending when nothing is active shows nothing.
        XCTAssertNil(state([.keyDown, .spanReleased, .resolved(.ended)]).statusLine)
        XCTAssertNil(state([.tapped]).statusLine)
    }

    func testInsertedConfirmsWithoutChangingTheFormat() {
        var s = state([.resolved(.format("Heading")), .flashExpired, .keyDown, .spanReleased, .resolved(.inserted("my address"))])
        XCTAssertEqual(s.statusLine, .confirmed("my address"))
        s.handle(.flashExpired)
        XCTAssertEqual(s.statusLine, .active("Heading"))
    }

    func testCancelledHoldGoesBackToWhatItWas() {
        XCTAssertNil(state([.keyDown, .keyCancelled]).statusLine)
        XCTAssertEqual(state([.resolved(.format("Heading")), .flashExpired, .keyDown, .keyCancelled]).statusLine,
                       .active("Heading"))
    }

    func testKeyDownClearsAFlashAndSessionEndResets() {
        XCTAssertEqual(state([.resolved(.notRecognised), .keyDown]).statusLine, .listening)
        XCTAssertNil(state([.resolved(.format("X")), .sessionEnded]).statusLine)
    }

    func testEveryFlashHasADuration() {
        XCTAssertNil(PillFormatState().flashSeconds)
        for e in [PillFormatState.Resolution.format("A"), .inserted("A"), .notRecognised] {
            XCTAssertNotNil(state([.resolved(e)]).flashSeconds)
        }
        XCTAssertEqual(state([.resolved(.format("A")), .resolved(.ended)]).flashSeconds, PillFormatState.endedSeconds)
    }

    func testWarningToneIsReadableOnThePillAndIsNotRed() {
        let c = PillPalette.contrast(PillPalette.warning, PillPalette.pillBackground)
        XCTAssertGreaterThanOrEqual(c, PillPalette.minimumContrast)
        for red in PillPalette.recordingRed {
            XCTAssertGreaterThan(PillPalette.distance(PillPalette.warning, red), 100)
        }
    }
}

final class FormatPhraseCatalogTests: XCTestCase {
    func testLanguagesFollowTheSpokenLanguagesThenFallBack() {
        XCTAssertEqual(FormatPhraseCatalog.languages(spoken: ["de-DE", "en-US"], uiLanguage: "fr"), ["de", "en"])
        XCTAssertEqual(FormatPhraseCatalog.languages(spoken: ["en-US", "en-GB", "pt-BR"], uiLanguage: "de"), ["en", "pt"])
        XCTAssertEqual(FormatPhraseCatalog.languages(spoken: [], uiLanguage: "de"), ["de", "en"])
        XCTAssertEqual(FormatPhraseCatalog.languages(spoken: ["sv-SE"], uiLanguage: "sv"), ["en"])
        XCTAssertEqual(FormatPhraseCatalog.languages(spoken: [], uiLanguage: "en"), ["en"])
        XCTAssertEqual(FormatPhraseCatalog.otherLanguages(than: ["de", "en"]).count, FormatPhrases.languages.count - 2)
    }

    func testPhrasesListEveryWordingOnceWithOwnWordsLast() {
        let list = FormatPhraseCatalog.phrases(.bulletList, languages: ["de", "en"], own: ["dash list", "Bullet Points"])
        XCTAssertEqual(list.first, "in Stichpunkten")
        XCTAssertTrue(list.contains("bullet list"))
        XCTAssertEqual(list.last, "dash list")                       // "Bullet Points" is the built-in "Bulletpoints": listed once
        XCTAssertFalse(list.contains("Bullet Points"))
        XCTAssertEqual(list.count, Set(list.map { FormatPhraseMatcher.normalizedTokens($0).joined() }).count)
        for preset in FormatPreset.allCases {
            XCTAssertGreaterThanOrEqual(FormatPhraseCatalog.phrases(preset, languages: ["de"]).count, 3, "\(preset) de")
            XCTAssertGreaterThanOrEqual(FormatPhraseCatalog.phrases(preset, languages: ["en"]).count, 2, "\(preset) en")
        }
    }

    func testCardSummaryShowsMainPlusTwoAndTheRest() {
        let s = FormatPhraseCatalog.summary(["a", "b", "c", "d", "e"])
        XCTAssertEqual(s, .init(main: "a", more: ["b", "c"], hidden: 2))
        XCTAssertEqual(FormatPhraseCatalog.summary(["a", "b"]), .init(main: "a", more: ["b"], hidden: 0))
        XCTAssertEqual(FormatPhraseCatalog.summary(["a"]), .init(main: "a", more: [], hidden: 0))
        XCTAssertNil(FormatPhraseCatalog.summary([]))
    }
}

@MainActor
final class CommandsMasterCardTests: XCTestCase {
    func testStateLineIsOnlyTheState() {
        XCTAssertNotEqual(CommandsMasterCard.stateTitle(isOn: true), CommandsMasterCard.stateTitle(isOn: false))
        XCTAssertNil(CommandsMasterCard.stateSubtitle(isOn: true))
        XCTAssertNotNil(CommandsMasterCard.stateSubtitle(isOn: false))
    }
}

final class FormatPhraseFitTests: XCTestCase {
    /// 1 unit per character; " · " = 3; "+N more" = 7 for one digit, 8 for two.
    private func fit(_ p: [String], lines: Int = 2, width: Double) -> FormatPhraseCatalog.Fitted {
        FormatPhraseCatalog.fit(p, maxLines: lines, width: width, measure: { Double($0.count) }, separator: 3,
                                moreWidth: { Double("+\($0) more".count) })
    }

    func testEverythingFitsWithoutAMoreLabel() {
        let r = fit(["aaaa", "bbbb", "cccc"], width: 30)
        XCTAssertEqual(r, .init(lines: [["aaaa", "bbbb", "cccc"]], hidden: 0))
    }

    func testWrapsToASecondLineAndNeverCutsAPhrase() {
        let r = fit(["aaaaaa", "bbbbbb", "cccccc", "dddddd"], width: 16)
        XCTAssertEqual(r.lines, [["aaaaaa", "bbbbbb"], ["cccccc", "dddddd"]])
        XCTAssertEqual(r.hidden, 0)
    }

    func testHiddenPhrasesAreCountedAndTheLabelGetsRoom() {
        let phrases = (0..<8).map { _ in "xxxxxx" }
        let r = fit(phrases, width: 20)
        XCTAssertGreaterThan(r.hidden, 0)
        XCTAssertEqual(r.lines.flatMap { $0 }.count + r.hidden, 8)
        let last = r.lines.last!
        let used = Double(last.count * 6 + (last.count - 1) * 3)
        XCTAssertLessThanOrEqual(used + 3 + Double("+\(r.hidden) more".count), 20)
        for line in r.lines {
            XCTAssertLessThanOrEqual(Double(line.count * 6 + (line.count - 1) * 3), 20)
        }
    }

    func testTheFirstPhraseIsAlwaysShown() {
        let r = fit(["a-very-long-main-phrase", "b"], width: 10)
        XCTAssertEqual(r.lines.first?.first, "a-very-long-main-phrase")
    }
}
