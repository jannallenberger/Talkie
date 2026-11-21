import XCTest
@testable import Talkie

/// A judge with scripted answers, keyed by the first fragment.
private struct ScriptedJudge: PauseStopJudging {
    var answers: [String: String]
    var delay: Double = 0
    func joined(before: String, after: String) async -> String? {
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        return answers[before]
    }
}

final class PauseStopsTests: XCTestCase {

    // MARK: Sentences

    func testSentencesSplitAtTerminatorsBeforeACapital() {
        XCTAssertEqual(PauseStops.sentences(of: "Yes, please. We also need that. First of all."),
                       ["Yes, please.", "We also need that.", "First of all."])
        XCTAssertEqual(PauseStops.sentences(of: "Is it on? Yes! Good."), ["Is it on?", "Yes!", "Good."])
        XCTAssertEqual(PauseStops.sentences(of: "  one sentence only  "), ["one sentence only"])
        XCTAssertEqual(PauseStops.sentences(of: ""), [])
    }

    func testAbbreviationsNumbersAndLowercaseDoNotSplit() {
        XCTAssertEqual(PauseStops.sentences(of: "Das kostet ca. Drei Euro."), ["Das kostet ca. Drei Euro."])
        XCTAssertEqual(PauseStops.sentences(of: "Nimm z. B. Das hier."), ["Nimm z. B. Das hier."])
        XCTAssertEqual(PauseStops.sentences(of: "Version 1.0.0 is out. Build 636. Done."),
                       ["Version 1.0.0 is out.", "Build 636.", "Done."])
        XCTAssertEqual(PauseStops.sentences(of: "auf einmal. gepastet"), ["auf einmal. gepastet"])
    }

    func testJoiningTheSentencesGivesTheTextBack() {
        let text = "Yes, please. We also need to make changes. First of all. We need that."
        XCTAssertEqual(PauseStops.sentences(of: text).joined(separator: " "), text)
    }

    // MARK: Fixed rules

    private func certain(_ a: String, _ b: String, _ lang: String? = "en") -> PauseStops.Decision? {
        PauseStops.certain(before: a, after: b, languageCode: lang)
    }

    func testASentenceCannotEndOnAnArticle() {
        XCTAssertEqual(certain("We need to make sure that the.", "Commands option when pressing the key."),
                       .join(.none, lead: nil))
        XCTAssertEqual(certain("I looked at your.", "Pull request."), .join(.none, lead: nil))
        // German "eine" can end a sentence: not a fixed rule.
        XCTAssertNil(certain("Ich möchte auch eine.", "Das wäre gut.", "de"))
    }

    func testEnglishStatementCannotStartWithAFiniteVerb() {
        XCTAssertEqual(certain("Whatever key is selected for the user.", "Is actually enabled by pressing the key."),
                       .join(.none, lead: "is"))
        // As a question the recognizer writes "?": that one stays.
        XCTAssertNil(certain("I am not sure about this one.", "Is it actually enabled?"))
        // Not applied to German, where "Was" starts a question.
        XCTAssertNil(certain("Das ist die Frage.", "Was machen wir jetzt.", "de"))
        XCTAssertNil(certain("Das ist die Frage.", "Was machen wir jetzt.", nil))
    }

    func testOpeningPhraseGetsAComma() {
        XCTAssertEqual(certain("First of all.", "We need to make sure."), .join(.comma, lead: "we"))
        // A name after the phrase keeps its capital.
        XCTAssertEqual(certain("By the way.", "Lars built it from source."), .join(.comma, lead: nil))
        // German: the verb follows directly, no comma.
        XCTAssertEqual(certain("Darüber hinaus.", "Bin ich ziemlich glücklich.", "de"), .join(.none, lead: "bin"))
        XCTAssertNil(certain("Darüber hinaus.", "Ich bin ziemlich glücklich.", "de"))
    }

