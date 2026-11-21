import XCTest
@testable import Talkie

/// "Format while you dictate" — the pure core: phrase matcher, command-key state
/// machine, span/region model, deterministic formatters and the paste-time assembly.
final class FormatPhraseMatcherTests: XCTestCase {

    private func assertMatch(_ spoken: String, _ expected: FormatCommand?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(FormatPhraseMatcher.match(spoken), expected, "\"\(spoken)\"", file: file, line: line)
    }

    /// Every phrase in the table must resolve to its own preset — this is what catches
    /// two presets accidentally sharing (or fuzzily colliding on) a phrase.
    func testEveryPhraseMatchesItsOwnPreset() {
        for preset in FormatPreset.allCases {
            for phrase in preset.germanPhrases + preset.englishPhrases {
                assertMatch(phrase, .apply(preset))
            }
        }
        for phrase in FormatCommand.germanEndPhrases + FormatCommand.englishEndPhrases {
            assertMatch(phrase, .end)
        }
    }

    func testGermanPhrasesWithCarrierWordsAndPunctuation() {
        assertMatch("In Stichpunkten, bitte.", .apply(.bulletList))
        assertMatch("als E-Mail", .apply(.email))
        assertMatch("Als E Mail.", .apply(.email))
        assertMatch("Alles groß", .apply(.allCaps))
        assertMatch("alles gross", .apply(.allCaps))
        assertMatch("Caps Lock", .apply(.allCaps))
        assertMatch("In Anführungszeichen", .apply(.quotes))
        assertMatch("in Klammern bitte", .apply(.parentheses))
        assertMatch("Mach eine Überschrift", .apply(.heading))
        assertMatch("Nummerierte Liste.", .apply(.numberedList))
        assertMatch("auf Englisch", .apply(.translateToEnglish))
        assertMatch("Auf Deutsch, bitte", .apply(.translateToGerman))
        assertMatch("jetzt wieder normal", .end)
        assertMatch("Ende.", .end)
    }

    func testEnglishPhrases() {
        assertMatch("Bullet points.", .apply(.bulletList))
        assertMatch("make it a numbered list", .apply(.numberedList))
        assertMatch("To do list", .apply(.todoList))
        assertMatch("ALL CAPS", .apply(.allCaps))
        assertMatch("in quotes", .apply(.quotes))
        assertMatch("as an email please", .apply(.email))
        assertMatch("make it shorter", .apply(.shorter))
        assertMatch("in English", .apply(.translateToEnglish))
        assertMatch("plain text", .end)
    }

    func testMisrecognisedVariants() {
        assertMatch("Stichpunkt", .apply(.bulletList))           // one letter short
        assertMatch("Stich Punkten", .apply(.bulletList))        // split compound
        assertMatch("Gänsefüsschen", .apply(.quotes))            // ss for ß
        assertMatch("Gänse Füßchen", .apply(.quotes))
        assertMatch("Ueberschrift", .apply(.heading))            // ue spelling
        assertMatch("Bullet point", .apply(.bulletList))
        assertMatch("numbered lists", .apply(.numberedList))
        assertMatch("Anführungszeichen.", .apply(.quotes))
        assertMatch("formel", .apply(.formal))                    // closer to formal than normal
        assertMatch("normale", .end)
    }

    func testNonCommandsDoNotMatch() {
        assertMatch("", nil)
        assertMatch("okay", nil)                                  // only filler
        assertMatch("the quick brown fox jumps", nil)
        assertMatch("Wir treffen uns morgen um neun", nil)
        assertMatch("and", nil)                                   // short words never fuzzy-match ("end")
        assertMatch("cold", nil)                                  // not "code"
    }

    func testAmbiguousSpanIsNotRecognised() {
        assertMatch("Liste oder Überschrift", nil)
    }

    func testWordRunInsideALongerUtterance() {
        assertMatch("okay jetzt dann Großbuchstaben", .apply(.allCaps))
    }
}

final class FormatKeyGestureTests: XCTestCase {

    func testFirstPressSwitchesListeningOnAndSecondPressSwitchesItOff() {
        var g = FormatKeyGesture()
        XCTAssertEqual(g.keyDown(at: 10, othersHeld: false), .pressed(at: 10))
        XCTAssertTrue(g.isHeld)
        XCTAssertTrue(g.isListening)
        // Releasing the key changes nothing: listening stays on, nothing is held.
        XCTAssertNil(g.keyUp(at: 10.1))
        XCTAssertFalse(g.isHeld)
        XCTAssertTrue(g.isListening)
        // The second press ends it; the command was said up to that key-down.
        XCTAssertNil(g.keyDown(at: 12, othersHeld: false))
        XCTAssertTrue(g.isListening)
        XCTAssertEqual(g.keyUp(at: 12.1), .span(start: 10, end: 12))
        XCTAssertFalse(g.isListening)
    }

    func testHowLongEitherPressIsHeldDoesNotMatter() {
        // Held for two seconds while speaking (the old habit): still just "on".
        var g = FormatKeyGesture()
        _ = g.keyDown(at: 0, othersHeld: false)
        XCTAssertNil(g.keyUp(at: 2))
        XCTAssertTrue(g.isListening)
        // A long second press ends at its key-down, not at its release.
        _ = g.keyDown(at: 3, othersHeld: false)
        XCTAssertEqual(g.keyUp(at: 5), .span(start: 0, end: 3))
    }

    func testQuickDoublePressIsATap() {
        var g = FormatKeyGesture()
        _ = g.keyDown(at: 5, othersHeld: false)
        _ = g.keyUp(at: 5.08)
        _ = g.keyDown(at: 5.2, othersHeld: false)
        XCTAssertEqual(g.keyUp(at: 5.3), .tap(at: 5.2))
        XCTAssertFalse(g.isListening)
    }

    func testMinimumSpanBoundary() {
        var g = FormatKeyGesture()
        _ = g.keyDown(at: 0, othersHeld: false)
        _ = g.keyUp(at: 0.05)
        _ = g.keyDown(at: 0.25, othersHeld: false)
        XCTAssertEqual(g.keyUp(at: 0.3), .span(start: 0, end: 0.25))
        _ = g.keyDown(at: 1, othersHeld: false)
        _ = g.keyUp(at: 1.05)
        _ = g.keyDown(at: 1.249, othersHeld: false)
        XCTAssertEqual(g.keyUp(at: 1.3), .tap(at: 1.249))
    }

