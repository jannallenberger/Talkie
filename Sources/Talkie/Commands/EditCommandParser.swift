import Foundation

/// The pure, deterministic core of voice editing of just-inserted text (B9):
/// parses "scratch that" / "delete that" and the anchored `replace <X> with <Y>` /
/// `change <X> to <Y>` forms, and computes the resulting edit against the text that
/// was just dictated. No AX, no injection, no MainActor — so the whole decision
/// (including the false-positive kill switch) is unit-testable in isolation, the way
/// `CrossSurfaceParser` and `SpellingParser` are.
///
/// The load-bearing safety property is the FALSE-POSITIVE KILL SWITCH: a
/// `replace X with Y` utterance is only ever treated as an edit when X *literally
/// occurs* (case-insensitive, word-bounded) in the text you just dictated. "replace
/// the filter with a new cartridge" edits ONLY if "the filter" is in that text —
/// otherwise it is not an edit at all and the caller types the phrase out literally
/// (fail-closed, matching every other command parser here). Both the parse AND the
/// containment check must pass; either failing means "this was ordinary dictation."
enum EditCommandParser {

    /// A parsed edit request, before it's checked against the actual dictated text.
    enum Request: Equatable {
        /// "scratch that" / "delete that" — remove the whole just-inserted text.
        case scratch
        /// `replace <find> with <replacement>` / `change <find> to <replacement>`.
        case replace(find: String, replacement: String)
    }

    /// Parse a whole utterance into an edit `Request`, or nil if it isn't one.
    ///
    /// Exact / whole-utterance only (mirrors macro matching): the utterance must BE
    /// the command, not merely contain it, so ordinary prose that happens to include
    /// "replace" or "scratch that" mid-sentence never parses. "undo" is deliberately
    /// NOT a scratch trigger — it's an overloaded word (undo the last commit, undo my
    /// changes) and the OS already owns ⌘Z; only the explicit "scratch that" / "delete
    /// that" forms qualify.
    static func parse(_ spoken: String) -> Request? {
        // Case-preserving tokens (whitespace-collapsed, edge punctuation trimmed) so the
        // operands keep their spoken casing: "replace Sara with Sarah" → replacement
        // "Sarah". Detection compares a lowercased COPY of each token, so casing never
        // affects matching. Token-level (not index-mapped) so it's immune to Unicode
        // special-casing where a character's length changes when lowercased.
        let tokens = casePreservingCollapsed(spoken).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        let lower = tokens.map { $0.lowercased() }

        if scratchPhrases.contains(lower.joined(separator: " ")) { return .scratch }

        // `replace X with Y` / `change X to Y`, anchored at the utterance start. The
        // first token must be the verb; the separator ("with"/"to") must appear as its
        // own whole token AFTER at least one find-token and BEFORE at least one
        // replacement-token. The separator being a standalone token is what keeps it
        // from splitting a word (the "to" inside "tomato" is never its own token). The
        // FIRST separator occurrence splits find|replacement, so a replacement may itself
        // contain "with"/"to" ("change Monday to next Tuesday to Friday" → find
        // "Monday", replacement "next Tuesday to Friday").
        for form in replaceForms {
            guard lower.first == form.verb else { continue }
            let afterVerbLower = Array(lower.dropFirst())
            let afterVerbCased = Array(tokens.dropFirst())
            guard let sepIdx = afterVerbLower.firstIndex(of: form.separator),
                  sepIdx > 0,                                   // at least one find-token
                  sepIdx < afterVerbCased.count - 1 else { continue } // at least one repl-token
            let find = afterVerbCased[0..<sepIdx].joined(separator: " ")
            let replacement = afterVerbCased[(sepIdx + 1)...].joined(separator: " ")
            guard !find.isEmpty, !replacement.isEmpty else { continue }
            return .replace(find: find, replacement: replacement)
        }
        return nil
    }