    func testBareIAndJoiningWords() {
        XCTAssertEqual(certain("So I.", "Want to change that."), .join(.none, lead: "want"))
        XCTAssertEqual(certain("We ship the pill and.", "The notes window."), .join(.none, lead: "the"))
        XCTAssertEqual(certain("Wir bauen das Layout und.", "Design neu.", "de"), .join(.none, lead: nil))
    }

    func testOtherTerminatorsAreNeverTouched() {
        XCTAssertEqual(certain("Is that the?", "Commands option."), .keep)
        XCTAssertEqual(certain("Stop the!", "Commands option."), .keep)
        XCTAssertEqual(certain("And then the…", "Commands option."), .keep)
    }

    func testRealSentenceEndsHaveNoFixedRule() {
        XCTAssertNil(certain("We also need to make a couple of changes that I will list now.", "First of all."))
        XCTAssertNil(certain("I also seem to need to hold the key down.", "Yeah so I don't know."))
        XCTAssertNil(certain("Das Fenster bewegt sich.", "Ich kann keinen Text markieren.", "de"))
    }

    func testHabitualJoinsOnlyJoiningWords() {
        XCTAssertEqual(PauseStops.habitual(before: "We should ship.", after: "Because it is ready."),
                       .join(.none, lead: "because"))
        XCTAssertEqual(PauseStops.habitual(before: "We should ship.", after: "It is ready."), .keep)
        XCTAssertEqual(PauseStops.habitual(before: "Should we ship?", after: "Because it is ready."), .keep)
    }

    // MARK: What is worth asking

    func testOnlyUnfinishedLookingStopsAreAsked() {
        XCTAssertTrue(PauseStops.looksUnfinished(
            before: "It is still the case that sentences are cut off by a long pause, which then.",
            after: "Leads to a point that is being set on the transcription."))
        XCTAssertTrue(PauseStops.looksUnfinished(before: "First of all.", after: "We need to make sure of it today."))
        XCTAssertFalse(PauseStops.looksUnfinished(
            before: "The sliders cannot be moved in this build.",
            after: "They drag the whole window instead of the handle."))
        XCTAssertFalse(PauseStops.looksUnfinished(before: "Is that really the case?", after: "Leads nowhere."))
    }

    // MARK: The model's answer

    func testModelAnswerCountsOnlyWithTheSameWords() {
        let a = "which then.", b = "Leads to a point."
        XCTAssertEqual(PauseStops.decision(fromModelOutput: "which then leads to a point.", before: a, after: b),
                       .join(.none, lead: "leads"))
        XCTAssertEqual(PauseStops.decision(fromModelOutput: "Which then, leads to a point.", before: a, after: b),
                       .join(.comma, lead: "leads"))
        XCTAssertEqual(PauseStops.decision(fromModelOutput: "which then. Leads to a point.", before: a, after: b),
                       .keep)
        // A changed, missing or extra word is no answer at all.
        XCTAssertNil(PauseStops.decision(fromModelOutput: "which then led to a point.", before: a, after: b))
        XCTAssertNil(PauseStops.decision(fromModelOutput: "which then leads to point.", before: a, after: b))
        XCTAssertNil(PauseStops.decision(fromModelOutput: "Sure! which then leads to a point.", before: a, after: b))
        XCTAssertNil(PauseStops.decision(fromModelOutput: "", before: a, after: b))
    }

    func testModelAnswerKeepsApostrophesAndNames() {
        XCTAssertEqual(PauseStops.decision(fromModelOutput: "I don't know if Lars is there.",
                                           before: "I don't know if.", after: "Lars is there."),
                       .join(.none, lead: "Lars"))
    }

    func testModelSeesOnlyTheEndAndTheBeginning() {
        let long = (1...60).map { "w\($0)" }.joined(separator: " ") + "."
        let pieces = PauseStops.modelPieces(before: long, after: long)
        XCTAssertEqual(pieces.before.split(separator: " ").count, PauseStops.contextWordsBefore)
        XCTAssertTrue(pieces.before.hasSuffix("w60."))
        XCTAssertEqual(pieces.after.split(separator: " ").count, PauseStops.contextWordsAfter)
        XCTAssertTrue(pieces.after.hasPrefix("w1 "))
    }

