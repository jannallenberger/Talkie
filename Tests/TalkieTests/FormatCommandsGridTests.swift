import AppKit
import AVFoundation
import XCTest
@testable import Talkie

/// "Format while you dictate", wave 3: phrases in every transcription language, the
/// phrase book (synonyms, on/off, user-made commands, conflicts), user-made command
/// rendering, snippets as fixed-text commands, cross-language span readings and the
/// pill's format state.
final class FormatPhraseTableTests: XCTestCase {

    private let book = FormatPhraseBook.builtIn

    func testEveryLanguageHasPhrasesForEveryCommand() {
        for language in FormatPhrases.languages {
            for preset in FormatPreset.allCases {
                XCTAssertFalse(FormatPhrases.phrases(preset, language: language).isEmpty, "\(preset) \(language)")
            }
            XCTAssertFalse(FormatPhrases.endPhrases(language: language).isEmpty, language)
        }
    }

    /// Every phrase in every language resolves to its own command — this catches two
    /// commands sharing (or fuzzily colliding on) a phrase across languages.
    func testEveryPhraseInEveryLanguageMatchesItsOwnCommand() {
        for preset in FormatPreset.allCases {
            for phrase in preset.allPhrases {
                XCTAssertEqual(FormatPhraseMatcher.match(phrase, book: book), .apply(preset), "\"\(phrase)\"")
            }
        }
        for phrase in FormatPhrases.allEndPhrases {
            XCTAssertEqual(FormatPhraseMatcher.match(phrase, book: book), .end, "\"\(phrase)\"")
        }
    }

    func testNoTwoCommandsShareANormalisedPhrase() {
        var seen: [String: FormatCommandOwner] = [:]
        for e in book.entries {
            if let other = seen[e.joined] { XCTAssertEqual(other, e.owner, "\"\(e.joined)\"") }
            seen[e.joined] = e.owner
        }
    }

    func testCarrierWordsInOtherLanguages() {
        XCTAssertEqual(FormatPhraseMatcher.match("Liste à puces, s'il vous plaît", book: book), .apply(.bulletList))
        XCTAssertEqual(FormatPhraseMatcher.match("en majuscules", book: book), .apply(.allCaps))
        XCTAssertEqual(FormatPhraseMatcher.match("entre comillas por favor", book: book), .apply(.quotes))
        XCTAssertEqual(FormatPhraseMatcher.match("come titolo", book: book), .apply(.heading))
        XCTAssertEqual(FormatPhraseMatcher.match("em inglês", book: book), .apply(.translateToEnglish))
        XCTAssertEqual(FormatPhraseMatcher.match("in het Duits", book: book), .apply(.translateToGerman))
        XCTAssertEqual(FormatPhraseMatcher.match("번호 목록", book: book), .apply(.numberedList))
    }

    func testUnspacedScriptsMatchTheLongestContainedPhrase() {
        XCTAssertEqual(FormatPhraseMatcher.match("箇条書きで", book: book), .apply(.bulletList))
        XCTAssertEqual(FormatPhraseMatcher.match("请用编号列表", book: book), .apply(.numberedList))   // not "列表"
        XCTAssertEqual(FormatPhraseMatcher.match("かぎかっこで", book: book), .apply(.quotes))
        XCTAssertNil(FormatPhraseMatcher.match("今日はいい天気", book: book))
    }

    func testShownPhraseFollowsTheUILanguage() {
        XCTAssertEqual(FormatPreset.bulletList.shownPhrase(uiLanguageCode: "fr"), "liste à puces")
        XCTAssertEqual(FormatPreset.bulletList.shownPhrase(uiLanguageCode: "pt-BR"), "com marcadores")
        XCTAssertEqual(FormatPreset.bulletList.shownPhrase(uiLanguageCode: "zh-Hans"), "项目符号")
        XCTAssertEqual(FormatPreset.bulletList.shownPhrase(uiLanguageCode: "sv"), "bullet points")
        XCTAssertEqual(FormatPreset.bulletList.shownPhrase(uiLanguageCode: nil), "bullet points")
    }
}

final class FormatPhraseBookTests: XCTestCase {

