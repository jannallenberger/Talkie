import Foundation

/// A user-made command for "format while you dictate" (the "+" card on the Commands
/// page). Said with the format key held, like a built-in format. Pure value type.
///
/// Fixed-text commands (`.insert`) are the old snippets: they live in `MacroStore`
/// (macros.json, unchanged on disk) so every existing snippet appears as a user-made
/// card and keeps working as its own dictation, {date}/{time} included. Every other
/// kind lives in `AppSettings.userFormatCommands`.
struct UserCommand: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    /// "When I say…": every phrase that triggers it (the first one is shown).
    var phrases: [String]
    var action: UserCommandAction
    var enabled: Bool = true

    var usesModel: Bool { if case .rewrite = action { return true }; return false }
    /// Inserts a fixed text at that point instead of formatting what follows.
    var isInsertion: Bool { if case .insert = action { return true }; return false }
    var shownPhrase: String { phrases.first ?? name }
}

enum UserTextCase: String, Codable, CaseIterable, Sendable {
    case upper, lower, title
}

/// "Do this" — one of five plain kinds.
enum UserCommandAction: Codable, Hashable, Sendable {
    /// Put text before and/or after.
    case wrap(before: String, after: String)
    /// Start every line with…
    case linePrefix(String)
    /// Make it UPPER / lower / Title case.
    case textCase(UserTextCase)
    /// Rewrite it like this (free instruction, on-device model, slower).
    case rewrite(instruction: String)
    /// Insert a fixed text ({date}, {today}, {time} are filled in).
    case insert(text: String)

    enum Kind: String, CaseIterable, Sendable, Identifiable {
        case wrap, linePrefix, textCase, rewrite, insert
        var id: String { rawValue }
    }

    var kind: Kind {
        switch self {
        case .wrap: return .wrap
        case .linePrefix: return .linePrefix
        case .textCase: return .textCase
        case .rewrite: return .rewrite
        case .insert: return .insert
        }
    }
}

/// The deterministic part of rendering a user-made command (the rewrite goes through
/// `FormatModelPass.rewrite`). Pure, unit-tested.
enum UserCommandRenderer {

    /// Render `text` (already cleaned) with `action`. Returns nil only for `.rewrite`,
    /// which the caller runs on the model.
    static func render(_ action: UserCommandAction, text: String, languageCode: String?,
                       now: Date = Date()) -> FormatRenderer.Piece? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .wrap(let before, let after):
            var body = trimmed
            if !after.isEmpty, body.hasSuffix("."), !body.hasSuffix("..") { body.removeLast() }
            return .init(text: before + body + after, isBlock: before.contains("\n") || after.contains("\n"))
        case .linePrefix(let prefix):
            let lines = FormatRenderer.sentences(in: trimmed).map(FormatRenderer.tidyItem).filter { !$0.isEmpty }
            return .init(text: lines.map { prefix + $0 }.joined(separator: "\n"), isBlock: true)
        case .textCase(let c):
            let locale = languageCode.map { Locale(identifier: $0) } ?? .current
            switch c {
            case .upper: return .init(text: trimmed.uppercased(with: locale), isBlock: false)
            case .lower: return .init(text: trimmed.lowercased(with: locale), isBlock: false)
            case .title: return .init(text: titleCased(trimmed, locale: locale), isBlock: false)
            }
        case .rewrite:
            return nil
        case .insert(let fixed):
            let filled = fillTokens(fixed, now: now)
            return .init(text: filled, isBlock: filled.contains("\n"))
        }
    }

    /// List items from pause-separated chunks (the line-prefix kind keeps the
    /// speaker's own pauses as line breaks, like the built-in lists).
    static func linePrefixed(_ prefix: String, items: [String]) -> String {
        items.flatMap(FormatRenderer.sentences(in:)).map(FormatRenderer.tidyItem)
            .filter { !$0.isEmpty }.map { prefix + $0 }.joined(separator: "\n")
    }

    /// Every word's first letter upper-cased, the rest kept.
    static func titleCased(_ text: String, locale: Locale) -> String {
        var out = ""
        var atWordStart = true
        for ch in text {
            if ch.isLetter {
                out += atWordStart ? String(ch).uppercased(with: locale) : String(ch)
                atWordStart = false
            } else {
                out.append(ch)
                atWordStart = ch.isWhitespace || ch == "-"
            }
        }
        return out
    }

    /// {date} / {today} / {time} → the moment it's said (same tokens as snippets).
    static func fillTokens(_ text: String, now: Date = Date()) -> String {
        guard text.contains("{") else { return text }
        let dateF = DateFormatter(); dateF.dateStyle = .long; dateF.timeStyle = .none
        let timeF = DateFormatter(); timeF.dateStyle = .none; timeF.timeStyle = .short
        return text
            .replacingOccurrences(of: "{date}", with: dateF.string(from: now))
            .replacingOccurrences(of: "{today}", with: dateF.string(from: now))
            .replacingOccurrences(of: "{time}", with: timeF.string(from: now))
    }
}
