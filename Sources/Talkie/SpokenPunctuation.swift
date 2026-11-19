import Foundation

/// Spoken punctuation in dictation: "Hallo Doppelpunkt" -> "Hallo:", "und Slash oder"
/// -> "und/oder", "Klammer auf wie gesagt Klammer zu" -> "(wie gesagt)".
///
/// Deterministic and on-device, no model. A sibling of `NumberNormalizer` and
/// `StructuralCommands`; it runs right after `StructuralCommands` (see AppDelegate) and on
/// the text of format-command spans.
///
/// ## The one rule: a word stays a word unless the evidence says it was a command
/// The owner's wording: a punctuation word that is part of the sentence ("in einer neuen
/// Zeile darunter …", "put a colon after …") must never be replaced, because a wrong
/// replacement while describing an edit is worse than a missed command. So the default is
/// LITERAL, and a word is replaced only when
///   1. it is in citation form (the exact table phrase; "Doppelpunkte", "Klammern",
///      "slashes", "neuen Zeile" never match), and
///   2. no sentence-use signal touches it: a determiner, preposition, adjective or an
///      object-taking verb directly before it ("einen/mit der neuen/setz …"), a finite
///      verb or copula directly after it ("Doppelpunkt ist …"), or a word like Zeichen,
///      Taste, key, command next to it (talk ABOUT punctuation). A signal only counts when
///      only whitespace separates it from the word: a recognizer comma in between ("Hallo,
///      Doppelpunkt, das") means the word stands on its own, and
///   3. for the few words that are ordinary too often ("dash", "Sternchen", "Raute",
///      "hashtag"; and every word of the unverified non-German/English tables) the
///      recognizer's own punctuation, or the text edge, touches the word on at least one side.
/// Recognizer word timings were measured and are NOT usable: a pause is folded into the
/// neighbouring word's time range (words abut, gaps are 0.0), so they cannot tell command
/// from sentence use. The new-line and new-paragraph commands stay in `StructuralCommands`
/// (both sides need recognizer punctuation).
///
/// A text with no trigger word comes back byte-identical; running the pass twice equals
/// running it once.
enum SpokenPunctuation {
    typealias Kind = SpokenPunctuationTables.Kind
    typealias Glue = SpokenPunctuationTables.Glue
    typealias Entry = SpokenPunctuationTables.Entry

    static func apply(_ text: String, languageCode: String?) -> String {
        guard !text.isEmpty else { return text }
        let (gaps, words) = tokenize(text)
        guard !words.isEmpty else { return text }
        let entries = SpokenPunctuationTables.entries(languageCode: languageCode)
        let lowered = words.map { $0.lowercased() }

        var out = ""
        var pendingGap = gaps[0]
        var lastRight: Glue? = nil          // nil = free (an ordinary word came before)
        var capitalizeNext = false
        var changed = false
        // Brackets/quotes opened by a spoken command and not yet closed.
        var open: [Family: Int] = [:]
        var i = 0

        while i < words.count {
            if let m = match(at: i, words: words, lowered: lowered, gaps: gaps, entries: entries,
                             languageCode: languageCode, open: open) {
                if m.literal {
                    for k in 0..<m.consumed {
                        out += resolve(pendingGap, lastRight, atEnd: false)
                        var word = words[i + k]
                        if capitalizeNext, let f = word.first, f.isLowercase { word = f.uppercased() + word.dropFirst() }
                        capitalizeNext = false
                        out += word
                        pendingGap = gaps[i + k + 1]
                        lastRight = nil
                    }
                    i += m.consumed
                    continue
                }
                changed = true
                if let f = m.entry.kind.openFamily { open[f, default: 0] += 1 }
                if let f = m.entry.kind.closeFamily, let n = open[f], n > 0 { open[f] = n - 1 }
                let spec = Self.spec(m.entry.kind, languageCode: languageCode)
                let end = i + m.consumed

                // Left side: keep what the recognizer wrote that we do not absorb ("?", "\n").
                let before = String(pendingGap.filter { !spec.absorbBefore.contains($0) && $0 != " " && $0 != "\t" })
                out += before
                let duplicatesTerminator = spec.terminal && before.contains { "?!…".contains($0) }
                if !duplicatesTerminator {
                    if spec.left == .space, lastRight != .attach,
                       let last = out.last, !last.isWhitespace {
                        out += " "
                    }
                    out += m.text ?? spec.text
                }

                // Right side: absorb the recognizer's own punctuation after the word.
                let after = gaps[end]
                var rest = Substring(after)
                while let c = rest.first, spec.absorbAfter.contains(c) || c == " " || c == "\t" {
                    rest = rest.dropFirst()
                }
                pendingGap = String(rest)
                lastRight = spec.right
                capitalizeNext = spec.capitalizeNext
                i = end
                continue
            }

            out += resolve(pendingGap, lastRight, atEnd: false)
            var word = words[i]
            if capitalizeNext, let f = word.first, f.isLowercase { word = f.uppercased() + word.dropFirst() }
            capitalizeNext = false
            out += word
            pendingGap = gaps[i + 1]
            lastRight = nil
            i += 1
        }
        guard changed else { return text }
        out += resolve(pendingGap, lastRight, atEnd: true)
        return out
    }

