import Foundation
import NaturalLanguage

/// Scores how strongly a transcript reads as a given one of the user's spoken
/// languages, so Talkie can decide — by AUDIO self-consistency — whether a
/// dictation was actually spoken in a different language than the one it was
/// first transcribed in (and should be re-transcribed in that language).
///
/// Why self-consistency and not "language-ID the transcript": the live session
/// runs in a single locale (Apple's recognizer is one language per session).
/// Speech in a *secondary* language decoded by the *primary* acoustic model comes
/// out as phonetic gibberish — and language-ID of that gibberish is unreliable
/// (it frequently scores as the primary language, or below any fixed threshold),
/// so a "switch if it looks like another language" trigger silently never fires.
/// Instead we re-transcribe the captured audio in each candidate language and
/// keep whichever output most strongly self-identifies as *its own* language:
/// coherent correct-language text scores high; wrong-language gibberish does not.
enum LanguageDetector {
    /// A transcript whose self-consistency with its current language is at or
    /// above this is taken as correct — the fast path skips all re-transcription.
    static let confidentMatch = 0.85
    /// Switch to a candidate language only if it beats the incumbent's
    /// self-consistency by at least this margin …
    static let switchMargin = 0.15
    /// … and is itself at least this confident, so a marginally-better but weak
    /// candidate can't win on noise.
    static let switchFloor = 0.50

    /// A candidate language must beat the current language's mean recognition
    /// confidence by at least this to win. Acoustic confidence separates the right
    /// model (fits the audio, high) from the wrong model decoding foreign speech
    /// (low), so a modest margin avoids flips on near-ties.
    static let switchConfidenceMargin = 0.08

    /// The given locale ids with at most one per language code, order preserved
    /// (en-US, en-GB, de-DE → en-US, de-DE). The recognizer can't tell same-code
    /// locales apart, so transcribing both is pure waste.
    static func distinctByCode(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids where seen.insert(languageCode(of: id) ?? id).inserted {
            out.append(id)
        }
        return out
    }

    /// Fewer whitespace-separated tokens than this is too short to language-ID
    /// (a word or two is noise). Callers use `canScore` to keep the current
    /// language for such utterances rather than burning a re-transcription that
    /// could never produce a confident answer.
    static let minimumScorableTokens = 3

    /// Whether `text` has enough words to language-ID at all. Lets callers skip
    /// the expensive re-transcription path for short commands ("yes", "undo
    /// that") instead of treating them as a failed language match.
    static func canScore(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace }).count >= minimumScorableTokens
    }

    /// The language code of a locale id (e.g. "de-DE" → "de"), or nil. Exposed so
    /// the dictation and meeting paths dedupe switch candidates by language the
    /// same way (en-US and en-GB are the same language to the recognizer).
    static func languageCode(of localeIdentifier: String) -> String? {
        Locale(identifier: localeIdentifier).language.languageCode?.identifier
    }

    /// The dominant natural language of `text` as a base code ("de", "en"), or nil
    /// when the text is too short to call reliably. Used to (a) name the language
    /// for the on-device cleanup model and (b) catch a rewrite that flipped
    /// languages (the model translating non-English dictation into English).
    static func dominantLanguageCode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canScore(trimmed) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        return recognizer.dominantLanguage?.rawValue
    }

    /// The English display name of a language code ("de" → "German"), used to name
    /// the target language to the on-device cleanup model.
    static func displayName(forLanguageCode code: String) -> String? {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code)
    }

    /// The confidence (0…1) the constrained recognizer assigns to `expected`'s
    /// language for `text`. Returns 0 when the text is too short to language-ID
    /// reliably (a word or two), when `expected` has no language code, or when it
    /// isn't among the recognized hypotheses. `candidates` constrains the
    /// recognizer to the languages the user actually speaks, which makes the score
    /// far more reliable than open-set detection.
    static func selfConsistency(_ text: String, expected: String, among candidates: [String]) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canScore(trimmed) else { return 0 }
        guard let expectedCode = languageCode(of: expected) else { return 0 }

        let recognizer = NLLanguageRecognizer()
        let constraints = candidates.compactMap { languageCode(of: $0) }.map { NLLanguage($0) }
        if !constraints.isEmpty {
            recognizer.languageConstraints = Array(Set(constraints))
        }
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: max(constraints.count, 3))
        return hypotheses[NLLanguage(expectedCode)] ?? 0
    }
}