    func testOtherInputDuringTheFirstPressCancels() {
        var g = FormatKeyGesture()
        _ = g.keyDown(at: 0, othersHeld: false)
        g.otherInput()                     // e.g. Ctrl+C in another app
        XCTAssertEqual(g.keyUp(at: 2), .cancelled)
        XCTAssertFalse(g.isListening)
    }

    func testOtherModifierAlreadyDownCancels() {
        var g = FormatKeyGesture()
        XCTAssertNil(g.keyDown(at: 0, othersHeld: true))   // ⌘ then ⌃ → a chord
        XCTAssertFalse(g.isListening)
        XCTAssertEqual(g.keyUp(at: 1), .cancelled)
    }

    func testShortcutChordWhileListeningLeavesListeningOn() {
        var g = FormatKeyGesture()
        _ = g.keyDown(at: 0, othersHeld: false)
        _ = g.keyUp(at: 0.1)
        // Ctrl+C while listening: not the second press.
        XCTAssertNil(g.keyDown(at: 1, othersHeld: false))
        g.otherInput()
        XCTAssertNil(g.keyUp(at: 1.2))
        XCTAssertTrue(g.isListening)
        // ⌘ already down, then the command key: a chord as well.
        XCTAssertNil(g.keyDown(at: 2, othersHeld: true))
        XCTAssertNil(g.keyUp(at: 2.1))
        XCTAssertTrue(g.isListening)
        // The real second press still ends the span that began at the first press.
        _ = g.keyDown(at: 3, othersHeld: false)
        XCTAssertEqual(g.keyUp(at: 3.1), .span(start: 0, end: 3))
    }

    func testCancellationDoesNotLeakIntoTheNextPress() {
        var g = FormatKeyGesture()
        _ = g.keyDown(at: 0, othersHeld: false)
        g.otherInput()
        _ = g.keyUp(at: 1)
        XCTAssertEqual(g.keyDown(at: 2, othersHeld: false), .pressed(at: 2))
        XCTAssertNil(g.keyUp(at: 2.1))
        _ = g.keyDown(at: 3, othersHeld: false)
        XCTAssertEqual(g.keyUp(at: 3.1), .span(start: 2, end: 3))
    }

    func testOtherInputWhileTheKeyIsUpIsIgnored() {
        var g = FormatKeyGesture()
        g.otherInput()
        _ = g.keyDown(at: 0, othersHeld: false)
        _ = g.keyUp(at: 0.1)
        g.otherInput()                     // typing while listening spoils nothing
        _ = g.keyDown(at: 1, othersHeld: false)
        XCTAssertEqual(g.keyUp(at: 1.1), .span(start: 0, end: 1))
    }

    func testDuplicateDownAndStrayUp() {
        var g = FormatKeyGesture()
        XCTAssertNil(g.keyUp(at: 0))
        XCTAssertEqual(g.keyDown(at: 1, othersHeld: false), .pressed(at: 1))
        XCTAssertNil(g.keyDown(at: 1.1, othersHeld: false))    // dropped up — keep the first
        XCTAssertNil(g.keyUp(at: 2))
        XCTAssertTrue(g.isListening)
    }

    func testLostReleaseForgetsThePressAndKeepsListening() {
        var g = FormatKeyGesture()
        _ = g.keyDown(at: 0, othersHeld: false)
        g.releaseLost()                    // the key-up never arrived
        XCTAssertFalse(g.isHeld)
        XCTAssertTrue(g.isListening)
        _ = g.keyDown(at: 2, othersHeld: false)
        XCTAssertEqual(g.keyUp(at: 2.1), .span(start: 0, end: 2))
        // Lost on the second press: listening stays on until a complete press.
        _ = g.keyDown(at: 5, othersHeld: false)
        _ = g.keyUp(at: 5.1)
        _ = g.keyDown(at: 6, othersHeld: false)
        g.releaseLost()
        XCTAssertTrue(g.isListening)
        _ = g.keyDown(at: 7, othersHeld: false)
        XCTAssertEqual(g.keyUp(at: 7.1), .span(start: 5, end: 7))
    }

    func testResetSwitchesListeningOff() {
        var g = FormatKeyGesture()
        _ = g.keyDown(at: 0, othersHeld: false)
        XCTAssertTrue(g.reset())
        XCTAssertNil(g.keyUp(at: 1))
        XCTAssertFalse(g.reset())
        // Listening with the key released counts as in flight too.
        _ = g.keyDown(at: 2, othersHeld: false)
        _ = g.keyUp(at: 2.1)
        XCTAssertTrue(g.reset())
        XCTAssertFalse(g.isListening)
        XCTAssertEqual(g.keyDown(at: 3, othersHeld: false), .pressed(at: 3))
    }

    func testOtherModifiersHeldIgnoresCommandAndDictationKeys() {
        let command = FormatCommandKey.defaultKey          // Left Control, bit 0x1
        let dictation = ActivationKey.rightOption          // bit 0x40
        XCTAssertFalse(FormatCommandKey.otherModifiersHeld(rawFlags: 0x1 | 0x40, excluding: [command, dictation]))
        XCTAssertTrue(FormatCommandKey.otherModifiersHeld(rawFlags: 0x1 | 0x8, excluding: [command, dictation]))  // + Left ⌘
        XCTAssertTrue(FormatCommandKey.otherModifiersHeld(rawFlags: 0x2, excluding: [command, dictation]))        // Left ⇧
        XCTAssertFalse(FormatCommandKey.otherModifiersHeld(rawFlags: 0, excluding: [command, dictation]))
    }

    func testEffectiveCommandKeyNeverEqualsTheDictationKey() {
        XCTAssertEqual(FormatCommandKey.effective(stored: nil, dictationKey: .rightOption), FormatCommandKey.defaultKey)
        XCTAssertEqual(FormatCommandKey.effective(stored: nil, dictationKey: FormatCommandKey.defaultKey), .leftOption)
        XCTAssertEqual(FormatCommandKey.effective(stored: .rightControl, dictationKey: .rightOption), .rightControl)
        XCTAssertEqual(FormatCommandKey.effective(stored: .rightOption, dictationKey: .rightOption), FormatCommandKey.defaultKey)
        XCTAssertNotNil(FormatCommandKey.refusal(for: .rightOption, dictationKey: .rightOption))
        XCTAssertNil(FormatCommandKey.refusal(for: .rightControl, dictationKey: .rightOption))
    }
}

