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

/// Pure, Sendable text post-processing — runs off the main actor after a session.
enum TextProcessor {
    static func apply(
        replacements: [Replacement],
        removeFillers: Bool,
        autoCapitalize: Bool,
        to input: String
    ) -> String {
        var text = input
        for r in replacements {
            text = applyOne(r, to: text)
        }
        if removeFillers {
            text = stripFillers(text)
        }
        if autoCapitalize {
            text = capitalizeFirstLetter(text)
        }
        return text
    }

    /// Common spoken disfluencies to drop. Kept conservative so real words survive.
    private static let fillerWords: Set<String> = [
        "um", "uh", "umm", "uhh", "uhm", "erm", "hmm", "mhm", "mmm", "uh-huh",
    ]

    /// Remove standalone filler tokens ("um", "uh", …) and tidy the leftover spacing.
    private static func stripFillers(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let punctuation = CharacterSet(charactersIn: ",.!?;:…")
        let kept = text.split(separator: " ", omittingEmptySubsequences: true).filter { token in
            let bare = String(token).trimmingCharacters(in: punctuation).lowercased()
            return !fillerWords.contains(bare)
        }
        var result = kept.joined(separator: " ")
        // Tidy artifacts left behind (" ," → ",", doubled spaces).
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func applyOne(_ r: Replacement, to text: String) -> String {
        guard !r.from.isEmpty else { return text }

        if r.wholeWord {
            let escaped = NSRegularExpression.escapedPattern(for: r.from)
            let pattern = "\\b\(escaped)\\b"
            var options: NSRegularExpression.Options = []
            if !r.caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return text
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let template = NSRegularExpression.escapedTemplate(for: r.to)
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        } else {
            let compareOptions: String.CompareOptions = r.caseSensitive ? [] : [.caseInsensitive]
            return text.replacingOccurrences(of: r.from, with: r.to, options: compareOptions)
        }
    }

    private static func capitalizeFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
