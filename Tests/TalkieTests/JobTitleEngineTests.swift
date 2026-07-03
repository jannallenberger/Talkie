import XCTest
@testable import Talkie

/// L5-b: the on-device *invented* job title. These tests cover the deterministic
/// surfaces — input assembly, output parsing/rejection, per-category fallback, and
/// the store's cache-invalidation policy on a tier crossing.
///
/// The model call itself is not exercised (the XCTest runner has no Apple
/// Intelligence, so `JobTitleEngine.isAvailable` is false). That's deliberate and
/// convenient: with the model unavailable, `generate` returns nil and the store
/// falls back to the deterministic table — so `ensure`/`regenerate` produce a
/// stable, assertable title with no network and no model, exactly the "never an
/// error state" contract.
final class JobTitleEngineTests: XCTestCase {

    // The two assemble tests build real `AppUsageStore`/`WordFrequencyStore`, which
    // read/write fixed files under Application Support. Snapshot both in setUp and
    // restore in tearDown so a developer running the suite never loses their real
    // usage/vocab stores (same discipline as `WordFrequencyStoreTests`).
    private var appUsageURL: URL { AppPaths.supportDirectory().appendingPathComponent("appusage.json") }
    private var wordFreqURL: URL { AppPaths.supportDirectory().appendingPathComponent("wordfreq.json") }
    private var savedAppUsage: Data?
    private var savedWordFreq: Data?

    override func setUp() {
        super.setUp()
        savedAppUsage = try? Data(contentsOf: appUsageURL)
        savedWordFreq = try? Data(contentsOf: wordFreqURL)
        try? FileManager.default.removeItem(at: appUsageURL)
        try? FileManager.default.removeItem(at: wordFreqURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: appUsageURL)
        try? FileManager.default.removeItem(at: wordFreqURL)
        if let d = savedAppUsage { try? d.write(to: appUsageURL) }
        if let d = savedWordFreq { try? d.write(to: wordFreqURL) }
        super.tearDown()
    }

    // MARK: - Input assembly (pure)

    @MainActor
    func testAssembleBuildsCategorySharesAppsAndWords() {
        let appUsage = AppUsageStore()
        appUsage.reset()
        // Coding dominates; a browser trickle. Words come from the freq store.
        // `record` re-classifies from bundleID/name, so the passed category is a
        // don't-care — Xcode → .coding, Chrome → .browser regardless.
        appUsage.record(target: TargetApp(bundleID: "com.apple.dt.Xcode", name: "Xcode", category: .other), words: 800)
        appUsage.record(target: TargetApp(bundleID: "com.google.Chrome", name: "Chrome", category: .other), words: 200)

        let wordFreq = WordFrequencyStore()
        wordFreq.clearAll()
        // Distinct, above the 3-char floor, non-stopwords.
        for _ in 0..<5 { wordFreq.record(text: "refactor") }
        for _ in 0..<3 { wordFreq.record(text: "handler") }

        let inputs = JobTitleEngine.Inputs.assemble(appUsage: appUsage, wordFreq: wordFreq)

        XCTAssertFalse(inputs.isEmpty)
        // Category shares are label + rounded percent, highest first.
        XCTAssertEqual(inputs.categoryShares.first, "Coding 80%")
        XCTAssertTrue(inputs.categoryShares.contains("Browsing 20%"))
        // Apps are display names, most-used first.
        XCTAssertEqual(inputs.topApps.first, "Xcode")
        XCTAssertTrue(inputs.topApps.contains("Chrome"))
        // Words are the content tokens, most-used first.
        XCTAssertEqual(inputs.topWords.first, "refactor")
        XCTAssertTrue(inputs.topWords.contains("handler"))

        // Cleanup so we don't leave a real appusage.json/wordfreq.json behind.
        appUsage.reset()
        wordFreq.clearAll()
    }

    @MainActor
    func testAssembleHonorsWordAndAppLimits() {
        let appUsage = AppUsageStore()
        appUsage.reset()
        for i in 0..<10 {
            appUsage.record(target: TargetApp(bundleID: "app.\(i)", name: "App\(i)", category: .other), words: 100 - i)
        }
        let wordFreq = WordFrequencyStore()
        wordFreq.clearAll()
        // 12 distinct words at descending counts.
        let vocab = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot",
                     "golf", "hotel", "india", "juliet", "kilo", "lima"]
        for (i, w) in vocab.enumerated() {
            for _ in 0...(vocab.count - i) { wordFreq.record(text: w) }
        }

        let inputs = JobTitleEngine.Inputs.assemble(appUsage: appUsage, wordFreq: wordFreq,
                                                    appLimit: 6, wordLimit: 8)
        XCTAssertEqual(inputs.topApps.count, 6, "app list is capped at the limit")
        XCTAssertEqual(inputs.topWords.count, 8, "word list is capped at the limit")
        XCTAssertEqual(inputs.topWords.first, "alpha", "highest-count word leads")