final class FormatTimelineTests: XCTestCase {

    private func w(_ text: String, _ start: Double, _ end: Double, seg: Int = 0) -> FormatWord {
        FormatWord(text: text, start: start, end: end, segment: seg)
    }

    /// "Ich brauche [⌃ in Stichpunkten] Milch … Eier … Brot"
    private var shoppingWords: [FormatWord] {
        [w("Ich", 0.0, 0.3), w(" brauche", 0.35, 0.8),
         w(" in", 1.2, 1.35), w(" Stichpunkten", 1.4, 2.0),
         w(" Milch", 2.5, 2.9), w(" Eier", 3.8, 4.1), w(" Brot", 5.0, 5.3)]
    }

    func testNoMarksIsOneUntouchedNormalRegion() {
        let layout = FormatTimeline.layout(words: shoppingWords, marks: [])
        XCTAssertEqual(layout.regions, [FormatRegion(format: nil, words: shoppingWords)])
        XCTAssertEqual(FormatTimeline.text(of: layout.regions[0].words), "Ich brauche in Stichpunkten Milch Eier Brot")
        XCTAssertTrue(layout.resolutions.isEmpty)
    }

    func testCommandSpanStartsAListAndItsWordsAreRemoved() {
        let layout = FormatTimeline.layout(words: shoppingWords, marks: [.span(start: 1.1, end: 2.1)])
        XCTAssertEqual(layout.resolutions, [.applied(.bulletList)])
        XCTAssertEqual(layout.regions.count, 2)
        XCTAssertNil(layout.regions[0].format)
        XCTAssertEqual(FormatTimeline.text(of: layout.regions[0].words), "Ich brauche")
        XCTAssertEqual(layout.regions[1].format, .bulletList)
        XCTAssertEqual(FormatTimeline.pauseChunks(of: layout.regions[1].words), ["Milch", "Eier", "Brot"])
        let all = layout.regions.flatMap(\.words).map(\.text).joined()
        XCTAssertFalse(all.contains("Stichpunkten"))
    }

    func testTapEndsTheMode() {
        var words = shoppingWords
        words.append(w(" danke", 7.0, 7.3))
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 1.1, end: 2.1), .endTap(at: 6.0)])
        XCTAssertEqual(layout.regions.map(\.format), [nil, .bulletList, nil])
        XCTAssertEqual(FormatTimeline.text(of: layout.regions[2].words), "danke")
    }

    func testSpokenEndCommandEndsTheMode() {
        let words = [w("Hallo", 0, 0.4), w(" alles", 1.0, 1.3), w(" groß", 1.35, 1.7),
                     w(" wichtig", 2.0, 2.5), w(" normal", 3.0, 3.4), w(" weiter", 4.0, 4.4)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0.9, end: 1.8), .span(start: 2.9, end: 3.5)])
        XCTAssertEqual(layout.resolutions, [.applied(.allCaps), .ended])
        XCTAssertEqual(layout.regions.map(\.format), [nil, .allCaps, nil])
        XCTAssertEqual(layout.regions.map { FormatTimeline.text(of: $0.words) }, ["Hallo", "wichtig", "weiter"])
    }

    func testAnotherCommandReplacesTheMode() {
        let words = [w("bullet", 0, 0.3), w(" points", 0.35, 0.6), w(" one", 1.0, 1.2),
                     w(" all", 2.0, 2.2), w(" caps", 2.25, 2.5), w(" loud", 3.0, 3.3)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0, end: 0.7), .span(start: 1.9, end: 2.6)])
        XCTAssertEqual(layout.regions.map(\.format), [.bulletList, .allCaps])
    }

    func testRepeatingTheSameFormatStartsANewRegion() {
        let words = [w("list", 0, 0.3), w(" a", 1.0, 1.2), w(" list", 2.0, 2.3), w(" b", 3.0, 3.2)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0, end: 0.4), .span(start: 1.9, end: 2.4)])
        XCTAssertEqual(layout.regions.map(\.format), [.bulletList, .bulletList])
    }

    func testUnrecognisedSpanChangesNothingAndItsWordsStayAsText() {
        let words = [w("one", 0, 0.3), w(" banana", 1.0, 1.4), w(" two", 2.0, 2.3)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0.9, end: 1.5)])
        XCTAssertEqual(layout.resolutions, [.notRecognised("banana")])
        XCTAssertEqual(layout.regions.count, 1)
        // Nothing the user said is lost: the words stay in the text.
        XCTAssertEqual(FormatTimeline.text(of: layout.regions[0].words), "one banana two")
    }

    func testSpanWithNoWordsEndsTheMode() {
        let words = [w("caps", 0, 0.3), w(" yes", 1.0, 1.3), w(" no", 3.0, 3.3)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0, end: 0.4), .span(start: 2.0, end: 2.5)])
        XCTAssertEqual(layout.resolutions, [.applied(.allCaps), .ended])
        XCTAssertEqual(layout.regions.map(\.format), [.allCaps, nil])
    }

    func testCommandAtTheEndLeavesNoEmptyRegion() {
        let words = [w("hello", 0, 0.4), w(" bullet", 1.0, 1.3), w(" list", 1.35, 1.6)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0.9, end: 1.7)])
        XCTAssertEqual(layout.regions.map(\.format), [nil])
        XCTAssertEqual(FormatTimeline.text(of: layout.regions[0].words), "hello")
    }

    func testOnlyCommandWordsMeansNoRegions() {
        let words = [w("bullet", 0.2, 0.5), w(" list", 0.55, 0.8)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 0.1, end: 0.9)])
        XCTAssertTrue(layout.regions.isEmpty)
    }

    func testPaddingCatchesWordsSlightlyOutsideTheHold() {
        // Recognizer time runs a little behind the key clock: the command word's
        // midpoint sits just before the press and just after the release.
        let words = [w("text", 0, 0.3), w(" caps", 0.9, 1.1), w(" lock", 1.15, 1.6), w(" more", 2.5, 2.8)]
        let layout = FormatTimeline.layout(words: words, marks: [.span(start: 1.05, end: 1.3)])
        XCTAssertEqual(layout.resolutions, [.applied(.allCaps)])
        XCTAssertEqual(layout.regions.map { FormatTimeline.text(of: $0.words) }, ["text", "more"])
    }

    func testWordsFromSegmentsUsesTimingsOrInterpolates() {
        let timed = TimedSegment(text: "Hallo Welt.", start: 0, end: 1,
                                 words: [SegmentWord(text: "Hallo", start: 0, end: 0.4),
                                         SegmentWord(text: " Welt.", start: 0.5, end: 1)])
        // Words that don't reproduce the text (e.g. a stripped hesitation marker) or are missing.
        let untimed = TimedSegment(text: "eins zwei", start: 2, end: 4, words: nil)
        let words = FormatTimeline.words(from: [timed, untimed])
        XCTAssertEqual(words.map(\.text), ["Hallo", " Welt.", "eins", " zwei"])
        XCTAssertEqual(words.map(\.segment), [0, 0, 1, 1])
        XCTAssertEqual(words[2].start, 2, accuracy: 0.001)
        XCTAssertEqual(words[3].start, 3, accuracy: 0.001)
    }

    func testSegmentTextsGroupBySegment() {
        let words = [w("Hallo.", 0, 0.4, seg: 0), w("Und", 2, 2.2, seg: 1), w(" weiter", 2.3, 2.6, seg: 1)]
        XCTAssertEqual(FormatTimeline.segmentTexts(of: words), ["Hallo.", "Und weiter"])
    }
}

