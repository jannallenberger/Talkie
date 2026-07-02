import Foundation

/// The honest escape hatch: "spell kilo-8-sierra" inserts "k8s" (A13, Dragon-parity
/// table stakes). For ticket IDs, license keys, and novel proper nouns a recognizer
/// mangles and the `NicheCorrector` can never rescue — a term it has never seen is
/// unfixable by definition (recognition-ceiling memo) — the user dictates the letters
/// and Talkie assembles the exact string, character by character. No mode, no setting:
/// the command IS the feature (a persistent HUD-cycled spelling mode is out of scope).
///
/// Non-mutating — it inserts assembled text at the cursor rather than transforming a
/// selection — so it mirrors `MacroIntent`'s insert-directly shape: `needsSelection`
/// is false and `run` returns a non-preview result. The output is fully deterministic
/// (no LLM), so a preview would only add a tap; the words are already spelled letter by
/// letter, so there is nothing to second-guess.
struct SpellingIntent: CommandIntent {
    let id = "spell"
    let needsSelection = false
    let isMutating = false

    /// The already-assembled string (the router hands over what the pure parser
    /// produced, so the intent stays trivially testable and side-effect free).
    let output: String

    func run(_ ctx: CommandContext) async -> CommandResult? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return CommandResult(replacement: text, preview: false, undoToken: nil)
    }
}

/// Pure parser for the spelling command. Turns "spell tango alpha lima kilo india echo"
/// into "talkie". Deterministic and side-effect free so the full letter/quirk table is
/// unit-testable without the recognizer or any app state.
///
/// **EN-only, v1.** Letter names ("ay/bee/see", the NATO alphabet) are locale-specific;
/// a German or Japanese speaker spells with entirely different words. Localizing this map
/// is a separate package — for now the parser is English, and the Commands tab documents
/// the NATO words as the reliable path (the recognizer mangles bare letter names but nails
/// "alpha/bravo/charlie").
enum SpellingParser {
    /// Trigger words that open a spelling command, longest first so "spell that" is
    /// tried before bare "spell". Kept minimal on purpose: a novel bare word after the
    /// trigger fails the parse and falls through to normal dictation, so prose that
    /// merely starts with the verb "spell" ("spell it out for the team") is never eaten.
    private static let triggers: [[String]] = [["spell", "that"], ["spell"]]

    /// Minimum spellable tokens required after the trigger for the parse to succeed.
    /// Below this we assume "spell" was used as an ordinary verb, not the command —
    /// a single stray "spell a" shouldn't hijack dictation.
    private static let minTokens = 2

    /// Parse a spoken phrase into the assembled string, or nil if it is not a
    /// (well-formed) spelling command. nil deliberately covers three cases the caller
    /// treats identically (fall through to normal dictation): no trigger, too few
    /// spellable tokens, or an unknown token mid-spell — the conservative choice, since
    /// eating prose is worse than making the user re-say a genuine spell command.
    static func parse(_ spoken: String) -> String? {
        let tokens = tokenize(spoken)
        guard let body = stripTrigger(tokens) else { return nil }
        guard body.count >= minTokens else { return nil }

        var out = ""
        var capitalizeNext = false
        var spellableCount = 0

        for token in body {
            if token == "capital" || token == "cap" || token == "uppercase" {
                // Modifies the NEXT letter. The flag persists across any connectors
                // spoken in between ("capital dash tango" still uppercases the T), and
                // is cleared once a letter consumes it — never leaking to a later one.
                capitalizeNext = true
                continue
            }
            guard let piece = piece(for: token) else { return nil }
            // A connector ("dash", "space", …) is structural, not a spellable unit —
            // it can't satisfy the ≥2-token floor on its own, so it doesn't count.
            if piece.isSpellable { spellableCount += 1 }
            if piece.isLetter {
                out += capitalizeNext ? piece.text.uppercased() : piece.text
                capitalizeNext = false
            } else {
                out += piece.text
            }
        }

        guard spellableCount >= minTokens, !out.isEmpty else { return nil }
        return out
    }

    // MARK: Tokenizing

    /// Split into spellable tokens. Two-stage on purpose: first split on WHITESPACE into
    /// words, then split each word on HYPHENS — EXCEPT words that are themselves a known
    /// hyphenated letter-name ("x-ray", "ex-ray"), which stay whole. This is the only way
    /// to serve both "kilo-8-sierra" (hyphen means "join these three spellable parts") and
    /// "x-ray" (the hyphen is INSIDE one letter's spelling) — the recognizer emits both
    /// shapes. Lowercased; punctuation it tacks on ("echo.") is trimmed per token.
    private static func tokenize(_ spoken: String) -> [String] {
        let words = spoken
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'")) }
            .filter { !$0.isEmpty }

        var tokens: [String] = []
        for word in words {
            if compoundLetterMap[word] != nil {
                tokens.append(word)                       // "x-ray" stays one token
            } else {
                // Explode on hyphens (ASCII and the non-breaking U+2011 the recognizer
                // sometimes emits), trimming any punctuation left on a sub-token.
                for sub in word.split(whereSeparator: { $0 == "-" || $0 == "\u{2011}" }) {
                    let t = sub.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'"))
                    if !t.isEmpty { tokens.append(t) }
                }
            }
        }
        return tokens
    }

    /// Drop the leading trigger phrase; nil if the phrase doesn't start with one.
    private static func stripTrigger(_ tokens: [String]) -> [String]? {
        for trigger in triggers where tokens.starts(with: trigger) {
            return Array(tokens.dropFirst(trigger.count))
        }
        return nil
    }

