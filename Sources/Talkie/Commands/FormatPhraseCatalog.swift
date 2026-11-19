import Foundation

/// Which wordings the Commands page lists for a command, in the languages the user
/// dictates in. Pure (no settings, no UI) so the choices are unit-tested.
///
/// Every built-in phrase in every language works whatever the dictation language is;
/// this only decides what the page SHOWS first: the user's own dictation languages
/// (their first one is the primary), falling back to the UI language and English.
enum FormatPhraseCatalog {

    /// Phrase-table language codes to show, in order, without duplicates. `spoken` are
    /// locale ids from Settings ▸ Languages ("de-DE", "en-US"); with none that has a
    /// phrase table, the UI language and then English.
    static func languages(spoken: [String], uiLanguage: String?) -> [String] {
        var out: [String] = []
        func add(_ code: String?) {
            if let code, !out.contains(code) { out.append(code) }
        }
        for id in spoken { add(FormatPhrases.language(of: id)) }
        if out.isEmpty {
            add(FormatPhrases.language(of: uiLanguage))
            add("en")
        }
        return out
    }

    /// The other phrase-table languages (those not shown first), in table order.
    static func otherLanguages(than shown: [String]) -> [String] {
        FormatPhrases.languages.filter { !shown.contains($0) }
    }

    /// Phrases of `preset` in `languages` (each language's table in turn), then the
    /// user's own words; spelling variants that normalise the same are listed once.
    static func phrases(_ preset: FormatPreset, languages: [String], own: [String] = []) -> [String] {
        unique(languages.flatMap { FormatPhrases.phrases(preset, language: $0) } + own)
    }

    /// First occurrence of each phrase (compared the way the matcher compares them).
    static func unique(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        return phrases.filter { phrase in
            let key = FormatPhraseMatcher.normalizedTokens(phrase).joined()
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    /// What a card shows: the main phrase, up to `extra` more, and how many are left.
    struct Summary: Equatable {
        var main: String
        var more: [String]
        var hidden: Int
    }

    static func summary(_ phrases: [String], extra: Int = 2) -> Summary? {
        guard let main = phrases.first else { return nil }
        let rest = Array(phrases.dropFirst())
        return Summary(main: main, more: Array(rest.prefix(extra)), hidden: max(0, rest.count - extra))
    }

    /// Whole phrases laid out on at most `maxLines` lines of `width`, in order; never
    /// cut mid-phrase. What does not fit is counted in `hidden` (shown as "+N more" at
    /// the end of the last line, which is given room). The first phrase is always shown.
    struct Fitted: Equatable {
        var lines: [[String]]
        var hidden: Int
    }

    static func fit(_ phrases: [String], maxLines: Int, width: Double,
                    measure: (String) -> Double, separator: Double, moreWidth: (Int) -> Double) -> Fitted {
        var lines: [[String]] = [[]]
        var used: [Double] = [0]
        var placed = 0
        for phrase in phrases {
            let w = measure(phrase)
            var li = lines.count - 1
            let extra = used[li] == 0 ? w : separator + w
            if used[li] + extra > width, !(lines[li].isEmpty) {
                guard lines.count < maxLines else { break }
                lines.append([]); used.append(0); li += 1
            }
            used[li] += used[li] == 0 ? w : separator + w
            lines[li].append(phrase)
            placed += 1
        }
        var hidden = phrases.count - placed
        // Make room for "+N more" at the end of the last line.
        while hidden > 0 {
            let li = lines.count - 1
            if used[li] + separator + moreWidth(hidden) <= width { break }
            guard placed > 1 else { break }
            let removed = lines[li].removeLast()
            used[li] -= lines[li].isEmpty ? measure(removed) : separator + measure(removed)
            if lines[li].isEmpty, lines.count > 1 { lines.removeLast(); used.removeLast() }
            placed -= 1
            hidden += 1
        }
        return Fitted(lines: lines.filter { !$0.isEmpty }, hidden: hidden)
    }
}
