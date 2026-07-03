import XCTest
@testable import Talkie

/// The pure "run [the] shortcut <name>" parser and the exact-name resolver (G8).
/// Both are deterministic and side-effect free — no Shortcut is ever executed here
/// (that requires the live `/usr/bin/shortcuts` and real user Shortcuts, which unit
/// tests must not touch). This is the whole matching contract; the router precedence
/// and the empty-replacement call-site guard live in `CommandRouterTests`.
final class RunShortcutParserTests: XCTestCase {

    // MARK: - Parser: the carrier phrase

    func testParsesPlainRunShortcut() {
        XCTAssertEqual(RunShortcutParser.parse("run shortcut Ship It"), "Ship It",
                       "the name after 'run shortcut' is captured with original casing")
    }

    func testParsesWithTheArticle() {
        XCTAssertEqual(RunShortcutParser.parse("run the shortcut Ship It"), "Ship It",
                       "'run the shortcut <name>' is accepted, the article is consumed")
    }

    func testCarrierIsCaseInsensitive() {
        XCTAssertEqual(RunShortcutParser.parse("RUN Shortcut Deploy"), "Deploy",
                       "the carrier words match case-insensitively; the name keeps its casing")
    }

    func testSingleWordName() {
        XCTAssertEqual(RunShortcutParser.parse("run shortcut Deploy"), "Deploy")
    }

    func testMultiWordNameKeepsSpacing() {
        XCTAssertEqual(RunShortcutParser.parse("run shortcut Post To Blog"), "Post To Blog",
                       "a multi-word shortcut name is joined back with single spaces")
    }

    // MARK: - Parser: the false-positive guards (the safety-critical cases)

    /// The headline acceptance criterion: dictation that merely starts with "run" but
    /// never says "shortcut" must NOT be treated as a command — it dictates literally.
    func testRunTheTestsIsNotACommand() {
        XCTAssertNil(RunShortcutParser.parse("run the tests then commit"),
                     "'run the tests then commit' has no 'shortcut' word — it must dictate normally")
    }

    func testRunWithoutShortcutWordIsNil() {
        XCTAssertNil(RunShortcutParser.parse("run the build"),
                     "no literal 'shortcut' after 'run' → not a run-shortcut command")
    }

    func testDoesNotStartWithRunIsNil() {
        XCTAssertNil(RunShortcutParser.parse("please run shortcut Ship It"),
                     "the carrier must LEAD; 'shortcut' mid-sentence is ordinary prose")
    }

    func testRunShortcutWithNoNameIsNil() {
        XCTAssertNil(RunShortcutParser.parse("run shortcut"),
                     "a carrier with no name to run is not a command")
        XCTAssertNil(RunShortcutParser.parse("run the shortcut"),
                     "carrier + article but no name is still not a command")
    }

    func testEmptyIsNil() {
        XCTAssertNil(RunShortcutParser.parse(""))
        XCTAssertNil(RunShortcutParser.parse("   "))
    }

    func testLeadingAndTrailingWhitespaceTolerated() {
        XCTAssertEqual(RunShortcutParser.parse("  run shortcut Ship It  "), "Ship It",
                       "surrounding whitespace is trimmed before parsing")
    }

    // MARK: - Resolver: exact, normalized, unambiguous only

    func testResolveExactMatch() {
        XCTAssertEqual(ShortcutsRunner.resolve("Ship It", in: ["Ship It", "Deploy"]), "Ship It")
    }

    func testResolveIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(ShortcutsRunner.resolve("ship it", in: ["Ship It"]), "Ship It",
                       "spoken lowercase resolves to the installed shortcut's real name")
        XCTAssertEqual(ShortcutsRunner.resolve("ship   it", in: ["Ship It"]), "Ship It",
                       "collapsed internal whitespace still matches")
    }

    func testResolveReturnsInstalledCasing() {
        // The returned name is what `shortcuts run` must receive — the installed casing,
        // not what the user happened to say.
        XCTAssertEqual(ShortcutsRunner.resolve("DEPLOY", in: ["Deploy"]), "Deploy")
    }

    func testResolveNoMatchReturnsNil() {
        XCTAssertNil(ShortcutsRunner.resolve("Delete Everything", in: ["Ship It", "Deploy"]),
                     "no installed shortcut by that name → nil (nothing runs)")
    }

    /// The destructive-misfire guard: two shortcuts that normalize the same are
    /// ambiguous, and ambiguity must REFUSE rather than guess which to run.
    func testResolveAmbiguousReturnsNil() {
        XCTAssertNil(ShortcutsRunner.resolve("deploy", in: ["Deploy", "deploy"]),
                     "two same-normalized names are ambiguous — never guess, return nil")
    }

    func testResolveEmptyRequestReturnsNil() {
        XCTAssertNil(ShortcutsRunner.resolve("", in: ["Ship It"]))
        XCTAssertNil(ShortcutsRunner.resolve("   ", in: ["Ship It"]))
    }

    func testResolveNoFuzzyMatch() {
        // v1 is exact-only: a near-miss must NOT match, so a user's "Ship" can never
        // fire "Ship It" (or vice-versa) by accident.
        XCTAssertNil(ShortcutsRunner.resolve("Ship", in: ["Ship It"]),
                     "exact-only: a substring is not a match")
        XCTAssertNil(ShortcutsRunner.resolve("Ship It Now", in: ["Ship It"]),
                     "exact-only: extra words are not a match")
    }

    func testNormalizeCollapsesWhitespaceAndLowercases() {
        XCTAssertEqual(ShortcutsRunner.normalize("  Ship\t It  "), "ship it")
    }
}
