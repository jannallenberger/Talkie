import Foundation

/// Where spoken punctuation sits relative to the cleanup model.
///
/// Every cleanup style (Neutral included) is told that the recognizer's commas and
/// periods are unreliable and to re-derive them, to fix grammar and to repair misheard
/// words. Those commas are exactly the signal that a punctuation word was said on its
/// own, and an article the model adds ("Doppelpunkt" -> "einen Doppelpunkt") or a word it
/// "repairs" changes the decision. So when a model runs, the decision is taken on the
/// recognizer's text BEFORE the model (after only the deterministic de-seam), the model
/// sees the characters instead of the words, and nothing re-decides on the model's text
/// afterwards. If the model then drops or adds one of the inserted characters, its
/// rewrite is rejected and the deterministic text is kept (the same "keep the raw" rule
/// as the other cleanup guards). Without a model the pass keeps its place after the
/// dictionary (see AppDelegate).
extension SpokenPunctuation {

    /// Characters this pass and the structural commands can insert.
    static let insertableMarks: Set<Character> = [
        ":", ";", "?", "!", "…", "(", ")", "[", "]", "{", "}", "\u{201E}", "\u{201C}", "\u{201D}",
        "/", "\\", "-", "_", "@", "—", "–", "%", "&", "=", "+", "*", "§", "#", "\n",
    ]

    /// The deterministic decision on recognizer text, before any model: the new-line /
    /// new-paragraph commands (both languages; `structural`) and then the marks.
    static func beforeModel(_ text: String, languageCode: String?, structural: Bool) -> String {
        let lines = structural ? StructuralCommands.apply(text, languageCode: languageCode, anyLanguage: true) : text
        return apply(lines, languageCode: languageCode)
    }

    /// The characters the decision added (more of them in `converted` than in `raw`).
    static func inserted(raw: String, converted: String) -> Set<Character> {
        let before = counts(raw), after = counts(converted)
        return Set(after.compactMap { c, n in n > (before[c] ?? 0) ? c : nil })
    }

    /// Whether a model rewrite kept every inserted character exactly as often as its
    /// input had it: no "(" lost, no second ":" invented next to ours.
    static func modelKeeps(_ marks: Set<Character>, input: String, output: String) -> Bool {
        guard !marks.isEmpty else { return true }
        let a = counts(input), b = counts(output)
        return marks.allSatisfy { (a[$0] ?? 0) == (b[$0] ?? 0) }
    }

    /// One model pass around the decision: convert `raw`, let `model` clean the result,
    /// keep the model's text only if it left the inserted characters alone. Never nil:
    /// a failed or rejected model call returns the converted text.
    static func aroundModel(_ raw: String, languageCode: String?, structural: Bool,
                            model: (String) async -> String?) async -> String {
        let converted = beforeModel(raw, languageCode: languageCode, structural: structural)
        let marks = inserted(raw: raw, converted: converted)
        return await guardedModel(converted, marks: marks, model: model)
    }

    /// The model call on already converted text (`marks` = what the decision inserted).
    static func guardedModel(_ converted: String, marks: Set<Character>,
                             model: (String) async -> String?) async -> String {
        guard let out = await model(converted) else { return converted }
        return modelKeeps(marks, input: converted, output: out) ? out : converted
    }

    private static func counts(_ s: String) -> [Character: Int] {
        var out: [Character: Int] = [:]
        for c in s where insertableMarks.contains(c) { out[c, default: 0] += 1 }
        return out
    }
}
