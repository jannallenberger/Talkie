import Foundation

/// Deterministic inverse text normalization (ITN) for *spoken numbers* in a
/// finalized dictation — the step that turns "Seedance two point zero" into
/// "Seedance 2.0".
///
/// Runs after cleanup, in EVERY mode (cleanup on or off, model available or not),
/// because the on-device cleanup model is unreliable here, is skipped entirely in
/// Faithful / None mode, and is bypassed on any guardrail fallback to the raw
/// transcript — and a version string is exactly where you never want "two point
/// zero" spelled out. It's a sibling of `SpokenFileMatcher` ("library dot tsx" →
/// ".tsx"): a deterministic spoken-form fixer in the same post-cleanup chain.
///
/// Two conversions, by design:
///   1. **Decimal / version patterns** — a number, a spoken separator, then more
///      numbers: "two point zero" → "2.0", "3 dot 12" → "3.12". Chains for
///      semver and IPs: "two point zero point one" → "2.0.1". ALWAYS converted,
///      regardless of magnitude, because the digits ARE the point of saying it.
///   2. **Standalone cardinals** — a run of number words on its own: converted to
///      digits ONLY when the value is greater than nine ("fifteen" → "15",
///      "twenty four" → "24"), so small numbers stay spelled out the way prose
///      style guides — and the user — want ("five" stays "five"). The >9 gate is
///      also what keeps the German indefinite article safe: "ein"/"eine" = 1 ≤ 9,
///      so a standalone "ein Hund" is never mangled into "1 Hund".
///
/// The separator mirrors what was spoken: "point"/"dot"/"Punkt" → "." and
/// "comma"/"Komma" → "," — so a German speaker gets "2,5" for a decimal but
/// "2.0" for a version, just by saying "Komma" vs "Punkt".
///
/// Languages: English + German number words (and bare digits). Multi-word runs
/// are only joined across plain spaces/hyphens, never across sentence
/// punctuation, so "I have twenty. Four left" is not fused into "24". Unknown
/// words are never touched, so the pass is safe to run on any text.
enum NumberNormalizer {

    // MARK: Lexicons