        appUsage.reset()
        wordFreq.clearAll()
    }

    func testEmptyInputsAreEmpty() {
        XCTAssertTrue(JobTitleEngine.Inputs(categoryShares: [], topApps: [], topWords: []).isEmpty)
        XCTAssertFalse(JobTitleEngine.Inputs(categoryShares: ["Coding 100%"], topApps: [], topWords: []).isEmpty)
    }

    func testBuildPromptIncludesEveryProvidedBlock() {
        let inputs = JobTitleEngine.Inputs(categoryShares: ["Coding 62%", "Browsing 20%"],
                                           topApps: ["Xcode", "Cursor"],
                                           topWords: ["refactor", "handler"])
        let prompt = JobTitleEngine.buildPrompt(from: inputs)
        XCTAssertTrue(prompt.contains("Coding 62%"))
        XCTAssertTrue(prompt.contains("Xcode"))
        XCTAssertTrue(prompt.contains("refactor"))
        XCTAssertTrue(prompt.contains("Two lines only"))
    }

    // MARK: - Output parse / reject (malformed → nil → caller falls back)

    func testParseAcceptsCleanTwoLineOutput() {
        let out = "Creative Development Direction\nYou don't write code — you direct it into being."
        let title = JobTitleEngine.parse(out)
        XCTAssertEqual(title?.title, "Creative Development Direction")
        XCTAssertEqual(title?.sentence, "You don't write code — you direct it into being.")
    }

    func testParseStripsOrnamentsAndQuotes() {
        let out = "Title: \"Vibe-Coding Conductor\"\nSentence: \u{201C}You talk code into being.\u{201D}"
        let title = JobTitleEngine.parse(out)
        XCTAssertEqual(title?.title, "Vibe-Coding Conductor")
        XCTAssertEqual(title?.sentence, "You talk code into being.")
    }

    func testParseSkipsBlankLinesBetweenTheTwo() {
        let out = "Inbox Diplomat\n\n\nYou turn a morning of messages into replies that sound like you."
        let title = JobTitleEngine.parse(out)
        XCTAssertEqual(title?.title, "Inbox Diplomat")
        XCTAssertNotNil(title?.sentence)
    }

    func testParseRejectsSingleLine() {
        XCTAssertNil(JobTitleEngine.parse("Creative Development Direction"))
    }

    func testParseRejectsOneWordTitle() {
        XCTAssertNil(JobTitleEngine.parse("Engineer\nYou build things all day."))
    }

    func testParseRejectsFiveWordTitle() {
        XCTAssertNil(JobTitleEngine.parse("The Grand High Code Whisperer\nYou do a lot."))
    }

    func testParseRejectsTitleWithPeriod() {
        // A period in line 1 means the model ran a sentence into the title slot.
        XCTAssertNil(JobTitleEngine.parse("You write code.\nAll day long you do."))
    }

    func testParseRejectsOverlongSentence() {
        let longSentence = String(repeating: "word ", count: 40) // > 140 chars
        XCTAssertNil(JobTitleEngine.parse("Longform Thinker\n\(longSentence)"))
    }

    func testParseRejectsEmpty() {
        XCTAssertNil(JobTitleEngine.parse(""))
        XCTAssertNil(JobTitleEngine.parse("\n\n"))
    }

    // MARK: - Fallback selection per category (never an error state)

    func testFallbackIsDistinctPerCategory() {
        var titles = Set<String>()
        for category in AppCategory.allCases {
            let fb = JobTitleEngine.fallback(for: category)
            XCTAssertFalse(fb.title.trimmingCharacters(in: .whitespaces).isEmpty,
                           "fallback title for \(category) must be non-empty")
            XCTAssertFalse(fb.sentence.trimmingCharacters(in: .whitespaces).isEmpty,
                           "fallback sentence for \(category) must be non-empty")
            titles.insert(fb.title)
        }
        XCTAssertEqual(titles.count, AppCategory.allCases.count,
                       "each category should get its own distinct fallback title")
    }

    func testFallbackForNilCategoryIsTheOtherBucket() {
        XCTAssertEqual(JobTitleEngine.fallback(for: nil).title,
                       JobTitleEngine.fallback(for: .other).title)
    }

    func testFallbackTitlesAreNeverLiteralProfessions() {
        // The honesty rule: the invented title must never be a bare job title.
        let banned = ["engineer", "developer", "writer", "designer", "manager", "programmer"]
        for category in AppCategory.allCases {
            let lower = JobTitleEngine.fallback(for: category).title.lowercased()
            for word in banned {
                XCTAssertFalse(lower == word, "fallback for \(category) is a literal profession: \(lower)")
            }
        }
    }

    // MARK: - Cache invalidation on tier crossing (store policy)
    //
    // These assert the regeneration POLICY via `generationCount`, not the title
    // text — the text is non-deterministic when Apple Intelligence is present on the
    // test machine (the model generates a real coinage), whereas the decision of
    // WHEN to (re)generate is deterministic and is exactly what the spec pins down.

    /// A fresh store with no cache generates once, then does NOT regenerate on a
    /// subsequent `ensure` at the same tier — but DOES when the tier climbs.
    @MainActor
    func testEnsureRegeneratesOnlyWhenTierClimbs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = JobTitleStore(directory: dir)
        let inputs = JobTitleEngine.Inputs(categoryShares: ["Coding 100%"], topApps: ["Xcode"], topWords: ["refactor"])

        // First appearance at tier 0 → generates once, and now has a title.
        await store.ensure(currentTier: 0, inputs: inputs, fallbackCategory: .coding)
        XCTAssertTrue(store.hasTitle)
        XCTAssertEqual(store.generationCount, 1, "the first ensure must generate exactly once")

        // Same tier again → cache honored, no regeneration.
        await store.ensure(currentTier: 0, inputs: inputs, fallbackCategory: .coding)
        XCTAssertEqual(store.generationCount, 1, "an ensure at the same tier must not re-coin")

        // Climb a tier → regenerates.
        await store.ensure(currentTier: 1, inputs: inputs, fallbackCategory: .coding)
        XCTAssertEqual(store.generationCount, 2, "crossing to a higher tier must re-coin")

        // And holds at the new tier.
        await store.ensure(currentTier: 1, inputs: inputs, fallbackCategory: .coding)
        XCTAssertEqual(store.generationCount, 2, "no further re-coin until the next crossing")
    }

    /// A store that already has a cached title from a LOWER tier re-coins on the
    /// first `ensure` at a higher tier after a reload — the crossing check reads the
    /// persisted `tierAtGeneration`.
    @MainActor
    func testCachedLowerTierRegeneratesOnReloadAtHigherTier() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputs = JobTitleEngine.Inputs(categoryShares: ["Coding 100%"], topApps: ["Xcode"], topWords: ["refactor"])
        let first = JobTitleStore(directory: dir)
        await first.ensure(currentTier: 0, inputs: inputs, fallbackCategory: .coding)
        XCTAssertEqual(first.generationCount, 1)

        // Reload (fresh session) with the cache on disk; same tier → no re-coin.
        let reloadedSameTier = JobTitleStore(directory: dir)
        XCTAssertTrue(reloadedSameTier.hasTitle, "the cached title loads")
        await reloadedSameTier.ensure(currentTier: 0, inputs: inputs, fallbackCategory: .coding)
        XCTAssertEqual(reloadedSameTier.generationCount, 0, "a reload at the cached tier does not re-coin")

        // Reload again, now standing on a higher tier → re-coins once.
        let reloadedHigher = JobTitleStore(directory: dir)
        await reloadedHigher.ensure(currentTier: 3, inputs: inputs, fallbackCategory: .coding)
        XCTAssertEqual(reloadedHigher.generationCount, 1, "a reload above the cached tier re-coins")
    }

    /// The explicit "Regenerate" button re-coins regardless of tier.
    @MainActor
    func testRegenerateAlwaysRuns() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = JobTitleStore(directory: dir)
        let inputs = JobTitleEngine.Inputs(categoryShares: ["Coding 100%"], topApps: ["Xcode"], topWords: ["refactor"])

        await store.ensure(currentTier: 0, inputs: inputs, fallbackCategory: .coding)
        XCTAssertEqual(store.generationCount, 1)

        // Same tier, but an explicit regenerate runs anyway.
        await store.regenerate(currentTier: 0, inputs: inputs, fallbackCategory: .coding)
        XCTAssertEqual(store.generationCount, 2, "regenerate must re-coin even at the same tier")
    }

    /// The cache round-trips through `job_title.json`, and `clearCache` wipes it.
    @MainActor
    func testCachePersistsAndClears() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputs = JobTitleEngine.Inputs(categoryShares: ["Notes 100%"], topApps: ["Obsidian"], topWords: ["clarity"])
        let store = JobTitleStore(directory: dir)
        await store.ensure(currentTier: 2, inputs: inputs, fallbackCategory: .notes)
        let cached = store.title
        XCTAssertFalse(cached.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("job_title.json").path))

        // A second store over the same dir loads the cached title WITHOUT generating.
        let reloaded = JobTitleStore(directory: dir)
        XCTAssertEqual(reloaded.title, cached, "the title must survive a reload from job_title.json")
        XCTAssertEqual(reloaded.generationCount, 0, "loading from cache does not count as a generation")

        // clearCache removes the file and empties the in-memory title.
        reloaded.clearCache()
        XCTAssertFalse(reloaded.hasTitle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("job_title.json").path),
                       "clearCache must delete job_title.json")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jobtitle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
