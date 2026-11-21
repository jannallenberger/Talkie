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

    // MARK: The live text in the pill

    /// One resolved command, placed in the live text by word position.
    struct Placed: Equatable, Sendable {
        enum Effect: Equatable, Sendable {
            /// The words after it are shown in this format.
            case format(FormatStyle)
            /// Back to normal text.
            case end
            /// A fixed text takes the place of the command's words; the format stays.
            case insert(String)
        }
        /// How many words of the live text come before the command's own words.
        var start: Int
        /// The first word after the command's own words (they are never shown).
        var end: Int
        var effect: Effect
    }

    /// How many leading words `before` and `after` share (compared like `addedWords`).
    static func sharedWordCount(before: String, after: String) -> Int {
        let b = before.split(whereSeparator: \.isWhitespace), a = after.split(whereSeparator: \.isWhitespace)
        func key(_ s: Substring) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var i = 0
        while i < a.count, i < b.count, key(a[i]) == key(b[i]) { i += 1 }
        return i
    }

    /// Which of the words in `heard` are the command itself: up to the first point
    /// where the command can be read, and back from there as far as the words are
    /// exactly one of its phrases ("all caps", not just "caps"). Words before it were
    /// said before the key (the recogniser shows them a moment late) and words after
    /// it are content: both stay in the text. All of `heard` when the phrase cannot
    /// be located (it was recognised in another language's reading).
    static func commandWordRange(in heard: String, command: FormatCommand?,
                                 book: FormatPhraseBook = .current) -> Range<Int> {
        let words = heard.split(whereSeparator: \.isWhitespace)
        guard let command, words.count > 1 else { return 0..<words.count }
        func text(_ range: Range<Int>) -> String { words[range].joined(separator: " ") }
        guard let end = (1...words.count).first(where: {
            FormatPhraseMatcher.match(text(0..<$0), book: book) == command
        }) else { return 0..<words.count }
        let start = (0..<end).first(where: {
            FormatPhraseMatcher.matchWhole(text($0..<end), book: book) == command
        }) ?? 0
        // "bullet" already reads as the list; "bullet list" is still the phrase.
        // (Only a word the phrase really uses: a filler the matcher skips, like
        // "please", is content said after the command.)
        var last = end
        while last < words.count,
              !FormatPhraseMatcher.normalizedTokens(String(words[last])).isEmpty,
              FormatPhraseMatcher.matchWhole(text(start..<(last + 1)), book: book) == command {
            last += 1
        }
        return start..<last
    }

    /// Where a command that resolved to `resolution` sits, given the live text at the
    /// first press (`before`) and now (`now`). Nil when nothing changes in the text
    /// (words that are no format stay as they are).
    static func placed(_ resolution: FormatSpanResolution, saidAnything: Bool, before: String, now: String,
                       book: FormatPhraseBook = .current, date: Date = Date()) -> Placed? {
        let start = sharedWordCount(before: before, after: now)
        guard saidAnything else {
            // Two presses with nothing said: the active format ends there.
            return Placed(start: start, end: start, effect: .end)
        }
        let heard = addedWords(before: before, after: now)
        let command: FormatCommand?
        let effect: Placed.Effect
        switch resolution {
        case .applied(let preset):
            command = .apply(preset)
            effect = .format(.preset(preset))
        case .appliedUser(let user):
            command = .user(user)
            effect = .format(.user(user))
        case .inserted(let user):
            command = .user(user)
            effect = .insert(UserCommandRenderer.render(user.action, text: "", languageCode: nil, now: date)?.text ?? "")
        case .ended:
            command = .end
            effect = .end
        case .notRecognised:
            return nil
        }
        let own = commandWordRange(in: heard, command: command, book: book)
        return Placed(start: start + own.lowerBound, end: start + own.upperBound, effect: effect)
    }

    /// Whether the pill can show this format as you speak. The rest is written by
    /// the on-device model when you stop, so the pill shows those words as heard.
    static func showsLive(_ style: FormatStyle) -> Bool {
        switch style {
        case .preset(let preset): return !preset.usesModel
        case .user(let command): return !command.usesModel
        }
    }

    /// The live text as the pill shows it: every region in its format, the commands'
    /// own words left out. Uses the paste path's renderers; what it cannot know yet
    /// (pause-separated list items, the model's rewriting) follows at the paste.
    static func displayed(_ text: String, commands: [Placed], languageCode: String?) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var pieces: [FormatRenderer.Piece] = []
        var style: FormatStyle?
        var cursor = 0
        func region(upTo end: Int) {
            guard end > cursor else { return }
            let body = words[cursor..<end].joined(separator: " ")
            pieces.append(style.map { piece($0, text: body, languageCode: languageCode) }
                          ?? FormatRenderer.Piece(text: body, isBlock: false))
        }
        for command in commands.sorted(by: { $0.start < $1.start }) {
            // A command beyond the text (the recogniser took words back) waits.
            guard command.start <= words.count, command.start >= cursor else { continue }
            region(upTo: command.start)
            cursor = min(max(command.end, command.start), words.count)
            switch command.effect {
            case .format(let next): style = next
            case .end: style = nil
            case .insert(let fixed): pieces.append(FormatRenderer.Piece(text: fixed, isBlock: false))
            }
        }
        region(upTo: words.count)
        return FormatAssembly.join(pieces)
    }

    /// The firm (committed) part and the still-changing rest of the displayed text:
    /// the firm part is what the committed words alone already produce.
    static func displayed(finalized: String, volatile: String, commands: [Placed],
                          languageCode: String?) -> (firm: String, rest: String) {
        let joiner = finalized.isEmpty || volatile.isEmpty ? "" : " "
        let all = displayed(finalized + joiner + volatile, commands: commands, languageCode: languageCode)
        guard !volatile.isEmpty else { return (all, "") }
        let firmOnly = displayed(finalized, commands: commands, languageCode: languageCode)
        let shared = all.commonPrefix(with: firmOnly)
        return (shared, String(all.dropFirst(shared.count)))
    }

    private static func piece(_ style: FormatStyle, text: String, languageCode: String?) -> FormatRenderer.Piece {
        switch style {
        case .preset(let preset):
            switch preset {
            case .bulletList, .numberedList, .todoList:
                return .init(text: FormatRenderer.list(preset, items: [text]), isBlock: true)
            case .verbatim:
                return FormatRenderer.verbatim(chunks: [text])
            case .allCaps:
                return .init(text: FormatRenderer.allCaps(text, languageCode: languageCode), isBlock: false)
            case .lowercase:
                return .init(text: FormatRenderer.lowercase(text, languageCode: languageCode), isBlock: false)
            case .quotes:
                return .init(text: FormatRenderer.quoted(text, languageCode: languageCode), isBlock: false)
            case .parentheses:
                return .init(text: FormatRenderer.parenthesized(text), isBlock: false)
            case .heading:
                return .init(text: FormatRenderer.heading(text), isBlock: true)
            case .email, .formal, .shorter, .translateToEnglish, .translateToGerman:
                return .init(text: text, isBlock: preset.isBlock)   // the model's, at the paste
            }
        case .user(let command):
            switch command.action {
            case .linePrefix(let prefix):
                return .init(text: UserCommandRenderer.linePrefixed(prefix, items: [text]), isBlock: true)
            case .wrap, .textCase:
                return UserCommandRenderer.render(command.action, text: text, languageCode: languageCode)
                    ?? .init(text: text, isBlock: false)
            case .rewrite, .insert:
                return .init(text: text, isBlock: false)
            }
        }
    }
}