    // MARK: Matching

    private struct Match {
        let entry: Entry
        let consumed: Int
        /// The phrase was recognised but a sentence-use signal keeps it as words; the
        /// caller copies its `consumed` words through so no inner word re-matches
        /// ("a forward slash" must not become "a forward/").
        var literal = false
        /// Overrides the kind's own text ("§ 5").
        var text: String? = nil
    }

    private static func match(at i: Int, words: [String], lowered: [String], gaps: [String],
                              entries: [Entry], languageCode: String?, open: [Family: Int]) -> Match? {
        let lang = languageCode?.lowercased().prefix(2).description
        for entry in entries {
            if let only = entry.onlyLanguages, !(lang.map(only.contains) ?? false) { continue }
            let n = entry.words.count
            guard i + n <= words.count else { continue }
            var ok = true
            for k in 0..<n {
                if lowered[i + k] != entry.words[k] { ok = false; break }
                if k > 0, !isJoinGap(gaps[i + k]) { ok = false; break }
            }
            guard ok else { continue }
            let j = i + n
            if let prefix = entry.followedByGapPrefix, gaps[j].first != prefix { continue }

            if entry.kind == .sectionNumber {
                // Only "Paragraph 5" / "Paragraf fünf": a number must follow.
                guard j < words.count, isSpaces(gaps[j]), let number = numeral(words[j]) else { continue }
                return Match(entry: entry, consumed: n + 1, text: "§ " + number)
            }
            let closesOpen = entry.kind.closeFamily.map { (open[$0] ?? 0) > 0 } ?? false
            if isSentenceUse(entry, at: i, length: n, words: words, lowered: lowered, gaps: gaps,
                             ignoreFollowingVerb: closesOpen) {
                return Match(entry: entry, consumed: n, literal: true)
            }
            if entry.needsBoundary, !touchesBoundary(at: i, length: n, gaps: gaps, count: words.count) {
                return Match(entry: entry, consumed: n, literal: true)
            }
            if entry.kind.isJoin, j >= words.count { return Match(entry: entry, consumed: n, literal: true) }
            if entry.words.last == "hashtag" {
                // "#launch" only when a word follows directly.
                guard j < words.count, isSpaces(gaps[j]) else { continue }
            }
            return Match(entry: entry, consumed: n)
        }
        return nil
    }

    /// The sentence-use signals (see the type comment). Only a word separated by plain
    /// whitespace (or a hyphen, "Slash-Befehl") governs the phrase.
    private static func isSentenceUse(_ entry: Entry, at i: Int, length n: Int, words: [String],
                                      lowered: [String], gaps: [String],
                                      ignoreFollowingVerb: Bool) -> Bool {
        let tables = SpokenPunctuationTables.self
        // Part of a hyphenated compound ("Semikolon-Regel", "Kaffee-Slash"): never touched.
        if i > 0, gaps[i] == "-" { return true }
        if i + n < words.count, gaps[i + n] == "-" { return true }
        if i > 0, isGoverning(gaps[i]) {
            let p = lowered[i - 1]
            let prevIsLetterA = words[i - 1] == "A" // "A Gleichheitszeichen B"
            let algebra = (p == "a") && i + n < words.count && words[i + n].count == 1
            if tables.aboutPunctuation.contains(p) { return true }
            if tables.literalBefore.contains(p), !entry.ignorePrev.contains(p), !prevIsLetterA, !algebra {
                return true
            }
        }
        let j = i + n
        if j < words.count, isGoverning(gaps[j]) {
            let nx = lowered[j]
            if tables.aboutPunctuation.contains(nx) { return true }
            // "Klammer auf … Klammer zu geht das": a closing word that matches an opening
            // command is kept, or the text would be left with a dangling bracket.
            if !ignoreFollowingVerb, tables.literalAfter.contains(nx) { return true }
        }
        return false
    }