    func testSynonymsMatchLikeBuiltInPhrases() {
        let book = FormatPhraseBook(synonyms: ["bulletList": ["tick marks"]])
        XCTAssertEqual(FormatPhraseMatcher.match("tick marks", book: book), .apply(.bulletList))
        XCTAssertEqual(FormatPhraseMatcher.match("okay tick marks please", book: book), .apply(.bulletList))
        XCTAssertNil(FormatPhraseMatcher.match("tick marks", book: .builtIn))
    }

    func testSwitchedOffCommandIsNotMatched() {
        let book = FormatPhraseBook(disabledPresets: [.heading])
        XCTAssertNil(FormatPhraseMatcher.match("heading", book: book))
        XCTAssertEqual(FormatPhraseMatcher.match("bullet points", book: book), .apply(.bulletList))
    }

    func testUserCommandsMatchAndDisabledOnesDoNot() {
        let shout = UserCommand(name: "Shout", phrases: ["shout it"], action: .textCase(.upper))
        var off = UserCommand(name: "Sign", phrases: ["my sig"], action: .insert(text: "Bye"))
        off.enabled = false
        let book = FormatPhraseBook(userCommands: [shout, off])
        XCTAssertEqual(FormatPhraseMatcher.match("shout it", book: book), .user(shout))
        XCTAssertNil(FormatPhraseMatcher.match("my sig", book: book))
    }

    func testDuplicatesAcrossCommandsAreRefusedWithAReason() {
        let shout = UserCommand(name: "Shout", phrases: ["yell please"], action: .textCase(.upper))
        let book = FormatPhraseBook(synonyms: ["bulletList": ["tick marks"]], userCommands: [shout])
        XCTAssertEqual(book.refusal(for: "in quotes", owner: .preset(.bulletList)),
                       .usedBy(FormatPreset.quotes.displayName))
        XCTAssertEqual(book.refusal(for: "Anführungszeichen!", owner: .user(shout.id)),
                       .usedBy(FormatPreset.quotes.displayName))
        XCTAssertEqual(book.refusal(for: "dot point", owner: .user(shout.id)),          // fuzzy collision
                       .usedBy(FormatPreset.bulletList.displayName))
        XCTAssertEqual(book.refusal(for: "yell", owner: .preset(.allCaps)), .usedBy("Shout"))
        // Within the misrecognition tolerance of another command counts as taken too
        // ("shout" is one letter from "short").
        XCTAssertEqual(book.refusal(for: "shout it", owner: .user(shout.id)), .usedBy(FormatPreset.shorter.displayName))
        XCTAssertEqual(book.refusal(for: "Schluss", owner: .preset(.allCaps)), .usedBy(FormatCommand.end.displayName))
        XCTAssertEqual(book.refusal(for: "please", owner: .preset(.allCaps)), .onlyFillerWords)
        XCTAssertEqual(book.refusal(for: "Tick marks.", owner: .preset(.bulletList)), .alreadyListed)
        XCTAssertNil(book.refusal(for: "make it loud", owner: .preset(.allCaps)))
        XCTAssertFalse(FormatPhraseBook.Refusal.usedBy("Shout").message.isEmpty)
    }

    func testBestAcrossReadings() {
        let book = FormatPhraseBook.builtIn
        // The German recognizer mangled an English command; the English reading wins.
        XCTAssertEqual(FormatPhraseMatcher.bestAcross(["Bulletin Pünktchen", "bullet points"], book: book),
                       .apply(.bulletList))
        // A whole-utterance reading beats a word run in another reading.
        XCTAssertEqual(FormatPhraseMatcher.bestAcross(["so heading then", "all caps"], book: book), .apply(.allCaps))
        // Equally good, different commands: the live (first) reading decides.
        XCTAssertEqual(FormatPhraseMatcher.bestAcross(["heading", "all caps"], book: book), .apply(.heading))
        XCTAssertNil(FormatPhraseMatcher.bestAcross(["banana", "Banane"], book: book))
        XCTAssertNil(FormatPhraseMatcher.bestAcross([], book: book))
    }
}

final class UserCommandTests: XCTestCase {

    private func w(_ text: String, _ start: Double, _ end: Double) -> FormatWord {
        FormatWord(text: text, start: start, end: end, segment: 0)
    }