final class FormatRendererTests: XCTestCase {

    func testLists() {
        XCTAssertEqual(FormatRenderer.list(.bulletList, items: ["milch", "Eier.", "brot"]), "- Milch\n- Eier\n- Brot")
        XCTAssertEqual(FormatRenderer.list(.numberedList, items: ["call Anna", "send the file."]), "1. Call Anna\n2. Send the file")
        XCTAssertEqual(FormatRenderer.list(.todoList, items: ["book the room"]), "- [ ] Book the room")
    }

    func testListSplitsSentencesInsideAnItem() {
        XCTAssertEqual(FormatRenderer.list(.bulletList, items: ["Milch holen. Eier kaufen."]), "- Milch holen\n- Eier kaufen")
        XCTAssertEqual(FormatRenderer.list(.bulletList, items: ["Zum Beispiel z. B. Milch"]), "- Zum Beispiel z. B. Milch")
        XCTAssertEqual(FormatRenderer.list(.bulletList, items: ["Is it done? Yes."]), "- Is it done?\n- Yes")
    }

    func testListDropsEmptyItemsAndExistingMarkers() {
        XCTAssertEqual(FormatRenderer.list(.numberedList, items: ["- one", "", "2. two"]), "1. One\n2. Two")
    }

    func testQuotesPerLanguage() {
        XCTAssertEqual(FormatRenderer.quoted("Hallo Welt.", languageCode: "de"), "\u{201E}Hallo Welt\u{201C}")
        XCTAssertEqual(FormatRenderer.quoted("less is more", languageCode: "en"), "\u{201C}less is more\u{201D}")
        XCTAssertEqual(FormatRenderer.quoted("oui", languageCode: "fr-FR"), "\u{00AB}\u{202F}oui\u{202F}\u{00BB}")
        XCTAssertEqual(FormatRenderer.quoted("はい", languageCode: "ja"), "\u{300C}はい\u{300D}")
        XCTAssertEqual(FormatRenderer.quoted("x", languageCode: nil), "\u{201C}x\u{201D}")
        XCTAssertEqual(FormatRenderer.quoted("Wirklich?", languageCode: "de"), "\u{201E}Wirklich?\u{201C}")
    }

    func testCaseParenthesesHeading() {
        XCTAssertEqual(FormatRenderer.allCaps("Straße ist frei", languageCode: "de"), "STRASSE IST FREI")
        XCTAssertEqual(FormatRenderer.lowercase("Read Me", languageCode: "en"), "read me")
        XCTAssertEqual(FormatRenderer.parenthesized("siehe unten."), "(siehe unten)")
        XCTAssertEqual(FormatRenderer.heading("next steps."), "# Next steps")
    }

    func testVerbatim() {
        XCTAssertEqual(FormatRenderer.verbatim(chunks: ["git status"]), .init(text: "`git status`", isBlock: false))
        XCTAssertEqual(FormatRenderer.verbatim(chunks: ["cd src", "make test"]),
                       .init(text: "```\ncd src\nmake test\n```", isBlock: true))
    }

    func testEmailFrameAddsGreetingClosingAndSignature() {
        XCTAssertEqual(FormatRenderer.emailFrame(body: "danke für das Gespräch.\n\nIch melde mich.", languageCode: "de", userName: "Jo"),
                       "Hallo,\n\ndanke für das Gespräch.\n\nIch melde mich.\n\nViele Grüße\nJo")
        XCTAssertEqual(FormatRenderer.emailFrame(body: "Thanks for the call.", languageCode: "en", userName: ""),
                       "Hi,\n\nThanks for the call.\n\nBest regards")
    }

    func testEmailFrameKeepsWhatTheSpeakerSaid() {
        XCTAssertEqual(FormatRenderer.emailFrame(body: "Hallo Anna,\n\nbis morgen.\n\nLiebe Grüße", languageCode: "de", userName: "Jo"),
                       "Hallo Anna,\n\nbis morgen.\n\nLiebe Grüße\nJo")
        XCTAssertEqual(FormatRenderer.emailFrame(body: "Hi Sam,\n\nsee you.\n\nCheers\nJo", languageCode: "en", userName: "Jo"),
                       "Hi Sam,\n\nsee you.\n\nCheers\nJo")
        // "Hier" starts with "hi" but is not a greeting.
        XCTAssertTrue(FormatRenderer.emailFrame(body: "Hier ist der Plan.", languageCode: "de", userName: "").hasPrefix("Hallo,"))
    }
}

final class FormatAssemblyTests: XCTestCase {

