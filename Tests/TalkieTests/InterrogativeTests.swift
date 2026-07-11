import XCTest
@testable import Talkie

/// Pure-logic tests for the deterministic "does this read as a question?" check
/// shared by the dictation answer-guard (`CleanupEngine.looksLikeAnswer`) and the
/// meeting pill's instant far-end question detector (`MeetingSubtopicEngine`).
final class InterrogativeTests: XCTestCase {
    func testExplicitQuestionMarkEnglish() {
        XCTAssertTrue(Interrogative.isQuestion("What time is the meeting?"))
    }

    func testExplicitQuestionMarkGerman() {
        XCTAssertTrue(Interrogative.isQuestion("Wie spät ist es?"))
    }

    func testLeadingQuestionWordWithoutQuestionMark() {
        XCTAssertTrue(Interrogative.isQuestion("what got you into this"),
                      "a spoken question with no recognizer punctuation still counts")
    }

    func testLeadingQuestionWordGermanWithoutQuestionMark() {
        XCTAssertTrue(Interrogative.isQuestion("kannst du mir helfen"))
    }

    func testPlainStatementIsNotAQuestion() {
        XCTAssertFalse(Interrogative.isQuestion("The budget review went well."))
    }

    func testPlainImperativeIsNotAQuestion() {
        XCTAssertFalse(Interrogative.isQuestion("Send me the file when you get a chance."))
    }

    func testEmptyStringIsNotAQuestion() {
        XCTAssertFalse(Interrogative.isQuestion(""))
    }

    func testWhitespaceOnlyIsNotAQuestion() {
        XCTAssertFalse(Interrogative.isQuestion("   "))
    }

    // MARK: - Long dictation with an embedded question (regression)

    /// A long, rambling, multi-sentence dictation that happens to contain ONE embedded
    /// question mid-paragraph must NOT read as "the whole utterance is a question" — that
    /// false positive let CleanupEngine's answer-guard reject a legitimate long cleanup
    /// rewrite (which plausibly drops that one "?" while paraphrasing) and fall back to
    /// the raw, unpolished transcript for the entire dictation.
    func testLongMonologueWithOneEmbeddedQuestionIsNotAQuestion() {
        let longDictation = String(repeating: "We need to plan the rollout carefully. ", count: 10)
            + "What will the identity of those influencers be? "
            + String(repeating: "Then we will need to generate the content and put text over it. ", count: 5)
        XCTAssertGreaterThan(longDictation.count, 300, "precondition: this must exceed the short-text threshold")
        XCTAssertFalse(Interrogative.isQuestion(longDictation),
                       "one embedded '?' among dozens of statement sentences doesn't make the whole thing a question")
    }

    /// The same long-text scope still correctly recognizes a genuine question when the
    /// "?" is TERMINAL — a longer message that closes with a question (however long the
    /// lead-up) is legitimately a question as a whole.
    func testLongMessageEndingInAQuestionIsAQuestion() {
        let longQuestion = String(repeating: "We need to plan the rollout carefully. ", count: 10)
            + "So given all of that, what do you think the identity of those influencers should be?"
        XCTAssertGreaterThan(longQuestion.count, 300, "precondition: this must exceed the short-text threshold")
        XCTAssertTrue(Interrogative.isQuestion(longQuestion),
                      "a long message that closes with a question is still a question overall")
    }

    /// A short dictation with an embedded (non-terminal) "?" is still short enough that
    /// one question mark plausibly covers most of it — stays a question, unaffected by
    /// the long-text scoping above.
    func testShortTextWithEmbeddedQuestionMarkIsStillAQuestion() {
        XCTAssertTrue(Interrogative.isQuestion("Wait, what time is it? I need to leave soon."))
    }
}