    private static let englishUnits: [String: Int] = [
        "zero": 0, "oh": 0, "nought": 0,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let englishTeens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let englishTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let englishScales: [String: Int] = [
        "hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    private static let english: [String: Int] = {
        var m = englishUnits
        m.merge(englishTeens) { a, _ in a }
        m.merge(englishTens) { a, _ in a }
        m.merge(englishScales) { a, _ in a }
        return m
    }()

    /// German number words 0–19, the round tens, and the scale words. Compounds
    /// (21–99, hundreds, thousands) are single words in German and are decomposed
    /// by `parseGerman`. Includes ASCII fallbacks (fuenf, zwoelf, dreissig) in
    /// case the recognizer drops the umlaut/ß.
    private static let germanLex: [String: Int] = [
        "null": 0, "ein": 1, "eins": 1, "eine": 1, "einen": 1, "zwei": 2, "drei": 3,
        "vier": 4, "fünf": 5, "fuenf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
        "zehn": 10, "elf": 11, "zwölf": 12, "zwoelf": 12, "dreizehn": 13, "vierzehn": 14,
        "fünfzehn": 15, "fuenfzehn": 15, "sechzehn": 16, "siebzehn": 17, "achtzehn": 18,
        "neunzehn": 19, "zwanzig": 20, "dreißig": 30, "dreissig": 30, "vierzig": 40,
        "fünfzig": 50, "fuenfzig": 50, "sechzig": 60, "siebzig": 70, "achtzig": 80,
        "neunzig": 90, "hundert": 100, "tausend": 1000,
    ]
    private static let germanOnes: [String: Int] = [
        "ein": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "fuenf": 5,
        "sechs": 6, "sieben": 7, "acht": 8, "neun": 9,
    ]
    private static let germanTens: [String: Int] = [
        "zwanzig": 20, "dreißig": 30, "dreissig": 30, "vierzig": 40, "fünfzig": 50,
        "fuenfzig": 50, "sechzig": 60, "siebzig": 70, "achtzig": 80, "neunzig": 90,
    ]

    /// Spoken decimal/version separators → the character they emit. "point",
    /// "dot", "Punkt" are dots; "comma"/"Komma" is a comma (German decimals).
    private static func separatorChar(_ word: String) -> String? {
        switch word.lowercased() {
        case "point", "dot", "punkt": return "."
        case "comma", "komma": return ","
        default: return nil
        }
    }

    // MARK: Per-token value

    /// The integer value of a single token if it is a number word (English or
    /// German) or a bare digit string, else nil. Digits are tried first, then the
    /// English lexicon, then German decomposition — so an English word like
    /// "hundred" resolves via the lexicon before German's `und`-splitter ever sees
    /// it.
    private static func value(of token: String) -> Int? {
        let w = token.lowercased()
        if let n = Int(w) { return n }
        if let v = english[w] { return v }
        return parseGerman(w)
    }

    /// True when a token is a single decimal digit 0–9 (as a digit or a units
    /// word). Used to decide whether a fractional run concatenates digit-by-digit
    /// ("seven five" → "75", preserving leading zeros) rather than reading as a
    /// cardinal.
    private static func isUnitDigit(_ token: String) -> Bool {
        // A value of 0–9 already means the token is a single digit (a digit char or
        // a units word); a multi-digit token like "75" has value 75 and is excluded.
        if let v = value(of: token) { return v >= 0 && v <= 9 }
        return false
    }

    /// Decompose a German number word into its value (e.g. "vierundzwanzig" → 24,
    /// "zweihundert" → 200, "neunzehnhundertfünfundachtzig" → 1985). Conservative:
    /// returns nil unless every sub-part is itself a valid German number, so
    /// ordinary words that merely contain "und" ("Hund", "fund", "around") are
    /// left untouched.
    private static func parseGerman(_ word: String) -> Int? {
        if let v = germanLex[word] { return v }
        if let v = germanScaleSplit(word, "tausend", 1000) { return v }
        if let v = germanScaleSplit(word, "hundert", 100) { return v }
        // ones + "und" + tens  →  einundzwanzig = 1 + 20 = 21
        if let r = word.range(of: "und") {
            let a = String(word[..<r.lowerBound])
            let b = String(word[r.upperBound...])
            if let av = germanOnes[a], let bv = germanTens[b] { return av + bv }
        }
        return nil
    }

    private static func germanScaleSplit(_ word: String, _ key: String, _ mult: Int) -> Int? {
        guard let r = word.range(of: key) else { return nil }
        let left = String(word[..<r.lowerBound])
        let right = String(word[r.upperBound...])
        let l = left.isEmpty ? 1 : parseGerman(left)
        guard let lv = l else { return nil }
        let rv = right.isEmpty ? 0 : parseGerman(right)
        guard let rvv = rv else { return nil }
        return lv * mult + rvv
    }

    /// Combine a sequence of cardinal token values into one number using the
    /// standard place-value algorithm ("one hundred twenty three" → 123).
    private static func combine(_ values: [Int]) -> Int {
        var total = 0, current = 0
        for v in values {
            if v >= 1000 {
                total += (current == 0 ? 1 : current) * v
                current = 0
            } else if v == 100 {
                current = (current == 0 ? 1 : current) * 100
            } else {
                current += v
            }
        }
        return total + current
    }

    // MARK: Normalize

    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let (gaps, words) = tokenize(text)
        guard !words.isEmpty else { return text }

        // A gap is "joinable" (part of the same number run) only when it's blank
        // space or a hyphen — never sentence punctuation, so runs don't cross a
        // period or newline.
        func joinable(_ i: Int) -> Bool {
            guard i >= 1, i < gaps.count else { return false }
            return gaps[i].allSatisfy { $0 == " " || $0 == "\t" || $0 == "-" }
        }

        /// Greedily parse a cardinal run starting at word `start`, crossing only
        /// joinable gaps. Returns the value and how many words it consumed.
        func parseCardinal(_ start: Int) -> (value: Int, consumed: Int)? {
            guard start < words.count, let first = value(of: words[start]) else { return nil }
            var vals = [first]
            var i = start + 1
            while i < words.count, joinable(i), let v = value(of: words[i]) {
                vals.append(v)
                i += 1
            }
            return (combine(vals), i - start)
        }

        /// Parse one fractional group (the digits after a separator). A run of
        /// bare digits concatenates ("seven five" → "75", "zero five" → "05");
        /// anything else reads as a cardinal ("twelve" → "12", "ninety nine" → "99").
        func parseFraction(_ start: Int) -> (digits: String, consumed: Int)? {
            guard start < words.count, value(of: words[start]) != nil else { return nil }
            var toks = [words[start]]
            var i = start + 1
            while i < words.count, joinable(i), value(of: words[i]) != nil {
                toks.append(words[i])
                i += 1
            }
            let consumed = i - start
            if toks.allSatisfy(isUnitDigit) {
                return (toks.map { String(value(of: $0)!) }.joined(), consumed)
            }
            return (String(combine(toks.map { value(of: $0)! })), consumed)
        }

        /// Decimal / version pattern: a cardinal, a spoken separator, a fractional
        /// group — chaining further "[separator][group]" pairs for semver and IPs.
        func matchDecimal(_ start: Int) -> (text: String, consumed: Int)? {
            guard let (intVal, intC) = parseCardinal(start) else { return nil }
            var idx = start + intC
            // The first separator must be present and immediately followed by a number.
            guard idx < words.count, joinable(idx), separatorChar(words[idx]) != nil,
                  idx + 1 < words.count, joinable(idx + 1), value(of: words[idx + 1]) != nil
            else { return nil }

            var out = String(intVal)
            var groups = 0
            while idx < words.count, joinable(idx), let sep = separatorChar(words[idx]),
                  let (frac, fc) = parseFraction(idx + 1), joinable(idx + 1) {
                out += sep + frac
                idx += 1 + fc
                groups += 1
            }
            guard groups > 0 else { return nil }
            return (out, idx - start)
        }

        /// English spoken year with the century elided: "nineteen eighty five" →
        /// "1985", "twenty twenty four" → "2024". The high group is a single token
        /// 10–99; the low group must *lead* with a tens/teen/zero word, so plain
        /// "twenty four" (tens + unit) stays a cardinal 24 rather than 2004.
        func matchYear(_ start: Int) -> (text: String, consumed: Int)? {
            guard start < words.count, let hi = value(of: words[start]), hi >= 10, hi <= 99
            else { return nil }
            let loStart = start + 1
            guard loStart < words.count, joinable(loStart) else { return nil }
            let lead = words[loStart].lowercased()
            guard englishTens[lead] != nil || englishTeens[lead] != nil || lead == "oh" || lead == "zero"
            else { return nil }
            guard let (lo, loC) = parseCardinal(loStart), lo >= 0, lo <= 99 else { return nil }
            return (String(hi * 100 + lo), 1 + loC)
        }

        /// Standalone cardinal, converted only when > 9 and the run is a
        /// recognizable shape (single token, a scale phrase, or tens+unit) — so a
        /// stray "five six" is never fused into "11".
        func matchCardinal(_ start: Int) -> (text: String, consumed: Int)? {
            guard let (val, c) = parseCardinal(start), val > 9 else { return nil }
            let toks = (start..<start + c).map { words[$0].lowercased() }
            let hasScale = toks.contains { englishScales[$0] != nil }
                || toks.contains { ["hundert", "tausend"].contains($0) || parseGerman($0).map { $0 >= 100 } == true }
            let tensUnit = c == 2 && englishTens[toks[0]] != nil && englishUnits[toks[1]] != nil
            guard c == 1 || hasScale || tensUnit else { return nil }
            return (String(val), c)
        }

        // Walk the words left to right, preferring decimal > year > cardinal, and
        // rebuild the string preserving the original (non-joined) spacing.
        var result = gaps[0]
        var i = 0
        while i < words.count {
            if let m = matchDecimal(i) ?? matchYear(i) ?? matchCardinal(i) {
                result += m.text
                i += m.consumed
            } else {
                result += words[i]
                i += 1
            }
            result += gaps[i]
        }
        return result
    }

    // MARK: Tokenize

    /// Split into alternating gaps and words. `gaps` has one more element than
    /// `words`: gaps[k] is the text *before* words[k], and the final gap is the
    /// trailing text. Reconstructing `gaps[0] + words[0] + gaps[1] + …` reproduces
    /// the input exactly; collapsing the interior gaps of a consumed run joins its
    /// words ("two point zero" → "2.0").
    private static func tokenize(_ s: String) -> (gaps: [String], words: [String]) {
        var gaps: [String] = [""]
        var words: [String] = []
        var buf = ""
        var bufIsWord: Bool? = nil

        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "'" || c == "’"
        }
        func flush() {
            guard let isWord = bufIsWord, !buf.isEmpty else { return }
            if isWord {
                words.append(buf)
                gaps.append("")
            } else {
                gaps[gaps.count - 1] += buf
            }
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
