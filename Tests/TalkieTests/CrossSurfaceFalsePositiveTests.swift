import XCTest
@testable import Talkie

/// Guards `CrossSurfaceParser.parse(_:)` against intercepting ordinary dictation.
/// The cross-surface command path is opt-in and, once enabled, runs on every
/// dictation ahead of normal insertion — a false positive here doesn't just
/// misfire a command, it silently eats the user's real spoken words and
/// replaces them with an unrelated preview pill. This checklist was written
/// against a confirmed gap (an earlier, unscoped "commit to" substring match
/// intercepted "I'll commit to finishing this by Friday" spoken as literal
/// content) and must keep passing before `crossSurfaceCommandsEnabled` is ever
/// defaulted to `true`.
final class CrossSurfaceFalsePositiveTests: XCTestCase {

    // MARK: Must NOT parse (ordinary dictation, including near-miss phrasing)

    func testLiteralCommitmentSentenceIsNotIntercepted() {
        XCTAssertNil(CrossSurfaceParser.parse("I'll commit to finishing this by Friday"),
                     "a literal dictated sentence must not be read as 'what did I commit to'")
    }

    func testCasualCommitQuestionIsNotIntercepted() {
        XCTAssertNil(CrossSurfaceParser.parse("can you commit to a deadline on this"))
    }

    func testCommitmentNounPhraseIsNotIntercepted() {
        XCTAssertNil(CrossSurfaceParser.parse("I have a strong commitment to quality"))
    }

    func testMeetingMentionWithoutContentKindIsNotIntercepted() {
        XCTAssertNil(CrossSurfaceParser.parse("let's schedule a meeting for Tuesday"),
                     "mentions 'meeting' but has no content-kind word (action items/decisions/summary)")
    }

    func testMeetingNotesAttachedDictatesLiterally() {
        // "meeting" + "notes" (-> .summary) with NO explicit meeting reference must
        // NOT parse (F4). This used to fall back to `.last` and draft the newest
        // meeting — the one documented dictation-interception case. It was always a
        // false positive dressed up as "by design": a person saying "the meeting
        // notes are attached" is narrating a fact, not commanding, and this intent
        // runs on every dictation once enabled. The `.last` fallback is now gone, so
        // the parser only fires when the user actually points at a meeting ("my last
        // meeting", "yesterday", "the meeting with Sarah"). This one dictates
        // literally, exactly as spoken.
        XCTAssertNil(CrossSurfaceParser.parse("the meeting notes are attached"),
                     "a bare 'meeting'+'notes' statement with no explicit reference must dictate literally, not draft the last meeting")
    }

    func testNotesFromLunchWithoutMeetingIsNotIntercepted() {
        XCTAssertNil(CrossSurfaceParser.parse("I'll email Sarah the notes from today's lunch"),
                     "not a meeting; 'notes' alone without 'meeting' must not qualify")
    }

    // MARK: Neutral control set — zero trigger words

    func testWeatherSentenceIsNotACommand() {
        XCTAssertNil(CrossSurfaceParser.parse("the weather is nice today"))
    }

    func testGroceryListSentenceIsNotACommand() {
        XCTAssertNil(CrossSurfaceParser.parse("please buy milk and eggs"))
    }

    // MARK: Expanded dictation corpus (F4 safety gate)
    //
    // ~50 realistic dictated utterances that brush against the parser's trigger
    // vocabulary — the word "meeting", a content-kind word ("notes", "summary",
    // "action items", "decision"), a channel verb ("email", "send", "message"),
    // a date word ("today", "yesterday"), or the stem "commit"/"promise" — yet are
    // ordinary prose a person would speak, not a command aimed at their own
    // meetings. Every one must return nil so it dictates literally. This is the
    // gate the whole feature-enable decision rests on: because the intent runs on
    // EVERY dictation once the toggle is on, any parse here is a false positive
    // that eats the user's real words and shows a preview pill instead.
    //
    // Traced by hand against `CrossSurfaceParser.parse` at authoring time: none
    // combine the literal word "meeting" + a content kind + an explicit meeting
    // reference (`meetingRef`), and none begin with / contain a commitment
    // query lead-in ("what did I commit", "did I promise", …).

