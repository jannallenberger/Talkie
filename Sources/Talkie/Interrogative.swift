import Foundation

/// Deterministic "does this text read as a question?" check — no model, no I/O.
/// Factored out of `CleanupEngine` (the dictation answer-guard) so the meeting
/// pill's instant far-end question detector (`MeetingSubtopicEngine`) shares the
/// exact same heuristic instead of drifting from a second copy.
enum Interrogative {
    /// A "?" anywhere isn't enough to call the WHOLE text "a question" once dictation
    /// gets long: a rambling multi-sentence brain-dump can contain one embedded
    /// question ("…what will the identity of those influencers be?…") among dozens of
    /// unrelated statements without the utterance AS A WHOLE being a question. Missing
    /// this let a legitimate long cleanup rewrite get rejected by CleanupEngine's
    /// answer-guard (the rewrite plausibly drops that one "?" while paraphrasing a
    /// 200+-word paragraph, tripping the guard) — falling back to the raw, unpolished
    /// ASR transcript for the whole dictation. Above this length, a "?" only counts if
    /// it's terminal (a single trailing question, however long the lead-up).
    private static let shortTextCharLimit = 300

    /// Does this text read as a question? Prefer an explicit "?"; otherwise fall
    /// back to a leading question word (English + German, the languages Talkie's
    /// user dictates in) so a spoken question with no recognizer punctuation still
    /// counts. Used by the (Q) and (B) answer guards, which ALSO require the output
    /// to have dropped the "?" AND added a new content word — so a stray match here
    /// on an imperative ("have a nice day") can't by itself reject anything.
    static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix("?") { return true }
        if t.contains("?"), t.count <= shortTextCharLimit { return true }
        guard let first = t.split(whereSeparator: { !$0.isLetter }).first.map(String.init)
        else { return false }
        return questionOpeners.contains(first)
    }

    private static let questionOpeners: Set<String> = [
        // English
        "what", "whats", "who", "whom", "whose", "when", "where", "why", "how",
        "which", "is", "are", "am", "was", "were", "do", "does", "did", "can",
        "could", "will", "would", "should", "shall", "may", "might", "has", "have",
        "had", "isnt", "arent", "cant", "wont", "didnt", "doesnt",
        // German
        "was", "wer", "wen", "wem", "wessen", "wann", "wo", "woher", "wohin",
        "warum", "wieso", "weshalb", "weswegen", "wie", "welche", "welcher",
        "welches", "welchen", "welchem", "ist", "sind", "war", "waren", "kann",
        "kannst", "könnt", "könnte", "könnten", "wird", "würde", "würden", "soll",
        "sollen", "hast", "habt", "haben", "hat", "darf", "muss", "müssen", "wieviel",
        "wieviele", "warst",
    ]
}