    /// Whether `find` occurs in `text` as a whole word, case-insensitively — the
    /// FALSE-POSITIVE KILL SWITCH. Word-bounded so "cat" in "replace cat with dog"
    /// does not match "category"; case-insensitive because the recognizer's casing of
    /// the spoken find-word won't match the dictated casing. `find` may be a
    /// multi-word phrase ("the filter"); the boundary check applies to the whole
    /// phrase's outer edges.
    static func contains(_ find: String, in text: String) -> Bool {
        rightmostRange(of: find, in: text) != nil
    }

    /// Apply a parsed request to the just-dictated `text`, returning the edited
    /// result — or nil when the edit can't apply (an empty scratch is expressed as
    /// `""`, but a `replace` whose find-word is absent returns nil so the caller
    /// falls back to literal insertion). For `replace`, the RIGHTMOST occurrence is
    /// swapped: when you say "replace foo with bar" after dictating "foo and foo", you
    /// almost always mean the last one you just spoke. The original casing of the
    /// surrounding text is untouched; only the matched span is replaced, verbatim,
    /// with the spoken replacement.
    static func edited(_ request: Request, in text: String) -> String? {
        switch request {
        case .scratch:
            return ""
        case .replace(let find, let replacement):
            guard let range = rightmostRange(of: find, in: text) else { return nil }
            var out = text
            out.replaceSubrange(range, with: replacement)
            return out
        }
    }

    // MARK: - Vocabulary

    /// The only scratch triggers. Whole-utterance, normalized. "undo" is intentionally
    /// excluded (see `parse`).
    private static let scratchPhrases: Set<String> = ["scratch that", "delete that"]

    /// The two anchored replace forms: verb + the separator word that splits find from
    /// replacement.
    private static let replaceForms: [(verb: String, separator: String)] = [
        (verb: "replace", separator: "with"),
        (verb: "change", separator: "to"),
    ]

    // MARK: - Helpers

    /// Collapse internal whitespace to single spaces and strip surrounding whitespace +
    /// trailing sentence punctuation the recognizer may append ("scratch that." →
    /// "scratch that"), WITHOUT changing case — so `replace Sara with Sarah` keeps
    /// "Sarah". `parse` lowercases a per-token copy for detection, so casing never
    /// affects matching while the operands keep their spoken form.
    static func casePreservingCollapsed(_ s: String) -> String {
        let joined = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
        return joined.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:"))
    }

    /// The range of the RIGHTMOST whole-word, case-insensitive occurrence of `needle`
    /// in `haystack`, or nil if absent. Word-bounded: the character immediately before
    /// the match (if any) and immediately after (if any) must be a non-alphanumeric
    /// boundary, so "cat" matches in "the cat sat" but not in "category" or "bobcat".
    /// A multi-word `needle` ("the filter") is matched as a literal span; the boundary
    /// test applies to its outer edges only.
    static func rightmostRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        let trimmedNeedle = needle.trimmingCharacters(in: .whitespaces)
        guard !trimmedNeedle.isEmpty else { return nil }
        var searchRange = haystack.startIndex..<haystack.endIndex
        var best: Range<String.Index>?
        while let found = haystack.range(of: trimmedNeedle, options: [.caseInsensitive], range: searchRange) {
            if isWordBounded(found, in: haystack) { best = found }
            // Continue scanning to the right of this match's start so we find the last one.
            if found.upperBound < haystack.endIndex {
                searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
            } else {
                break
            }
        }
        return best
    }

    /// Whether `range` sits on word boundaries in `text`: the char just before it and
    /// just after it are each either absent (string edge) or a non-alphanumeric
    /// character. Uses Unicode alphanumerics so accented identifiers behave.
    private static func isWordBounded(_ range: Range<String.Index>, in text: String) -> Bool {
        func isWordChar(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if isWordChar(before) { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if isWordChar(after) { return false }
        }
        return true
    }
}
