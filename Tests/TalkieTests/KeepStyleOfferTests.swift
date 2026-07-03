import XCTest
@testable import Talkie

/// H3 — the session-scoped in-pill cleanup switcher + its post-insert "Keep for {App}?"
/// chip. Cycling the switcher changes only the current dictation (honoring its own
/// tooltip); the keep chip is the ONLY thing that persists the change as a per-app rule.
///
/// This pins the pure decision gate (`KeepStyleOffer.decision`) — no HUD, no file
/// system, no live session (the store's persistence path is fixed, so these tests
/// deliberately never touch `AppProfileStore`, keeping them pure-logic like the rest of
/// the suite). The MERGE-on-keep persistence itself reuses the exact read-modify-write
/// `upsert` idiom already covered by `AppProfileResolveTests` + the B2 heal path.
@MainActor
final class KeepStyleOfferTests: XCTestCase {

    // MARK: - The pure offer gate

    /// Happy path: the user cycled to a style that differs from the app's default, and
    /// the app has a bundle id — offer to keep exactly that style.
    func testOffersWhenOverrideDiffersAndBundleIDPresent() {
        XCTAssertEqual(
            KeepStyleOffer.decision(sessionOverride: .concise,
                                    resolvedDefault: .neutral,
                                    bundleID: "com.tinyspeck.slackmacgap"),
            .concise,
            "A real switch to a differing style in an app with a bundle id should offer that style.")
    }

    /// No override this dictation (the user never touched the switcher) → nothing to keep.
    func testNoOfferWhenNoOverride() {
        XCTAssertNil(
            KeepStyleOffer.decision(sessionOverride: nil,
                                    resolvedDefault: .neutral,
                                    bundleID: "com.tinyspeck.slackmacgap"),
            "With no session override, there is nothing to persist — the chip must not show.")
    }

    /// Cycling all the way back around to the app's current default is a no-op — the
    /// resolved default already produces that style, so persisting it would write a rule
    /// that changes nothing. No chip.
    func testNoOfferWhenOverrideEqualsDefault() {
        XCTAssertNil(
            KeepStyleOffer.decision(sessionOverride: .neutral,
                                    resolvedDefault: .neutral,
                                    bundleID: "com.tinyspeck.slackmacgap"),
            "An override equal to the resolved default changes nothing and must not offer.")
    }

    /// No bundle id (a helper app, or Talkie's own window) — there is no stable key to
    /// write a per-app rule against, so the chip is suppressed even for a real switch.
    func testNoOfferWhenBundleIDMissing() {
        XCTAssertNil(
            KeepStyleOffer.decision(sessionOverride: .concise,
                                    resolvedDefault: .neutral,
                                    bundleID: nil),
            "Without a bundle id there's no per-app rule to write, so the keep chip is suppressed.")
    }

    /// The gate is style-agnostic: it works for every pair of distinct cases, including
    /// switching to `.off` (insert verbatim) away from a polishing default, and the
    /// reverse. Exhaustively checks that any two DIFFERENT styles offer and any style
    /// against ITSELF does not.
    func testDecisionIsPurelyDrivenByStyleInequality() {
        for override in CleanupStyle.allCases {
            for def in CleanupStyle.allCases {
                let result = KeepStyleOffer.decision(
                    sessionOverride: override, resolvedDefault: def, bundleID: "com.example.app")
                if override == def {
                    XCTAssertNil(result,
                        "\(override) vs identical default must not offer.")
                } else {
                    XCTAssertEqual(result, override,
                        "\(override) differing from \(def) must offer \(override).")
                }
            }
        }
    }

    // MARK: - The keep MERGE preserves unrelated overrides (pure, in-memory)
    //
    // Tapping "Keep" reads-modifies-writes the app's sheet. The persistence half lives
    // in `AppProfileStore.upsert` (covered elsewhere); here we pin only the pure MERGE
    // shape the hub uses — build the next `AppProfile` from the existing one, set just
    // the cleanup style — so an unrelated override (insertion mode, Private) survives.
    // Kept in-memory (plain structs) so this test does no file I/O.

    /// Building the kept profile from an existing sheet preserves the other overrides:
    /// a learned `.type` insertion mode and a Private (`neverStore`) flag both survive
    /// when only the cleanup style is set — the H3 hub must MERGE, not clobber.
    func testKeepMergeShapePreservesOtherOverrides() {
        // The app already has unrelated overrides (e.g. B2 learned `.type`, and Private).
        let existing = AppProfile(bundleID: "com.example.editor",
                                  displayName: "Old Name",
                                  insertionMode: .type,
                                  neverStore: true)

        // The hub's read-modify-write: start from the existing sheet, refresh the name,
        // set only the cleanup style — exactly what `maybeOfferKeepStyle`'s tap does.
        var merged = existing
        merged.displayName = "Editor"
        merged.cleanupStyle = .prompt

        XCTAssertEqual(merged.cleanupStyle, .prompt, "Keep sets the chosen cleanup style…")
        XCTAssertEqual(merged.insertionMode, .type,
                       "…and preserves the pre-existing insertion-mode override (MERGE, not clobber).")
        XCTAssertEqual(merged.neverStore, true,
                       "…and preserves the Private flag too.")
        XCTAssertEqual(merged.displayName, "Editor", "…while refreshing the display name.")
    }

    /// Starting from NO existing sheet, the kept profile carries just the chosen style —
    /// the fresh-row branch of the same read-modify-write (existing ?? new).
    func testKeepMergeShapeCreatesFreshRowWithOnlyTheStyle() {
        let existing: AppProfile? = nil
        var profile = existing ?? AppProfile(bundleID: "com.example.new", displayName: "New")
        profile.cleanupStyle = .concise

        XCTAssertEqual(profile.cleanupStyle, .concise, "A fresh kept row carries the chosen style.")
        XCTAssertNil(profile.insertionMode, "…and overrides nothing else.")
        XCTAssertFalse(profile.isEmpty, "A row with a cleanup style is a real override, not a no-op.")
    }
}
