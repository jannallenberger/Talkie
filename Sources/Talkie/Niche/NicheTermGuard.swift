import Foundation

/// The **false-boost defense**. The most user-visible failure mode of vocabulary
/// biasing is forcing a rare jargon spelling onto a common word the user actually
/// said (you say "cube", the recognizer is biased toward "kube" and writes it).
/// `rejections`-after-the-fact can't prevent that — by the time the user corrects
/// it, the transcript was already wrong. So we guard *before* injection: never
/// bias toward a term that collides (is, or is edit-distance-1 from) a
/// high-frequency common word.
///
/// Phase 0 ships a compact built-in common-word set. A later phase swaps in the
/// full shipped background-frequency table (`background_unigrams.json`), which is
/// also what scores term "rareness" — the same asset, used defensively first.
struct NicheTermGuard: Sendable {
    let commonWords: Set<String>

    /// True if `term` is safe to inject as a recognizer bias phrase.
    func isSafeToInject(_ term: String) -> Bool {
        let word = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Too short to be distinctive jargon; biasing it is all risk, no reward.
        guard word.count >= 3 else { return false }
        // Multi-word phrases (e.g. "context graph") don't collide with a single
        // common word, but only admit one that carries at least one distinctive
        // token (≥4 chars and not a high-frequency common word) — a phrase made
        // entirely of short/common words ("for me", "and the") is a recognizer
        // no-op and only risks stamping caps/spacing onto ordinary speech.
        if word.contains(" ") {
            let parts = word.split(separator: " ").map(String.init)
            return parts.contains { $0.count >= 4 && !commonWords.contains($0) }
        }
        // It *is* a common word: the model already nails it, and boosting it risks
        // crowding the budget / overriding nearby words. Skip.
        if commonWords.contains(word) { return false }
        // Acoustic/spelling collision: within edit distance 1 of a common word.
        for common in commonWords where abs(common.count - word.count) <= 1 {
            if Self.isWithinEditDistance1(word, common) { return false }
        }
        return true
    }

    /// Bounded Levenshtein: true iff `a` and `b` are within one insert/delete/
    /// substitute. O(n) and allocation-free — far cheaper than a full DP table,
    /// which is the point when this runs against the whole common-word set per term.
    static func isWithinEditDistance1(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        let dl = x.count - y.count
        if abs(dl) > 1 { return false }
        if dl == 0 {
            // Same length: at most one substitution allowed.
            var diffs = 0
            for i in 0..<x.count where x[i] != y[i] {
                diffs += 1
                if diffs > 1 { return false }
            }
            return true
        }
        // Lengths differ by one: the longer must equal the shorter with one
        // character inserted. Walk both with a single allowed skip.
        let (longer, shorter) = x.count > y.count ? (x, y) : (y, x)
        var i = 0, j = 0, skipped = false
        while i < longer.count && j < shorter.count {
            if longer[i] == shorter[j] {
                i += 1; j += 1
            } else {
                if skipped { return false }
                skipped = true
                i += 1
            }
        }
        return true
    }

    /// A compact list of the most frequent English words — the Phase 0 guard basis.
    /// Deliberately small (function words, pronouns, common verbs/nouns) so it ships
    /// in-code; it catches the highest-traffic collisions without the licensing /
    /// bundling work of the full frequency table.
    static let `default` = NicheTermGuard(commonWords: builtinCommonWords)

    static let builtinCommonWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had",
        "her", "was", "one", "our", "out", "day", "get", "has", "him", "his", "how",
        "man", "new", "now", "old", "see", "two", "way", "who", "boy", "did", "its",
        "let", "put", "say", "she", "too", "use", "dad", "mom", "cube", "code", "node",
        "kind", "type", "data", "case", "test", "user", "name", "time", "work", "make",
        "made", "back", "call", "came", "come", "down", "each", "find", "from", "give",
        "good", "have", "here", "into", "just", "know", "like", "live", "look", "made",
        "many", "more", "most", "move", "must", "need", "next", "only", "open", "over",
        "part", "play", "said", "same", "show", "some", "such", "take", "tell", "than",
        "that", "them", "then", "they", "this", "tree", "true", "view", "want", "well",
        "went", "were", "what", "when", "will", "with", "word", "your", "about", "after",
        "again", "based", "build", "could", "every", "first", "found", "great", "house",
        "large", "learn", "model", "never", "other", "place", "point", "right", "small",
        "sound", "start", "state", "still", "their", "there", "these", "thing", "think",
        "three", "under", "until", "value", "where", "which", "while", "world", "would",
        "write", "graph", "scale", "stack", "table", "token", "block", "class", "field",
        "frame", "group", "index", "input", "layer", "level", "logic", "queue", "query",
        "range", "shape", "store", "style", "topic", "track", "train", "video", "voice",
    ]
}
