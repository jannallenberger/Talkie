import Foundation

/// The deterministic formatters for "format while you dictate". Pure string → string;
/// they run AFTER cleanup on a formatted region, so cleanup can never undo them.
enum FormatRenderer {

    /// One rendered piece of the pasted text.
    struct Piece: Sendable, Equatable {
        var text: String
        /// Block pieces (lists, headings, e-mails, fenced code) sit on their own lines.
        var isBlock: Bool
    }

    // MARK: Lists

    /// Render list items (already cleaned). Each item is tidied (trimmed, a stray
    /// marker or trailing period removed, first letter capitalised).
    static func list(_ preset: FormatPreset, items: [String]) -> String {
        let tidied = items.flatMap(sentences(in:)).map(tidyItem).filter { !$0.isEmpty }
        return tidied.enumerated().map { index, item in
            switch preset {
            case .numberedList: return "\(index + 1). \(item)"
            case .todoList: return "- [ ] \(item)"
            default: return "- \(item)"
            }
        }.joined(separator: "\n")
    }

    /// Split cleaned text into sentences at `.`/`!`/`?`/`…` followed by a space and an
    /// upper-case letter or digit — never after a common abbreviation ("z. B.", "e.g.").
    static func sentences(in text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if ".!?…".contains(c), i + 2 < chars.count, chars[i + 1] == " ",
               chars[i + 2].isUppercase || chars[i + 2].isNumber,
               !endsWithAbbreviation(current) {
                out.append(current)
                current = ""
                i += 2   // skip the space
                continue
            }
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static let abbreviations: Set<String> = [
        "z", "b", "bzw", "usw", "ca", "etc", "vgl", "ggf", "evtl", "nr", "dr", "prof", "mr", "mrs",
        "ms", "vs", "e.g", "i.e", "eg", "ie", "inkl", "sog", "st",
    ]

    private static func endsWithAbbreviation(_ s: String) -> Bool {
        guard s.hasSuffix(".") else { return false }
        let word = s.dropLast().split(whereSeparator: { $0 == " " }).last.map(String.init) ?? ""
        return abbreviations.contains(word.lowercased())
    }

    /// Trim, drop a leading list marker the text may already carry, drop a trailing
    /// period/comma/semicolon, capitalise the first letter.
    static func tidyItem(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["- [ ] ", "- ", "• ", "* "] where s.hasPrefix(marker) {
            s = String(s.dropFirst(marker.count))
            break
        }
        if let match = s.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) {
            s = String(s[match.upperBound...])
        }
        while let last = s.last, ".,;:".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        return capitalizeFirst(s)
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    // MARK: Inline / single formats

    static func allCaps(_ text: String, languageCode: String?) -> String {
        text.uppercased(with: locale(languageCode))
    }

    static func lowercase(_ text: String, languageCode: String?) -> String {
        text.lowercased(with: locale(languageCode))
    }

    /// Typographic quotation marks of the dictation language.
    static func quoteMarks(languageCode: String?) -> (open: String, close: String) {
        switch languageCode?.lowercased().prefix(2) {
        case "de": return ("\u{201E}", "\u{201C}")                 // „…“
        case "fr": return ("\u{00AB}\u{202F}", "\u{202F}\u{00BB}") // « … »
        case "es", "it": return ("\u{00AB}", "\u{00BB}")           // «…»
        case "ja": return ("\u{300C}", "\u{300D}")                 // 「…」
        default: return ("\u{201C}", "\u{201D}")                   // “…” (en, nl, pt, zh, ko)
        }
    }

    static func quoted(_ text: String, languageCode: String?) -> String {
        let marks = quoteMarks(languageCode: languageCode)
        return marks.open + stripOneTrailingPeriod(text) + marks.close
    }

    static func parenthesized(_ text: String) -> String {
        "(" + stripOneTrailingPeriod(text) + ")"
    }

    static func heading(_ text: String) -> String {
        "# " + tidyItem(text)
    }

    /// Verbatim: the raw words, no cleanup. One chunk → inline code; several
    /// pause-separated chunks → a fenced block, one chunk per line.
    static func verbatim(chunks: [String]) -> Piece {
        let lines = chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if lines.count <= 1 { return Piece(text: "`" + (lines.first ?? "") + "`", isBlock: false) }
        return Piece(text: "```\n" + lines.joined(separator: "\n") + "\n```", isBlock: true)
    }

    private static func stripOneTrailingPeriod(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("."), !s.hasSuffix("..") { s.removeLast() }
        return s
    }

    private static func locale(_ code: String?) -> Locale {
        code.map { Locale(identifier: $0) } ?? .current
    }

    // MARK: E-mail frame

    /// Wrap an e-mail body (paragraphs from the model) in a greeting, closing and
    /// signature — deterministically, so the model never has to invent them. Anything
    /// the speaker already said ("Hallo Anna", "Viele Grüße") is kept and not doubled.
    static func emailFrame(body: String, languageCode: String?, userName: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lang = String(languageCode?.lowercased().prefix(2) ?? "en")
        let words = defaultEmailWords(lang)
        var parts: [String] = []
        if !startsWithGreeting(trimmed), let greeting = words.greeting { parts.append(greeting) }
        parts.append(trimmed)
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        if endsWithClosing(trimmed) {
            if !name.isEmpty, !lastLine.localizedCaseInsensitiveContains(name) {
                parts[parts.count - 1] = trimmed + "\n" + name
            }
        } else if let closing = words.closing {
            parts.append(name.isEmpty ? closing : closing + "\n" + name)
        } else if !name.isEmpty {
            parts.append(name)
        }
        return parts.joined(separator: "\n\n")
    }

    static func defaultEmailWords(_ lang: String) -> (greeting: String?, closing: String?) {
        switch lang {
        case "de": return ("Hallo,", "Viele Grüße")
        case "fr": return ("Bonjour,", "Cordialement")
        case "es": return ("Hola:", "Saludos")
        case "it": return ("Buongiorno,", "Cordiali saluti")
        case "nl": return ("Hallo,", "Met vriendelijke groet")
        case "pt": return ("Olá,", "Atenciosamente")
        case "ja", "zh", "ko": return (nil, nil)
        default: return ("Hi,", "Best regards")
        }
    }

    private static let greetingStarts: [String] = [
        "hi", "hello", "hey", "dear", "good morning", "good afternoon", "good evening",
        "hallo", "liebe", "lieber", "liebes", "sehr geehrte", "sehr geehrter", "guten tag",
        "guten morgen", "moin", "servus", "bonjour", "hola", "ciao", "buongiorno", "olá", "ola",
    ]

    private static let closingStarts: [String] = [
        "best", "best regards", "kind regards", "regards", "cheers", "thanks", "thank you",
        "all the best", "sincerely", "viele grüße", "beste grüße", "liebe grüße", "herzliche grüße",
        "mit freundlichen grüßen", "freundliche grüße", "grüße", "gruß", "lg", "vg", "danke",
        "vielen dank", "cordialement", "saludos", "cordiali saluti", "met vriendelijke groet",
        "atenciosamente",
    ]

    static func startsWithGreeting(_ text: String) -> Bool {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return startsWithPhrase(first, greetingStarts)
    }

    static func endsWithClosing(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        // The closing may be the last line, or the one before a name line — never the
        // first line ("Thanks for the call" opens a body, it doesn't close one), and
        // only a short line counts.
        guard lines.count >= 2 else { return false }
        return lines.dropFirst().suffix(2).contains { startsWithPhrase($0, closingStarts) && $0.count <= 30 }
    }

    private static func startsWithPhrase(_ line: String, _ phrases: [String]) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        return phrases.contains { p in
            guard lower.hasPrefix(p) else { return false }
            let rest = lower.dropFirst(p.count)
            return rest.first.map { !$0.isLetter } ?? true
        }
    }
}

