import Foundation
import NaturalLanguage

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
///      Added in the second pass: two or more mark names linked by "und/oder/and/or/
///      statt …" are a list and stay words ("Fragezeichen oder Punkt?"); a mark that
///      attaches to the previous word but is said FIRST with more words after it has
///      nothing to attach to ("Fragezeichen am Ende fehlt"); a preposition right after
///      ("Fragezeichen durch Punkte ersetzen"); for joining marks and symbols a verb right
///      after ("backslash matters", "asterisk marks"), for joining marks a determiner
///      after or a modal before ("slash the prices", "we should slash prices"). The
///      on-device lexical tagger (NaturalLanguage) adds verbs, prepositions and
///      determiners the lists miss; without a tagger model the lists alone decide.
///   3. for the few words that are ordinary too often ("dash", "hashtag"; and every word
///      of the unverified non-German/English tables) the
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

    /// - Parameter useTagger: also ask the on-device lexical tagger (NaturalLanguage) for
    ///   the word class of the neighbours. It only ever ADDS reasons to keep a word; when
    ///   the tagger has no model for the language the word lists alone decide. Tests pass
    ///   `false` to pin the word-list behaviour.
    static func apply(_ text: String, languageCode: String?, useTagger: Bool = true) -> String {
        guard !text.isEmpty else { return text }
        let (gaps, words, offsets) = tokenize(text)
        guard !words.isEmpty else { return text }
        let entries = SpokenPunctuationTables.entries(languageCode: languageCode)
        let lowered = words.map { $0.lowercased() }
        let ctx = Context(text: text, words: words, lowered: lowered, gaps: gaps, offsets: offsets,
                          entries: entries, languageCode: languageCode, useTagger: useTagger)

        var out = ""
        var pendingGap = gaps[0]
        var lastRight: Glue? = nil          // nil = free (an ordinary word came before)
        var capitalizeNext = false
        var changed = false
        // Brackets/quotes opened by a spoken command and not yet closed.
        var open: [Family: Int] = [:]
        var i = 0

        while i < words.count {
            if let m = match(at: i, ctx, open: open) {
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

    private static func match(at i: Int, _ c: Context, open: [Family: Int]) -> Match? {
        let words = c.words, gaps = c.gaps
        let lang = c.languageCode?.lowercased().prefix(2).description
        for entry in c.entries {
            if let only = entry.onlyLanguages, !(lang.map(only.contains) ?? false) { continue }
            let n = entry.words.count
            guard c.phrase(entry, at: i) else { continue }
            let j = i + n
            if let prefix = entry.followedByGapPrefix, gaps[j].first != prefix { continue }

            if entry.kind == .sectionNumber {
                // Only "Paragraph 5" / "Paragraf fünf": a number must follow.
                guard j < words.count, isSpaces(gaps[j]), let number = numeral(words[j]) else { continue }
                return Match(entry: entry, consumed: n + 1, text: "§ " + number)
            }
            let closesOpen = entry.kind.closeFamily.map { (open[$0] ?? 0) > 0 } ?? false
            if isSentenceUse(entry, at: i, length: n, c, closesOpen: closesOpen) {
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
    private static func isSentenceUse(_ entry: Entry, at i: Int, length n: Int, _ c: Context,
                                      closesOpen: Bool) -> Bool {
        let tables = SpokenPunctuationTables.self
        let words = c.words, lowered = c.lowered, gaps = c.gaps
        let kind = entry.kind
        let j = i + n
        // Part of a hyphenated compound ("Semikolon-Regel", "Kaffee-Slash"): never touched.
        if i > 0, gaps[i] == "-" { return true }
        if j < words.count, gaps[j] == "-" { return true }
        // Two or more mark names joined by "und/oder/and/or …" ("Doppelpunkt, Semikolon
        // und Slash", "Fragezeichen oder Punkt?"): talk ABOUT punctuation.
        if isEnumeration(at: i, end: j, c) { return true }
        // A mark that attaches to the word before it, said first with more words after
        // ("Fragezeichen am Ende fehlt", "colon cancer screening"): there is nothing for it
        // to attach to, so it is a noun. A dictation of only marks ("Exclamation point")
        // is still a command.
        if kind.attachesToPrevious, i == 0, gaps[0].allSatisfy(\.isWhitespace), j < words.count { return true }

        let hasPrev = i > 0 && isGoverning(gaps[i])
        let hasNext = j < words.count && isGoverning(gaps[j])
        if hasPrev {
            let p = lowered[i - 1]
            let prevIsLetterA = words[i - 1] == "A" // "A Gleichheitszeichen B"
            let algebra = (p == "a") && j < words.count && words[j].count == 1
            if tables.aboutPunctuation.contains(p) { return true }
            if tables.literalBefore.contains(p), !entry.ignorePrev.contains(p), !prevIsLetterA, !algebra {
                return true
            }
            if !entry.ignorePrev.contains(p), !prevIsLetterA, !algebra {
                // "mit der neuen …": an adjective after a determiner or preposition.
                // Articles and prepositions from the lists only: "Is this right question
                // mark" has a pronoun, not a determiner, before the adjective.
                if c.isAdjective(i - 1), i >= 2, isGoverning(gaps[i - 1]),
                   tables.articles.contains(lowered[i - 2]) || tables.prepositions.contains(lowered[i - 2]) {
                    return true
                }
                // "we should slash prices", "wir müssen Unterstrich …": a modal or a verb
                // right before a joining mark makes the mark word a verb or an object. In
                // English only the auxiliaries count: the tagger reads names like "max" as
                // verbs ("write to max at sign example").
                if kind.isJoin, tables.auxiliaries.contains(p) || (c.isGermanTagging && c.isVerb(i - 1)) {
                    return true
                }
            }
        }
        if hasNext {
            let nx = lowered[j]
            if tables.aboutPunctuation.contains(nx) { return true }
            // "Klammer auf … Klammer zu geht das": a closing word that matches an opening
            // command is kept, or the text would be left with a dangling bracket.
            if !closesOpen {
                if tables.literalAfter.contains(nx) { return true }
                // "Fragezeichen durch Punkte ersetzen", "Unterstrich statt Leerzeichen",
                // "colon in the title": a preposition right after makes it a noun. Openers
                // are exempt ("Klammer auf in der Regel Klammer zu").
                if !kind.isOpener, c.isPreposition(j) { return true }
                // "backslash funktioniert …", "asterisk marks the footnote": a verb right
                // after a joining mark or symbol. (Not after "?", "!", ":": a new clause
                // often starts with a verb there, "Bist du sicher? Kommst du mit?".)
                if kind.isJoin || kind.isSymbol, c.isVerb(j) { return true }
                if kind.attachesToPrevious, hasPrev, tables.conjunctions.contains(lowered[i - 1]), c.isVerb(j) {
                    return true
                }
                // "underscore the importance", "slash the prices": a determiner after a
                // joining mark.
                if kind.isJoin, c.isDeterminer(j) { return true }
            }
        }
        return false
    }

    /// Whether the phrase at `i..<end` is one item of a list of mark names linked by a
    /// connector word ("und", "oder", "and", "or", "statt", "instead of" …).
    private static func isEnumeration(at i: Int, end: Int, _ c: Context) -> Bool {
        let tables = SpokenPunctuationTables.self
        let count = c.words.count
        var linked = false
        // Rightwards.
        var pos = end
        while pos < count, isListGap(c.gaps[pos]) {
            var q = pos
            var connector = false
            if let len = tables.connectorLength(c.lowered, at: q) {
                connector = true
                q += len
                guard q < count, isSpaces(c.gaps[q]) else { break }
            }
            guard let len = c.markNameStarting(at: q) else { break }
            linked = linked || connector
            pos = q + len
        }
        if linked { return true }
        // Leftwards.
        pos = i
        while pos > 0, isListGap(c.gaps[pos]) {
            var q = pos - 1
            var connector = false
            if let start = tables.connectorStart(c.lowered, endingAt: q) {
                connector = true
                guard start > 0, isListGap(c.gaps[start]) else { break }
                q = start - 1
            }
            guard let len = c.markNameEnding(at: q) else { break }
            linked = linked || connector
            pos = q - len + 1
        }
        return linked
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
    fileprivate static func isJoinGap(_ gap: String) -> Bool { isSpaces(gap) || gap == "-" }
    private static func isGoverning(_ gap: String) -> Bool { isJoinGap(gap) }
    /// Between two items of a spoken list: spaces, optionally one comma.
    private static func isListGap(_ gap: String) -> Bool {
        let t = gap.filter { $0 != " " && $0 != "\t" }
        return !gap.isEmpty && (t.isEmpty || t == ",")
    }

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
    /// `offsets` holds each word's UTF-16 start offset (to line it up with the tagger).
    private static func tokenize(_ s: String) -> (gaps: [String], words: [String], offsets: [Int]) {
        var gaps: [String] = [""]
        var words: [String] = []
        var offsets: [Int] = []
        var buf = ""
        var bufStart = 0
        var position = 0
        var bufIsWord: Bool? = nil
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }
        func flush() {
            guard let isWord = bufIsWord, !buf.isEmpty else { return }
            if isWord { words.append(buf); offsets.append(bufStart); gaps.append("") } else { gaps[gaps.count - 1] += buf }
            buf = ""
        }
        for c in s {
            let w = isWordChar(c)
            if bufIsWord == nil { bufIsWord = w; buf = String(c); bufStart = position }
            else if w == bufIsWord { buf.append(c) }
            else { flush(); bufIsWord = w; buf = String(c); bufStart = position }
            position += c.utf16.count
        }
        flush()
        return (gaps, words, offsets)
    }

    // MARK: Context (words, gaps, and the lazily computed word classes)

    private final class Context {
        let text: String
        let words: [String]
        let lowered: [String]
        let gaps: [String]
        let offsets: [Int]
        let entries: [Entry]
        let languageCode: String?
        let useTagger: Bool

        init(text: String, words: [String], lowered: [String], gaps: [String], offsets: [Int],
             entries: [Entry], languageCode: String?, useTagger: Bool) {
            self.text = text; self.words = words; self.lowered = lowered; self.gaps = gaps
            self.offsets = offsets; self.entries = entries; self.languageCode = languageCode
            self.useTagger = useTagger
        }

        /// Whether `entry`'s words stand at `i` (only spaces or a hyphen between them).
        func phrase(_ entry: Entry, at i: Int) -> Bool {
            let n = entry.words.count
            guard i >= 0, i + n <= words.count else { return false }
            for k in 0..<n {
                if lowered[i + k] != entry.words[k] { return false }
                if k > 0, !SpokenPunctuation.isJoinGap(gaps[i + k]) { return false }
            }
            return true
        }

        /// Length of the mark name (a table phrase or a plain punctuation noun such as
        /// "Punkt", "Komma", "brackets") starting at `k`, or nil.
        func markNameStarting(at k: Int) -> Int? {
            guard k < words.count else { return nil }
            var best: Int? = nil
            for e in entries where phrase(e, at: k) { best = max(best ?? 0, e.words.count) }
            if best == nil, SpokenPunctuationTables.markNouns.contains(lowered[k]) { best = 1 }
            return best
        }

        /// Length of the mark name ending at word `k` (inclusive), or nil.
        func markNameEnding(at k: Int) -> Int? {
            guard k >= 0, k < words.count else { return nil }
            var best: Int? = nil
            for e in entries where phrase(e, at: k - e.words.count + 1) { best = max(best ?? 0, e.words.count) }
            if best == nil, SpokenPunctuationTables.markNouns.contains(lowered[k]) { best = 1 }
            return best
        }

        func isPreposition(_ k: Int) -> Bool {
            SpokenPunctuationTables.prepositions.contains(lowered[k]) || tag(k) == .preposition
        }
        func isDeterminer(_ k: Int) -> Bool {
            SpokenPunctuationTables.determiners.contains(lowered[k]) || tag(k) == .determiner
        }
        func isVerb(_ k: Int) -> Bool { tag(k) == .verb }
        var isGermanTagging: Bool { useTagger && taggingLanguage == .german }
        private lazy var taggingLanguage: NLLanguage? = SpokenPunctuation.taggerLanguage(for: text, languageCode: languageCode)
        func isAdjective(_ k: Int) -> Bool { tag(k) == .adjective }

        private lazy var tags: [Int: NLTag] = computeTags()

        private func tag(_ k: Int) -> NLTag? {
            guard useTagger, k >= 0, k < offsets.count else { return nil }
            return tags[offsets[k]]
        }

        private func computeTags() -> [Int: NLTag] {
            guard let language = taggingLanguage else { return [:] }
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = text
            tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
            var out: [Int: NLTag] = [:]
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                                 options: [.omitWhitespace, .omitPunctuation]) { tag, range in
                if let tag { out[text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)] = tag }
                return true
            }
            return out
        }
    }

    /// German or English for the lexical tagger: the dictation language when it is one of
    /// them, otherwise whichever of the two the text looks like. Nil when the tagger has no
    /// lexical-class model for it on this Mac (then only the word lists decide).
    static func taggerLanguage(for text: String, languageCode: String?) -> NLLanguage? {
        let base = languageCode?.lowercased().prefix(2)
        let language: NLLanguage
        if base == "de" { language = .german }
        else if base == "en" { language = .english }
        else {
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.german, .english]
            recognizer.processString(text)
            language = recognizer.dominantLanguage ?? .english
        }
        return taggerAvailable(language) ? language : nil
    }

    static func taggerAvailable(_ language: NLLanguage) -> Bool {
        NLTagger.availableTagSchemes(for: .word, language: language).contains(.lexicalClass)
    }
}