    func testRenderers() {
        let wrap = UserCommandRenderer.render(.wrap(before: "**", after: "**"), text: "very important.", languageCode: "en")
        XCTAssertEqual(wrap, .init(text: "**very important**", isBlock: false))
        let before = UserCommandRenderer.render(.wrap(before: "Note: ", after: ""), text: "call Anna.", languageCode: "en")
        XCTAssertEqual(before?.text, "Note: call Anna.")
        XCTAssertEqual(UserCommandRenderer.render(.textCase(.upper), text: "straße", languageCode: "de")?.text, "STRASSE")
        XCTAssertEqual(UserCommandRenderer.render(.textCase(.lower), text: "Read Me", languageCode: "en")?.text, "read me")
        XCTAssertEqual(UserCommandRenderer.render(.textCase(.title), text: "the year-end report", languageCode: "en")?.text,
                       "The Year-End Report")
        XCTAssertEqual(UserCommandRenderer.render(.linePrefix("> "), text: "First point. Second point.", languageCode: "en"),
                       .init(text: "> First point\n> Second point", isBlock: true))
        XCTAssertNil(UserCommandRenderer.render(.rewrite(instruction: "as a haiku"), text: "x", languageCode: "en"))
        let fixed = UserCommandRenderer.render(.insert(text: "Today is {date}"), text: "", languageCode: "en",
                                               now: Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(fixed)
        XCTAssertFalse(fixed!.text.contains("{date}"))
        XCTAssertEqual(UserCommandRenderer.linePrefixed("• ", items: ["milk", "eggs"]), "• Milk\n• Eggs")
    }

    func testCodableRoundTrip() throws {
        let commands = [
            UserCommand(name: "A", phrases: ["a1", "a2"], action: .wrap(before: "[", after: "]")),
            UserCommand(name: "B", phrases: ["b"], action: .linePrefix("> ")),
            UserCommand(name: "C", phrases: ["c"], action: .textCase(.title)),
            UserCommand(name: "D", phrases: ["d"], action: .rewrite(instruction: "friendlier")),
        ]
        let data = try JSONEncoder().encode(commands)
        XCTAssertEqual(try JSONDecoder().decode([UserCommand].self, from: data), commands)
        XCTAssertTrue(commands[3].usesModel)
        XCTAssertFalse(commands[0].usesModel)
    }

    func testLayoutAppliesAUserFormatAndPlacesAFixedText() {
        let shout = UserCommand(name: "Shout", phrases: ["shout it"], action: .textCase(.upper))
        let sign = UserCommand(name: "Signature", phrases: ["my signature"], action: .insert(text: "— Alex"))
        let book = FormatPhraseBook(userCommands: [shout, sign])
        let words = [w("hello", 0, 0.4), w(" shout", 1.0, 1.3), w(" it", 1.35, 1.6), w(" now", 2.0, 2.3),
                     w(" my", 3.0, 3.2), w(" signature", 3.25, 3.8), w(" done", 4.4, 4.7)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0.9, end: 1.7), .span(start: 2.9, end: 3.9)],
                                           book: book)
        XCTAssertEqual(layout.resolutions, [.appliedUser(shout), .inserted(sign)])
        XCTAssertEqual(layout.regions.map(\.style), [nil, .user(shout), .user(sign), .user(shout)])
        XCTAssertEqual(layout.regions.map { FormatTimeline.text(of: $0.words) }, ["hello", "now", "", "done"])
    }

    func testAssemblerRendersUserCommandsAndFallsBackForARejectedRewrite() async {
        let shout = UserCommand(name: "Shout", phrases: ["shout it"], action: .textCase(.upper))
        let poem = UserCommand(name: "Poem", phrases: ["as a poem"], action: .rewrite(instruction: "a poem"))
        let sign = UserCommand(name: "Signature", phrases: ["my signature"], action: .insert(text: "— Alex"))
        let book = FormatPhraseBook(userCommands: [shout, poem, sign])
        let seg = TimedSegment(text: "hi shout it loud my signature", start: 0, end: 5, words: [
            SegmentWord(text: "hi", start: 0, end: 0.3),
            SegmentWord(text: " shout", start: 1.0, end: 1.3), SegmentWord(text: " it", start: 1.35, end: 1.6),
            SegmentWord(text: " loud", start: 2.0, end: 2.4),
            SegmentWord(text: " my", start: 3.0, end: 3.2), SegmentWord(text: " signature", start: 3.25, end: 3.8),
        ])
        let plan = await FormatDictationAssembler.assemble(
            segments: [seg], marks: [.span(start: 0.9, end: 1.7), .span(start: 2.9, end: 3.9)], book: book,
            clean: nil, postProcessFormatted: { $0 }, languageCode: "en", userName: "",
            model: { _, _, _ in nil }, rewrite: { _, _, _ in nil })
        let text = FormatAssembly.substitute(processed: plan.normalStream, parts: plan.parts)
        XCTAssertEqual(text, "hi LOUD — Alex")
        XCTAssertEqual(plan.plainRaw, "hi loud")

        let seg2 = TimedSegment(text: "as a poem roses are red", start: 0, end: 3, words: [
            SegmentWord(text: "as", start: 0, end: 0.2), SegmentWord(text: " a", start: 0.25, end: 0.3),
            SegmentWord(text: " poem", start: 0.35, end: 0.7),
            SegmentWord(text: " roses", start: 1.2, end: 1.5), SegmentWord(text: " are", start: 1.55, end: 1.7),
            SegmentWord(text: " red", start: 1.75, end: 2.0),
        ])
        let fell = await FormatDictationAssembler.assemble(
            segments: [seg2], marks: [.span(start: 0, end: 0.8)], book: book,
            clean: nil, postProcessFormatted: { $0 }, languageCode: "en", userName: "",
            model: { _, _, _ in nil }, rewrite: { _, _, _ in nil })
        XCTAssertTrue(fell.modelFallback)
        XCTAssertEqual(FormatAssembly.substitute(processed: fell.normalStream, parts: fell.parts), "roses are red")
        let ran = await FormatDictationAssembler.assemble(
            segments: [seg2], marks: [.span(start: 0, end: 0.8)], book: book,
            clean: nil, postProcessFormatted: { $0 }, languageCode: "en", userName: "",
            model: { _, _, _ in nil }, rewrite: { instruction, text, _ in "\(instruction): \(text)" })
        XCTAssertFalse(ran.modelFallback)
        XCTAssertEqual(FormatAssembly.substitute(processed: ran.normalStream, parts: ran.parts), "a poem: roses are red")
    }

    func testSpanAlternativesDecideWhenTheLiveReadingIsMangled() {
        let words = [w("Ich", 0, 0.3), w(" brauche", 0.35, 0.8), w(" Bulletin", 1.2, 1.5), w(" Pünktchen", 1.55, 2.0),
                     w(" Milch", 2.5, 2.9)]
        let marks: [FormatMark] = [.span(start: 1.1, end: 2.1)]
        let without = FormatTimeline.layout(words: words, marks: marks, book: .builtIn)
        XCTAssertEqual(without.resolutions, [.notRecognised("Bulletin Pünktchen")])
        let with = FormatTimeline.layout(words: words, marks: marks, book: .builtIn,
                                         alternatives: { _ in ["bullet points"] })
        XCTAssertEqual(with.resolutions, [.applied(.bulletList)])
        XCTAssertEqual(with.regions.map(\.format), [nil, .bulletList])
        XCTAssertEqual(FormatTimeline.spanTexts(words: words, marks: marks), ["Bulletin Pünktchen"])
    }
}

