import Foundation
import FoundationModels

/// L5-b — the on-device *invented* job title for the Milestones ("Plumage") page.
///
/// This is a PLAYFUL LABEL, never a claim about the user's real profession. From
/// where their words actually go (app-category shares + the apps they dictate
/// into most) and the words they reach for most, the model coins a 2–4 word title
/// and one short sentence in a warm, second-person voice — "Creative Development
/// Direction · you don't write code, you direct it into being", not "Software
/// Engineer".
///
/// It MIRRORS `ContextSummaryEngine`: an `actor`, one `LanguageModelSession`
/// spun per call with greedy sampling, availability gated on
/// `CleanupEngine.isAvailable`, returning `nil` on any failure so the caller
/// falls back. It NEVER surfaces an error state — when Apple Intelligence is off,
/// the store hands back a deterministic, localized title keyed by the top app
/// category (the F3/E8 PrivacyWall culture: a graceful default, never a wall).
///
/// On-device only. No network, no API key, no cost — the same guarantee as every
/// other Talkie generator. The result is shown ONLY on the personal Milestones
/// surface; it must never leak into an export or share artifact.
actor JobTitleEngine {
    /// Same availability gate as the Brief and cleanup — the on-device model is
    /// usable only when Apple Intelligence is on.
    static var isAvailable: Bool { CleanupEngine.isAvailable }

    private static let instructions = """
    You invent a playful, affectionate "job title" for a person based only on \
    where their dictated words go (which kinds of apps, and the words they reach \
    for most). It is a fond nickname for how they spend their words — NOT a claim \
    about their real profession, and you must NEVER output a literal job title \
    ("Software Engineer", "Writer", "Designer", "Manager"). Instead, name the \
    SPIRIT of it in a fresh, slightly whimsical phrase.

    Output EXACTLY two lines and nothing else:
    Line 1: the title — 2 to 4 words, Title Case, no quotes, no trailing period.
    Line 2: one second-person sentence of at most 140 characters that completes \
    the idea warmly ("you don't write code, you direct it into being"). No quotes.

    Good example:
    Creative Development Direction
    You don't write code — you direct it into being, one clear instruction at a time.

    Do NOT add a preamble, a heading, bullet points, a third line, or any \
    explanation. Two lines only.
    """

    /// The immutable inputs the prompt is built from — assembled on the main actor
    /// (the stores are `@MainActor`) and handed to the actor as a plain value, so
    /// the model call itself touches no UI state.
    struct Inputs: Sendable, Equatable {
        /// Category label + rounded percentage share, highest first (e.g.
        /// "Coding 62%").
        var categoryShares: [String]
        /// The app display names the user dictates into most, highest first.
        var topApps: [String]
        /// The content words the user says most, highest first.
        var topWords: [String]

        /// True when there's genuinely nothing to base a title on — the caller
        /// uses the deterministic fallback rather than prompting an empty model.
        var isEmpty: Bool {
            categoryShares.isEmpty && topApps.isEmpty && topWords.isEmpty
        }

        /// Assemble the inputs from the live stores (spec L5-b): category shares +
        /// top ~6 app names from `AppUsageStore`, and the top ~8 content words from
        /// `WordFrequencyStore`. Reads `@MainActor` stores, so it's `@MainActor`;
        /// the resulting value is `Sendable` and handed to the actor for the model
        /// call. Shares are rounded to whole percents ("Coding 62%") — the model
        /// gets a shape, not false precision.
        @MainActor
        static func assemble(appUsage: AppUsageStore,
                             wordFreq: WordFrequencyStore,
                             appLimit: Int = 6,
                             wordLimit: Int = 8) -> Inputs {
            let categories = appUsage.byCategory().prefix(4).map {
                "\($0.category.label) \(Int(($0.fraction * 100).rounded()))%"
            }
            let apps = appUsage.topApps(limit: appLimit).map(\.name)
            let words = wordFreq.words
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(wordLimit)
                .map(\.key)
            return Inputs(categoryShares: Array(categories),
                          topApps: apps,
                          topWords: Array(words))
        }
    }

    /// A parsed, validated title: a short name and one short sentence.
    struct Title: Sendable, Equatable {
        var title: String
        var sentence: String
    }

    /// Generate a title from the assembled inputs, or `nil` on any failure
    /// (unavailable model, empty inputs, malformed output). `nil` is the caller's
    /// signal to fall back — this method never throws and never blocks the UI.
    func generate(from inputs: Inputs) async -> Title? {
        guard Self.isAvailable, !inputs.isEmpty else { return nil }

        let prompt = Self.buildPrompt(from: inputs)
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            // Greedy + low temperature: a stable, deterministic coinage (mirrors the
            // Brief and cleanup), so the same usage profile keeps the same title
            // until the inputs actually change.
            let options = GenerationOptions(sampling: .greedy, temperature: 0.6)
            let response = try await session.respond(to: prompt, options: options)
            return Self.parse(response.content)
        } catch {
            return nil
        }
    }

    // MARK: - Pure helpers (input assembly, prompt, parse, fallback)

    /// Build the user-facing half of the prompt from the inputs. Pure and
    /// deterministic so it can be asserted in tests without the model.
    static func buildPrompt(from inputs: Inputs) -> String {
        var blocks: [String] = []
        if !inputs.categoryShares.isEmpty {
            blocks.append("Where their words go (by share):\n" +
                          inputs.categoryShares.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !inputs.topApps.isEmpty {
            blocks.append("Apps they dictate into most: " + inputs.topApps.joined(separator: ", "))
        }
        if !inputs.topWords.isEmpty {
            blocks.append("Words they reach for most: " + inputs.topWords.joined(separator: ", "))
        }
        return """
        \(blocks.joined(separator: "\n\n"))

        Invent their title now. Two lines only.
        """
    }

    /// Parse the model's raw output into a validated `Title`, or `nil` if it is
    /// malformed. We REQUIRE exactly the two-line contract:
    ///   • strip a leading "Title:" / "1." / "-" ornament the model sometimes adds,
    ///   • the first non-empty line is the title — 2…4 words after de-ornamenting,
    ///   • the next non-empty line is the sentence — non-empty and ≤ 140 chars.
    /// Anything else returns `nil` so the caller shows the deterministic fallback
    /// instead of a broken title.
    static func parse(_ raw: String) -> Title? {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { cleanLine($0) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        let title = lines[0]
        let sentence = lines[1]

        // Title: 2…4 words, no sentence-ending punctuation (a period means the model
        // ran the sentence into line 1).
        let words = title.split(whereSeparator: { $0 == " " }).filter { !$0.isEmpty }
        guard (2...4).contains(words.count) else { return nil }
        guard !title.contains(".") else { return nil }

        // Sentence: present, and short enough to sit under the card without wrapping
        // into a paragraph.
        guard !sentence.isEmpty, sentence.count <= 140 else { return nil }

        return Title(title: title, sentence: sentence)
    }

    /// Strip surrounding whitespace, wrapping quotes, and a leading ornament
    /// ("Title:", "1.", "-", "•") the model occasionally prepends despite the
    /// instructions. Used for both lines so parsing is forgiving of formatting but
    /// strict about structure.
    private static func cleanLine(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)

        // Leading label like "Title:" / "Sentence:".
        for label in ["title:", "sentence:", "line 1:", "line 2:"] {
            if s.lowercased().hasPrefix(label) {
                s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // Leading list ornament: "1.", "1)", "-", "*", "•".
        while let first = s.first, "-*•".contains(first) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let dot = s.firstIndex(of: "."), s[s.startIndex..<dot].allSatisfy(\.isNumber), dot != s.startIndex {
            s = String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        // Wrapping quotes.
        if s.count >= 2,
           (s.first == "\"" && s.last == "\"") || (s.first == "\u{201C}" && s.last == "\u{201D}") {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// The deterministic, never-fails fallback keyed by the user's top app
    /// category. Used when the model is unavailable OR its output was malformed —
    /// the card ALWAYS has a title, and it is never an error message.
    ///
    /// Every string is localized. The titles are the same fond, non-literal voice
    /// as the generated ones (no "Engineer"/"Writer"), so a user with Apple
    /// Intelligence off gets a coherent card, not a degraded one.
    static func fallback(for category: AppCategory?) -> Title {
        switch category ?? .other {
        case .coding:
            return Title(title: "Vibe-Coding Conductor".loc,
                         sentence: "You don't type code so much as talk it into being.".loc)
        case .browser:
            return Title(title: "Deep-Web Wayfarer".loc,
                         sentence: "You think out loud across a hundred open tabs and somehow find the thread.".loc)
        case .mail:
            return Title(title: "Inbox Diplomat".loc,
                         sentence: "You turn a morning of messages into replies that actually sound like you.".loc)
        case .chat:
            return Title(title: "Conversation Keeper".loc,
                         sentence: "Your words live in the back-and-forth — quick, warm, always in motion.".loc)
        case .notes:
            return Title(title: "Longform Thinker".loc,
                         sentence: "You dictate your way to clarity, one paragraph at a time.".loc)
        case .terminal:
            return Title(title: "Command-Line Whisperer".loc,
                         sentence: "You speak to the machine directly, and it listens.".loc)
        case .design:
            return Title(title: "Idea Sketcher".loc,
                         sentence: "You narrate what you see before it exists on the canvas.".loc)
        case .other:
            return Title(title: "Word Wanderer".loc,
                         sentence: "Your voice goes everywhere your work does — a little of everything.".loc)
        }
    }
}

/// Holds the invented job title (persisted to `job_title.json`) and decides when
/// to regenerate. MIRRORS `ContextSummaryStore`: a `@MainActor` `ObservableObject`
/// owning the cache + generation lifecycle around the pure `JobTitleEngine` actor.
///
/// Regeneration policy (spec L5-b): auto-regenerate ONLY when the user has climbed
/// to a milestone tier ABOVE the one the cached title was generated at (a real
/// change of station is worth a re-coining), or on an explicit "Regenerate" tap.
/// It is content-derived — its inputs are your vocabulary + app usage — so the
/// cache is wiped whenever `WordFrequencyStore.clearAll()` runs (via the Memory
/// "Clear everything" flow), and it is listed in the privacy receipt.
@MainActor
final class JobTitleStore: ObservableObject {
    /// The current title + sentence, or empty strings before the first generation.
    @Published private(set) var title: String = ""
    @Published private(set) var sentence: String = ""
    /// True while a generation is in flight — the card shows a placeholder, the
    /// page never blocks.
    @Published private(set) var isGenerating = false
    /// How many times a (re)generation has actually run this session. Not shown in
    /// the UI; it lets a test assert the regeneration POLICY (did an `ensure` re-coin
    /// or honor the cache?) without depending on the title text — which is
    /// non-deterministic when Apple Intelligence is present.
    @Published private(set) var generationCount = 0

    private let engine = JobTitleEngine()
    private let fileURL: URL

    /// The milestone tier index the cached title was generated at (nil = below the
    /// first rung / never generated). Drives the "climbed a tier → recoin" check.
    private var tierAtGeneration: Int?
    private var generatedAt: Date?

    init(directory: URL = AppPaths.supportDirectory()) {
        fileURL = directory.appendingPathComponent("job_title.json")
        load()
    }

    /// Whether the on-device model is available (the card uses this only to word
    /// its footer honestly — a title is shown either way).
    var isAvailable: Bool { JobTitleEngine.isAvailable }

    /// True once we have any title to show (generated or fallback, loaded or fresh).
    var hasTitle: Bool { !title.isEmpty }

    /// Ensure a title exists for the current tier, generating asynchronously if
    /// needed. Safe to call every time the page appears: it regenerates ONLY when
    /// there's no cached title yet, or the user has crossed above the cached tier.
    /// The `inputs`/`fallbackCategory` are captured by the caller from the live
    /// `@MainActor` stores; generation happens off the main actor.
    func ensure(currentTier: Int?, inputs: JobTitleEngine.Inputs, fallbackCategory: AppCategory?) async {
        guard !isGenerating else { return }
        // Regenerate when we have nothing, or the user has climbed above the cached
        // tier. A DROP never re-coins (tiers only rise in practice; be defensive).
        let climbed = (currentTier.map { tier in (tierAtGeneration ?? -1) < tier } ?? false)
        guard !hasTitle || climbed else { return }
        await run(currentTier: currentTier, inputs: inputs, fallbackCategory: fallbackCategory)
    }

    /// Force a fresh title regardless of cache — backing the explicit "Regenerate"
    /// button (a button, not a setting).
    func regenerate(currentTier: Int?, inputs: JobTitleEngine.Inputs, fallbackCategory: AppCategory?) async {
        guard !isGenerating else { return }
        await run(currentTier: currentTier, inputs: inputs, fallbackCategory: fallbackCategory)
    }

    private func run(currentTier: Int?, inputs: JobTitleEngine.Inputs, fallbackCategory: AppCategory?) async {
        isGenerating = true
        defer { isGenerating = false }

        // Try the model; on nil (unavailable, empty, or malformed) use the
        // deterministic fallback so the card is never blank and never an error.
        let result = await engine.generate(from: inputs)
            ?? JobTitleEngine.fallback(for: fallbackCategory)

        title = result.title
        sentence = result.sentence
        tierAtGeneration = currentTier
        generatedAt = Date()
        generationCount += 1
        save()
    }

    /// Wipe the persisted title. Called when the vocabulary/usage it was derived
    /// from is cleared, so a coinage can't outlive its inputs.
    func clearCache() {
        title = ""
        sentence = ""
        tierAtGeneration = nil
        generatedAt = nil
        // Remove the file outright (rather than writing an empty one) so the
        // privacy receipt reads "not created yet" until the next generation.
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Persistence

    private struct Payload: Codable {
        var title: String
        var sentence: String
        var tierAtGeneration: Int?
        var generatedAtUnix: Double?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        title = p.title
        sentence = p.sentence
        tierAtGeneration = p.tierAtGeneration
        generatedAt = p.generatedAtUnix.map { Date(timeIntervalSince1970: $0) }
    }

    private func save() {
        let p = Payload(title: title, sentence: sentence,
                        tierAtGeneration: tierAtGeneration,
                        generatedAtUnix: generatedAt?.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
