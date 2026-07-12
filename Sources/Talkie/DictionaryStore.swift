import Foundation
import AppKit

/// A spoken→written substitution. Applied to the final transcript.
struct Replacement: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// What the recognizer tends to produce (e.g. "get hub", "api").
    var from: String
    /// What it should become (e.g. "GitHub", "API").
    var to: String
    var caseSensitive: Bool = false
    /// Only replace when `from` stands as a whole word.
    var wholeWord: Bool = true
    /// True if Talkie added this automatically by watching you edit (optional for
    /// back-compat with older saved files).
    var learned: Bool?
    /// True when this is a *confidence-gated* learned rule: `to` is itself an
    /// ordinary dictionary word (e.g. "their"→"there"), so rewriting `from`→`to`
    /// blindly would be illogical — it would clobber every future genuine `from`.
    /// A weighted rule instead fires ONLY when the recognizer was unsure it heard
    /// `from` this session (see `TextProcessor.apply`); when it was confident,
    /// `from` stands. Optional for back-compat: absent/false is a hard always-
    /// replace rule — the right behavior for learned jargon (`to` NOT a dictionary
    /// word, e.g. "GitHub"), which must snap every time.
    var weighted: Bool?

    var isLearned: Bool { learned ?? false }
    /// See `weighted`. A weighted rule is gated on recognizer confidence.
    var isWeighted: Bool { weighted ?? false }
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
        cleanupChirpSeedIfNeeded()
    }

    /// Undo the brief Chirp rename: remove the auto-added `chirp → Chirp` seed if it's
    /// still present, so an existing dictionary doesn't carry a stray rule now that the
    /// app is "Talkie" again. Idempotent; only removes that exact auto-added rule (it was
    /// added by an earlier launch, never by the user).
    private func cleanupChirpSeedIfNeeded() {
        let before = replacements.count
        replacements.removeAll {
            $0.from.caseInsensitiveCompare("chirp") == .orderedSame &&
            $0.to.caseInsensitiveCompare("Chirp") == .orderedSame
        }
        if replacements.count != before { save() }
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

    /// Remove a vocabulary term by value (case-insensitively) — the symmetric undo
    /// of `addVocabularyTerm`, used to reverse a Claude-suggested add from the HUD
    /// Undo pill (`DictionaryInbox`). No-op if the term isn't present. Persistence is
    /// the caller's responsibility (matching the other value mutators here, which the
    /// Dictionary view drives via `.onChange`; the inbox calls `save()` itself).
    func removeVocabularyTerm(_ term: String) {
        let key = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        vocabulary.removeAll { $0.caseInsensitiveCompare(key) == .orderedSame }
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
        // When the TARGET is itself an ordinary dictionary word (e.g. "their"→
        // "there"), a hard always-replace rule is illogical: it would rewrite every
        // future genuine `from`. Store it CONFIDENCE-GATED instead — it fires only
        // when the recognizer was unsure it heard `from` (see `TextProcessor.apply`).
        // A target that is NOT a dictionary word — learned jargon like "GitHub" or
        // "claude.md" — stays a hard rule so it keeps snapping every time.
        let weighted = Self.isOrdinaryDictionaryWord(t)
        replacements.append(Replacement(from: f, to: t, caseSensitive: false, wholeWord: true,
                                        learned: true, weighted: weighted))
        save()
        return true
    }

    /// Whether `word` is an ordinary word already in the user's dictionary — the
    /// signal that a learned correction *toward* it must be confidence-gated rather
    /// than a hard always-replace. The built-in high-frequency set is the
    /// deterministic floor; `NSSpellChecker` broadens it to the full system
    /// dictionary. Multi-word targets are treated as jargon (hard rule) — a phrase
    /// isn't a single lexical item the recognizer confuses with a common word.
    ///
    /// Ordinary in EN or DE (the user dictates both). Uses the language-parameterized
    /// `NSSpellChecker` API and only trusts a language whose dictionary is actually
    /// installed — the previous single, ambient-language `checkSpelling(of:startingAt:)`
    /// under-covered German dictation.
    static func isOrdinaryDictionaryWord(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, !w.contains(" ") else { return false }
        if NicheTermGuard.default.commonWords.contains(w) { return true }
        // `checkSpelling` returns the range of the first misspelling; NSNotFound
        // means the whole word is known-good (i.e. it's in that language's dictionary).
        let checker = NSSpellChecker.shared
        let available = checker.availableLanguages
        for lang in ["en", "de"] {
            // Pass the actual installed identifier ("en_US"/"de_DE"), not the bare
            // "en"/"de" prefix — more robust across `NSSpellChecker` versions than
            // hoping the bare prefix is itself a language `checkSpelling` accepts.
            guard let installed = available.first(where: { $0.hasPrefix(lang) }) else { continue }
            let misspelling = checker.checkSpelling(of: w, startingAt: 0, language: installed,
                                                     wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if misspelling.location == NSNotFound { return true }
        }
        return false
    }

    /// Ordinary word, or a phrase whose every component is ordinary (EN/DE). Feeds
    /// the harvest filter (multi-word candidates like "For me" that PhraseMiner
    /// otherwise mines from ordinary prose) — a phrase with even one distinctive,
    /// non-ordinary component (e.g. "context graph") still counts as jargon.
    static func isOrdinaryPhraseOrWord(_ s: String) -> Bool {
        let parts = s.split(separator: " ").map(String.init)
        if parts.count <= 1 { return isOrdinaryDictionaryWord(s) }
        return parts.allSatisfy { isOrdinaryDictionaryWord($0) }
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

    // MARK: L15 — dictionary management applied from the confirm-with-Undo inbox
    //
    // These back the Claude-suggested EDIT/REMOVE operations (`DictionaryInbox`),
    // the same way `addVocabularyTerm`/`addLearnedReplacement` back the ADDs. They
    // match a rule by its (from, to) pair case-insensitively — the same key
    // `get_dictionary` displays and the model references — and return enough state
    // (the exact prior `Replacement`, preserving id + all flags) for the HUD Undo to
    // restore the previous state verbatim. Each persists via `save()` since inbox
    // writes aren't driven by the Dictionary view's `.onChange`.

    /// Remove the FIRST replacement rule matching (from, to) case-insensitively,
    /// regardless of whether it was learned or curated (Claude can manage either).
    /// Returns the removed rule (for an exact Undo restore) or nil if none matched.
    @discardableResult
    func removeReplacementMatching(from: String, to: String) -> Replacement? {
        let f = from.trimmingCharacters(in: .whitespaces).lowercased()
        let t = to.trimmingCharacters(in: .whitespaces).lowercased()
        guard let idx = replacements.firstIndex(where: {
            $0.from.lowercased() == f && $0.to.lowercased() == t
        }) else { return nil }
        let removed = replacements.remove(at: idx)
        save()
        return removed
    }

    /// Change the target of the FIRST rule matching (from, to) case-insensitively to
    /// `newTo`, preserving the rule's id and flags. Returns the rule's PRIOR state
    /// (for an exact Undo restore) or nil if none matched or `newTo` is empty / the
    /// same as the current target (a no-op).
    @discardableResult
    func updateReplacementTarget(from: String, to: String, newTo: String) -> Replacement? {
        let f = from.trimmingCharacters(in: .whitespaces).lowercased()
        let t = to.trimmingCharacters(in: .whitespaces).lowercased()
        let n = newTo.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        guard let idx = replacements.firstIndex(where: {
            $0.from.lowercased() == f && $0.to.lowercased() == t
        }) else { return nil }
        let prior = replacements[idx]
        guard prior.to != n else { return nil }   // already at the requested target
        replacements[idx].to = n
        save()
        return prior
    }

    /// Restore a replacement rule captured before a remove/update, for the HUD Undo.
    /// Re-inserts it verbatim (id + flags preserved). If a rule with the same id is
    /// somehow already present, this replaces it in place rather than duplicating —
    /// so a double-fire can't leave two copies. Persists.
    func restoreReplacement(_ rule: Replacement) {
        if let idx = replacements.firstIndex(where: { $0.id == rule.id }) {
            replacements[idx] = rule
        } else {
            replacements.append(rule)
        }
        save()
    }

    /// Re-add a vocabulary term for the HUD Undo of a removal. Symmetric with
    /// `removeVocabularyTerm`; persists. (Ordering isn't preserved — vocabulary is a
    /// set-like bias list — but the term reappears, which is what Undo promises.)
    func restoreVocabularyTerm(_ term: String) {
        addVocabularyTerm(term)
        save()
    }

    // MARK: One-file import / export (.talkiepack)

    /// Snapshot the whole dictionary into a shareable pack. `name`/`description`/
    /// `attribution` come from the export UI. Learned rules are exported too — they're
    /// still your corrections — but the `learned` flag is deliberately dropped in the
    /// pack (see `TalkiePack.PackReplacement`), so a recipient gets them as curated
    /// rules, not "Talkie learned this" rows. Only rules with a non-empty `from` are
    /// exported (mirrors `replacementsSnapshot()`), so a blank draft row never ships.
    func exportPack(name: String, description: String?, attribution: String?) -> TalkiePack {
        let rules = replacements
            .filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty
                        && !$0.to.trimmingCharacters(in: .whitespaces).isEmpty }
            .map {
                TalkiePack.PackReplacement(from: $0.from, to: $0.to,
                                           caseSensitive: $0.caseSensitive, wholeWord: $0.wholeWord)
            }
        return TalkiePack(name: name,
                          description: description?.isEmpty == true ? nil : description,
                          attribution: attribution?.isEmpty == true ? nil : attribution,
                          createdAtUnix: Date().timeIntervalSince1970,
                          vocabulary: vocabulary,
                          replacements: rules)
    }

    /// Dry-run a merge against the CURRENT state without writing anything, so the
    /// import sheet can show what will be added vs. what already exists (collisions).
    /// Pure with respect to the store (reads `vocabulary`/`replacements`, mutates
    /// nothing). Dedup rules match `merge(pack:)` exactly: vocabulary is compared
    /// case-insensitively; a replacement collides on its (from, to) pair, both compared
    /// case-insensitively — so re-importing the same pack shows every row as existing.
    /// Rows that repeat WITHIN the pack are de-duplicated here too, so the preview count
    /// equals what `merge` will actually add.
    func previewMerge(pack: TalkiePack) -> MergePreview {
        let existingVocabLower = Set(vocabulary.map { $0.lowercased() })
        var seenVocabLower = Set<String>()
        var vocabRows: [MergePreview.VocabRow] = []
        for term in pack.vocabulary {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            let alreadyInPack = seenVocabLower.contains(lower)
            seenVocabLower.insert(lower)
            let existing = existingVocabLower.contains(lower) || alreadyInPack
            vocabRows.append(.init(term: trimmed, existing: existing))
        }

        let existingRuleKeys = Set(replacements.map { ruleKey($0.from, $0.to) })
        var seenRuleKeys = Set<String>()
        var ruleRows: [MergePreview.RuleRow] = []
        for rule in pack.replacements {
            let from = rule.from.trimmingCharacters(in: .whitespaces)
            let to = rule.to.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { continue }
            let key = ruleKey(from, to)
            let alreadyInPack = seenRuleKeys.contains(key)
            seenRuleKeys.insert(key)
            let existing = existingRuleKeys.contains(key) || alreadyInPack
            ruleRows.append(.init(from: from, to: to, existing: existing))
        }

        return MergePreview(packName: pack.name,
                            packDescription: pack.description,
                            attribution: pack.attribution,
                            vocab: vocabRows,
                            rules: ruleRows)
    }

    /// Merge a pack into the dictionary and return what actually changed. This is the
    /// import commit: it appends only the entries that don't already exist, NEVER
    /// overwrites one of your existing rules (dedup is add-if-absent, not replace), and
    /// tags imported rules as curated — `learned: false` — so they read as your own,
    /// not as auto-learned. Persists once at the end via `save()`. All-or-nothing isn't
    /// needed because the operation only ever adds; a duplicate pack is a no-op.
    @discardableResult
    func merge(pack: TalkiePack) -> MergeSummary {
        var summary = MergeSummary()

        // Vocabulary — case-insensitive dedup against existing AND within the pack.
        var vocabLower = Set(vocabulary.map { $0.lowercased() })
        for term in pack.vocabulary {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lower = trimmed.lowercased()
            if vocabLower.contains(lower) {
                summary.vocabularySkipped += 1
            } else {
                vocabLower.insert(lower)
                vocabulary.append(trimmed)
                summary.vocabularyAdded += 1
            }
        }

        // Replacements — dedup on the (from, to) pair, case-insensitively. An imported
        // rule keeps its own case-sensitivity / whole-word flags but is curated, not
        // learned.
        var ruleKeys = Set(replacements.map { ruleKey($0.from, $0.to) })
        for rule in pack.replacements {
            let from = rule.from.trimmingCharacters(in: .whitespaces)
            let to = rule.to.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { continue }
            let key = ruleKey(from, to)
            if ruleKeys.contains(key) {
                summary.replacementsSkipped += 1
            } else {
                ruleKeys.insert(key)
                replacements.append(Replacement(from: from, to: to,
                                                caseSensitive: rule.resolvedCaseSensitive,
                                                wholeWord: rule.resolvedWholeWord,
                                                learned: false))
                summary.replacementsAdded += 1
            }
        }

        if !summary.isEmpty { save() }
        return summary
    }

    /// The dedup key for a replacement: the (from, to) pair, lowercased so
    /// "API"→"API" and "api"→"API" collide. Kept here so `previewMerge` and `merge`
    /// can't disagree on what "already have this rule" means.
    private func ruleKey(_ from: String, _ to: String) -> String {
        "\(from.trimmingCharacters(in: .whitespaces).lowercased())\u{0}\(to.trimmingCharacters(in: .whitespaces).lowercased())"
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
        to input: String,
        wordConfidences: [WordConfidence] = []
    ) -> ProcessedText {
        var text = input
        var replacementHits = 0
        var replacedWords: [String] = []
        for r in replacements {
            // A confidence-gated (weighted) rule fires ONLY when the recognizer was
            // unsure it heard `from` this session. If it was confident — or `from`
            // never appears in the confidences (e.g. an interim pass hands none) —
            // the recognizer stands by what it heard, so we leave `from` alone. Hard
            // rules (the jargon default) skip this gate and always apply.
            if r.isWeighted, !recognizerWasUnsure(about: r.from, in: wordConfidences) {
                continue
            }
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

    /// Whether the recognizer was visibly UNSURE it heard `word` this session — the
    /// gate a `weighted` (confidence-gated) rule fires on. True iff some recognized
    /// token equals `word` (case-insensitively, ignoring surrounding punctuation)
    /// with confidence below `ConfidenceGate.floor`. When the word never appears, or
    /// only appears with solid confidence, this is false: the recognizer stands by
    /// what it heard, so a weighted rule must NOT rewrite it. Pure.
    static func recognizerWasUnsure(about word: String, in confidences: [WordConfidence]) -> Bool {
        let target = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        for wc in confidences {
            let token = wc.word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if token == target && wc.confidence < ConfidenceGate.floor { return true }
        }
        return false
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
