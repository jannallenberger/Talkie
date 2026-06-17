import XCTest
@testable import Talkie

/// Covers `LanguageDetector.switchTarget` — the pure core of the stop-time
/// acoustic language-switch decision (the dictation end-of-session block in
/// `AppDelegate`). The regression of interest (P1-10): when the current locale
/// produces no scored entry, the relative margin degrades to a near-zero bar and
/// a garbage `best` flips the language. The helper guards that with an absolute
/// floor.
final class LanguageSwitchDecisionTests: XCTestCase {
    typealias C = LanguageDetector.LanguageCandidate

    /// P1-10: no scored entry for the current language (its re-transcribe came back
    /// empty) and the best candidate is weak — must NOT switch. Pre-fix, the
    /// baseline was 0 and `best.confidence >= 0 + 0.08` waved this through.
    func testNoCurrentBaselineWeakBestDoesNotSwitch() {
        let scored = [
            C(localeID: "de-DE", text: "irgendein müll", confidence: 0.20),
        ]
        XCTAssertNil(
            LanguageDetector.switchTarget(among: scored, currentCode: "en"),
            "A weak best with no current-locale baseline must not trigger a switch."
        )
    }

    /// No current baseline, but the best candidate clears the absolute floor — a
    /// genuinely confident foreign-language result is allowed to win.
    func testNoCurrentBaselineConfidentBestSwitches() {
        let scored = [
            C(localeID: "de-DE", text: "das ist ein test", confidence: 0.80),
        ]
        let target = LanguageDetector.switchTarget(among: scored, currentCode: "en")
        XCTAssertEqual(target?.localeID, "de-DE")
    }

    /// A candidate exactly on the absolute floor is allowed (>=), one just under is
    /// rejected.
    func testNoCurrentBaselineFloorBoundary() {
        let onFloor = [C(localeID: "de-DE", text: "auf der schwelle", confidence: LanguageDetector.switchAbsoluteFloor)]
        XCTAssertEqual(LanguageDetector.switchTarget(among: onFloor, currentCode: "en")?.localeID, "de-DE")

        let underFloor = [C(localeID: "de-DE", text: "knapp darunter", confidence: LanguageDetector.switchAbsoluteFloor - 0.01)]
        XCTAssertNil(LanguageDetector.switchTarget(among: underFloor, currentCode: "en"))
    }

    /// With a current-language baseline present, the relative margin governs: a
    /// candidate that beats the incumbent by the margin wins.
    func testBeatsIncumbentByMargin() {
        let scored = [
            C(localeID: "en-US", text: "this is english-ish", confidence: 0.40),
            C(localeID: "de-DE", text: "das ist deutsch", confidence: 0.40 + LanguageDetector.switchConfidenceMargin),
        ]
        XCTAssertEqual(
            LanguageDetector.switchTarget(among: scored, currentCode: "en")?.localeID,
            "de-DE"
        )
    }

    /// A candidate that beats the incumbent but by less than the margin must not
    /// switch (avoid flips on near-ties).
    func testDoesNotSwitchWithinMargin() {
        let scored = [
            C(localeID: "en-US", text: "this is english", confidence: 0.60),
            C(localeID: "de-DE", text: "knapp besser", confidence: 0.60 + LanguageDetector.switchConfidenceMargin - 0.01),
        ]
        XCTAssertNil(LanguageDetector.switchTarget(among: scored, currentCode: "en"))
    }

    /// The best candidate is the current language: nothing to switch to. (Here the
    /// incumbent is also the strongest — even an empty-floor path can't apply.)
    func testBestIsCurrentLanguageNoSwitch() {
        let scored = [
            C(localeID: "en-US", text: "clearly english", confidence: 0.90),
            C(localeID: "de-DE", text: "weniger gut", confidence: 0.30),
        ]
        XCTAssertNil(LanguageDetector.switchTarget(among: scored, currentCode: "en"))
    }

    /// A confident winner with empty text never wins (nothing to insert).
    func testEmptyTextNeverSwitches() {
        let scored = [
            C(localeID: "de-DE", text: "", confidence: 0.95),
        ]
        XCTAssertNil(LanguageDetector.switchTarget(among: scored, currentCode: "en"))
    }

    /// en-US and en-GB are the same language to the recognizer: a stronger en-GB
    /// candidate is not a "switch" away from an en-US session.
    func testSameLanguageCodeNotASwitch() {
        let scored = [
            C(localeID: "en-US", text: "current", confidence: 0.50),
            C(localeID: "en-GB", text: "stronger but same language", confidence: 0.95),
        ]
        XCTAssertNil(LanguageDetector.switchTarget(among: scored, currentCode: "en"))
    }

    /// Empty candidate set keeps the current language.
    func testEmptyScoredKeepsCurrent() {
        XCTAssertNil(LanguageDetector.switchTarget(among: [], currentCode: "en"))
    }
}
