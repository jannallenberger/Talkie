import XCTest
@testable import Talkie

/// Locks the resolution surface the dictation pipeline now consumes
/// (`AppProfileStore.resolve` / `.biasVocabulary`). The key property under test is
/// *behavior preservation*: an empty store must resolve to exactly the global
/// `settings.*` values, so a user with no per-app rules is unaffected by the wiring.
@MainActor
final class AppProfileResolveTests: XCTestCase {

    private func app(_ bundleID: String?, category: AppCategory = .other) -> TargetApp {
        TargetApp(bundleID: bundleID, name: bundleID ?? "Unknown", category: category)
    }

    // MARK: - Behavior preservation: empty store mirrors `settings.*`

    func testEmptyStoreResolvesToGlobalSettings() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let target = app("com.example.app", category: .browser)

        let resolved = store.resolve(for: target, settings: settings)

        // A user with NO per-app rules resolves to the per-category style (Talkie's
        // only cleanup model now) and the universal paste default. Insertion falls
        // back to `.paste` because B2 removed the global picker.
        XCTAssertEqual(resolved.cleanupStyle, settings.cleanupStyle(for: target.category))
        XCTAssertEqual(resolved.insertionMode, .paste,
                       "With the global insert-by control gone, an app with no rule must resolve to paste")
        XCTAssertEqual(resolved.category, target.category)
        XCTAssertEqual(resolved.bundleID, "com.example.app")
    }

    func testNilBundleIDResolvesToGlobalSettings() {
        // Helper apps with no bundle id can never match a profile; they always
        // get the global defaults.
        let store = AppProfileStore()
        let settings = AppSettings()
        let target = app(nil, category: .terminal)

        let resolved = store.resolve(for: target, settings: settings)

        XCTAssertEqual(resolved.insertionMode, .paste)
        XCTAssertEqual(resolved.cleanupStyle, settings.cleanupStyle(for: target.category))
        XCTAssertNil(resolved.bundleID)
    }

    // MARK: - Per-app override wins, unset fields fall back to settings

    func testPerAppOverrideWinsAndUnsetFieldsFallBack() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let bundleID = "com.apple.Terminal"

        // Override cleanupStyle + insertionMode; leave the rest to inherit. The
        // resolved insertion default is `.paste`, so `.type` is the meaningful
        // override; `.concise` is NOT the terminal category default (`.faithful`),
        // so it proves the per-app style beat the category style.
        let overrideStyle: CleanupStyle = .concise
        let overrideInsertion: InsertionMode = .type
        store.upsert(AppProfile(
            bundleID: bundleID,
            displayName: "Terminal",
            cleanupStyle: overrideStyle,
            insertionMode: overrideInsertion
        ))

        let target = app(bundleID, category: .terminal)
        let resolved = store.resolve(for: target, settings: settings)

        // Overridden fields take the profile value (per-app style wins over category).
        XCTAssertEqual(resolved.cleanupStyle, overrideStyle,
                       "A per-app style override must win over the category style")
        XCTAssertEqual(resolved.insertionMode, overrideInsertion)

        // A different app (no profile) is untouched — the override is scoped by id,
        // and its style falls back to the category default.
        let other = store.resolve(for: app("com.other.app", category: .terminal), settings: settings)
        XCTAssertEqual(other.insertionMode, .paste)
        XCTAssertEqual(other.cleanupStyle, settings.cleanupStyle(for: .terminal))
    }

    // MARK: - neverStore ("Private app", I1)

    /// An app with no profile — and one whose profile leaves `neverStore` unset —
    /// must resolve to `false`, so the store/learn path is unchanged for everyone who
    /// hasn't marked an app Private.
    func testNeverStoreResolvesFalseByDefault() {
        let store = AppProfileStore()
        let settings = AppSettings()

        // No profile at all.
        let noProfile = store.resolve(for: app("com.no.profile", category: .browser), settings: settings)
        XCTAssertFalse(noProfile.neverStore, "An app with no profile is never Private")

        // A profile that overrides something else but leaves neverStore unset.
        let bundleID = "com.apple.Terminal"
        store.upsert(AppProfile(bundleID: bundleID, displayName: "Terminal", insertionMode: .type))
        let resolved = store.resolve(for: app(bundleID, category: .terminal), settings: settings)
        XCTAssertFalse(resolved.neverStore, "A profile that doesn't set neverStore resolves to not-Private")
    }

    /// Marking an app Private (`neverStore: true`) resolves to `true` for that app
    /// only; a different app is unaffected.
    func testNeverStoreResolvesTrueWhenSet() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let bundleID = "com.1password.1password"
        store.upsert(AppProfile(bundleID: bundleID, displayName: "1Password", neverStore: true))

        let resolved = store.resolve(for: app(bundleID, category: .other), settings: settings)
        XCTAssertTrue(resolved.neverStore, "An app marked Private must resolve neverStore = true")

        let other = store.resolve(for: app("com.other.app", category: .other), settings: settings)
        XCTAssertFalse(other.neverStore, "neverStore is scoped by bundle id — a different app stays not-Private")
    }

    /// A profile whose ONLY override is `neverStore` must NOT be treated as empty,
    /// so `upsert` keeps it instead of dropping it as a no-op row.
    func testNeverStoreOnlyProfileIsNotEmpty() {
        let onlyPrivate = AppProfile(bundleID: "com.app", displayName: "App", neverStore: true)
        XCTAssertFalse(onlyPrivate.isEmpty, "A profile carrying only neverStore=true is a real override")

        // neverStore=false / nil are no-ops and must still read as empty.
        XCTAssertTrue(AppProfile(bundleID: "com.app", displayName: "App", neverStore: false).isEmpty,
                      "neverStore=false overrides nothing")
        XCTAssertTrue(AppProfile(bundleID: "com.app", displayName: "App").isEmpty,
                      "an unset neverStore overrides nothing")

        // And the store must actually persist a private-only profile (not drop it).
        let store = AppProfileStore()
        store.upsert(onlyPrivate)
        XCTAssertNotNil(store.profile(for: "com.app"), "upsert must keep a private-only profile")
        store.remove(bundleID: "com.app")
    }

    /// Back-compat: an `app_profiles.json` written before the `neverStore` field
    /// existed must decode cleanly (absent ⇒ nil ⇒ resolves false), and a sparse
    /// profile carrying only `neverStore` must survive a decode without being lost.
    func testNeverStoreSurvivesSparseDecodeOfOldProfilesJSON() throws {
        // An "old" profile: no neverStore key at all (pre-I1 file shape).
        let oldJSON = Data("""
        { "com.apple.Terminal": { "bundleID": "com.apple.Terminal", "displayName": "Terminal", "insertionMode": "type" } }
        """.utf8)
        let oldDecoded = try JSONDecoder().decode([String: AppProfile].self, from: oldJSON)
        XCTAssertNil(oldDecoded["com.apple.Terminal"]?.neverStore,
                     "A pre-I1 profile with no neverStore key decodes to nil, not a failure")

        // A sparse profile carrying ONLY neverStore round-trips through decode.
        let sparseJSON = Data("""
        { "com.private.app": { "bundleID": "com.private.app", "displayName": "Vault", "neverStore": true } }
        """.utf8)
        let sparseDecoded = try JSONDecoder().decode([String: AppProfile].self, from: sparseJSON)
        let p = try XCTUnwrap(sparseDecoded["com.private.app"], "a neverStore-only profile must decode")
        XCTAssertEqual(p.neverStore, true, "the neverStore flag survives a sparse decode")
        XCTAssertFalse(p.isEmpty, "a decoded neverStore-only profile is not empty")
        XCTAssertNil(p.cleanupStyle, "no other field is invented by the decode")
    }

    // MARK: - biasVocabulary filtering

    func testBiasVocabularyAppliesProfileFilter() {
        let store = AppProfileStore()
        let dictionary = DictionaryStore()
        dictionary.replacements = []          // drop the seeded `talkie → Talkie`
        dictionary.vocabulary = ["Kubernetes", "Anthropic", "Bjarne"]
        let bundleID = "com.apple.Terminal"

        // Only "Kubernetes" should bias terminal dictation.
        store.upsert(AppProfile(
            bundleID: bundleID,
            displayName: "Terminal",
            vocabularyFilter: ["Kubernetes"]
        ))

        let biased = store.biasVocabulary(for: app(bundleID, category: .terminal), dictionary: dictionary)
        XCTAssertEqual(Set(biased), ["Kubernetes"])
    }

    func testBiasVocabularyFilterIsCaseInsensitive() {
        let store = AppProfileStore()
        let dictionary = DictionaryStore()
        dictionary.replacements = []
        dictionary.vocabulary = ["Kubernetes", "Anthropic"]
        let bundleID = "com.apple.Terminal"
        store.upsert(AppProfile(
            bundleID: bundleID,
            displayName: "Terminal",
            vocabularyFilter: ["kubernetes"]   // lower-cased filter still matches
        ))

        let biased = store.biasVocabulary(for: app(bundleID, category: .terminal), dictionary: dictionary)
        XCTAssertEqual(Set(biased), ["Kubernetes"])
    }

    func testBiasVocabularyWithoutProfileReturnsAllTerms() {
        let store = AppProfileStore()
        let dictionary = DictionaryStore()
        dictionary.replacements = []
        dictionary.vocabulary = ["Kubernetes", "Anthropic", "Bjarne"]

        // No profile at all → all dictionary terms.
        let all = store.biasVocabulary(for: app("com.no.profile"), dictionary: dictionary)
        XCTAssertEqual(Set(all), ["Kubernetes", "Anthropic", "Bjarne"])
    }

    func testBiasVocabularyWithEmptyFilterReturnsAllTerms() {
        let store = AppProfileStore()
        let dictionary = DictionaryStore()
        dictionary.replacements = []
        dictionary.vocabulary = ["Kubernetes", "Anthropic"]
        let bundleID = "com.apple.Terminal"
        // A profile that overrides something else but leaves the filter empty must
        // NOT narrow the vocabulary (empty filter == "all").
        store.upsert(AppProfile(
            bundleID: bundleID,
            displayName: "Terminal",
            insertionMode: .type,
            vocabularyFilter: []
        ))

        let biased = store.biasVocabulary(for: app(bundleID, category: .terminal), dictionary: dictionary)
        XCTAssertEqual(Set(biased), ["Kubernetes", "Anthropic"])
    }

    // MARK: - Self-healing insertion (B2)

    /// The verdict the self-healing path keys off. `endDictation` re-inserts by
    /// typing and learns `.type` ONLY on `.notLanded`; `.landed` (paste worked) and
    /// `.unverifiable` (AX-blind app — fail open) must NOT trigger the fallback,
    /// otherwise every paste into Slack/VS Code would be re-typed. This locks that
    /// decision boundary at the pure function the async healing consumes.
    func testVerifierVerdictThatTriggersTypeFallback() {
        // Readable field that never contains our text ⇒ genuine miss ⇒ retry.
        XCTAssertEqual(
            InsertionVerifier.decide(from: [.value("something else entirely")], inserted: "hello world"),
            .notLanded,
            "A readable field missing our text is the only case that should heal to typing")
        // Paste landed ⇒ no retry.
        XCTAssertEqual(
            InsertionVerifier.decide(from: [.value("hello world")], inserted: "hello world"),
            .landed)
        // Nothing readable (Electron/web) ⇒ fail open, no retry.
        XCTAssertEqual(
            InsertionVerifier.decide(from: [.unreadable, .unreadable], inserted: "hello world"),
            .unverifiable)
    }

    /// The persisted outcome of a failed-paste heal: the store learns `.type` for the
    /// app, and any pre-existing unrelated overrides (cleanup, vocabulary) survive the
    /// read-modify-write `endDictation` performs. This is the durable half of "each
    /// app fails at most once" — the second dictation reads `.type` straight from here.
    func testHealingUpsertLearnsTypeAndPreservesOtherOverrides() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let bundleID = "com.healing.preserve.\(UUID().uuidString)"

        // The user had already customized cleanup + vocabulary for this app. Use a
        // style that is NOT the terminal category default (`.faithful`), so the
        // assertion proves the OVERRIDE survived rather than coincidentally matching
        // the category fallback.
        store.upsert(AppProfile(
            bundleID: bundleID,
            displayName: "Old Name",
            cleanupStyle: .concise,
            vocabularyFilter: ["Kubernetes"]
        ))

        // Replay the exact read-modify-write the heal path runs on `.notLanded`:
        // preserve the existing sheet, refresh the display name, force `.type`.
        var learned = store.profile(for: bundleID)
            ?? AppProfile(bundleID: bundleID, displayName: "New Name")
        learned.displayName = "New Name"
        learned.insertionMode = .type
        store.upsert(learned)

        let resolved = store.resolve(for: app(bundleID, category: .terminal), settings: settings)
        XCTAssertEqual(resolved.insertionMode, .type, "The learned winner must stick for this app")
        XCTAssertEqual(resolved.cleanupStyle, .concise, "An unrelated cleanup override must survive the heal")

        let stored = store.profile(for: bundleID)
        XCTAssertEqual(stored?.vocabularyFilter, ["Kubernetes"], "The vocabulary override must survive the heal")
        XCTAssertEqual(stored?.displayName, "New Name", "The heal refreshes the display name")

        store.remove(bundleID: bundleID) // don't leak into the shared profiles file
    }

    /// When no per-app sheet exists yet, the heal creates one carrying only `.type`
    /// (every other field still inherits) — so a brand-new app that ate its paste
    /// switches to typing without picking up any other stray override.
    func testHealingUpsertCreatesTypeOnlyProfileWhenNonePreexists() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let bundleID = "com.healing.fresh.\(UUID().uuidString)"

        XCTAssertNil(store.profile(for: bundleID), "precondition: no sheet yet")

        var learned = store.profile(for: bundleID)
            ?? AppProfile(bundleID: bundleID, displayName: "Fresh App")
        learned.insertionMode = .type
        store.upsert(learned)

        let resolved = store.resolve(for: app(bundleID, category: .other), settings: settings)
        XCTAssertEqual(resolved.insertionMode, .type)
        // Style still inherits the category default; capitalization is the always-on
        // smart default (an "other" app, never the terminal/coding faithful exception).
        XCTAssertEqual(resolved.cleanupStyle, settings.cleanupStyle(for: .other))
        XCTAssertTrue(resolved.autoCapitalize)
        XCTAssertNil(store.profile(for: bundleID)?.cleanupStyle, "the heal must not invent unrelated overrides")

        store.remove(bundleID: bundleID)
    }

    // MARK: - autoCapitalize smart default (terminal/coding + faithful ⇒ lowercase)

    /// The one behavior change this simplification introduces: a dictated shell
    /// command must not gain a leading capital. The rule is `true` everywhere EXCEPT
    /// a terminal- or coding-category app whose resolved style is `.faithful`.
    func testAutoCapitalizeSuppressedOnlyForFaithfulTerminalOrCoding() {
        // Terminal + Faithful (the terminal category default) ⇒ NO leading capital.
        XCTAssertFalse(
            ResolvedProfile(cleanupStyle: .faithful, insertionMode: .paste,
                            bundleID: "com.apple.Terminal", category: .terminal).autoCapitalize,
            "A faithful terminal must not capitalize — `git status` stays lowercase")
        // Coding + Faithful (the coding category default) ⇒ NO leading capital.
        XCTAssertFalse(
            ResolvedProfile(cleanupStyle: .faithful, insertionMode: .paste,
                            bundleID: "com.microsoft.VSCode", category: .coding).autoCapitalize,
            "A faithful coding app must not capitalize a dictated identifier/command")
        // Same category but a NON-faithful style ⇒ capitalize (the user chose prose).
        XCTAssertTrue(
            ResolvedProfile(cleanupStyle: .neutral, insertionMode: .paste,
                            bundleID: "com.apple.Terminal", category: .terminal).autoCapitalize,
            "A terminal with a non-faithful style is prose again — capitalize")
        // Faithful but a normal app (e.g. Notes) ⇒ capitalize (only terminal/coding are exempt).
        XCTAssertTrue(
            ResolvedProfile(cleanupStyle: .faithful, insertionMode: .paste,
                            bundleID: "com.apple.Notes", category: .notes).autoCapitalize,
            "Faithful only suppresses capitalization in terminal/coding apps")
    }

    /// End-to-end acceptance: the deterministic post-processing the pipeline runs
    /// when the model didn't rewrite the text (`removeFillers: !aiHandledFillers`,
    /// i.e. always-on here). "um" is stripped in BOTH a faithful Terminal and Notes;
    /// only Notes gains a leading capital, because a dictated shell command must not.
    func testDeterministicCleanupCapitalizesNotesButNotFaithfulTerminal() {
        let terminal = ResolvedProfile(cleanupStyle: .faithful, insertionMode: .paste,
                                       bundleID: "com.apple.Terminal", category: .terminal)
        let notes = ResolvedProfile(cleanupStyle: .faithful, insertionMode: .paste,
                                    bundleID: "com.apple.Notes", category: .notes)

        // The model didn't run, so fillers strip deterministically (`!aiHandledFillers`
        // == true) and capitalization follows the resolved rule.
        let inTerminal = TextProcessor.apply(
            replacements: [], removeFillers: true, autoCapitalize: terminal.autoCapitalize,
            to: "um git status")
        XCTAssertEqual(inTerminal.text, "git status",
                       "Terminal/Faithful: 'um' stripped, and no leading capital on the command")

        let inNotes = TextProcessor.apply(
            replacements: [], removeFillers: true, autoCapitalize: notes.autoCapitalize,
            to: "um remember to call mom")
        XCTAssertEqual(inNotes.text, "Remember to call mom",
                       "Notes: 'um' stripped and the first letter capitalized")
    }
}

