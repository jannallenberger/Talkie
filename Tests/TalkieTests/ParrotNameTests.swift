import XCTest
@testable import Talkie

/// K6 — "Name your parrot" is two pure seams: the name NORMALIZER on
/// `AppSettings` (trim + 24-char cap, idempotent) and the name-aware learned-ping
/// BUILDER on `AppDelegate`. Both are static and side-effect-free, so they test
/// without a running app or a live `UserDefaults`.
///
/// Note on localization: under `swift test` the bundle is the test runner, so
/// `.loc` finds no `Localizable.strings` and falls back to the English key text.
/// Every expectation below is therefore the English source format with its
/// arguments filled — deterministic regardless of the host machine's language.
///
/// `@MainActor` because both seams live on main-actor-isolated types
/// (`AppSettings`, `AppDelegate`), so their statics are called synchronously here.
@MainActor
final class ParrotNameTests: XCTestCase {

    // MARK: - Normalizer: trimming

    func testTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(AppSettings.normalizedParrotName("  Kiwi  "), "Kiwi")
        XCTAssertEqual(AppSettings.normalizedParrotName("\tKiwi\n"), "Kiwi")
    }

    func testAllWhitespaceCollapsesToEmpty() {
        XCTAssertEqual(AppSettings.normalizedParrotName("     "), "")
        XCTAssertEqual(AppSettings.normalizedParrotName("\n\t "), "")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(AppSettings.normalizedParrotName(""), "")
    }

    func testInteriorWhitespaceIsPreserved() {
        // Only the ends are trimmed — a two-word bird name survives intact.
        XCTAssertEqual(AppSettings.normalizedParrotName("  Sir Squawks  "), "Sir Squawks")
    }

    // MARK: - Normalizer: length cap

    func testCapsAtMaxLength() {
        let long = String(repeating: "a", count: 40)
        let out = AppSettings.normalizedParrotName(long)
        XCTAssertEqual(out.count, AppSettings.parrotNameMaxLength)
        XCTAssertEqual(out, String(repeating: "a", count: AppSettings.parrotNameMaxLength))
    }

    func testNameAtExactlyMaxLengthIsUntouched() {
        let exact = String(repeating: "b", count: AppSettings.parrotNameMaxLength)
        XCTAssertEqual(AppSettings.normalizedParrotName(exact), exact)
    }

    func testTrimHappensBeforeCap() {
        // Padding shouldn't eat into the 24-char budget: trim first, then measure.
        let padded = "   " + String(repeating: "c", count: AppSettings.parrotNameMaxLength) + "   "
        let out = AppSettings.normalizedParrotName(padded)
        XCTAssertEqual(out.count, AppSettings.parrotNameMaxLength)
    }

    func testCapCountsGraphemesNotUTF16() {
        // An emoji is one grapheme cluster (several UTF-16 code units); the cap must
        // count clusters so a name of 24 emoji is kept whole, not split mid-emoji.
        let emojiName = String(repeating: "🦜", count: AppSettings.parrotNameMaxLength)
        let out = AppSettings.normalizedParrotName(emojiName)
        XCTAssertEqual(out.count, AppSettings.parrotNameMaxLength)
        XCTAssertEqual(out, emojiName)
    }

    // MARK: - Normalizer: idempotence (the didSet re-entrancy guard depends on this)

    func testNormalizationIsIdempotent() {
        for raw in ["  Kiwi  ", "", "     ",
                    String(repeating: "z", count: 99),
                    "🦜🦜🦜 Polly the Third of Featherington 🦜🦜🦜"] {
            let once = AppSettings.normalizedParrotName(raw)
            let twice = AppSettings.normalizedParrotName(once)
            XCTAssertEqual(once, twice, "normalizer must be a fixed point for \(raw.debugDescription)")
        }
    }

    // MARK: - Learned-ping builder: named bird

    func testNamedBirdPingUsesTheName() {
        let msg = AppDelegate.learnedPingMessage(parrotName: "Kiwi", to: "claude.md", source: .fieldEdit)
        XCTAssertEqual(msg, "Kiwi learned “claude.md”")
    }

    func testNamedBirdPingIgnoresSource() {
        // With a name, both learn sources speak in the bird's voice — the name is
        // the stronger ownership signal than the "from your Claude Code prompt" nuance.
        let field = AppDelegate.learnedPingMessage(parrotName: "Kiwi", to: "kubernetes", source: .fieldEdit)
        let claude = AppDelegate.learnedPingMessage(parrotName: "Kiwi", to: "kubernetes", source: .claudeCode)
        XCTAssertEqual(field, claude)
        XCTAssertEqual(field, "Kiwi learned “kubernetes”")
    }

    func testNamedBirdPingNormalizesRawName() {
        // A caller-supplied (untrimmed / over-long) name is normalized in the builder
        // too, so the ping never shows padding or an essay-length name.
        let padded = AppDelegate.learnedPingMessage(parrotName: "  Polly  ", to: "x", source: .fieldEdit)
        XCTAssertEqual(padded, "Polly learned “x”")

        let long = String(repeating: "n", count: 40)
        let capped = AppDelegate.learnedPingMessage(parrotName: long, to: "x", source: .fieldEdit)
        let expectedName = String(repeating: "n", count: AppSettings.parrotNameMaxLength)
        XCTAssertEqual(capped, "\(expectedName) learned “x”")
    }

    // MARK: - Learned-ping builder: unnamed fallback (empty name changes nothing)

    func testUnnamedFieldEditFallsBackToPlainCopy() {
        let msg = AppDelegate.learnedPingMessage(parrotName: "", to: "coralate", source: .fieldEdit)
        XCTAssertEqual(msg, "Added “coralate” to dictionary")
    }

    func testUnnamedClaudeCodeKeepsItsSourceNuance() {
        let msg = AppDelegate.learnedPingMessage(parrotName: "", to: "higgsfield", source: .claudeCode)
        XCTAssertEqual(msg, "Added “higgsfield” — from your Claude Code prompt")
    }

    func testWhitespaceOnlyNameIsTreatedAsUnnamed() {
        // A name that normalizes to empty must take the unnamed path, not render
        // " learned …" with a blank subject.
        let msg = AppDelegate.learnedPingMessage(parrotName: "   ", to: "term", source: .fieldEdit)
        XCTAssertEqual(msg, "Added “term” to dictionary")
    }
}
