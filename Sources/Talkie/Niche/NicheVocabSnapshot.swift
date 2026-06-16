import Foundation

/// An immutable, `Sendable` view of the niche vocabulary — the single query
/// surface the dictation/meeting bias assembly reads, mirroring
/// `ContextGraphSnapshot`. Produced by `NicheVocabStore.snapshot()`.
struct NicheVocabSnapshot: Sendable {
    let niches: [Niche]
    /// All terms, keyed by `nicheKey`.
    let termsByNiche: [String: [NicheTerm]]
    let termGuard: NicheTermGuard
    /// The instant confidence is evaluated against (passed in so the surface is
    /// deterministic and testable).
    let nowUnix: Double

    static let empty = NicheVocabSnapshot(
        niches: [], termsByNiche: [:], termGuard: .default, nowUnix: 0
    )

    /// Confidence for a term at this snapshot's instant.
    func confidence(_ term: NicheTerm) -> Double {
        NicheConfidence.score(term, nowUnix: nowUnix)
    }

    /// Phrases to bias the recognizer toward for the active niche: **only graduated
    /// terms that clear the false-boost guard**, highest confidence first, deduped,
    /// capped to `limit`. This is the niche layer's contribution to the bias union
    /// assembled in `AppDelegate.beginDictation` — appended before the global cap so
    /// confidence governs which terms win budget.
    func biasPhrases(forNiche key: String, limit: Int) -> [String] {
        let candidates = termsByNiche[key] ?? []
        let boosted = candidates
            .filter { NicheConfidence.isBoosted($0, nowUnix: nowUnix) && termGuard.isSafeToInject($0.term) }
            .sorted { confidence($0) > confidence($1) }
        var out: [String] = []
        var seen = Set<String>()
        for term in boosted where seen.insert(term.term.lowercased()).inserted {
            out.append(term.term)
            if out.count >= limit { break }
        }
        return out
    }

    /// All terms for a niche sorted by confidence — the data behind the
    /// "Detected vocabulary" settings card (boosted vs greyed candidates).
    func terms(forNiche key: String) -> [(term: NicheTerm, confidence: Double, boosted: Bool)] {
        (termsByNiche[key] ?? [])
            .map { ($0, confidence($0), NicheConfidence.isBoosted($0, nowUnix: nowUnix)) }
            .sorted { $0.1 > $1.1 }
    }
}
