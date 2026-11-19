import Foundation

/// Which command a phrase belongs to — the key for synonyms, on/off and conflicts.
enum FormatCommandOwner: Hashable, Sendable {
    case preset(FormatPreset)
    case user(UUID)
    case end

    /// The settings-store key for a built-in's synonyms / on-off ("bulletList").
    var settingsKey: String? {
        if case .preset(let p) = self { return p.rawValue }
        return nil
    }
}

/// Every phrase the matcher knows right now: the built-ins in all languages (minus the
/// commands switched off), the user's synonyms, and the user-made commands. Pure value;
/// the app keeps `FormatPhraseBook.current` in step with the settings.
struct FormatPhraseBook: Sendable {
    struct Entry: Sendable, Equatable {
        let joined: String
        let command: FormatCommand
        let owner: FormatCommandOwner
        /// Written without spaces (Japanese, Chinese): also matched as a contained run.
        let unspaced: Bool
    }

    private(set) var entries: [Entry]

    init(disabledPresets: Set<FormatPreset> = [], synonyms: [String: [String]] = [:],
         userCommands: [UserCommand] = []) {
        var out: [Entry] = []
        func add(_ phrases: [String], _ command: FormatCommand, _ owner: FormatCommandOwner) {
            for p in phrases {
                let joined = FormatPhraseMatcher.normalizedTokens(p).joined()
                guard !joined.isEmpty, !out.contains(where: { $0.joined == joined && $0.owner == owner }) else { continue }
                out.append(Entry(joined: joined, command: command, owner: owner,
                                 unspaced: FormatPhraseMatcher.isUnspacedScript(joined)))
            }
        }
        for preset in FormatPreset.allCases where !disabledPresets.contains(preset) {
            add(preset.allPhrases + (synonyms[preset.rawValue] ?? []), .apply(preset), .preset(preset))
        }
        add(FormatPhrases.allEndPhrases, .end, .end)
        for command in userCommands where command.enabled {
            add(command.phrases, .user(command), .user(command.id))
        }
        entries = out
    }

    static let builtIn = FormatPhraseBook()

    // MARK: Shared instance

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var book = FormatPhraseBook.builtIn
    }
    private static let box = Box()

    /// The book the live matcher uses. Set by the app when commands, synonyms or
    /// on/off change; tests pass explicit books instead.
    static var current: FormatPhraseBook {
        get { box.lock.lock(); defer { box.lock.unlock() }; return box.book }
        set { box.lock.lock(); box.book = newValue; box.lock.unlock() }
    }

    // MARK: Conflicts

    enum Refusal: Error, Equatable, Sendable {
        /// Nothing left after dropping filler words ("as", "please" …).
        case onlyFillerWords
        /// Already said for another command (its display name).
        case usedBy(String)
        /// Already in this command's list.
        case alreadyListed

        /// The one-line reason shown under the field.
        var message: String {
            switch self {
            case .onlyFillerWords:
                return "Add a word that says what it does — that one is only filler words.".loc
            case .usedBy(let name):
                return String(format: "Already used by \u{201C}%@\u{201D} — pick another phrase.".loc, name)
            case .alreadyListed:
                return "That phrase is already in the list.".loc
            }
        }
    }

    /// Why `phrase` can't be added to `owner`, or nil when it can. A phrase that equals
    /// — or is within the misrecognition tolerance of — another command's phrase is
    /// refused, because the matcher could no longer tell the two apart.
    func refusal(for phrase: String, owner: FormatCommandOwner) -> Refusal? {
        let joined = FormatPhraseMatcher.normalizedTokens(phrase).joined()
        guard !joined.isEmpty else { return .onlyFillerWords }
        if entries.contains(where: { $0.owner == owner && $0.joined == joined }) { return .alreadyListed }
        for e in entries where e.owner != owner {
            let allowed = FormatPhraseMatcher.allowedDistance(forLength: max(e.joined.count, joined.count))
            guard abs(e.joined.count - joined.count) <= allowed else { continue }
            if e.joined == joined || FormatPhraseMatcher.levenshtein(e.joined, joined) <= allowed {
                return .usedBy(e.command.displayName)
            }
        }
        return nil
    }
}

