import XCTest
@testable import Talkie

/// The vibe-coding corrector-term surface gate (WP4/4e): `AppDelegate.endDictation`
/// only folds vibe-sourced terms (active-file identifiers + the vibe snapshot's
/// mined repo/Obsidian jargon) into the corrector's term list on a coding/terminal
/// surface. Feeding those identifiers into a chat dictation caused a real
/// self-inflicted correction ("sense" → "sensor") purely because a repo identifier
/// happened to be sitting in the vibe snapshot. `AppDelegate.vibeSurfaceEnabled` is
/// the pure gate extracted from that call site so it's unit-testable without a live
/// dictation session (mirrors `AppDelegate.learnedPingMessage`'s extraction).
///
/// `@MainActor` because `AppDelegate` (and hence its statics) is main-actor
/// isolated — mirrors `ParrotNameTests`, which extracts/tests `learnedPingMessage`
/// the same way.
@MainActor
final class VibeSurfaceGateTests: XCTestCase {
    func testExcludedForChatCategory() {
        XCTAssertFalse(AppDelegate.vibeSurfaceEnabled(vibeOn: true, category: .chat),
                       "vibe-sourced corrector terms must never reach a chat dictation")
    }

    func testExcludedForOtherCategories() {
        for category: AppCategory in [.browser, .mail, .notes, .design, .other] {
            XCTAssertFalse(AppDelegate.vibeSurfaceEnabled(vibeOn: true, category: category),
                           "\(category) is not a coding/terminal surface")
        }
    }

    func testIncludedForCodingAndTerminal() {
        XCTAssertTrue(AppDelegate.vibeSurfaceEnabled(vibeOn: true, category: .coding))
        XCTAssertTrue(AppDelegate.vibeSurfaceEnabled(vibeOn: true, category: .terminal))
    }

    func testOffWhenVibeCodingIsOff() {
        XCTAssertFalse(AppDelegate.vibeSurfaceEnabled(vibeOn: false, category: .coding),
                       "the category gate never overrides the vibeOn toggle")
    }
}
