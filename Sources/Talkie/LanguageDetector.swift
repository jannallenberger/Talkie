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

    /// The margin once a close head probe has been rescored over the WHOLE utterance.
    /// Averaged over a long dictation, a small lead is real: English speech in a
    /// German session scored de 0.84 / en 0.91 over ~400 words — a clear English win
    /// the 0.08 short-probe margin threw away, inserting German-model gibberish. The
    /// wrong model on foreign speech sits well below (English speech: en leads by
    /// 0.07–0.31; German speech: en only 0.05–0.38 absolute), so 0.03 is still safe.
    static let wholeRescoreMargin = 0.03

    /// Absolute acoustic-confidence floor a candidate must clear before it can win
    /// the language switch when there's *no* score for the current language to
    /// compare against (the current-locale re-transcribe came back empty, so its
    /// baseline confidence is 0). Without this, the margin-only test degrades to
    /// `best.confidence >= switchConfidenceMargin` — a near-zero bar that lets a
    /// garbage `best` flip the language. Requiring genuine acoustic confidence here
    /// keeps the switch honest when there's no incumbent to beat.
    static let switchAbsoluteFloor = 0.50

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

    /// One re-transcription candidate from the stop-time acoustic language-detect:
    /// a locale id, its committed text, and the model's mean per-word confidence.
    struct LanguageCandidate {
        let localeID: String
        let text: String
        let confidence: Double
    }

    /// Decide, by acoustic confidence, which language a finished dictation was
    /// *actually* spoken in — or `nil` to keep the current language. This is the
    /// pure core of the stop-time switch so it can be reasoned about and tested
    /// without the recognizer.
    ///
    /// - `scored`: every spoken language re-transcribed against the same audio,
    ///   including (normally) the current one as the comparison baseline.
    /// - `currentCode`: the language code the live session ran in.
    ///
    /// A switch fires only when the winning candidate is a *different* language,
    /// has non-empty text, and clears the bar:
    /// - When the current language is present in `scored`, beat it by
    ///   `switchConfidenceMargin`.
    /// - When it is **not** present (its re-transcribe came back empty, so the
    ///   baseline is 0), don't switch off the margin alone — that's a near-zero bar
    ///   that a garbage `best` clears trivially. Require `best` to clear
    ///   `switchAbsoluteFloor` instead, so an empty current-locale result keeps the
    ///   current language rather than flipping to noise.
    static func switchTarget(
        among scored: [LanguageCandidate],
        currentCode: String?,
        margin: Double = switchConfidenceMargin
    ) -> LanguageCandidate? {
        guard let best = scored.max(by: { $0.confidence < $1.confidence }) else { return nil }
        guard languageCode(of: best.localeID) != currentCode, !best.text.isEmpty else { return nil }

        let currentEntry = scored.first { languageCode(of: $0.localeID) == currentCode }
        if let currentEntry {
            // Incumbent present: beat it by the relative margin.
            return best.confidence >= currentEntry.confidence + margin ? best : nil
        }
        // No incumbent to compare against — demand absolute confidence instead of
        // letting the margin-vs-zero test wave anything through.
        return best.confidence >= switchAbsoluteFloor ? best : nil
    }

    /// Whether a head-only language probe was too close to call — no switch, but a
    /// rival language scored within `switchConfidenceMargin` of the incumbent. The
    /// caller then rescores the WHOLE utterance before deciding, rather than letting
    /// the tie default to the current language.
    ///
    /// Why: a few seconds of speech usually separate the languages, but not always.
    /// The wrong model can fit an opening phrase as well as the right one (English
    /// speech scored de 0.87 / en 0.87 on a 12 s probe), and a tie keeps the
    /// incumbent — so a 2½-minute English dictation was inserted as German-model
    /// gibberish. Clear wins either way stay on the fast path.
    static func probeIsInconclusive(
        among scored: [LanguageCandidate],
        currentCode: String?
    ) -> Bool {
        guard switchTarget(among: scored, currentCode: currentCode) == nil,
              let current = scored.first(where: { languageCode(of: $0.localeID) == currentCode })
        else { return false }
        return scored.contains {
            languageCode(of: $0.localeID) != currentCode && !$0.text.isEmpty
                && abs($0.confidence - current.confidence) < switchConfidenceMargin
        }
    }

    /// Seconds of captured audio at which the mid-dictation probe checks the
    /// language. The first check is early so the pill stops showing the wrong
    /// model's gibberish quickly; the second runs only when the first was too
    /// close to call (see `probeIsInconclusive`).
    static let liveProbeCheckpoints: [Double] = [6, 12]

    /// Whether the mid-dictation probe should restart the live session in another
    /// language. Stricter than the stop-time `switchTarget`: a live restart is
    /// visible (the preview resets and refills), so on top of beating the incumbent
    /// by the margin, the winner must clear `switchAbsoluteFloor` on its own —
    /// two weak scores a margin apart are noise, not a language.
    static func liveSwitchTarget(
        among scored: [LanguageCandidate],
        currentCode: String?
    ) -> LanguageCandidate? {
        guard let best = switchTarget(among: scored, currentCode: currentCode),
              best.confidence >= switchAbsoluteFloor else { return nil }
        return best
    }
}
