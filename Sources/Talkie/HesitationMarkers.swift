import Foundation

/// Apple's recognizer marks hesitations it hears with a leading `#` — `#um`, `#ah`,
/// `#Ah` — and those tokens flowed straight into the pill, the transcript and history.
/// The plain filler stripper never caught them: it matches the bare word ("um") and
/// runs only for English, because "um" is an ordinary German word. The `#` removes
/// that ambiguity — it is the recognizer saying "this was a hesitation", never the
/// German preposition — so these go in EVERY language, at the source.
///
/// Only known hesitation sounds are dropped: a dictated hashtag ("#launch") stays.
enum HesitationMarkers {
    /// Hesitation sounds the recognizer tags with `#` (lowercased, without the `#`).
    static let sounds: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "ah", "ahh", "eh", "er", "erm", "hm", "hmm",
        "mm", "mmm", "mhm", "oh", "äh", "ähm", "öh", "öhm",
    ]

    private static let pattern: NSRegularExpression = {
        // A `#hesitation` token plus any comma right after it, with the space before it.
        let alternation = sounds.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "\\s*(?<![\\p{L}\\p{N}])#(?:\(alternation))(?![\\p{L}\\p{N}])[,，]?",
            options: [.caseInsensitive])
    }()

    /// `text` with every `#hesitation` token removed and the seams tidied.
    static func strip(_ text: String) -> String {
        guard text.contains("#") else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out = pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        out = out.replacingOccurrences(of: " ,", with: ",")
        out = out.replacingOccurrences(of: ",,", with: ",")
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        // A marker that opened the text can leave a stray leading comma.
        return trimmed.hasPrefix(",") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// Whether a single recognized word is a `#hesitation` marker.
    static func isMarker(_ word: String) -> Bool {
        guard word.hasPrefix("#") else { return false }
        let bare = word.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:…")).lowercased()
        return sounds.contains(bare)
    }
}