    /// The byte-for-byte guarantee: no command span → the normal path; and the
    /// substitution step is the identity when nothing was formatted.
    func testNoSpanMeansNoAssemblyAndIdentity() {
        XCTAssertFalse(FormatAssembly.needsAssembly([]))
        XCTAssertFalse(FormatAssembly.needsAssembly([.endTap(at: 1), .endTap(at: 2)]))
        XCTAssertTrue(FormatAssembly.needsAssembly([.span(start: 0, end: 1)]))
        let text = "  Hello ,  world.\nNew line  "
        XCTAssertEqual(FormatAssembly.substitute(processed: text, parts: [.normal(text)]), text)
        XCTAssertEqual(FormatAssembly.substitute(processed: text, parts: []), text)
    }

    func testRoundTripWithBlockAndInlinePieces() {
        let parts: [FormatAssembly.Part] = [
            .normal("Ich brauche:"),
            .formatted(.init(text: "- Milch\n- Eier", isBlock: true)),
            .normal("und dann"),
            .formatted(.init(text: "\u{201E}Ruhe\u{201C}", isBlock: false)),
            .normal(", bitte."),
        ]
        let stream = FormatAssembly.normalStream(parts)
        XCTAssertEqual(stream, "Ich brauche: \u{E000} und dann \u{E001} , bitte.")
        // The chain may change the normal text around the placeholders.
        let processed = "Ich brauche: \u{E000} Und dann \u{E001}, bitte."
        XCTAssertEqual(FormatAssembly.substitute(processed: processed, parts: parts),
                       "Ich brauche:\n- Milch\n- Eier\nUnd dann \u{201E}Ruhe\u{201C}, bitte.")
    }

    func testAllFormatted() {
        let parts: [FormatAssembly.Part] = [.formatted(.init(text: "LOUD", isBlock: false))]
        XCTAssertEqual(FormatAssembly.substitute(processed: FormatAssembly.normalStream(parts), parts: parts), "LOUD")
    }

    func testLostPlaceholderFallsBackToPreChainJoin() {
        let parts: [FormatAssembly.Part] = [.normal("a"), .formatted(.init(text: "B", isBlock: false)), .normal("c")]
        XCTAssertEqual(FormatAssembly.substitute(processed: "a c", parts: parts), "a B c")
        XCTAssertEqual(FormatAssembly.substitute(processed: "a \u{E000} \u{E000} c", parts: parts), "a B c")
    }

    func testAssemblerCleansFirstThenFormats() async {
        // "note [⌃ alles groß] wichtig"
        let seg = TimedSegment(text: "note alles groß wichtig", start: 0, end: 3, words: [
            SegmentWord(text: "note", start: 0, end: 0.4),
            SegmentWord(text: " alles", start: 1.0, end: 1.3),
            SegmentWord(text: " groß", start: 1.35, end: 1.7),
            SegmentWord(text: " wichtig", start: 2.2, end: 2.6),
        ])
        let plan = await FormatDictationAssembler.assemble(
            segments: [seg], marks: [.span(start: 0.9, end: 1.8)],
            clean: { "\($0)!" },                       // stand-in cleanup: appends "!"
            postProcessFormatted: { $0 },
            languageCode: "de", userName: "",
            model: { _, _, _ in nil })
        XCTAssertEqual(plan.resolutions, [.applied(.allCaps)])
        XCTAssertEqual(plan.plainRaw, "note wichtig")
        XCTAssertEqual(plan.parts, [.normal("note!"), .formatted(.init(text: "WICHTIG!", isBlock: false))])
        XCTAssertEqual(FormatAssembly.substitute(processed: plan.normalStream, parts: plan.parts), "note! WICHTIG!")
        XCTAssertFalse(plan.modelFallback)
    }

    func testListItemsAreCleanedOneByOne() async {
        let seg = TimedSegment(text: "list milk eggs", start: 0, end: 4, words: [
            SegmentWord(text: "list", start: 0, end: 0.3),
            SegmentWord(text: " milk", start: 1.0, end: 1.3),
            SegmentWord(text: " eggs", start: 2.5, end: 2.8),
        ])
        let plan = await FormatDictationAssembler.assemble(
            segments: [seg], marks: [.span(start: 0, end: 0.5)],
            clean: { $0.uppercased() + "." }, postProcessFormatted: { $0 },
            languageCode: "en", userName: "", model: { _, _, _ in nil })
        XCTAssertEqual(plan.parts, [.formatted(.init(text: "- MILK\n- EGGS", isBlock: true))])
    }

    func testVerbatimSkipsCleanup() async {
        let seg = TimedSegment(text: "code um git status", start: 0, end: 3, words: [
            SegmentWord(text: "code", start: 0, end: 0.3),
            SegmentWord(text: " um", start: 1.0, end: 1.1),
            SegmentWord(text: " git", start: 1.2, end: 1.4),
            SegmentWord(text: " status", start: 1.45, end: 1.8),
        ])
        let plan = await FormatDictationAssembler.assemble(
            segments: [seg], marks: [.span(start: 0, end: 0.4)],
            clean: { _ in "CLEANED" }, postProcessFormatted: { _ in "POST" },
            languageCode: "en", userName: "", model: { _, _, _ in nil })
        XCTAssertEqual(plan.parts, [.formatted(.init(text: "`um git status`", isBlock: false))])
    }

    func testModelFormatFallsBackToCleanedTextAndFlagsIt() async {
        let seg = TimedSegment(text: "email thanks for today", start: 0, end: 3, words: [
            SegmentWord(text: "email", start: 0, end: 0.4),
            SegmentWord(text: " thanks", start: 1.0, end: 1.3),
            SegmentWord(text: " for", start: 1.35, end: 1.5),
            SegmentWord(text: " today", start: 1.55, end: 1.9),
        ])
        let unavailable = await FormatDictationAssembler.assemble(
            segments: [seg], marks: [.span(start: 0, end: 0.5)],
            clean: nil, postProcessFormatted: { $0 },
            languageCode: "en", userName: "Jo", model: { _, _, _ in nil })
        XCTAssertTrue(unavailable.modelFallback)
        XCTAssertEqual(unavailable.parts, [.formatted(.init(text: "thanks for today", isBlock: true))])

        let ok = await FormatDictationAssembler.assemble(
            segments: [seg], marks: [.span(start: 0, end: 0.5)],
            clean: nil, postProcessFormatted: { $0 },
            languageCode: "en", userName: "Jo", model: { _, text, _ in "Thanks for today." })
        XCTAssertFalse(ok.modelFallback)
        XCTAssertEqual(ok.parts, [.formatted(.init(text: "Hi,\n\nThanks for today.\n\nBest regards\nJo", isBlock: true))])
    }
}

