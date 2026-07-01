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

    func testMeetingNotesAttachedFallsBackToLastMeetingOnPurpose() {
        // "meeting" + "notes" (-> .summary) with no explicit ref falls back to
        // `.last` by design (CrossSurfaceParser.swift:275) — this one IS expected
        // to parse. Documented here as a known, accepted match, not a false
        // positive: a user saying this mid-dictation is a real edge case worth
        // being aware of, but the intercepted result is still preview-only
        // (never silently injected), so the blast radius is a pill, not lost text.
        XCTAssertNotNil(CrossSurfaceParser.parse("the meeting notes are attached"))
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

    // MARK: Must parse (the actual feature working)

    func testCommitmentQuestionParses() {
        XCTAssertNotNil(CrossSurfaceParser.parse("what did I commit to this week"))
    }

    func testCrossSurfaceMeetingRequestParses() {
        XCTAssertNotNil(CrossSurfaceParser.parse("email Sarah the action items from my last meeting"))
    }
}
