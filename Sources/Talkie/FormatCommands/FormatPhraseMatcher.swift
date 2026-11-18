import Foundation

/// Matches the words recognised inside a command span against every preset's German
/// and English phrases. Pure and deterministic.
///
/// Tolerance, in order of preference:
///   1. the whole utterance equals a phrase after normalisation (case, accents, ß,
///      hyphens, spacing and filler/carrier words like "als", "bitte", "make it",
///      "in" are ignored — so "In Stichpunkten, bitte." and "stichpunkten" match);
///   2. the whole utterance is within a small edit distance of a phrase (a
///      misrecognised letter or two: "Stichpunkte" / "Stichpunkt" / "Gänsefüsschen");
///   3. a run of words inside the utterance matches (1) or (2) — so "okay jetzt als
///      E-Mail" still finds "E-Mail".
/// Two different commands matching equally well is ambiguous and returns nil — a
/// wrong format is worse than "not recognised".
enum FormatPhraseMatcher {

    /// The command for `spoken`, or nil when nothing matches (or it's ambiguous).
    static func match(_ spoken: String) -> FormatCommand? {
        let tokens = normalizedTokens(spoken)
        guard !tokens.isEmpty else { return nil }

        // Whole utterance first.
        if let whole = bestMatch(for: tokens.joined()) { return whole.command }

        // Then runs of words, longest first; among equal lengths, exact beats fuzzy.
        let maxWindow = min(4, tokens.count - 1)
        guard maxWindow >= 1 else { return nil }
        for length in stride(from: maxWindow, through: 1, by: -1) {
            var hits: [(command: FormatCommand, distance: Int)] = []
            for start in 0...(tokens.count - length) {
                let joined = tokens[start..<(start + length)].joined()
                if let hit = bestMatch(for: joined) { hits.append(hit) }
            }
            guard let best = hits.map(\.distance).min() else { continue }
            let winners = Set(hits.filter { $0.distance == best }.map { key($0.command) })
            if winners.count == 1, let w = hits.first(where: { $0.distance == best }) { return w.command }
            return nil   // two different formats in one span → ambiguous
        }
        return nil
    }

    /// Strict variant: only when the WHOLE utterance is a phrase (exact or within the
    /// edit tolerance) — no word-run search. Used to find exactly where a command
    /// phrase sits in a transcript.
    static func matchWhole(_ spoken: String) -> FormatCommand? {
        let tokens = normalizedTokens(spoken)
        guard !tokens.isEmpty else { return nil }
        return bestMatch(for: tokens.joined())?.command
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

    // MARK: - Phrase table

    private struct Entry { let joined: String; let command: FormatCommand }

    private static let entries: [Entry] = {
        var out: [Entry] = []
        func add(_ phrases: [String], _ command: FormatCommand) {
            for p in phrases {
                let joined = normalizedTokens(p).joined()
                if !joined.isEmpty { out.append(Entry(joined: joined, command: command)) }
            }
        }
        for preset in FormatPreset.allCases {
            add(preset.germanPhrases, .apply(preset))
            add(preset.englishPhrases, .apply(preset))
        }
        add(FormatCommand.germanEndPhrases, .end)
        add(FormatCommand.englishEndPhrases, .end)
        return out
    }()

    /// How many edits a phrase of this length tolerates. Short phrases ("end", "code",
    /// "mail") must match exactly — one letter off is a different word.
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
    private static func bestMatch(for joined: String) -> (command: FormatCommand, distance: Int)? {
        guard !joined.isEmpty else { return nil }
        var best: Int?
        var commands: [FormatCommand] = []
        for e in entries {
            let allowed = allowedDistance(forLength: e.joined.count)
            // Cheap length prefilter.
            guard abs(e.joined.count - joined.count) <= allowed else { continue }
            let d = e.joined == joined ? 0 : levenshtein(joined, e.joined)
            guard d <= allowed else { continue }
            if best == nil || d < best! {
                best = d
                commands = [e.command]
            } else if d == best!, !commands.contains(e.command) {
                commands.append(e.command)
            }
        }
        guard let best, commands.count == 1 else { return nil }
        return (commands[0], best)
    }

    private static func key(_ c: FormatCommand) -> String {
        switch c {
        case .apply(let p): return p.rawValue
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
