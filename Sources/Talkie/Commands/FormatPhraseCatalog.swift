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
}
