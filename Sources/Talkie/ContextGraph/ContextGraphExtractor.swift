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
    ///
    /// Everything from `PhraseMiner` lands as `.term` — Stage-1 has no reliable
    /// signal to tell a project apart from any other identifier-shaped phrase (an
    /// earlier version guessed "dotted/underscored/internal-capital → project",
    /// which mislabeled plain acronyms like "TSX" or "GDPR" as projects purely
    /// because they're all-caps). `.project` is reserved for higher-confidence
    /// sources: the folder name Vibe Coding is actually pointed at, or Stage-2 LLM
    /// extraction (`GraphLLMExtractor`) once it's wired into the live ingest path.
    static func candidates(from text: String) -> [Candidate] {
        var out: [Candidate] = []
        for phrase in PhraseMiner.mine(from: [text], limit: 20) {
            out.append(Candidate(kind: .term, displayName: phrase))
        }
        for clause in commitments(in: text) {
            out.append(Candidate(kind: .commitment, displayName: clause))
        }
        return out
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
