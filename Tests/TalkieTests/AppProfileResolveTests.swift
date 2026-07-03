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

        // Every field a user with NO per-app rules sees must equal the global
        // default the pipeline read directly before this fix. Insertion is the one
        // exception: B2 removed the global picker, so it falls back to `.paste`
        // (the universal default) rather than any `settings.*` value.
        XCTAssertEqual(resolved.cleanupLevel, settings.cleanupLevel)
        XCTAssertEqual(resolved.insertionMode, .paste,
                       "With the global insert-by control gone, an app with no rule must resolve to paste")
        XCTAssertEqual(resolved.autoCapitalize, settings.autoCapitalize)
        XCTAssertEqual(resolved.removeFillers, settings.cleanupFillers)
        XCTAssertEqual(resolved.appAdaptiveCleanup, settings.appAdaptiveCleanup)
        XCTAssertEqual(resolved.cleanupStyle, settings.cleanupStyle(for: target.category))
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
        XCTAssertEqual(resolved.removeFillers, settings.cleanupFillers)
        XCTAssertEqual(resolved.cleanupStyle, settings.cleanupStyle(for: target.category))
        XCTAssertNil(resolved.bundleID)
    }

    // MARK: - Per-app override wins, unset fields fall back to settings

    func testPerAppOverrideWinsAndUnsetFieldsFallBack() {
        let store = AppProfileStore()
        let settings = AppSettings()
        let bundleID = "com.apple.Terminal"

        // Override only insertionMode + removeFillers; leave the rest to inherit.
        // The resolved default is `.paste`, so `.type` is the meaningful override.
        let overrideInsertion: InsertionMode = .type
        let overrideRemoveFillers = !settings.cleanupFillers
        store.upsert(AppProfile(
            bundleID: bundleID,
            displayName: "Terminal",
            insertionMode: overrideInsertion,
            removeFillers: overrideRemoveFillers
        ))

        let target = app(bundleID, category: .terminal)
        let resolved = store.resolve(for: target, settings: settings)

        // Overridden fields take the profile value...
        XCTAssertEqual(resolved.insertionMode, overrideInsertion)
        XCTAssertEqual(resolved.removeFillers, overrideRemoveFillers)
        // ...unset fields still fall back to the global settings.
        XCTAssertEqual(resolved.autoCapitalize, settings.autoCapitalize)
        XCTAssertEqual(resolved.cleanupLevel, settings.cleanupLevel)
        XCTAssertEqual(resolved.cleanupStyle, settings.cleanupStyle(for: target.category))

        // A different app (no profile) is untouched — the override is scoped by id.
        let other = store.resolve(for: app("com.other.app", category: .terminal), settings: settings)
        XCTAssertEqual(other.insertionMode, .paste)
        XCTAssertEqual(other.removeFillers, settings.cleanupFillers)
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
            removeFillers: true,
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
        // Everything else still inherits the global defaults.
        XCTAssertEqual(resolved.autoCapitalize, settings.autoCapitalize)
        XCTAssertEqual(resolved.removeFillers, settings.cleanupFillers)
        XCTAssertNil(store.profile(for: bundleID)?.cleanupStyle, "the heal must not invent unrelated overrides")

        store.remove(bundleID: bundleID)
    }
}
