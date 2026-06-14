// Pre-WER text normalization, applied identically to reference and hypothesis.
//
// The point: don't penalize formatting differences (case, punctuation,
// contractions, spelled-out vs digit numbers) as if they were mistranscriptions.
// This is a pragmatic Swift port of the spirit of OpenAI's `EnglishTextNormalizer`
// (the field-standard normalizer used to report Whisper/LibriSpeech WER) — it is
// NOT a byte-for-byte clone (that lives in Python `whisper-normalizer`), and the
// docs say so. For an external apples-to-apples comparison against published
// numbers, re-score the raw `--json` output with that Python normalizer; for
// Talkie-vs-itself and the on-device headline, this is consistent and sufficient.
//
// Both sides go through the SAME function, so any residual normalization quirk
// affects both equally and cannot bias the comparison.

import Foundation

enum TextNormalizer {
    /// Normalize and split into word tokens for WER.
    static func normalizeToWords(_ text: String) -> [String] {
        normalize(text).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Normalize and return the character stream for CER (spaces preserved as
    /// single separators; the array is the sequence of Characters).
    static func normalizeToCharacters(_ text: String) -> [Character] {
        Array(normalize(text))
    }

    /// The shared normalization pass: lowercase, expand common contractions,
    /// canonicalize small spelled-out numbers to digits, strip punctuation,
    /// collapse whitespace.
    static func normalize(_ text: String) -> String {
        var s = text.lowercased()

        // Normalize a few unicode oddities to ASCII so the steps below catch them.
        s = s.replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: "‘", with: "'")
        s = s.replacingOccurrences(of: "“", with: "\"")
        s = s.replacingOccurrences(of: "”", with: "\"")
        s = s.replacingOccurrences(of: "—", with: " ")
        s = s.replacingOccurrences(of: "–", with: " ")

        // Expand contractions BEFORE punctuation is stripped (they contain ').
        for (contraction, expansion) in Self.contractions {
            s = s.replacingOccurrences(of: contraction, with: expansion)
        }

        // Strip every character that isn't a lowercase letter, digit, or space.
        // (Apostrophes in any surviving possessives become nothing, e.g.
        // "dogs'" → "dogs", which matches on both sides.)
        var stripped = String.UnicodeScalarView()
        stripped.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                stripped.append(scalar)
            } else {
                stripped.append(" ")
            }
        }
        s = String(stripped)

        // Map small spelled-out numbers to digits (token-wise) so "twenty" and
        // "20" score equal. Kept deliberately simple: standalone number words.
        let tokens = s.split(separator: " ", omittingEmptySubsequences: true).map { token -> String in
            Self.numberWords[String(token)] ?? String(token)
        }

        return tokens.joined(separator: " ")
    }

    /// Common English contractions → their expanded forms. Applied lowercase,
    /// pre-punctuation-strip. Mirrors the most frequent entries in the standard
    /// Whisper normalizer's contraction map (not exhaustive by design).
    static let contractions: [(String, String)] = [
        ("won't", "will not"),
        ("can't", "can not"),
        ("shan't", "shall not"),
        ("ain't", "am not"),
        ("n't", " not"),         // generic: don't/isn't/wasn't/couldn't/...
        ("'ll", " will"),
        ("'ve", " have"),
        ("'re", " are"),
        ("'m", " am"),
        ("let's", "let us"),
        ("'d", " would"),        // approximate (would/had); standard normalizer's choice
        ("'s", " s"),            // possessive/“is”; rendered as a separate token on both sides
    ]

    /// Standalone number words → digits, for 0–20 plus common round numbers.
    /// LibriSpeech references spell numbers out; recognizers may emit digits.
    static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
        "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60",
        "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000", "million": "1000000",
    ]
}