/// Locks the H2 one-time migration that folds the deleted cleanup *intensity level*
/// and adaptive master toggle into the surviving per-category *style* model. Runs
/// against an isolated `UserDefaults` suite so it never touches the real app plist.
/// `@MainActor` because the migration helpers live on `@MainActor final class AppSettings`.
@MainActor
final class CleanupMigrationTests: XCTestCase {

    /// A private, wiped defaults domain per test (so ordering/leftovers can't bleed).
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "talkie.h2.migration.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return (d, suite)
    }

    // The pure level→style mapping the migration relies on.
    func testMigratedStyleMapping() {
        XCTAssertEqual(AppSettings.migratedStyle(forLegacyLevel: "none"), .off)
        XCTAssertEqual(AppSettings.migratedStyle(forLegacyLevel: "light"), .faithful)
        XCTAssertEqual(AppSettings.migratedStyle(forLegacyLevel: "medium"), .neutral)
        XCTAssertEqual(AppSettings.migratedStyle(forLegacyLevel: "high"), .concise)
        XCTAssertEqual(AppSettings.migratedStyle(forLegacyLevel: "garbage"), .neutral,
                       "An unknown stored level folds to the old medium default (neutral)")
    }

    /// The headline case from the spec: adaptive OFF + level High ⇒ Concise stamped
    /// across EVERY category, and both legacy keys removed afterward.
    func testAdaptiveOffHighMigratesEveryCategoryToConcise() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }

        d.set(false, forKey: "appAdaptiveCleanup")   // user was on the level path
        d.set("high", forKey: "cleanupLevel")

        AppSettings.migrateLevelToStyleIfNeeded(d)

        let styles = d.dictionary(forKey: "appCleanupStyles") as? [String: String] ?? [:]
        for category in AppCategory.allCases {
            XCTAssertEqual(styles[category.rawValue], CleanupStyle.concise.rawValue,
                           "Adaptive-off + High must map \(category.rawValue) to Concise")
        }
        XCTAssertNil(d.object(forKey: "cleanupLevel"), "the legacy level key must be dropped")
        XCTAssertNil(d.object(forKey: "appAdaptiveCleanup"), "the legacy adaptive key must be dropped")
    }

    /// Adaptive ON (the registered default) is already the style path, so migration
    /// must NOT rewrite the user's category styles — only drop the stale keys.
    func testAdaptiveOnLeavesCategoryStylesUntouched() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }

        // A user who customized one category under the adaptive path.
        d.set(true, forKey: "appAdaptiveCleanup")
        d.set("high", forKey: "cleanupLevel")   // present but irrelevant on the style path
        d.set([AppCategory.mail.rawValue: CleanupStyle.friendly.rawValue], forKey: "appCleanupStyles")

        AppSettings.migrateLevelToStyleIfNeeded(d)

        let styles = d.dictionary(forKey: "appCleanupStyles") as? [String: String] ?? [:]
        XCTAssertEqual(styles[AppCategory.mail.rawValue], CleanupStyle.friendly.rawValue,
                       "Adaptive-on users keep their exact category styles — no stamping")
        XCTAssertNil(styles[AppCategory.terminal.rawValue],
                     "No category the user didn't set should be invented on the style path")
        XCTAssertNil(d.object(forKey: "cleanupLevel"))
        XCTAssertNil(d.object(forKey: "appAdaptiveCleanup"))
    }

    /// Idempotent: with the legacy keys already gone (a second launch, or a fresh
    /// install that never had them), migration is a no-op and never stamps styles.
    func testMigrationIsIdempotentAndNoOpWhenKeysAbsent() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }

        AppSettings.migrateLevelToStyleIfNeeded(d)   // nothing set at all

        XCTAssertNil(d.dictionary(forKey: "appCleanupStyles"),
                     "A fresh install with no legacy keys must not have styles stamped by migration")
        XCTAssertNil(d.object(forKey: "cleanupLevel"))
        XCTAssertNil(d.object(forKey: "appAdaptiveCleanup"))
    }

    /// The two Basic-cleanup toggles are also dropped, whichever cleanup path the
    /// user was on — those who had disabled them get the always-on defaults back.
    func testBasicCleanupTogglesAreDropped() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }

        d.set(false, forKey: "autoCapitalize")
        d.set(false, forKey: "cleanupFillers")

        AppSettings.migrateLevelToStyleIfNeeded(d)

        XCTAssertNil(d.object(forKey: "autoCapitalize"), "the removed capitalize toggle must be dropped")
        XCTAssertNil(d.object(forKey: "cleanupFillers"), "the removed filler toggle must be dropped")
    }
}