@MainActor
final class MacroAsUserCommandTests: XCTestCase {

    func testOldSnippetJSONDecodesAndBecomesAFixedTextCommand() throws {
        let json = #"[{"id":"7C0B5F0E-2A62-4C55-9C3B-6C3C55B7E0A1","trigger":"my address","expansion":"1 Main St"}]"#
        let macros = try JSONDecoder().decode([Macro].self, from: Data(json.utf8))
        XCTAssertEqual(macros.count, 1)
        let command = macros[0].userCommand
        XCTAssertEqual(command.id, macros[0].id)
        XCTAssertEqual(command.name, "my address")
        XCTAssertEqual(command.phrases, ["my address"])
        XCTAssertEqual(command.action, .insert(text: "1 Main St"))
        XCTAssertTrue(command.enabled)
        XCTAssertTrue(command.isInsertion)
    }

    func testFixedTextCommandRoundTripsThroughAMacro() {
        let command = UserCommand(name: "Address", phrases: ["my address", "where I live"],
                                  action: .insert(text: "1 Main St, {date}"))
        let macro = Macro(command)
        XCTAssertEqual(macro.trigger, "my address")
        XCTAssertEqual(macro.synonyms, ["where I live"])
        XCTAssertEqual(macro.userCommand, command)
    }