    // MARK: Applying

    func testApplyNeverChangesAWord() {
        let sentences = ["First of all.", "We need to make sure that the.", "Commands option is on.", "Good."]
        let out = PauseStops.apply([.join(.comma, lead: "we"), .join(.none, lead: nil), .keep], to: sentences)
        XCTAssertEqual(out, "First of all, we need to make sure that the Commands option is on. Good.")
        XCTAssertEqual(PauseStops.words(of: out).map(PauseStops.key),
                       PauseStops.words(of: sentences.joined(separator: " ")).map(PauseStops.key))
        // A lead that is not the same word is ignored.
        XCTAssertEqual(PauseStops.apply([.join(.none, lead: "they")], to: ["So I.", "Want that."]), "So I Want that.")
    }

    func testLoweringProtectsIAndAcronyms() {
        XCTAssertEqual(PauseStops.lowered("Want"), "want")
        XCTAssertEqual(PauseStops.lowered("I"), "I")
        XCTAssertEqual(PauseStops.lowered("I'm"), "I'm")
        XCTAssertEqual(PauseStops.lowered("DMG"), "DMG")
        XCTAssertNil(PauseStops.loweredIfFunctionWord("Lars"))
        XCTAssertNil(PauseStops.loweredIfFunctionWord("Sie"))
        XCTAssertEqual(PauseStops.loweredIfFunctionWord("We"), "we")
    }

    // MARK: One dictation

    private let dictated = "We also need to make a couple of changes that I will list now. First of all. "
        + "We need to make sure that the. Commands option when pressing the control key or whatever key is "
        + "selected for the user. Is actually is enabled by just pressing the key once. "
        + "Sentences are cut off by a long pause, which then. Leads to a full stop."

    func testFixedRulesAloneRepairTheClearCases() async {
        let resolver = PauseStopResolver(judge: nil)
        let out = await resolver.settled(dictated, languageCode: "en", budget: 1)
        XCTAssertEqual(out, "We also need to make a couple of changes that I will list now. First of all, "
            + "we need to make sure that the Commands option when pressing the control key or whatever key is "
            + "selected for the user is actually is enabled by just pressing the key once. "
            + "Sentences are cut off by a long pause, which then. Leads to a full stop.")
        // Without a judge the live text is the same: nothing to wait for.
        XCTAssertEqual(resolver.live(dictated, languageCode: "en"), out)
    }

    func testTheModelSettlesWhatTheRulesCannot() async {
        let judge = ScriptedJudge(answers: [
            "Sentences are cut off by a long pause, which then.":
                "Sentences are cut off by a long pause, which then leads to a full stop.",
            "We also need to make a couple of changes that I will list now.":
                "We also need to make a couple of changes that I will list now. First of all.",
        ])
        let resolver = PauseStopResolver(judge: judge)
        let out = await resolver.settled(dictated, languageCode: "en", budget: 2)
        XCTAssertTrue(out.hasSuffix("Sentences are cut off by a long pause, which then leads to a full stop."), out)
        XCTAssertTrue(out.hasPrefix("We also need to make a couple of changes that I will list now. First of all, we"), out)
        XCTAssertEqual(PauseStops.words(of: out).map(PauseStops.key),
                       PauseStops.words(of: dictated).map(PauseStops.key))
    }

    func testAnAnswerWithChangedWordsIsIgnored() async {
        let judge = ScriptedJudge(answers: [
            "Sentences are cut off by a long pause, which then.":
                "Sentences get cut off by a long pause, which then leads to a full stop.",
        ])
        let resolver = PauseStopResolver(judge: judge)
        let out = await resolver.settled(dictated, languageCode: "en", budget: 2)
        XCTAssertTrue(out.hasSuffix("which then. Leads to a full stop."), out)
    }

