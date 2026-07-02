import XCTest
@testable import Talkie

/// `InsertionVerifier` answers "did our paste actually land?" best-effort. The
/// verdict logic is a pure function over the sequence of field reads collected
/// during the watch window, so it's tested here with no live Accessibility:
///   • `.landed`        — some readable value contains the inserted text.
///   • `.notLanded`     — the field was readable, but the text never appeared.
///   • `.unverifiable`  — nothing was ever readable (Electron/web false-negative)
///                        → fail OPEN, never report a false miss.
/// Plus the reformatting case (smart quotes) that must still count as landed,
/// since apps rewrite punctuation on paste.
@MainActor
final class InsertionVerifierTests: XCTestCase {

    // MARK: landed

    /// The inserted text appears verbatim in a readable field → landed.
    func testLandedWhenValueContainsInserted() {
        let reads: [InsertionVerifier.ReadResult] = [.value("the correlate engine is running")]
        XCTAssertEqual(
            InsertionVerifier.decide(from: reads, inserted: "correlate engine"),
            .landed,
            "a readable field containing the inserted text must be judged landed")
    }

    /// The paste may only show up on a later poll (the target reads the pasteboard
    /// asynchronously); an earlier unreadable/blank poll must not shadow a later hit.
    func testLandedWhenTextAppearsOnLaterPoll() {
        let reads: [InsertionVerifier.ReadResult] = [
            .unreadable,
            .value(""),
            .value("Meeting notes: ship the deck Friday"),
        ]
        XCTAssertEqual(
            InsertionVerifier.decide(from: reads, inserted: "ship the deck Friday"),
            .landed,
            "a hit on any poll counts as landed even after earlier empty/unreadable polls")
    }

    // MARK: notLanded

    /// The field is readable throughout, but our text is nowhere in it → a genuine
    /// (best-effort) miss.
    func testNotLandedWhenReadableButTextAbsent() {
        let reads: [InsertionVerifier.ReadResult] = [
            .value("some other text"),
            .value("some other text still"),
        ]
        XCTAssertEqual(
            InsertionVerifier.decide(from: reads, inserted: "coralate engine"),
            .notLanded,
            "a readable field that never shows the inserted text is a real miss")
    }

    /// An empty readable field (value present, just "") is still readable — so if the
    /// text never lands it's a miss, not unverifiable.
    func testNotLandedWhenFieldReadableButEmpty() {
        let reads: [InsertionVerifier.ReadResult] = [.value(""), .value("")]
        XCTAssertEqual(
            InsertionVerifier.decide(from: reads, inserted: "hello there"),
            .notLanded,
            "an empty but readable field is a readable value, so an absent text is notLanded")
    }

    // MARK: unverifiable (fail open)

    /// No AX value was ever reachable — the Electron/web case. Must fail OPEN as
    /// unverifiable, never notLanded, so a paste into Slack/VS Code isn't flagged.
    func testUnverifiableWhenNeverReadable() {
        let reads: [InsertionVerifier.ReadResult] = [.unreadable, .unreadable, .unreadable, .unreadable]
        XCTAssertEqual(
            InsertionVerifier.decide(from: reads, inserted: "anything at all"),
            .unverifiable,
            "a field we can never read yields no signal — unverifiable, not a miss")
    }

    /// Degenerate: no polls happened at all (e.g. immediate cancellation) → still
    /// unverifiable, never a false miss.
    func testUnverifiableWhenNoReads() {
        XCTAssertEqual(
            InsertionVerifier.decide(from: [], inserted: "anything"),
            .unverifiable,
            "with zero reads there is no signal, so the verdict is unverifiable")
    }

    // MARK: reformatting tolerance

    /// Apps reformat on paste — straight quotes become smart quotes, hyphens become
    /// en/em dashes. The inserted text must still be recognized as landed.
    func testLandedDespiteSmartQuoteReformatting() {
        // Field shows curly apostrophe + em dash; we inserted the straight-ASCII form.
        let reads: [InsertionVerifier.ReadResult] = [
            .value("I\u{2019}ll send it \u{2014} promise"),
        ]
        XCTAssertEqual(
            InsertionVerifier.decide(from: reads, inserted: "I'll send it - promise"),
            .landed,
            "smart-quote / dash reformatting on paste must still count as landed")
    }

    /// The reverse skew (we inserted smart punctuation, the field normalized it to
    /// ASCII) must also be tolerated by the loose match.
    func testLandedWhenInsertedSmartFieldPlain() {
        let reads: [InsertionVerifier.ReadResult] = [.value("say \"hello\" now")]
        XCTAssertEqual(
            InsertionVerifier.decide(from: reads, inserted: "say \u{201C}hello\u{201D} now"),
            .landed,
            "loose matching must fold curly quotes so either skew direction counts as landed")
    }
}