    func testSnippetSynonymsAndOffSwitchInOwnDictation() {
        let store = MacroStore()
        let saved = store.macros
        for m in saved { store.delete(m) }
        defer {
            for m in store.macros { store.delete(m) }
            for m in saved { store.upsert(m) }
        }
        var command = UserCommand(name: "Address", phrases: ["my address", "where I live"],
                                  action: .insert(text: "1 Main St"))
        store.upsert(Macro(command))
        XCTAssertEqual(store.match("Where I live."), "1 Main St")
        XCTAssertEqual(store.match("my address"), "1 Main St")
        command.enabled = false
        store.upsert(Macro(command))
        XCTAssertNil(store.match("my address"))
        store.delete(id: command.id)
        XCTAssertTrue(store.macros.isEmpty)
    }
}

final class FormatCrossLanguageTests: XCTestCase {

    func testOnlyWithMoreThanOneLanguage() {
        XCTAssertFalse(FormatCrossLanguage.shouldRecognise(spokenLanguages: ["de-DE"]))
        XCTAssertFalse(FormatCrossLanguage.shouldRecognise(spokenLanguages: ["en-US", "en-GB"]))
        XCTAssertTrue(FormatCrossLanguage.shouldRecognise(spokenLanguages: ["de-DE", "en-US"]))
        XCTAssertEqual(FormatCrossLanguage.otherLanguages(spokenLanguages: ["de-DE", "en-US", "fr-FR"],
                                                          currentLocaleID: "de-DE"), ["en-US", "fr-FR"])
        XCTAssertEqual(FormatCrossLanguage.otherLanguages(spokenLanguages: ["de-DE"], currentLocaleID: "de-DE"), [])
    }

    func testBufferRangeCoversTheSpan() {
        let frames = Array(repeating: 1600, count: 50)            // 0.1 s buffers at 16 kHz
        XCTAssertEqual(FormatCrossLanguage.bufferRange(frameCounts: frames, sampleRate: 16_000, from: 1.0, to: 2.0), 10..<20)
        XCTAssertEqual(FormatCrossLanguage.bufferRange(frameCounts: frames, sampleRate: 16_000, from: 1.05, to: 1.25), 10..<13)
        XCTAssertEqual(FormatCrossLanguage.bufferRange(frameCounts: frames, sampleRate: 16_000, from: -0.3, to: 0.15), 0..<2)
        XCTAssertEqual(FormatCrossLanguage.bufferRange(frameCounts: frames, sampleRate: 16_000, from: 4.8, to: 9), 48..<50)
        XCTAssertEqual(FormatCrossLanguage.bufferRange(frameCounts: frames, sampleRate: 16_000, from: 7, to: 9), 0..<0)
        XCTAssertEqual(FormatCrossLanguage.bufferRange(frameCounts: frames, sampleRate: 16_000, from: 2, to: 1), 0..<0)
        XCTAssertEqual(FormatCrossLanguage.bufferRange(frameCounts: [], sampleRate: 16_000, from: 0, to: 1), 0..<0)
    }