    func testASlowModelDoesNotHoldUpThePaste() async {
        let judge = ScriptedJudge(answers: [
            "Sentences are cut off by a long pause, which then.":
                "Sentences are cut off by a long pause, which then leads to a full stop.",
        ], delay: 3)
        let resolver = PauseStopResolver(judge: judge)
        let started = Date()
        let out = await resolver.settled(dictated, languageCode: "en", budget: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(out.hasSuffix("which then. Leads to a full stop."), out)   // settled by rule
        resolver.cancel()
    }

    func testLiveTextUpdatesWhenAnAnswerArrives() async {
        let judge = ScriptedJudge(answers: [
            "Sentences are cut off by a long pause, which then.":
                "Sentences are cut off by a long pause, which then leads to a full stop.",
        ], delay: 0.15)
        let changed = expectation(description: "settled")
        changed.assertForOverFulfill = false
        let resolver = PauseStopResolver(judge: judge) { changed.fulfill() }
        let text = "Sentences are cut off by a long pause, which then. Leads to a full stop."
        resolver.noteFinalized(text, languageCode: "en")
        XCTAssertEqual(resolver.live(text, languageCode: "en"), text)             // still being asked
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertEqual(resolver.live(text, languageCode: "en"),
                       "Sentences are cut off by a long pause, which then leads to a full stop.")
    }

    func testGermanTextIsLeftAloneWithoutAReason() async {
        let text = "Das Fenster bewegt sich. Ich kann keinen Text markieren. Bitte einmal ändern."
        let out = await PauseStopResolver(judge: nil).settled(text, languageCode: "de", budget: 1)
        XCTAssertEqual(out, text)
    }

    // MARK: The real model (opt-in: needs Apple Intelligence on this Mac)

    func testRealModelOnTheDictatedExample() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TALKIE_PAUSESTOP_MODEL_TEST"] == "1",
                          "set TALKIE_PAUSESTOP_MODEL_TEST=1 to ask the on-device model")
        try XCTSkipUnless(OnDevicePauseStopJudge.isUsable, "on-device model not available")
        let heard = "Yes, please. We also need to make a couple of changes that I will list now. First of all. "
            + "We need to make sure that the. Commands option when pressing the control key or whatever key is "
            + "selected for the user. Is actually is enabled by just pressing the key ones and disabled by "
            + "pressing the key once again because currently there's kind of like a long press going on, that I "
            + "do not seem to understand because I also seem to, need to hold the key down. Yeah so I don't know "
            + "if I need to hold the key down further while I'm still, saying the command and the other thing is "
            + "that we are in deep need of, clearly communicating what the users do now. It's still the case "
            + "that a certain sentences are just being cut off by a long pause, which then. Leads to a point "
            + "that is being set on the transcription."
        let resolver = PauseStopResolver(judge: OnDevicePauseStopJudge())
        let started = Date()
        let out = await resolver.settled(heard, languageCode: "en", budget: 20)
        print("PAUSESTOPS seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
        print("PAUSESTOPS out=\(out)")
        XCTAssertEqual(PauseStops.words(of: out).map(PauseStops.key), PauseStops.words(of: heard).map(PauseStops.key))
        XCTAssertTrue(out.contains("First of all, we need to make sure that the Commands option"), out)
        XCTAssertTrue(out.contains("for the user is actually"), out)
        XCTAssertTrue(out.contains("which then leads to a point"), out)
        XCTAssertTrue(out.contains("list now. First of all"), out)
        XCTAssertTrue(out.contains("key down. Yeah so"), out)
        XCTAssertTrue(out.hasPrefix("Yes, please. We also"), out)
    }
}

final class PillLiveTextTests: XCTestCase {
    func testShortTextIsShownWhole() {
        XCTAssertEqual(PillLiveText.dropCount(length: 0), 0)
        XCTAssertEqual(PillLiveText.dropCount(length: PillLiveText.maxCharacters), 0)
        XCTAssertEqual(PillLiveText.window("a few words"), "a few words")
    }

