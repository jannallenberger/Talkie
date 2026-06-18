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
        // ABSENT (no file on disk) is the only state that should seed defaults.
        // An UNDECODABLE file (present but unreadable/corrupt JSON) must NEVER
        // re-seed or save — that would clobber a user's curated vocab on a
        // transient read error or a one-off corruption. So we split the two
        // cases instead of collapsing both into one `try?` guard.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Truly first run (or the file was deleted): seed the illustrative
            // defaults and persist them so the UI isn't blank.
            seedDefaultsIfEmpty()
            return
        }

        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            // The file exists but we can't decode it. Preserve the bad bytes by
            // renaming them aside (so the user — or we — can recover them later)
            // and continue with in-memory defaults. Crucially we do NOT call
            // `save()` here: writing now would overwrite the on-disk vocab that a
            // later launch (or a fixed decoder) might still recover.
            quarantineCorruptFile()
            replacements = Self.defaultReplacements
            vocabulary = []
            return
        }
        replacements = payload.replacements
        vocabulary = payload.vocabulary
    }

    /// Move an undecodable store file to `dictionary.json.corrupt` so it's
    /// preserved (and out of the way) rather than silently overwritten. Best
    /// effort: a failure here just leaves the original in place — we still avoid
    /// clobbering it because `load()` never writes on the failure path.
    private func quarantineCorruptFile() {
        let corruptURL = fileURL.appendingPathExtension("corrupt")
        // Clear any stale quarantine from a previous failed launch so the move
        // can't fail just because a `.corrupt` file already exists.
        try? FileManager.default.removeItem(at: corruptURL)
        try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
    }

    func save() {
        // Don't persist a blank draft row the user is still filling in.
        let persistable = replacements.filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
        let payload = Payload(replacements: persistable, vocabulary: vocabulary)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// A couple of illustrative entries so the UI isn't blank on first run.
    /// Shared so the undecodable-file path falls back to the same in-memory
    /// defaults it would have seeded — without re-saving over the bad file.
    static let defaultReplacements: [Replacement] = [
        Replacement(from: "talkie", to: "Talkie"),
    ]

    private func seedDefaultsIfEmpty() {
        replacements = Self.defaultReplacements
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
    /// Returns `true` when a NEW rule was added (so the caller can ping the user),
    /// `false` when it was empty, a no-op, or already present.
    @discardableResult
    func addLearnedReplacement(from: String, to: String) -> Bool {
        let f = from.trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty, f.lowercased() != t.lowercased() else { return false }
        // Skip if we already have this exact correction.
        if replacements.contains(where: { $0.from.lowercased() == f.lowercased() && $0.to == t }) { return false }
        replacements.append(Replacement(from: f, to: t, caseSensitive: false, wholeWord: true, learned: true))
        save()
        return true
    }

    /// Undo a just-learned correction: remove the matching learned rule. Only
    /// touches rules Talkie added automatically (`isLearned`), never the user's
    /// own curated entries.
    func removeLearnedReplacement(from: String, to: String) {
        let f = from.trimmingCharacters(in: .whitespaces).lowercased()
        let t = to.trimmingCharacters(in: .whitespaces).lowercased()
        let before = replacements.count
        replacements.removeAll {
            $0.isLearned && $0.from.lowercased() == f && $0.to.lowercased() == t
        }
        if replacements.count != before { save() }
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
    /// The `to` values of every replacement rule that fired, in order, deduped.
    var replacedWords: [String] = []
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
        var replacedWords: [String] = []
        for r in replacements {
            let (out, hits) = applyOne(r, to: text)
            text = out
            replacementHits += hits
            if hits > 0, !replacedWords.contains(r.to) {
                replacedWords.append(r.to)
            }
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
        return ProcessedText(text: text, replacementHits: replacementHits,
                             fillersRemoved: fillersRemoved, replacedWords: replacedWords)
    }

    /// Replacement targets the recognizer produced on its own because it was biased
    /// toward them (every rule's `to` is fed to the recognizer as a contextual
    /// string), so `apply`'s find-and-replace never had a `from` to match. That's
    /// invisible in the post-cleanup text alone, so we compare the raw transcript
    /// with what we actually inserted: a rule counts when it's a genuine respelling
    /// (`from` ≠ `to`), the user did NOT speak the `from` (that's the find-and-
    /// replace path, already tallied by `apply`), and the `to` is present — as a
    /// whole word — in both the raw transcript and the final text. Returned in rule
    /// order, deduped; these complement the literal hits from `apply`.
    static func biasAppliedTargets(rules: [Replacement], raw: String, output: String) -> [String] {
        var out: [String] = []
        for r in rules {
            let from = r.from.trimmingCharacters(in: .whitespaces)
            let to = r.to.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty,
                  from.lowercased() != to.lowercased() else { continue }
            // The user literally spoke the `from` → find-and-replace path, already
            // counted by `apply`. Skip so we don't double-report.
            if occurs(from, in: raw, wholeWord: r.wholeWord, caseSensitive: r.caseSensitive) { continue }
            // Bias path: the corrected spelling is in the raw transcript and made it
            // all the way into the inserted text.
            guard occurs(to, in: raw, wholeWord: r.wholeWord, caseSensitive: r.caseSensitive),
                  occurs(to, in: output, wholeWord: r.wholeWord, caseSensitive: r.caseSensitive)
            else { continue }
            if !out.contains(to) { out.append(to) }
        }
        return out
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

    /// Whole-word / case-sensitivity–aware presence test, matching `applyOne`'s
    /// matching rules so application and detection agree on what "present" means.
    private static func occurs(_ needle: String, in haystack: String, wholeWord: Bool, caseSensitive: Bool) -> Bool {
        guard !needle.isEmpty else { return false }
        if wholeWord {
            let escaped = NSRegularExpression.escapedPattern(for: needle)
            var options: NSRegularExpression.Options = []
            if !caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: options) else {
                return false
            }
            let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
            return regex.firstMatch(in: haystack, options: [], range: range) != nil
        } else {
            let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            return haystack.range(of: needle, options: opts) != nil
        }
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
