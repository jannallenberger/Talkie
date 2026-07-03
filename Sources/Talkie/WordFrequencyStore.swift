import Foundation

/// Running frequency counts of the words and short phrases the user actually
/// dictates — the data behind a future "your most-used word / phrase" stat.
///
/// WHY A STANDING STORE, not a query over history: the default transcript
/// retention is 7 days, so "most used, ever" can't be recomputed on demand —
/// the evidence is gone. Instead we ACCUMULATE at record time: every finalized
/// dictation is tokenized once and folded into `words` / `phrases`. Deleting a
/// dictation calls `purge(text:)`, the exact inverse, so the counts track the
/// history that still exists plus everything that has scrolled out of it.
///
/// PRIVACY: `wordfreq.json` holds the user's literal vocabulary and phrasing —
/// the same privacy class as `dictionary.json`. It never leaves the Mac, is
/// listed in the privacy receipt (DoctorReport), and is wiped by "Clear
/// everything" alongside history.
@MainActor
final class WordFrequencyStore: ObservableObject {
    /// non-stopword token → lifetime count.
    @Published private(set) var words: [String: Int] = [:]
    /// sentence-bounded trigram (space-joined) → lifetime count.
    @Published private(set) var phrases: [String: Int] = [:]

    /// Keep the store bounded: the long tail of one-off words/phrases is noise for
    /// a "most used" stat, so on save we evict everything past these caps, lowest
    /// count first. Generous enough that a real favourite is never at risk.
    static let wordCap = 400
    static let phraseCap = 200

    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("wordfreq.json")
        load()
    }

    // MARK: Recording

    /// Fold one dictation into the counts: +1 per non-stopword token, +1 per
    /// sentence-bounded trigram that carries at least one non-stopword token.
    func record(text: String) {
        var changed = false
        for token in Self.contentTokens(in: text) {
            words[token, default: 0] += 1
            changed = true
        }
        for phrase in Self.phrases(in: text) {
            phrases[phrase, default: 0] += 1
            changed = true
        }
        if changed { save() }
    }

    /// The exact inverse of `record(text:)`: tokenize identically and DECREMENT,
    /// flooring at 0 and dropping any entry that reaches 0. Recording a text then
    /// purging the same text returns the store to where it started.
    func purge(text: String) {
        var changed = false
        for token in Self.contentTokens(in: text) {
            if let current = words[token] {
                let next = current - 1
                if next <= 0 { words[token] = nil } else { words[token] = next }
                changed = true
            }
        }
        for phrase in Self.phrases(in: text) {
            if let current = phrases[phrase] {
                let next = current - 1
                if next <= 0 { phrases[phrase] = nil } else { phrases[phrase] = next }
                changed = true
            }
        }
        if changed { save() }
    }

    /// Wipe both maps — called from "Clear everything" so the vocabulary store
    /// can't outlive the history it was built from.
    func clearAll() {
        guard !words.isEmpty || !phrases.isEmpty else { return }
        words = [:]
        phrases = [:]
        save()
    }

    func reset() { clearAll() }

    // MARK: Tokenizer (pure, static)

    /// Lowercase and split `text` into word tokens. Splits on any character that
    /// is not a letter or digit, EXCEPT an apostrophe or hyphen sitting between
    /// two word characters (so "don't" and "context-aware" survive intact, but a
    /// leading/trailing/standalone '-' or ''' is dropped). Only tokens of length
    /// 3…24 (inclusive) are kept — shorter is mostly noise, longer is rarely a
    /// real word and usually an artifact.
    ///
    /// This is the ONE tokenizer both counting and phrase-building use, so record
    /// and purge can never disagree about what a token is.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            // Trim any apostrophes/hyphens that ended up on the edges (they're only
            // legal between word chars).
            let trimmed = current.trimmingCharacters(in: Self.edgePunctuation)
            if trimmed.count >= 3, trimmed.count <= 24 {
                tokens.append(trimmed)
            }
            current = ""
        }

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" || scalar == "-" {
                // Keep an in-word connector only if we're already inside a word;
                // an edge connector is trimmed on flush anyway, but not starting a
                // token with one keeps "-foo" from ever holding a leading dash.
                if !current.isEmpty {
                    current.unicodeScalars.append(scalar)
                }
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Tokens that carry meaning: `tokenize` minus the stop-word set. These are
    /// what `words` counts.
    static func contentTokens(in text: String) -> [String] {
        tokenize(text).filter { !stopWords.contains($0) }
    }

    /// Sentence-bounded trigrams over the raw token stream. The text is split into
    /// sentences first (on `.`, `!`, `?`, or a newline) so a phrase never spans a
    /// sentence boundary. A trigram is kept only if at least one of its three
    /// tokens is a non-stopword — an all-function-word window ("of the to") is
    /// noise. Stop words are KEPT inside a kept trigram, so the phrase reads
    /// naturally ("end of the world"): the ≥1-content-word rule gates the window,
    /// it doesn't strip words from it.
    static func phrases(in text: String) -> [String] {
        var result: [String] = []
        for sentence in text.components(separatedBy: sentenceBoundary) {
            let toks = tokenize(sentence)
            guard toks.count >= 3 else { continue }
            for i in 0...(toks.count - 3) {
                let window = Array(toks[i..<(i + 3)])
                if window.contains(where: { !stopWords.contains($0) }) {
                    result.append(window.joined(separator: " "))
                }
            }
        }
        return result
    }

    /// Sentence terminators + newline, as a CharacterSet for `components(separatedBy:)`.
    private static let sentenceBoundary = CharacterSet(charactersIn: ".!?\n")
    /// Connectors that are legal only between word characters, trimmed off edges.
    private static let edgePunctuation = CharacterSet(charactersIn: "'\u{2019}-")

    /// Function words filtered out of `words` and used to gate all-stopword
    /// trigrams. English core plus the commonest function words of German, French,
    /// Spanish, Italian, Dutch, and Portuguese — Talkie's polyglot users dictate
    /// in these, and their articles/pronouns/prepositions would otherwise dominate
    /// the "most used word" stat and drown out anything meaningful. Entries are
    /// lowercase and length-agnostic; the 3-char minimum in `tokenize` already
    /// drops most 1–2 letter words, so this list leans toward 3+ char words that
    /// would otherwise slip through.
    static let stopWords: Set<String> = [
        // ── English ──
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can",
        "had", "her", "was", "one", "our", "out", "day", "get", "has", "him",
        "his", "how", "man", "new", "now", "old", "see", "two", "way", "who",
        "boy", "did", "its", "let", "put", "say", "she", "too", "use", "that",
        "with", "have", "this", "will", "your", "from", "they", "know", "want",
        "been", "good", "much", "some", "time", "very", "when", "come", "here",
        "just", "like", "long", "make", "many", "over", "such", "take", "than",
        "them", "well", "were", "what", "would", "there", "their", "about",
        "could", "other", "these", "those", "which", "while", "should", "into",
        "then", "also", "only", "even", "back", "because", "does", "each", "more",
        "most", "must", "onto", "unto", "upon", "yeah", "okay", "gonna", "kind",
        "gotta", "wanna", "really", "actually", "basically", "something",
        // ── German ──
        "und", "der", "die", "das", "ich", "nicht", "ein", "eine", "mit", "auf",
        "für", "auch", "von", "sich", "aber", "sind", "wird", "dass", "war",
        "haben", "sein", "einen", "einer", "eines", "dem", "den", "des", "wenn",
        "aus", "bei", "nur", "noch", "wie", "man", "über", "vor", "durch", "zum",
        "zur", "kann", "wir", "sie", "ihr", "mein", "dein", "sein", "unser",
        // ── French ──
        "les", "des", "une", "est", "que", "qui", "pas", "pour", "dans", "sur",
        "avec", "vous", "nous", "ils", "mais", "son", "ses", "ces", "cette",
        "aux", "par", "plus", "être", "avoir", "fait", "tout", "bien", "comme",
        "leur", "cela", "donc", "elle", "ont", "sont", "peut", "sans",
        // ── Spanish ──
        "por", "para", "con", "una", "los", "las", "que", "del", "como", "más",
        "pero", "sus", "muy", "esta", "este", "esto", "son", "está", "han",
        "hay", "sin", "ser", "hacer", "todo", "porque", "cuando", "también",
        "donde", "entre", "sobre", "desde", "hasta", "ellos", "nosotros",
        // ── Italian ──
        "che", "non", "una", "per", "con", "sono", "questo", "questa", "come",
        "anche", "della", "dello", "delle", "degli", "nella", "nello", "gli",
        "loro", "molto", "quando", "perché", "essere", "avere", "fare", "tutto",
        // ── Dutch ──
        "het", "een", "van", "voor", "met", "niet", "aan", "maar", "ook", "dat",
        "zijn", "hebben", "wordt", "werd", "deze", "door", "naar", "over", "bij",
        "nog", "wel", "want", "omdat", "waar", "hoe", "wat", "zij", "hij",
        // ── Portuguese ──
        "que", "não", "uma", "por", "para", "com", "dos", "das", "como", "mais",
        "mas", "seu", "sua", "está", "são", "pelo", "pela", "isso", "isto",
        "quando", "porque", "também", "onde", "entre", "sobre", "desde", "eles",
        "nós", "ser", "ter", "fazer", "muito", "tudo",
    ]

    // MARK: Persistence

    private struct Payload: Codable {
        var words: [String: Int]
        var phrases: [String: Int]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        words = p.words
        phrases = p.phrases
    }

    /// Atomic write, capped. Eviction happens here (not on every increment) so the
    /// caps are enforced against the final state regardless of how the counts got
    /// there — including on load-then-immediately-save paths.
    private func save() {
        capIfNeeded()
        let p = Payload(words: words, phrases: phrases)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Evict the lowest-count entries beyond each cap. Ties are broken by key so
    /// eviction is deterministic (important for tests and for not thrashing which
    /// arbitrary entry survives run to run).
    private func capIfNeeded() {
        words = Self.capped(words, to: Self.wordCap)
        phrases = Self.capped(phrases, to: Self.phraseCap)
    }

    private static func capped(_ map: [String: Int], to cap: Int) -> [String: Int] {
        guard map.count > cap else { return map }
        // Highest count first; ties alphabetical. Keep the top `cap`.
        let kept = map.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }.prefix(cap)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
