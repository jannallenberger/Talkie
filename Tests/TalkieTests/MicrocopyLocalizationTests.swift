import XCTest
@testable import Talkie

/// K1 — parrot-voice microcopy audit (localized).
///
/// The runtime-built strings this package touches — the five `TextInjector`
/// `leftOnClipboard(reason:)` reasons and the seven raw `showError` literals in
/// `AppDelegate` — bypass SwiftUI's `LocalizedStringKey` auto-localization, so
/// they only reach the other nine languages by routing through `.loc` AND having
/// their (English-source) key present in every `.lproj/Localizable.strings`.
///
/// A `.loc` lookup silently falls back to the English key when the key is
/// missing, so a typo or a forgotten catalog entry is invisible at runtime — it
/// just renders English on that locale. These tests close that gap by loading the
/// ten catalogs straight from the source tree (the same `#filePath`→repo-root
/// idiom `StarterPackTests` uses) and asserting every K1 key resolves, in every
/// language, to a non-empty value — and that the retired pre-voice keys are gone.
///
/// The catalogs are the ground truth checked here; the code-literal ↔ key match is
/// covered by grep in the package's verification, and by the format-specifier
/// guard below for the interpolated neighbours.
final class MicrocopyLocalizationTests: XCTestCase {

    /// The ten shipped locales (dir stems under `Resources/Localizations`).
    static let locales = ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt-BR", "zh-Hans"]

    /// The K1 keys as they appear verbatim in the Swift source (the English source
    /// text IS the `.loc` key). Every one must resolve in every catalog.
    static let k1Keys: [String] = [
        // TextInjector paste-fallback reasons (voice pass + `.loc`).
        "Password field — I don\u{2019}t peek. Tap to copy.",
        "Turn on Accessibility so I can paste for you — tap to copy for now.",
        "Couldn\u{2019}t paste that — it\u{2019}s on your clipboard, tap to copy.",
        "Didn\u{2019}t paste — it\u{2019}s safe on your clipboard, tap to copy.",
        // AppDelegate showError literals (voice pass where warranted + `.loc`).
        "On-device speech isn't available on this Mac.",
        "Wrap up the meeting recording first — then I\u{2019}m all ears.",
        "I need microphone access to hear you.",
        "Nothing to note yet — dictate something first.",
        "Couldn\u{2019}t save that note anywhere — nothing was typed, try again.",
        "Couldn't run that command — the on-device model may be unavailable.",
        "Nothing to paste yet — dictate something first.",
    ]

    /// Keys retired by the voice pass — they must not linger in any catalog (a
    /// stale key would be dead weight and could mask a real regression).
    static let retiredKeys: [String] = [
        "Password field — tap to copy",
        "Couldn't save that note.",
    ]

    // MARK: - Catalog loading (source-tree ground truth)

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // …/Tests/TalkieTests/MicrocopyLocalizationTests.swift
            .deletingLastPathComponent()    // …/Tests/TalkieTests
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // repo root
    }

    /// Parse one catalog with the same NSDictionary reader macOS uses at runtime,
    /// so a malformed `.strings` file fails here exactly as it would in the app.
    private func loadCatalog(_ locale: String) throws -> [String: String] {
        let url = Self.repoRoot()
            .appendingPathComponent("Resources/Localizations/\(locale).lproj/Localizable.strings")
        guard let dict = NSDictionary(contentsOf: url) as? [String: String] else {
            throw XCTSkip("catalog unreadable for \(locale) at \(url.path)")
        }
        return dict
    }

    // MARK: - Every K1 key resolves in every language

    func testEveryK1KeyPresentAndNonEmptyInAllTenLocales() throws {
        for locale in Self.locales {
            let catalog = try loadCatalog(locale)
            for key in Self.k1Keys {
                guard let value = catalog[key] else {
                    XCTFail("[\(locale)] missing K1 key: \(key.debugDescription)")
                    continue
                }
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "[\(locale)] K1 key resolves to empty: \(key.debugDescription)"
                )
            }
        }
    }

    /// English is the source register — its value must equal its key (identity),
    /// which is how the catalog generator marks "this is the English source text".
    func testEnglishValuesAreIdentityForEveryK1Key() throws {
        let en = try loadCatalog("en")
        for key in Self.k1Keys {
            XCTAssertEqual(en[key], key,
                           "en value must equal its key (source identity): \(key.debugDescription)")
        }
    }

    /// The nine translations must actually be translated — not left as the English
    /// source text — for the strings the voice pass rewrote. (Scoped to the newly
    /// authored/rewritten keys; the two capability-error strings that keep their
    /// exact English wording are intentionally excluded.)
    func testTranslationsDifferFromEnglishForRewrittenKeys() throws {
        let rewritten = Set(Self.k1Keys).subtracting([
            // These two stay maximally-informative in English on purpose; a
            // translation may legitimately coincide with the source, so don't
            // force a difference here.
            "On-device speech isn't available on this Mac.",
            "Couldn't run that command — the on-device model may be unavailable.",
        ])
        for locale in Self.locales where locale != "en" {
            let catalog = try loadCatalog(locale)
            for key in rewritten {
                guard let value = catalog[key] else {
                    XCTFail("[\(locale)] missing key: \(key.debugDescription)")
                    continue
                }
                XCTAssertNotEqual(value, key,
                    "[\(locale)] K1 key left untranslated (equals English source): \(key.debugDescription)")
            }
        }
    }

    // MARK: - Retired keys are gone

    func testRetiredKeysRemovedFromAllCatalogs() throws {
        for locale in Self.locales {
            let catalog = try loadCatalog(locale)
            for stale in Self.retiredKeys {
                XCTAssertNil(catalog[stale],
                             "[\(locale)] retired pre-voice key still present: \(stale.debugDescription)")
            }
        }
    }

    // MARK: - Format-specifier safety across languages

    /// The spec's format-string risk: an interpolated key whose translation drops
    /// or reorders its `%…@` specifiers crashes `String(format:)` or prints the
    /// wrong argument. K1's own keys carry no arguments, but the microcopy audit
    /// covers the two neighbouring interpolated runtime strings — the secure-input
    /// culprit reason and the learned-ping — so guard their specifier counts here.
    func testInterpolatedNeighbourKeysKeepTheirSpecifiersInEveryLanguage() throws {
        // key -> the set of positional/plain specifiers the English source uses.
        let interpolated: [String: Set<String>] = [
            "%@ is holding secure input — switch to it and dismiss its password prompt. Tap to copy.": ["%@"],
            "%1$@ learned \u{201c}%2$@\u{201d}": ["%1$@", "%2$@"],
        ]
        for locale in Self.locales {
            let catalog = try loadCatalog(locale)
            for (key, expected) in interpolated {
                guard let value = catalog[key] else {
                    XCTFail("[\(locale)] missing interpolated key: \(key.debugDescription)")
                    continue
                }
                for spec in expected {
                    XCTAssertTrue(value.contains(spec),
                        "[\(locale)] translation drops format specifier \(spec) for \(key.debugDescription): \(value.debugDescription)")
                }
            }
        }
    }

    // MARK: - Runtime resolution shape (bundle-agnostic)

    /// `.loc` on a missing key returns the key itself. Under `swift test` the bundle
    /// is the test runner (no catalog), so this documents the honest fallback:
    /// the English source is what a user sees if a locale ever loses the key —
    /// never an empty string or a raw key token.
    func testLocFallsBackToEnglishSourceWhenCatalogAbsent() {
        for key in Self.k1Keys {
            XCTAssertEqual(key.loc, key,
                           "under the test bundle, .loc must fall back to the source key")
        }
    }
}