    func testVeryLongTextKeepsTheNewestPartAndCutsInSteps() {
        let over = PillLiveText.maxCharacters + 1
        let drop = PillLiveText.dropCount(length: over)
        XCTAssertGreaterThan(drop, 0)
        XCTAssertEqual(drop % PillLiveText.cutStep, 0)
        XCTAssertGreaterThanOrEqual(over - drop, PillLiveText.keptCharacters)
        // The cut does not move with every new word.
        XCTAssertEqual(PillLiveText.dropCount(length: over + 50), drop)
        XCTAssertEqual(PillLiveText.dropCount(length: over + PillLiveText.cutStep), drop + PillLiveText.cutStep)
    }

    func testWindowStartsAtAWordAndEndsWithTheNewestWords() {
        let text = (0..<800).map { "word\($0)" }.joined(separator: " ")
        let window = PillLiveText.window(text)
        XCTAssertLessThan(window.count, text.count)
        XCTAssertTrue(window.hasSuffix("word799"))
        XCTAssertTrue(window.hasPrefix("word"))
        XCTAssertTrue(text.hasSuffix(window))
    }

    func testOnlyAFullBlockRollsAndOnlyUpwards() {
        let maxHeight: CGFloat = 60
        // Still growing towards the block's height: no roll.
        XCTAssertEqual(PillLiveText.rollStart(current: 0, delta: 13, newHeight: 39, maxHeight: maxHeight), 0)
        // One more line than fits: the lines hold their place by that line, then roll.
        XCTAssertEqual(PillLiveText.rollStart(current: 0, delta: 13, newHeight: 78, maxHeight: maxHeight), 13)
        // A second line while the first roll is under way adds up.
        XCTAssertEqual(PillLiveText.rollStart(current: 6, delta: 13, newHeight: 91, maxHeight: maxHeight), 19)
        // The recogniser took a line back: snap.
        XCTAssertEqual(PillLiveText.rollStart(current: 6, delta: -13, newHeight: 78, maxHeight: maxHeight), 0)
        // Many lines at once never push the text out of the block.
        XCTAssertEqual(PillLiveText.rollStart(current: 0, delta: 400, newHeight: 500, maxHeight: maxHeight), maxHeight)
    }

    func testBlockHoldsFourLinesAndAFadingOne() {
        let line = PillLiveText.lineHeight(fontSize: 11)
        XCTAssertGreaterThan(line, 11)
        let height = PillLiveText.maxHeight(fontSize: 11)
        XCTAssertGreaterThan(height, line * 4)          // four readable lines …
        XCTAssertLessThanOrEqual(height, line * 5)      // … and one that fades out above them
    }
}

final class ScreenShareVisibilityTests: XCTestCase {
    func testHiddenWindowsAreLeftOutOfCaptures() {
        XCTAssertEqual(ScreenShareVisibility.sharingType(hidden: true), .none)
        XCTAssertEqual(ScreenShareVisibility.sharingType(hidden: false), .readOnly)
    }

    @MainActor
    func testRegisteredWindowFollowsTheSetting() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ScreenShareVisibility.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: ScreenShareVisibility.defaultsKey) }
            else { defaults.removeObject(forKey: ScreenShareVisibility.defaultsKey) }
        }
        defaults.removeObject(forKey: ScreenShareVisibility.defaultsKey)
        XCTAssertTrue(ScreenShareVisibility.hidesFromSharing)      // on unless turned off
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        ScreenShareVisibility.register(window)
        XCTAssertEqual(window.sharingType, .none)
        defaults.set(false, forKey: ScreenShareVisibility.defaultsKey)
        XCTAssertFalse(ScreenShareVisibility.hidesFromSharing)
        let shared = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        ScreenShareVisibility.register(shared)
        XCTAssertEqual(shared.sharingType, .readOnly)
    }
}
