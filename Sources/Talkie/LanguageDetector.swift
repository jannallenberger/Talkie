import Foundation
import NaturalLanguage

/// Detects which of the user's spoken languages a transcript is in, so Talkie
/// can re-transcribe it in the right language if the first pass used the wrong one.
enum LanguageDetector {
    /// Returns the best-matching locale identifier from `candidates` for `text`,
    /// or nil if detection isn't confident enough to act on.
    static func detect(_ text: String, among candidates: [String], minConfidence: Double = 0.62) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short text is unreliable to language-ID; don't switch on a word or two.
        guard trimmed.split(whereSeparator: { $0.isWhitespace }).count >= 3 else { return nil }
        guard candidates.count > 1 else { return nil }

        let recognizer = NLLanguageRecognizer()
        // Constrain to the languages the user actually speaks → far more reliable.
        let constraints = candidates.compactMap { languageCode(of: $0) }.map { NLLanguage($0) }
        if !constraints.isEmpty {
            recognizer.languageConstraints = Array(Set(constraints))
        }
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let (best, confidence) = hypotheses.max(by: { $0.value < $1.value }),
              confidence >= minConfidence else { return nil }

        // Map the detected language back to one of the candidate locale identifiers.
        return candidates.first { languageCode(of: $0) == best.rawValue }
    }

    private static func languageCode(of localeIdentifier: String) -> String? {
        Locale(identifier: localeIdentifier).language.languageCode?.identifier
    }
}