    /// The recognizer's own punctuation (or the start/end of the text) on at least one side.
    private static func touchesBoundary(at i: Int, length n: Int, gaps: [String], count: Int) -> Bool {
        let marks: Set<Character> = [",", ".", ";", ":", "!", "?", "…", "\n"]
        let before = gaps[i], after = gaps[i + n]
        let atStart = i == 0 && before.allSatisfy(\.isWhitespace)
        let atEnd = i + n == count && after.allSatisfy { $0.isWhitespace || marks.contains($0) }
        return atStart || atEnd || before.contains(where: marks.contains) || after.contains(where: marks.contains)
    }

    private static func isSpaces(_ gap: String) -> Bool { !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "\t" } }
    private static func isJoinGap(_ gap: String) -> Bool { isSpaces(gap) || gap == "-" }
    private static func isGoverning(_ gap: String) -> Bool { isJoinGap(gap) }

    /// A number after "Paragraph": digits ("5", "12", "5a") or a German number word.
    private static func numeral(_ word: String) -> String? {
        if word.allSatisfy(\.isNumber) { return word }
        if word.count >= 2, word.dropLast().allSatisfy(\.isNumber), word.last!.isLetter, word.last!.isASCII { return word }
        return SpokenPunctuationTables.numberWords[word.lowercased()]
    }

    // MARK: Spacing

    typealias Family = SpokenPunctuationTables.Family

    private struct Spec {
        var text: String
        var left: Glue
        var right: Glue
        var absorbBefore: Set<Character>
        var absorbAfter: Set<Character>
        var terminal = false
        var capitalizeNext = false
    }

    private static func spec(_ kind: Kind, languageCode: String?) -> Spec {
        let all: Set<Character> = [",", ".", ";", ":"]
        let soft: Set<Character> = [",", ";", ":"]
        let comma: Set<Character> = [",", ";"]
        let base = languageCode?.lowercased().prefix(2).description
        let english = base == nil || base == "en"
        let quotes = FormatRenderer.quoteMarks(languageCode: languageCode)
        switch kind {
        case .colon: return Spec(text: ":", left: .attach, right: .space, absorbBefore: all, absorbAfter: all, terminal: true)
        case .semicolon: return Spec(text: ";", left: .attach, right: .space, absorbBefore: all, absorbAfter: all, terminal: true)
        case .question:
            return Spec(text: "?", left: .attach, right: .space, absorbBefore: all,
                        absorbAfter: all.union(["!", "?"]), terminal: true, capitalizeNext: true)
        case .exclaim:
            return Spec(text: "!", left: .attach, right: .space, absorbBefore: all,
                        absorbAfter: all.union(["!", "?"]), terminal: true, capitalizeNext: true)
        case .ellipsis: return Spec(text: "…", left: .attach, right: .space, absorbBefore: all, absorbAfter: all, terminal: true)
        case .openParen: return Spec(text: "(", left: .space, right: .attach, absorbBefore: [], absorbAfter: all)
        case .openBracket: return Spec(text: "[", left: .space, right: .attach, absorbBefore: [], absorbAfter: all)
        case .openBrace: return Spec(text: "{", left: .space, right: .attach, absorbBefore: [], absorbAfter: all)
        case .quoteOpen: return Spec(text: quotes.open, left: .space, right: .attach, absorbBefore: [], absorbAfter: all)
        case .closeParen: return Spec(text: ")", left: .attach, right: .space, absorbBefore: all, absorbAfter: [])
        case .closeBracket: return Spec(text: "]", left: .attach, right: .space, absorbBefore: all, absorbAfter: [])
        case .closeBrace: return Spec(text: "}", left: .attach, right: .space, absorbBefore: all, absorbAfter: [])
        case .quoteClose: return Spec(text: quotes.close, left: .attach, right: .space, absorbBefore: all, absorbAfter: [])
        case .slash: return Spec(text: "/", left: .attach, right: .attach, absorbBefore: all, absorbAfter: all)
        case .backslash: return Spec(text: "\\", left: .attach, right: .attach, absorbBefore: all, absorbAfter: all)
        case .hyphen: return Spec(text: "-", left: .attach, right: .attach, absorbBefore: all, absorbAfter: all)
        case .underscore: return Spec(text: "_", left: .attach, right: .attach, absorbBefore: all, absorbAfter: all)
        case .at: return Spec(text: "@", left: .attach, right: .attach, absorbBefore: all, absorbAfter: all)
        case .emDash: return Spec(text: "—", left: .attach, right: .attach, absorbBefore: soft, absorbAfter: soft)
        case .enDash: return Spec(text: "–", left: .attach, right: .attach, absorbBefore: soft, absorbAfter: soft)
        case .dash:
            return english
                ? Spec(text: "—", left: .attach, right: .attach, absorbBefore: soft, absorbAfter: soft)
                : Spec(text: "–", left: .space, right: .space, absorbBefore: soft, absorbAfter: soft)
        case .dashSpaced: return Spec(text: "–", left: .space, right: .space, absorbBefore: soft, absorbAfter: soft)
        case .percent:
            return Spec(text: "%", left: base == "de" ? .space : .attach, right: .space, absorbBefore: [], absorbAfter: [])
        case .ampersand: return Spec(text: "&", left: .space, right: .space, absorbBefore: comma, absorbAfter: comma)
        case .equals: return Spec(text: "=", left: .space, right: .space, absorbBefore: comma, absorbAfter: comma)
        case .plus: return Spec(text: "+", left: .space, right: .space, absorbBefore: comma, absorbAfter: comma)
        case .asterisk: return Spec(text: "*", left: .space, right: .space, absorbBefore: comma, absorbAfter: comma)
        case .section, .sectionNumber: return Spec(text: "§", left: .space, right: .space, absorbBefore: comma, absorbAfter: comma)
        case .hash: return Spec(text: "#", left: .space, right: .attach, absorbBefore: comma, absorbAfter: comma)
        }
    }

    /// The gap text to write after a mark (or a word), given how that mark glues right.
    private static func resolve(_ raw: String, _ glue: Glue?, atEnd: Bool) -> String {
        guard let glue else { return raw }
        let trimmed = raw.drop { $0 == " " || $0 == "\t" }
        switch glue {
        case .attach: return String(trimmed)
        case .space:
            if let f = trimmed.first {
                if f == "\n" { return raw }
                if ".,;:!?)]}”’»".contains(f) { return String(trimmed) }
            }
            if raw.first == " " || raw.first == "\t" { return raw }
            if raw.isEmpty { return atEnd ? "" : " " }
            return " " + raw
        }
    }

    // MARK: Tokenize

    /// Alternating gaps and words, like `StructuralCommands`: `gaps.count == words.count + 1`.
    /// A word is a run of letters/digits/apostrophes; punctuation lives in the gaps.
    private static func tokenize(_ s: String) -> (gaps: [String], words: [String]) {
        var gaps: [String] = [""]
        var words: [String] = []
        var buf = ""
        var bufIsWord: Bool? = nil
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }
        func flush() {
            guard let isWord = bufIsWord, !buf.isEmpty else { return }
            if isWord { words.append(buf); gaps.append("") } else { gaps[gaps.count - 1] += buf }
            buf = ""
        }
        for c in s {
            let w = isWordChar(c)
            if bufIsWord == nil { bufIsWord = w; buf = String(c) }
            else if w == bufIsWord { buf.append(c) }
            else { flush(); bufIsWord = w; buf = String(c) }
        }
        flush()
        return (gaps, words)
    }
}
