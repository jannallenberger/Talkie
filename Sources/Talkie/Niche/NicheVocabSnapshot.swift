import Foundation

/// An immutable, `Sendable` view of the niche vocabulary — the single query
/// surface the live corrector and the settings UI read, mirroring
/// `ContextGraphSnapshot`. Produced by `NicheVocabStore.snapshot()`.
///
/// The graduated terms flow into the **post-hoc `NicheCorrector`**
/// (`correctorTerms`), not the recognizer's bias slot — on-device
/// `contextualStrings` biasing is a proven no-op on this stack (gate-zero verdict),
/// so the correction happens on the finalized transcript instead. `biasPhrases`
/// is retained for the offline bias A/B probe only.
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

    /// The graduated niche terms to feed the post-hoc `NicheCorrector` for the
    /// active niche: **only boosted terms that clear the false-boost guard**,
    /// highest confidence first, deduped, capped to `limit`. Unioned with the
    /// hand-curated `dictionary.vocabulary` in `AppDelegate.endDictation` — the cap
    /// bounds the corrector's O(words × targets) cost, and confidence governs which
    /// terms make the cut. The guard (`isSafeToInject`) is what stops a jargon
    /// spelling from being forced onto a common word the user actually said, so it
    /// gates the corrector list exactly as it once gated the (retired) bias list.
    func correctorTerms(forNiche key: String, limit: Int) -> [String] {
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

    /// Retained for the offline bias A/B probe (`BiasABProbe`) only — the live path
    /// no longer biases the recognizer (gate-zero verdict). Same graduated + guarded
    /// + confidence-ranked selection as `correctorTerms`.
    func biasPhrases(forNiche key: String, limit: Int) -> [String] {
        correctorTerms(forNiche: key, limit: limit)
    }

    /// All terms for a niche sorted by confidence — the data behind the
    /// "Detected vocabulary" settings card (boosted vs greyed candidates).
    func terms(forNiche key: String) -> [(term: NicheTerm, confidence: Double, boosted: Bool)] {
        (termsByNiche[key] ?? [])
            .map { ($0, confidence($0), NicheConfidence.isBoosted($0, nowUnix: nowUnix)) }
            .sorted { $0.1 > $1.1 }
    }
}