final class FormatModelPassGuardTests: XCTestCase {

    func testRefusalAndEmptyAreRejected() {
        XCTAssertNil(FormatModelPass.accept(input: "x", output: "  ", preset: .formal, outputCode: nil))
        XCTAssertNil(FormatModelPass.accept(input: "damn it send it",
                                            output: "I cannot comply with that request as it contains offensive language.",
                                            preset: .formal, outputCode: nil))
    }

    func testAnswerBackIsRejected() {
        XCTAssertNil(FormatModelPass.accept(
            input: "what is the capital of germany?",
            output: "Berlin",
            preset: .shorter, outputCode: nil))
    }

    func testFaithfulRewriteIsAccepted() {
        XCTAssertEqual(FormatModelPass.accept(input: "can you please send the report today",
                                              output: "Could you please send the report today?",
                                              preset: .formal, outputCode: nil),
                       "Could you please send the report today?")
    }

    func testTranslationGrowthGuard() {
        XCTAssertNotNil(FormatModelPass.accept(input: "bis morgen", output: "see you tomorrow",
                                               preset: .translateToEnglish, outputCode: nil))
        XCTAssertNil(FormatModelPass.accept(input: "bis morgen",
                                            output: "See you tomorrow. Also, here are ten tips for a productive day at the office",
                                            preset: .translateToEnglish, outputCode: nil))
    }
}

/// The command key fed with synthetic tap events, exactly as `HotKeyMonitor` does.
final class FormatKeyStepTests: XCTestCase {
    private let command = FormatCommandKey.defaultKey      // Left ⌃ (59, bit 0x1)
    private let dictation = ActivationKey.rightOption       // Right ⌥ (61, bit 0x40)

    private func ctrl(_ down: Bool, extra: UInt64 = 0) -> ActivationKey.Event {
        .flagsChanged(keyCode: 59, rawFlags: (down ? 0x1 : 0) | extra)
    }

    private func step(_ g: inout FormatKeyGesture, _ e: ActivationKey.Event, flags: UInt64 = 0,
                      active: Bool = true, at t: TimeInterval) -> FormatKeyGesture.Output? {
        g.step(e, rawFlags: flags, commandKey: command, dictationKey: dictation, dictationActive: active, now: t)
    }

    /// One clean press and release of the command key.
    private func press(_ g: inout FormatKeyGesture, at t: TimeInterval, extra: UInt64 = 0) -> FormatKeyGesture.Output? {
        let down = step(&g, ctrl(true, extra: extra), flags: 0x1 | extra, at: t)
        let up = step(&g, ctrl(false, extra: extra), flags: extra, at: t + 0.08)
        return down ?? up
    }

    func testTwoPressesAreASpan() {
        var g = FormatKeyGesture()
        XCTAssertEqual(step(&g, ctrl(true), flags: 0x1, at: 1), .pressed(at: 1))
        XCTAssertNil(step(&g, ctrl(false), at: 1.1))
        XCTAssertNil(step(&g, ctrl(true), flags: 0x1, at: 2))
        XCTAssertEqual(step(&g, ctrl(false), at: 2.1), .span(start: 1, end: 2))
    }

    func testControlCShortcutCancelsTheFirstPress() {
        var g = FormatKeyGesture()
        _ = step(&g, ctrl(true), flags: 0x1, at: 1)
        XCTAssertNil(step(&g, .keyDown(keyCode: 8, isAutorepeat: false), flags: 0x1, at: 1.3))   // C
        XCTAssertNil(step(&g, .keyUp(keyCode: 8), flags: 0x1, at: 1.4))
        XCTAssertEqual(step(&g, ctrl(false), at: 2), .cancelled)
    }

    func testControlCShortcutWhileListeningIsNotTheSecondPress() {
        var g = FormatKeyGesture()
        XCTAssertEqual(press(&g, at: 1), .pressed(at: 1))
        _ = step(&g, ctrl(true), flags: 0x1, at: 2)
        _ = step(&g, .keyDown(keyCode: 8, isAutorepeat: false), flags: 0x1, at: 2.1)   // C
        _ = step(&g, .keyUp(keyCode: 8), flags: 0x1, at: 2.2)
        XCTAssertNil(step(&g, ctrl(false), at: 2.3))
        XCTAssertTrue(g.isListening)
        XCTAssertEqual(press(&g, at: 3), .span(start: 1, end: 3))
    }

    func testTypingWhileListeningDoesNotEndIt() {
        var g = FormatKeyGesture()
        _ = press(&g, at: 1)
        XCTAssertNil(step(&g, .keyDown(keyCode: 0, isAutorepeat: false), at: 1.5))   // A, key is up
        XCTAssertNil(step(&g, .mouseDown(button: 0), at: 1.6))
        XCTAssertEqual(press(&g, at: 2), .span(start: 1, end: 2))
    }

    func testMouseClickDuringThePressCancels() {
        var g = FormatKeyGesture()
        _ = step(&g, ctrl(true), flags: 0x1, at: 1)
        _ = step(&g, .mouseDown(button: 0), flags: 0x1, at: 1.5)
        XCTAssertEqual(step(&g, ctrl(false), at: 2), .cancelled)
    }

    func testChordStartedWithAnotherModifierCancels() {
        var g = FormatKeyGesture()
        // ⌘ already down (bit 0x8), then ⌃.
        XCTAssertNil(step(&g, ctrl(true, extra: 0x8), flags: 0x1 | 0x8, at: 1))
        XCTAssertEqual(step(&g, ctrl(false, extra: 0x8), flags: 0x8, at: 2), .cancelled)
    }

    func testShiftPressedDuringThePressCancels() {
        var g = FormatKeyGesture()
        _ = step(&g, ctrl(true), flags: 0x1, at: 1)
        _ = step(&g, .flagsChanged(keyCode: 56, rawFlags: 0x1 | 0x2), flags: 0x1 | 0x2, at: 1.2)
        XCTAssertEqual(step(&g, ctrl(false), at: 2), .cancelled)
    }