    // MARK: Token → output piece

    private struct Piece {
        let text: String
        let isLetter: Bool
        /// A spellable unit is a letter or a digit — the things the ≥2 floor counts.
        /// Connectors (dash/dot/space/…) are structural and don't count.
        let isSpellable: Bool
    }

    private static func letter(_ s: String) -> Piece { Piece(text: s, isLetter: true, isSpellable: true) }
    private static func digit(_ s: String) -> Piece { Piece(text: s, isLetter: false, isSpellable: true) }
    private static func connector(_ s: String) -> Piece { Piece(text: s, isLetter: false, isSpellable: false) }

    private static func piece(for token: String) -> Piece? {
        if let letter = compoundLetterMap[token] { return Self.letter(letter) }
        if let letter = letterMap[token] { return Self.letter(letter) }
        if let d = digitMap[token] { return digit(d) }
        if let c = connectorMap[token] { return connector(c) }
        // A literal digit the recognizer emitted ("8") passes straight through.
        if token.count == 1, let scalar = token.unicodeScalars.first,
           CharacterSet.decimalDigits.contains(scalar) {
            return digit(token)
        }
        // A bare single letter the recognizer emitted ("k") is honored too — but only a
        // single ASCII letter, so a novel word never silently becomes its first letter.
        if token.count == 1, let scalar = token.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(scalar), scalar.isASCII {
            return Self.letter(token)
        }
        return nil
    }

    // MARK: Tables (EN-only, v1)

    /// Letter names that are themselves HYPHENATED, so the tokenizer must keep them whole
    /// instead of splitting on the interior hyphen. "x-ray" / "ex-ray" is the one the
    /// recognizer emits constantly for the letter X (risks note in the A13 spec calls it
    /// out by name); "double-u" for W is the other. Everything else spells with a single
    /// unhyphenated word.
    private static let compoundLetterMap: [String: String] = [
        "x-ray": "x", "ex-ray": "x", "xray-": "x",
        "double-u": "w", "double-you": "w",
    ]

    /// NATO alphabet + plain letter names + the recognizer's homophone spellings for
    /// bare letters. The recognizer rarely returns a clean single "b" — it returns
    /// "be"/"bee"/"bea", "c" comes back "see"/"sea", "x" as "ex"/"eks", "y" as "why".
    /// Those homophones are the reason the bare-letter path is unreliable and the NATO
    /// words are the documented one; we map both so either works.
    private static let letterMap: [String: String] = [
        // NATO phonetic alphabet — the reliable path.
        "alpha": "a", "alfa": "a", "bravo": "b", "charlie": "c", "delta": "d",
        "echo": "e", "foxtrot": "f", "golf": "g", "hotel": "h", "india": "i",
        "juliet": "j", "juliett": "j", "kilo": "k", "lima": "l", "mike": "m",
        "november": "n", "oscar": "o", "papa": "p", "quebec": "q", "romeo": "r",
        "sierra": "s", "tango": "t", "uniform": "u", "victor": "v", "whiskey": "w",
        "whisky": "w", "xray": "x", "yankee": "y", "zulu": "z",

        // Plain letter names as the recognizer tends to spell them (homophones incl.).
        "ay": "a", "aye": "a", "eh": "a",
        "be": "b", "bee": "b", "bea": "b",
        "cee": "c", "see": "c", "sea": "c",
        "dee": "d",
        "ee": "e",
        "ef": "f", "eff": "f",
        "gee": "g",
        "aitch": "h", "haitch": "h",
        // "eye"/"i" → i (bare "i" also caught by the single-letter fallback).
        "eye": "i",
        "jay": "j",
        "kay": "k",
        "el": "l", "ell": "l",
        "em": "m",
        "en": "n",
        "oh": "o", "ohh": "o",
        "pee": "p", "pea": "p",
        "cue": "q", "queue": "q",
        "ar": "r", "are": "r",
        "es": "s", "ess": "s",
        "tee": "t", "tea": "t",
        "you": "u", "yew": "u", "ewe": "u",
        "vee": "v",
        "doubleu": "w",   // hyphenated "double-u" is handled by compoundLetterMap
        "ex": "x", "eks": "x",
        "why": "y", "wy": "y",
        "zee": "z", "zed": "z",
    ]

    /// Spoken digit names. Literal digits the recognizer emits ("8") pass through the
    /// single-character fallback in `piece(for:)`, so only the words live here.
    private static let digitMap: [String: String] = [
        // "oh" is deliberately absent: it resolves to the letter O in letterMap (which
        // wins), because O is far more common in spelled strings than a zero said "oh".
        // Say "zero" for the digit.
        "zero": "0",
        "one": "1", "won": "1",
        "two": "2", "to": "2", "too": "2",
        "three": "3",
        "four": "4", "for": "4", "fore": "4",
        "five": "5",
        "six": "6",
        "seven": "7",
        "eight": "8", "ate": "8",
        "nine": "9",
    ]

    /// Connectors: structural glue between spellable units. Default output is
    /// contiguous (no separators) — a term like "k8s" has none — so a separator only
    /// appears when explicitly spoken.
    private static let connectorMap: [String: String] = [
        "dash": "-", "hyphen": "-", "minus": "-",
        "dot": ".", "point": ".", "period": ".",
        "underscore": "_", "under": "_",
        "slash": "/", "stroke": "/",
        "at": "@",
        "space": " ",
    ]
}
