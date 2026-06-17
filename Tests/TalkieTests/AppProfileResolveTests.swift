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
        // default the pipeline read directly before this fix.
        XCTAssertEqual(resolved.cleanupLevel, settings.cleanupLevel)
        XCTAssertEqual(resolved.insertionMode, settings.insertionMode)
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

        XCTAssertEqual(resolved.insertionMode, settings.insertionMode)
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
        let overrideInsertion: InsertionMode = settings.insertionMode == .paste ? .type : .paste
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
        XCTAssertEqual(other.insertionMode, settings.insertionMode)
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
}