/// Puts the pasted text together. Formatted regions are replaced by private-use
/// placeholder characters while the normal text runs the usual post-cleanup chain
/// (dictionary, numbers, structural commands …) and are substituted back at the very
/// end — so nothing in that chain can touch a format.
enum FormatAssembly {

    /// Whether a dictation needs the formatted assembly at all. False when the command
    /// key was never held for a span — then the normal path runs, byte for byte.
    static func needsAssembly(_ marks: [FormatMark]) -> Bool {
        marks.contains(where: \.isSpan)
    }

    static let placeholderBase: UInt32 = 0xE000

    static func placeholder(_ index: Int) -> String {
        String(Character(UnicodeScalar(placeholderBase + UInt32(index))!))
    }

    private static func placeholderIndex(_ scalar: Unicode.Scalar, count: Int) -> Int? {
        let v = scalar.value
        guard v >= placeholderBase, v < placeholderBase + UInt32(count) else { return nil }
        return Int(v - placeholderBase)
    }

    /// Join pieces: blocks get line breaks around them, inline pieces a space.
    static func join(_ pieces: [FormatRenderer.Piece]) -> String {
        var out = ""
        var previous: FormatRenderer.Piece?
        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let prev = previous {
                if prev.isBlock || piece.isBlock {
                    out += "\n"
                } else if let first = text.first, ".,;:!?)…".contains(first) {
                    // "… “quote”, and then" — punctuation hugs the piece before it.
                } else {
                    out += " "
                }
            }
            out += text
            previous = FormatRenderer.Piece(text: text, isBlock: piece.isBlock)
        }
        return out
    }

    /// The normal-text stream handed to the post-cleanup chain: normal texts as-is,
    /// each formatted region as its placeholder, space-separated.
    static func normalStream(_ parts: [Part]) -> String {
        var formattedIndex = 0
        var pieces: [String] = []
        for part in parts {
            switch part {
            case .normal(let text):
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { pieces.append(t) }
            case .formatted:
                pieces.append(placeholder(formattedIndex))
                formattedIndex += 1
            }
        }
        return pieces.joined(separator: " ")
    }

    enum Part: Sendable, Equatable {
        case normal(String)
        case formatted(FormatRenderer.Piece)
    }

    /// Replace the placeholders in the processed normal stream with the formatted
    /// pieces. When nothing was formatted the text is returned untouched. If the
    /// chain somehow lost or duplicated a placeholder, falls back to joining the
    /// pre-chain `parts` directly — a format is never silently dropped.
    static func substitute(processed: String, parts: [Part]) -> String {
        let formatted: [FormatRenderer.Piece] = parts.compactMap {
            if case .formatted(let p) = $0 { return p } else { return nil }
        }
        guard !formatted.isEmpty else { return processed }

        var pieces: [FormatRenderer.Piece] = []
        var seen = Set<Int>()
        var buffer = ""
        var intact = true
        for scalar in processed.unicodeScalars {
            if let i = placeholderIndex(scalar, count: formatted.count) {
                pieces.append(FormatRenderer.Piece(text: buffer, isBlock: false))
                buffer = ""
                if !seen.insert(i).inserted { intact = false }
                pieces.append(formatted[i])
            } else {
                buffer.unicodeScalars.append(scalar)
            }
        }
        pieces.append(FormatRenderer.Piece(text: buffer, isBlock: false))
        if !intact || seen.count != formatted.count {
            return join(parts.map {
                switch $0 {
                case .normal(let t): return FormatRenderer.Piece(text: t, isBlock: false)
                case .formatted(let p): return p
                }
            })
        }
        return join(pieces)
    }
}
