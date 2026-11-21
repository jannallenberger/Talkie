import Foundation

/// The pill's instant read of a command span, from the live transcript alone (the
/// recognizer has no word timings for still-volatile words). It compares the live
/// text at key-down with the text shortly after release; the new words are the
/// command (plus maybe a word said right after letting go, which the matcher's
/// word-run search tolerates). This is only the preview: the pasted text is decided
/// at the end from real word timings (`FormatTimeline`).
enum FormatLivePreview {

    /// Words in `after` beyond the longest common word prefix with `before`
    /// (compared case- and punctuation-insensitively, since the recognizer re-punctuates).
    static func addedWords(before: String, after: String) -> String {
        let b = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let a = after.split(whereSeparator: \.isWhitespace).map(String.init)
        func key(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        var i = 0
        while i < a.count, i < b.count, key(a[i]) == key(b[i]) { i += 1 }
        return a[i...].joined(separator: " ")
    }

    /// What the pill should show for the words heard in a span.
    static func resolve(_ spoken: String, alternatives: [String] = [],
                        book: FormatPhraseBook = .current) -> FormatSpanResolution {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let others = alternatives.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !trimmed.isEmpty || !others.isEmpty else { return .ended }
        let command = others.isEmpty
            ? FormatPhraseMatcher.match(trimmed, book: book)
            : FormatPhraseMatcher.bestAcross([trimmed] + others, book: book)
        return resolution(command, heard: trimmed.isEmpty ? (others.first ?? "") : trimmed)
    }

    static func resolution(_ command: FormatCommand?, heard: String) -> FormatSpanResolution {
        switch command {
        case .apply(let preset)?: return .applied(preset)
        case .user(let c)?: return c.isInsertion ? .inserted(c) : .appliedUser(c)
        case .end?: return .ended
        case nil: return .notRecognised(heard)
        }
    }
}