    /// Utterances that mention "meeting" but aren't a command about one (no
    /// content kind, or no explicit meeting reference, or both).
    func testMeetingAdjacentProseDictatesLiterally() {
        let corpus = [
            "the meeting notes are attached",
            "the meeting notes should be attached to the invite",
            "I already sent the meeting notes around",
            "can we move the meeting to Thursday afternoon",
            "the meeting ran long so I skipped lunch",
            "she is in a meeting until three",
            "let's find a meeting room on the fourth floor",
            "the all-hands meeting was pretty inspiring",
            "I think the meeting could have been an email honestly",
            "please book a meeting with the vendor next quarter",
            "the standing meeting is cancelled this week",
            "our meeting agenda has too many items on it",
            "the summary of the meeting was posted to the wiki by someone else",
            "the decision from the meeting still isn't final",
            "action items from meetings tend to pile up fast",
            "I owe you the recap but the meeting just wrapped",
            "we never took any notes during that meeting",
            "the meeting felt productive even without an agenda",
            "there's a follow-up meeting on the calendar already",
        ]
        for phrase in corpus {
            XCTAssertNil(CrossSurfaceParser.parse(phrase),
                         "meeting-adjacent prose must dictate literally: \u{201c}\(phrase)\u{201d}")
        }
    }

    /// Literal spoken commitments and promises — content the user is dictating,
    /// not a "what did I commit to" query.
    func testLiteralCommitmentsAndPromisesDictateLiterally() {
        let corpus = [
            "I'll commit to finishing this by Friday",
            "I commit to reviewing the pull request tonight",
            "we should commit these changes before lunch",
            "let's commit to a decision by end of week",
            "I promise I'll get to it this afternoon",
            "I promised the team a demo on Tuesday",
            "he made a real commitment to the project",
            "our commitment to privacy is the whole point",
            "commit the file and push it when you're done",
            "I can't promise anything until I see the numbers",
            "she committed to shipping before the holidays",
            "remember to commit early and commit often",
            "the commitment ceremony is next spring",
            "I promise this is the last change today",
        ]
        for phrase in corpus {
            XCTAssertNil(CrossSurfaceParser.parse(phrase),
                         "a literal commitment/promise must dictate literally: \u{201c}\(phrase)\u{201d}")
        }
    }

    /// Email / message dictation — the utterance opens with (or contains) a
    /// channel verb, but it's prose being dictated INTO a message, not a
    /// cross-surface command.
    func testEmailAndMessageDictationDictatesLiterally() {
        let corpus = [
            "email me the file when you get a chance",
            "email the team that I'll be five minutes late",
            "send Sarah the invoice from the accounting folder",
            "send me a reminder tomorrow morning",
            "message the group that lunch is here",
            "tell Bob the build is finally green",
            "ping me when the deploy finishes",
            "text mom that I'll call her tonight",
            "email everyone the updated agenda for tomorrow",
            "send over the notes whenever you can",
            "let me email you the summary later today",
            "message me the decisions once they're made",
            "write up the action items and send them out",
            "email the client a recap of where we landed",
        ]
        for phrase in corpus {
            XCTAssertNil(CrossSurfaceParser.parse(phrase),
                         "email/message dictation must dictate literally: \u{201c}\(phrase)\u{201d}")
        }
    }

    /// Content-kind words (notes / summary / decision / action items / recap)
    /// and date words in ordinary prose, with no "meeting" anchor.
    func testContentKindAndDateProseDictatesLiterally() {
        let corpus = [
            "here are my notes from the conference talk",
            "the summary at the top needs a rewrite",
            "that was a tough decision but the right one",
            "the action items are all overdue at this point",
            "let's do a quick recap of the quarter",
            "today is going to be a long one",
            "yesterday's game went into overtime",
            "the overview slide is missing a chart",
            "next steps are unclear until we hear back",
            "I took notes on the lecture this morning",
            "the decisions we made last year held up well",
            "give me a recap of the weekend when you're free",
            "the to-do list is a mile long today",
        ]
        for phrase in corpus {
            XCTAssertNil(CrossSurfaceParser.parse(phrase),
                         "content-kind/date prose without a meeting must dictate literally: \u{201c}\(phrase)\u{201d}")
        }
    }

    // MARK: Must parse (the actual feature working)

    func testCommitmentQuestionParses() {
        XCTAssertNotNil(CrossSurfaceParser.parse("what did I commit to this week"))
    }

    func testCrossSurfaceMeetingRequestParses() {
        XCTAssertNotNil(CrossSurfaceParser.parse("email Sarah the action items from my last meeting"))
    }
}