    func testSliceOfRealBuffers() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffers = (0..<20).map { _ -> AVAudioPCMBuffer in
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            b.frameLength = 1600
            return b
        }
        XCTAssertEqual(TranscriptionEngine.slice(buffers, from: 0.5, to: 1.0).count, 5)
        XCTAssertTrue(TranscriptionEngine.slice([], from: 0, to: 1).isEmpty)
    }

    func testWaitIsBoundedAndNeverBlocks() async {
        let fast = Task<[String], Never> { ["bullet points"] }
        let fastValue = await FormatCrossLanguage.value(of: fast, within: 1)
        XCTAssertEqual(fastValue, ["bullet points"])
        let slow = Task<[String], Never> {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return ["late"]
        }
        let started = Date()
        let slowValue = await FormatCrossLanguage.value(of: slow, within: 0.2)
        XCTAssertNil(slowValue)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        let none = await FormatCrossLanguage.value(of: fast, within: 0)
        XCTAssertNil(none)
    }
}

final class PillFormatStateTests: XCTestCase {

    func testKeyDownTurnsBlueImmediatelyWithTheHint() {
        var s = PillFormatState()
        XCTAssertFalse(s.waveformIsBlue)
        XCTAssertNil(s.chip)
        s.handle(.keyDown)
        XCTAssertTrue(s.textIsBlue)
        XCTAssertTrue(s.waveformIsBlue)
        XCTAssertTrue(s.showsListeningHint)
        XCTAssertNil(s.chip)
    }

    func testReleaseKeepsCheckingUntilResolved() {
        var s = PillFormatState()
        s.handle(.keyDown)
        s.handle(.spanReleased)
        XCTAssertTrue(s.textIsBlue)
        XCTAssertTrue(s.showsListeningHint)
    }

    func testRecognisedFormatConfirmsThenKeepsTheChip() {
        var s = PillFormatState()
        s.handle(.keyDown)
        s.handle(.spanReleased)
        s.handle(.resolved(.format("Bullet list")))
        XCTAssertFalse(s.textIsBlue)
        XCTAssertTrue(s.waveformIsBlue)
        XCTAssertFalse(s.showsListeningHint)
        XCTAssertEqual(s.chip?.name, "Bullet list")
        XCTAssertEqual(s.chip?.confirming, true)
        s.handle(.flashExpired)
        XCTAssertEqual(s.chip?.name, "Bullet list")
        XCTAssertEqual(s.chip?.confirming, false)
        XCTAssertTrue(s.waveformIsBlue)
    }

    func testNotRecognisedIsItsOwnStateAndKeepsTheActiveFormat() {
        var s = PillFormatState()
        s.handle(.resolved(.format("ALL CAPS")))
        s.handle(.flashExpired)
        s.handle(.keyDown)
        XCTAssertEqual(s.chip?.name, "ALL CAPS")      // stays visible while listening again
        s.handle(.spanReleased)
        s.handle(.resolved(.notRecognised))
        XCTAssertTrue(s.showsNotRecognised)
        XCTAssertEqual(s.chip?.name, "ALL CAPS")
        XCTAssertFalse(s.showsListeningHint)
        s.handle(.flashExpired)
        XCTAssertFalse(s.showsNotRecognised)
        XCTAssertEqual(s.chip?.name, "ALL CAPS")
    }

    func testNotRecognisedWithoutAFormat() {
        var s = PillFormatState()
        s.handle(.keyDown)
        s.handle(.spanReleased)
        s.handle(.resolved(.notRecognised))
        XCTAssertTrue(s.showsNotRecognised)
        XCTAssertNil(s.chip)
        XCTAssertFalse(s.waveformIsBlue)
    }

    func testInsertedConfirmsWithoutChangingTheFormat() {
        var s = PillFormatState()
        s.handle(.resolved(.format("Heading")))
        s.handle(.flashExpired)
        s.handle(.keyDown)
        s.handle(.spanReleased)
        s.handle(.resolved(.inserted("Signature")))
        XCTAssertEqual(s.chip?.name, "Signature")
        XCTAssertEqual(s.chip?.confirming, true)
        s.handle(.flashExpired)
        XCTAssertEqual(s.chip?.name, "Heading")
    }

    func testEndingRemovesTheChip() {
        var s = PillFormatState()
        s.handle(.resolved(.format("Heading")))
        s.handle(.resolved(.ended))
        XCTAssertNil(s.chip)
        XCTAssertFalse(s.waveformIsBlue)

        s.handle(.resolved(.format("Heading")))
        s.handle(.tapped)
        XCTAssertNil(s.chip)
        XCTAssertFalse(s.waveformIsBlue)
    }