    func testHeldDictationKeyDoesNotCancel() {
        // Push-to-talk: Right ⌥ is held the whole time; its flags are present.
        var g = FormatKeyGesture()
        XCTAssertEqual(press(&g, at: 1, extra: 0x40), .pressed(at: 1))
        XCTAssertEqual(press(&g, at: 1.6, extra: 0x40), .span(start: 1, end: 1.6))
    }

    func testQuickDoublePressIsATap() {
        var g = FormatKeyGesture()
        _ = press(&g, at: 1)
        XCTAssertEqual(press(&g, at: 1.15), .tap(at: 1.15))
    }

    func testIgnoredWhenNoDictationIsActive() {
        var g = FormatKeyGesture()
        XCTAssertNil(step(&g, ctrl(true), flags: 0x1, active: false, at: 1))
        XCTAssertNil(step(&g, ctrl(false), active: false, at: 2))
        // Listening that was on when the dictation ended is switched off: the next
        // dictation starts with a first press again.
        _ = press(&g, at: 3)
        XCTAssertTrue(g.isListening)
        XCTAssertNil(step(&g, .keyDown(keyCode: 0, isAutorepeat: false), active: false, at: 3.2))
        XCTAssertFalse(g.isListening)
        XCTAssertEqual(press(&g, at: 4), .pressed(at: 4))
    }

    func testFeatureOffOrSameKeyIsInert() {
        var g = FormatKeyGesture()
        XCTAssertNil(g.step(ctrl(true), rawFlags: 0x1, commandKey: nil, dictationKey: dictation,
                            dictationActive: true, now: 1))
        XCTAssertNil(g.step(ctrl(true), rawFlags: 0x1, commandKey: command, dictationKey: command,
                            dictationActive: true, now: 1))
    }

    func testFunctionKeyCommandIgnoresItsOwnAutorepeat() {
        let f5 = ActivationKey(kind: .function, code: 96)
        var g = FormatKeyGesture()
        func s(_ e: ActivationKey.Event, _ t: TimeInterval) -> FormatKeyGesture.Output? {
            g.step(e, rawFlags: 0, commandKey: f5, dictationKey: dictation, dictationActive: true, now: t)
        }
        XCTAssertEqual(s(.keyDown(keyCode: 96, isAutorepeat: false), 1), .pressed(at: 1))
        XCTAssertNil(s(.keyDown(keyCode: 96, isAutorepeat: true), 1.5))
        XCTAssertNil(s(.keyUp(keyCode: 96), 2))
        XCTAssertNil(s(.keyDown(keyCode: 96, isAutorepeat: false), 3))
        XCTAssertNil(s(.keyDown(keyCode: 96, isAutorepeat: true), 3.5))
        XCTAssertEqual(s(.keyUp(keyCode: 96), 4), .span(start: 1, end: 3))
    }
}

final class FormatLivePreviewTests: XCTestCase {
    func testAddedWordsAfterTheCommonPrefix() {
        XCTAssertEqual(FormatLivePreview.addedWords(before: "Ich brauche", after: "Ich brauche in Stichpunkten"),
                       "in Stichpunkten")
        // Re-punctuation of the earlier words doesn't count as new words.
        XCTAssertEqual(FormatLivePreview.addedWords(before: "ich brauche", after: "Ich brauche. Alles groß"),
                       "Alles groß")
        XCTAssertEqual(FormatLivePreview.addedWords(before: "", after: "bullet points"), "bullet points")
        XCTAssertEqual(FormatLivePreview.addedWords(before: "same", after: "same"), "")
    }

    func testResolve() {
        XCTAssertEqual(FormatLivePreview.resolve(""), .ended)
        XCTAssertEqual(FormatLivePreview.resolve("in Stichpunkten Milch"), .applied(.bulletList))
        XCTAssertEqual(FormatLivePreview.resolve("Ende"), .ended)
        XCTAssertEqual(FormatLivePreview.resolve("banana"), .notRecognised("banana"))
    }
}

/// The stop-time language check stays on for dictations with format commands: the
/// audio is re-transcribed in the right language and the command spans (audio time)
/// are laid over the NEW words.
final class FormatRetranscriptionTests: XCTestCase {

    private func fw(_ t: String, _ s: Double, _ e: Double) -> FormatWord { FormatWord(text: t, start: s, end: e, segment: 0) }
    private func sw(_ t: String, _ s: Double, _ e: Double) -> SegmentWord { SegmentWord(text: t, start: s, end: e) }

    /// The live session decoded German speech with the English model (gibberish).
    private let originalGibberish = [TimedSegment(text: "Ick brow ka in stick punk ten milk I a", start: 0, end: 5, words: nil)]

    private func assemble(_ words: [FormatWord], marks: [FormatMark], fallback: [FormatCommand?] = [],
                          refine: Bool = false) async -> FormatDictationAssembler.Plan {
        await FormatDictationAssembler.assemble(
            segments: [], marks: marks, words: words, fallbackCommands: fallback, refineByPhrase: refine,
            clean: nil, postProcessFormatted: { $0 }, languageCode: "de", userName: "",
            model: { _, _, _ in nil })
    }

    func testOneSpanOverReTranscribedTimedWords() async {
        let text = "Ich brauche in Stichpunkten Milch Eier"
        let seg = TimedSegment(text: text, start: 0, end: 4.2, words: [
            sw("Ich", 0, 0.3), sw(" brauche", 0.35, 0.8), sw(" in", 1.2, 1.35), sw(" Stichpunkten", 1.4, 2.0),
            sw(" Milch", 2.5, 2.9), sw(" Eier", 3.8, 4.1)])
        let laid = FormatRetranscription.words(retranscribed: [seg], text: text,
                                               original: FormatTimeline.words(from: originalGibberish), duration: 4.2)
        XCTAssertFalse(laid.proportional)
        let plan = await assemble(laid.words, marks: [.span(start: 1.1, end: 2.1)])
        XCTAssertEqual(plan.resolutions, [.applied(.bulletList)])
        XCTAssertEqual(plan.parts, [.normal("Ich brauche"), .formatted(.init(text: "- Milch\n- Eier", isBlock: true))])
        XCTAssertFalse(plan.plainRaw.contains("Stichpunkten"))
    }