/// Matches the words recognised inside a command span against a phrase book (every
/// language's built-in phrases, synonyms and user-made commands). Pure and
/// deterministic.
///
/// Tolerance, in order of preference:
///   1. the whole utterance equals a phrase after normalisation (case, accents, ß,
///      hyphens, spacing and filler/carrier words like "als", "bitte", "make it",
///      "in", "en", "como" are ignored — so "In Stichpunkten, bitte." matches);
///   2. the whole utterance is within a small edit distance of a phrase (a
///      misrecognised letter or two: "Stichpunkte" / "Stichpunkt" / "Gänsefüsschen");
///   3. a run of words inside the utterance matches (1) or (2) — so "okay jetzt als
///      E-Mail" still finds "E-Mail"; for Japanese and Chinese, which are written
///      without spaces, the longest phrase contained in the utterance.
/// Two different commands matching equally well is ambiguous and returns nil — a
/// wrong format is worse than "not recognised".
enum FormatPhraseMatcher {

    /// How good a match is: lower is better (whole utterance before word runs, then
    /// fewer edits).
    struct Score: Comparable, Sendable {
        var tier: Int
        var distance: Int
        static func < (a: Score, b: Score) -> Bool { (a.tier, a.distance) < (b.tier, b.distance) }
    }

    /// The command for `spoken`, or nil when nothing matches (or it's ambiguous).
    static func match(_ spoken: String, book: FormatPhraseBook = .current) -> FormatCommand? {
        scored(spoken, book: book)?.command
    }

    /// `match` with its score, for comparing candidates from several recognisers.
    static func scored(_ spoken: String, book: FormatPhraseBook = .current) -> (command: FormatCommand, score: Score)? {
        let tokens = normalizedTokens(spoken)
        guard !tokens.isEmpty else { return nil }

        // Whole utterance first.
        let whole = tokens.joined()
        if let hit = bestMatch(for: whole, book: book) { return (hit.command, Score(tier: 0, distance: hit.distance)) }

        // Then runs of words, longest first; among equal lengths, exact beats fuzzy.
        let maxWindow = min(4, tokens.count - 1)
        if maxWindow >= 1 {
            for length in stride(from: maxWindow, through: 1, by: -1) {
                var hits: [(command: FormatCommand, distance: Int)] = []
                for start in 0...(tokens.count - length) {
                    let joined = tokens[start..<(start + length)].joined()
                    if let hit = bestMatch(for: joined, book: book) { hits.append(hit) }
                }
                guard let best = hits.map(\.distance).min() else { continue }
                let winners = hits.filter { $0.distance == best }
                if Set(winners.map { key($0.command) }).count == 1 {
                    return (winners[0].command, Score(tier: 1, distance: best))
                }
                return nil   // two different formats in one span → ambiguous
            }
        }

        // Unspaced scripts: the longest phrase contained in the utterance.
        if isUnspacedScript(whole) {
            let contained = book.entries.filter { $0.unspaced && $0.joined.count >= 2 && whole.contains($0.joined) }
            guard let longest = contained.map(\.joined.count).max() else { return nil }
            let winners = contained.filter { $0.joined.count == longest }
            if Set(winners.map { key($0.command) }).count == 1 {
                return (winners[0].command, Score(tier: 2, distance: whole.count - longest))
            }
        }
        return nil
    }

    /// The best command across several readings of the same span (the live recogniser
    /// and re-recognitions in the other enabled languages). The best score wins; on a
    /// tie between different commands the first candidate's reading (the live one)
    /// breaks it, otherwise it is ambiguous (nil).
    static func bestAcross(_ candidates: [String], book: FormatPhraseBook = .current) -> FormatCommand? {
        let hits = candidates.enumerated().compactMap { i, text in
            scored(text, book: book).map { (index: i, command: $0.command, score: $0.score) }
        }
        guard let best = hits.map(\.score).min() else { return nil }
        let winners = hits.filter { $0.score == best }
        if Set(winners.map { key($0.command) }).count == 1 { return winners[0].command }
        return winners.first(where: { $0.index == 0 })?.command
    }