    func testCancelledHoldGoesBack() {
        var s = PillFormatState()
        s.handle(.keyDown)
        s.handle(.keyCancelled)
        XCTAssertEqual(s, PillFormatState())

        s.handle(.resolved(.format("Formal")))
        s.handle(.flashExpired)
        let active = s
        s.handle(.keyDown)
        s.handle(.keyCancelled)
        XCTAssertEqual(s, active)
    }

    func testSessionEndResetsEverything() {
        var s = PillFormatState()
        s.handle(.resolved(.format("Formal")))
        s.handle(.keyDown)
        s.handle(.sessionEnded)
        XCTAssertEqual(s, PillFormatState())
    }

    func testResolutionMapping() {
        let c = UserCommand(name: "Sig", phrases: ["sig"], action: .insert(text: "x"))
        let u = UserCommand(name: "Loud", phrases: ["loud"], action: .textCase(.upper))
        XCTAssertEqual(PillFormatState.resolution(.applied(.bulletList)), .format(FormatPreset.bulletList.displayName))
        XCTAssertEqual(PillFormatState.resolution(.appliedUser(u)), .format("Loud"))
        XCTAssertEqual(PillFormatState.resolution(.inserted(c)), .inserted("Sig"))
        XCTAssertEqual(PillFormatState.resolution(.ended), .ended)
        XCTAssertEqual(PillFormatState.resolution(.notRecognised("x")), .notRecognised)
    }

    func testLivePreviewUsesOtherReadings() {
        XCTAssertEqual(FormatLivePreview.resolve("Bulletin Pünktchen", book: .builtIn), .notRecognised("Bulletin Pünktchen"))
        XCTAssertEqual(FormatLivePreview.resolve("Bulletin Pünktchen", alternatives: ["bullet points"], book: .builtIn),
                       .applied(.bulletList))
        XCTAssertEqual(FormatLivePreview.resolve("", alternatives: ["in quotes"], book: .builtIn), .applied(.quotes))
        XCTAssertEqual(FormatLivePreview.resolve("", book: .builtIn), .ended)
    }
}

final class PillPaletteTests: XCTestCase {

    /// The format blue on the pill: bars, hint text and chip text must clear 4.5:1 on
    /// the black pill, on the hold-to-lock fill, and on the chips' own fills.
    func testFormatBlueContrastOnThePill() {
        let blue = PillPalette.formatBlue
        let black = PillPalette.pillBackground
        XCTAssertGreaterThanOrEqual(PillPalette.contrast(blue, black), PillPalette.minimumContrast)
        let latch = PillPalette.over(PillPalette.recordingRed[1], alpha: PillPalette.latchFillOpacity, black)
        XCTAssertGreaterThanOrEqual(PillPalette.contrast(blue, latch), PillPalette.minimumContrast)
        for alpha in [PillPalette.chipFillOpacity, PillPalette.confirmingChipFillOpacity] {
            let chip = PillPalette.over(blue, alpha: alpha, black)
            XCTAssertGreaterThanOrEqual(PillPalette.contrast(blue, chip), PillPalette.minimumContrast, "\(alpha)")
        }
    }

    /// Clearly not the normal (red) waveform, in either appearance.
    func testFormatBlueIsClearlyDifferentFromTheNormalWaveform() {
        for red in PillPalette.recordingRed {
            XCTAssertGreaterThan(PillPalette.distance(PillPalette.formatBlue, red), 200)
        }
    }

    /// It is the brand blue's dark-surface value, at full strength.
    @MainActor
    func testFormatBlueIsTheBrandBluesDarkValue() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var resolved: NSColor?
        dark.performAsCurrentDrawingAppearance {
            resolved = NSColor(Theme.coral).usingColorSpace(.sRGB)
        }
        let c = try XCTUnwrap(resolved)
        XCTAssertEqual(c.redComponent * 255, PillPalette.formatBlue.r, accuracy: 1)
        XCTAssertEqual(c.greenComponent * 255, PillPalette.formatBlue.g, accuracy: 1)
        XCTAssertEqual(c.blueComponent * 255, PillPalette.formatBlue.b, accuracy: 1)
        XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.001)
    }
}