    func testTwoSpansOverReTranscribedTimedWords() async {
        let text = "Liste Milch Eier alles groß wichtig"
        let seg = TimedSegment(text: text, start: 0, end: 6, words: [
            sw("Liste", 0.1, 0.5), sw(" Milch", 1.0, 1.3), sw(" Eier", 2.2, 2.5),
            sw(" alles", 3.0, 3.3), sw(" groß", 3.35, 3.7), sw(" wichtig", 4.5, 5.0)])
        let laid = FormatRetranscription.words(retranscribed: [seg], text: text, original: [], duration: 6)
        let plan = await assemble(laid.words, marks: [.span(start: 0, end: 0.6), .span(start: 2.9, end: 3.8)])
        XCTAssertEqual(plan.resolutions, [.applied(.bulletList), .applied(.allCaps)])
        XCTAssertEqual(plan.parts, [.formatted(.init(text: "- Milch\n- Eier", isBlock: true)),
                                    .formatted(.init(text: "WICHTIG", isBlock: false))])
    }

    func testEmptyReTranscribedSpanFallsBackToTheOriginalThenTheLivePreview() async {
        // The re-transcription has no words inside the span (0.9–1.6 s).
        let words = [fw("Hallo", 0, 0.4), fw(" Milch", 2.0, 2.3), fw(" Eier", 3.2, 3.5)]
        let marks: [FormatMark] = [.span(start: 0.9, end: 1.6)]
        // 1) The original transcript heard "bullet points" in that span.
        let original = [fw("hello", 0, 0.4), fw(" bullet", 1.0, 1.2), fw(" points", 1.25, 1.5), fw(" milk", 2.0, 2.3)]
        let fromOriginal = FormatRetranscription.fallbackCommands(original: original, marks: marks, live: [nil])
        XCTAssertEqual(fromOriginal, [.apply(.bulletList)])
        let plan = await assemble(words, marks: marks, fallback: fromOriginal)
        XCTAssertEqual(plan.resolutions, [.applied(.bulletList)])
        XCTAssertEqual(plan.parts.last, .formatted(.init(text: "- Milch\n- Eier", isBlock: true)))
        // 2) The original span is gibberish too → the live preview's match at release.
        let gibberish = [fw("hello", 0, 0.4), fw(" grumble", 1.0, 1.4)]
        let fromLive = FormatRetranscription.fallbackCommands(original: gibberish, marks: marks, live: [.apply(.allCaps)])
        XCTAssertEqual(fromLive, [.apply(.allCaps)])
        let plan2 = await assemble(words, marks: marks, fallback: fromLive)
        XCTAssertEqual(plan2.parts.last, .formatted(.init(text: "MILCH EIER", isBlock: false)))
        // 3) No fallback at all → an empty span ends the mode, as before.
        let plan3 = await assemble(words, marks: marks, fallback: [nil])
        XCTAssertEqual(plan3.resolutions, [.ended])
    }

    func testUnmatchedReTranscribedSpanUsesTheFallback() async {
        let words = [fw("Hallo", 0, 0.4), fw(" Stich", 1.0, 1.2), fw(" bunt", 1.25, 1.5), fw(" Milch", 2.0, 2.3)]
        let plan = await assemble(words, marks: [.span(start: 0.9, end: 1.6)], fallback: [.apply(.bulletList)])
        XCTAssertEqual(plan.resolutions, [.applied(.bulletList)])
        XCTAssertFalse(plan.plainRaw.contains("Stich"))
    }

    func testNoWordTimingsUsesProportionalPositionAndNeverPastesCommandWords() async {
        // Re-transcribed text with no usable timings (text mismatch / words nil).
        let text = "Ich brauche heute in Stichpunkten Milch und Eier"
        let reSegments = [TimedSegment(text: "something else", start: 0, end: 5, words: nil)]
        // The original recording's word times (6 words; the new text has 8 tokens, so
        // the proportional estimate is off by a word or so).
        let original = [fw("Ick", 0, 0.3), fw(" brow", 0.35, 0.8), fw(" in", 1.2, 1.35),
                        fw(" stickpunk", 1.4, 2.0), fw(" milk", 2.5, 2.9), fw(" eye", 3.8, 4.1)]
        let laid = FormatRetranscription.words(retranscribed: reSegments, text: text, original: original, duration: 4.2)
        XCTAssertTrue(laid.proportional)
        XCTAssertEqual(laid.words.count, 8)
        let marks: [FormatMark] = [.span(start: 1.1, end: 2.1)]
        let fallback = FormatRetranscription.fallbackCommands(original: original, marks: marks, live: [.apply(.bulletList)])
        let plan = await assemble(laid.words, marks: marks, fallback: fallback, refine: true)
        XCTAssertEqual(plan.resolutions, [.applied(.bulletList)])
        XCTAssertFalse(plan.plainRaw.contains("Stichpunkten"))
        XCTAssertFalse(plan.plainRaw.split(separator: " ").contains("in"))
        XCTAssertTrue(plan.plainRaw.contains("heute"))     // real words are kept
        XCTAssertTrue(plan.plainRaw.contains("Eier"))
        guard case .formatted(let piece)? = plan.parts.last else { return XCTFail("no formatted part") }
        XCTAssertTrue(piece.text.hasPrefix("- Milch"))
    }

    func testProportionalWordsWithoutReferenceSpreadEvenly() {
        let words = FormatTimeline.proportionalWords(text: "a b c d", reference: [], duration: 4)
        XCTAssertEqual(words.map(\.start), [0, 1, 2, 3])
        XCTAssertEqual(words.map(\.text), ["a", " b", " c", " d"])
    }

    func testTimedSegmentsWithoutWordTimingsAreMarkedEstimated() {
        let seg = TimedSegment(text: "eins zwei", start: 1, end: 2, words: nil)
        let laid = FormatRetranscription.words(retranscribed: [seg], text: "eins zwei", original: [], duration: 2)
        XCTAssertTrue(laid.proportional)
        XCTAssertEqual(laid.words.map(\.start), [1, 1.5])
    }
}