    /// Strict variant: only when the WHOLE utterance is a phrase (exact or within the
    /// edit tolerance) — no word-run search. Used to find exactly where a command
    /// phrase sits in a transcript.
    static func matchWhole(_ spoken: String, book: FormatPhraseBook = .current) -> FormatCommand? {
        let tokens = normalizedTokens(spoken)
        guard !tokens.isEmpty else { return nil }
        return bestMatch(for: tokens.joined(), book: book)?.command
    }

    // MARK: - Normalisation

    /// Carrier and filler words that never decide a format (folded spellings).
    static let stopWords: Set<String> = [
        // German
        "als", "in", "im", "ins", "auf", "bitte", "mach", "mache", "machs", "mal", "das",
        "es", "den", "die", "der", "dem", "ein", "eine", "einer", "einen", "jetzt", "format",
        "formatieren", "formatiert", "schreib", "schreibe", "schreiben", "modus", "und",
        "okay", "ok", "also", "ah", "ahm", "ubersetze", "ubersetzen", "uebersetze", "nun",
        // English
        "as", "a", "an", "into", "the", "please", "make", "it", "this", "that", "formatted",
        "write", "now", "mode", "to", "um", "uh", "translate", "translated", "and", "so",
        // French
        "en", "comme", "le", "la", "les", "un", "une", "des", "du", "de", "sil", "vous", "plait",
        "traduire", "traduis",
        // Spanish / Portuguese / Italian
        "como", "con", "el", "los", "las", "una", "por", "favor", "al", "del", "traducir",
        "em", "com", "o", "os", "um", "uma", "para", "ao", "da", "traduzir",
        "come", "per", "il", "lo", "di", "traduci",
        // Dutch
        "het", "een", "naar", "alsjeblieft", "maak", "vertaal",
    ]

    /// Lowercased, accent-folded, ß→ss, punctuation and hyphens as spaces, stop words
    /// dropped.
    static func normalizedTokens(_ text: String) -> [String] {
        let folded = text
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ẞ", with: "ss")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        let spaced = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return spaced.split(separator: " ").map(String.init).filter { !stopWords.contains($0) }
    }

    /// Japanese kana/kanji or Chinese ideographs (scripts written without spaces).
    static func isUnspacedScript(_ s: String) -> Bool {
        s.unicodeScalars.contains { v in
            (0x3040...0x30FF).contains(v.value) || (0x4E00...0x9FFF).contains(v.value)
                || (0x3400...0x4DBF).contains(v.value)
        }
    }

    // MARK: - Matching

    /// How many edits a phrase of this length tolerates. Short phrases ("end", "code",
    /// "mail") must match exactly — one letter off is a different word. Ideographic
    /// phrases are short in characters and always exact.
    static func allowedDistance(forLength n: Int) -> Int {
        switch n {
        case ..<5: return 0
        case 5..<8: return 1
        case 8..<13: return 2
        default: return 3
        }
    }

    /// The closest phrase within tolerance for one joined candidate, or nil. Ties
    /// between DIFFERENT commands are ambiguous (nil).
    private static func bestMatch(for joined: String, book: FormatPhraseBook) -> (command: FormatCommand, distance: Int)? {
        guard !joined.isEmpty else { return nil }
        var best: Int?
        var commands: [FormatCommand] = []
        for e in book.entries {
            let allowed = e.unspaced ? 0 : allowedDistance(forLength: e.joined.count)
            // Cheap length prefilter.
            guard abs(e.joined.count - joined.count) <= allowed else { continue }
            let d = e.joined == joined ? 0 : levenshtein(joined, e.joined)
            guard d <= allowed else { continue }
            if best == nil || d < best! {
                best = d
                commands = [e.command]
            } else if d == best!, !commands.contains(where: { key($0) == key(e.command) }) {
                commands.append(e.command)
            }
        }
        guard let best, commands.count == 1 else { return nil }
        return (commands[0], best)
    }

    private static func key(_ c: FormatCommand) -> String {
        switch c {
        case .apply(let p): return p.rawValue
        case .user(let u): return u.id.uuidString
        case .end: return "end"
        }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
