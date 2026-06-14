import Foundation

/// Stage-1 **heuristic** extraction of entities from text — no model required, so
/// it works even when Apple Intelligence is off (the OSS / wider-hardware path).
/// Reuses `PhraseMiner` for proper-noun / identifier candidates and a small set of
/// commitment cues. Pure + `Sendable`; safe to run off the main actor. Stage-2 LLM
/// refinement (alias merge, structured commitments, person/project disambiguation)
/// layers on top later, behind the `Summarizer` seam.
enum ContextGraphExtractor {
    struct Candidate: Sendable {
        var kind: EntityKind
        var displayName: String
    }

    /// Extract candidate entities from a free-text body (a dictation, or a meeting
    /// transcript / turn).
    static func candidates(from text: String) -> [Candidate] {
        var out: [Candidate] = []
        for phrase in PhraseMiner.mine(from: [text], limit: 20) {
            out.append(Candidate(kind: classify(phrase), displayName: phrase))
        }
        for clause in commitments(in: text) {
            out.append(Candidate(kind: .commitment, displayName: clause))
        }
        return out
    }

    /// Heuristic kind for a mined phrase: a dotted / snake / CamelCase identifier
    /// reads as a project; a plain Capitalized word stays a term until later
    /// evidence (e.g. a meeting participant match) promotes it to a person.
    private static func classify(_ phrase: String) -> EntityKind {
        let looksLikeIdentifier =
            phrase.contains(".") || phrase.contains("_") || phrase.dropFirst().contains(where: \.isUppercase)
        return looksLikeIdentifier ? .project : .term
    }

    /// Pull short commitment clauses out of text using simple cue phrases. Kept
    /// deliberately conservative (bounded length, explicit cues) to avoid noise.
    static func commitments(in text: String) -> [String] {
        let cues = [
            "i'll ", "i will ", "i need to ", "i have to ", "i'm going to ",
            "let me ", "waiting on ", "follow up", "i should ", "we need to ",
        ]
        var out: [String] = []
        for raw in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            let clause = raw.trimmingCharacters(in: .whitespaces)
            let lower = clause.lowercased()
            if clause.count >= 8, clause.count <= 160, cues.contains(where: { lower.contains($0) }) {
                out.append(clause)
            }
        }
        return out
    }
}
