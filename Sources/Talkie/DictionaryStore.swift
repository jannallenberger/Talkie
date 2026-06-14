import Foundation

/// A spoken→written substitution. Applied to the final transcript.
struct Replacement: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// What the recognizer tends to produce (e.g. "correlate", "api").
    var from: String
    /// What it should become (e.g. "Coralate", "API").
    var to: String
    var caseSensitive: Bool = false
    /// Only replace when `from` stands as a whole word.
    var wholeWord: Bool = true
    /// True if Talkie added this automatically by watching you edit (optional for
    /// back-compat with older saved files).
    var learned: Bool?

    var isLearned: Bool { learned ?? false }
}

/// User vocabulary + substitutions. Backs both the dictionary UI and the
/// recognizer's contextual biasing.
@MainActor
final class DictionaryStore: ObservableObject {
    @Published var replacements: [Replacement] = []
    /// Names / jargon / brand terms fed to the recognizer to bias spelling.
    @Published var vocabulary: [String] = []

    private let fileURL: URL

    init() {
        self.fileURL = AppPaths.supportDirectory().appendingPathComponent("dictionary.json")
        load()
    }

    // MARK: Persistence

    private struct Payload: Codable {
        var replacements: [Replacement]
        var vocabulary: [String]
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            seedDefaultsIfEmpty()
            return
        }
        replacements = payload.replacements
        vocabulary = payload.vocabulary
    }

    func save() {
        // Don't persist a blank draft row the user is still filling in.
        let persistable = replacements.filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
        let payload = Payload(replacements: persistable, vocabulary: vocabulary)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func seedDefaultsIfEmpty() {
        // A couple of illustrative entries so the UI isn't blank on first run.
        replacements = [
            Replacement(from: "talkie", to: "Talkie"),
        ]
        vocabulary = []
        save()
    }

    // MARK: Mutations (UI calls these)

    // Mutations only touch the @Published arrays; persistence is driven by the
    // view's `.onChange` (which also catches direct text-field edits). Keeping a
    // single save path avoids the double-write the two-path version had.

    func addReplacement() {
        replacements.append(Replacement(from: "", to: ""))
    }

    func removeReplacements(at offsets: IndexSet) {
        replacements.remove(atOffsets: offsets)
    }

    func addVocabularyTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vocabulary.contains(trimmed) else { return }
        vocabulary.append(trimmed)
    }

    /// Auto-add a correction Talkie learned from watching the user edit text.
    func addLearnedReplacement(from: String, to: String) {
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty, f.lowercased() != t.lowercased() else { return }
        // Skip if we already have this exact correction.
        if replacements.contains(where: { $0.from.lowercased() == f.lowercased() && $0.to == t }) { return }
        replacements.append(Replacement(from: f, to: t, caseSensitive: false, wholeWord: true, learned: true))
        save()
    }

    func removeVocabulary(at offsets: IndexSet) {
        vocabulary.remove(atOffsets: offsets)
    }

    // MARK: Snapshots for the engine (Sendable plain values)

    /// Phrases that bias recognition: vocabulary plus the corrected spellings.
    func contextualPhrasesSnapshot() -> [String] {
        var phrases = Set(vocabulary)
        for r in replacements where !r.to.trimmingCharacters(in: .whitespaces).isEmpty {
            phrases.insert(r.to)
        }
        return Array(phrases)
    }

    func replacementsSnapshot() -> [Replacement] {
        replacements.filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Result of post-processing: the final text plus a tally of what was changed
/// (so the dashboard can show how many fixes Talkie made).
struct ProcessedText {
    var text: String
    var replacementHits: Int = 0
    var fillersRemoved: Int = 0
}

/// Pure, Sendable text post-processing — runs off the main actor after a session.
enum TextProcessor {
    static func apply(
        replacements: [Replacement],
        removeFillers: Bool,
        autoCapitalize: Bool,
        to input: String
    ) -> ProcessedText {
        var text = input
        var replacementHits = 0
        for r in replacements {
            let (out, hits) = applyOne(r, to: text)
            text = out
            replacementHits += hits
        }
        var fillersRemoved = 0
        if removeFillers {
            let (out, removed) = stripFillers(text)
            text = out
            fillersRemoved = removed
        }
        if autoCapitalize {
            text = capitalizeFirstLetter(text)
        }
        return ProcessedText(text: text, replacementHits: replacementHits, fillersRemoved: fillersRemoved)
    }

    /// Common spoken disfluencies to drop. Kept conservative so real words survive.
    private static let fillerWords: Set<String> = [
        "um", "uh", "umm", "uhh", "uhm", "erm", "hmm", "mhm", "mmm", "uh-huh",
    ]

    /// Remove standalone filler tokens ("um", "uh", …) and tidy the leftover
    /// spacing. Returns the cleaned text and how many tokens were dropped.
    private static func stripFillers(_ text: String) -> (String, Int) {
        guard !text.isEmpty else { return (text, 0) }
        let punctuation = CharacterSet(charactersIn: ",.!?;:…")
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        let kept = tokens.filter { token in
            let bare = String(token).trimmingCharacters(in: punctuation).lowercased()
            return !fillerWords.contains(bare)
        }
        let removed = tokens.count - kept.count
        var result = kept.joined(separator: " ")
        // Tidy artifacts left behind (" ," → ",", doubled spaces).
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return (result.trimmingCharacters(in: .whitespaces), removed)
    }

    /// Apply one rule, returning the new text and how many occurrences it changed.
    private static func applyOne(_ r: Replacement, to text: String) -> (String, Int) {
        guard !r.from.isEmpty else { return (text, 0) }

        if r.wholeWord {
            let escaped = NSRegularExpression.escapedPattern(for: r.from)
            let pattern = "\\b\(escaped)\\b"
            var options: NSRegularExpression.Options = []
            if !r.caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return (text, 0)
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.numberOfMatches(in: text, options: [], range: range)
            guard matches > 0 else { return (text, 0) }
            let template = NSRegularExpression.escapedTemplate(for: r.to)
            let out = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
            return (out, matches)
        } else {
            let compareOptions: String.CompareOptions = r.caseSensitive ? [] : [.caseInsensitive]
            let hits = countOccurrences(of: r.from, in: text, caseSensitive: r.caseSensitive)
            guard hits > 0 else { return (text, 0) }
            let out = text.replacingOccurrences(of: r.from, with: r.to, options: compareOptions)
            return (out, hits)
        }
    }

    private static func countOccurrences(of needle: String, in haystack: String, caseSensitive: Bool) -> Int {
        guard !needle.isEmpty else { return 0 }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, options: opts, range: search) {
            count += 1
            search = r.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    /// Rough count of how many words changed between two versions of a transcript
    /// — used to estimate how much the on-device AI cleanup rewrote. Pure.
    static func changedWordCount(before: String, after: String) -> Int {
        guard before != after else { return 0 }
        let a = before.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let b = after.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let diff = b.difference(from: a)
        // Each removal/insertion is a touched word; a substitution shows up as one
        // of each, so the larger side approximates the number of words altered.
        let removals = diff.removals.count
        let insertions = diff.insertions.count
        return max(removals, insertions)
    }
}
