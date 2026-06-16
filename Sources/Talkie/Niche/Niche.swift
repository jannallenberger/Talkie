import Foundation

/// The confidence-based **niche vocabulary** model. Talkie learns the rare,
/// domain-specific words you actually use (jargon, product names, code
/// identifiers) and biases on-device speech recognition toward them, ranked by a
/// confidence it builds from your own usage — so niche terms get transcribed
/// correctly instead of being rounded off to common words.
///
/// 100% local. The store persists to `~/Library/Application Support/Talkie/niche/`
/// and the only place these terms ever go is into the recognizer's on-device
/// `contextualStrings` bias slot (see `NicheVocabSnapshot.biasPhrases`).
///
/// Phase 0 treats the whole user as one implicit niche (`NicheID.default`);
/// per-niche detection arrives in a later phase but the model already carries
/// `nicheKey` so nothing has to change underneath it.

/// A stable identity for a niche — a slug like `ml-infra` or `chess`.
struct NicheID: Codable, Sendable, Hashable {
    var key: String

    /// The single implicit niche used before multi-niche detection exists.
    static let `default` = NicheID(key: "default")
}

/// A domain the user speaks in. `centroid`/`appCategoryPriors` are seeded by later
/// detection phases and are nil/empty under the Phase 0 single-niche model.
struct Niche: Codable, Sendable, Identifiable {
    var id: NicheID
    var displayName: String
    /// `NLEmbedding` sentence-vector of representative text; nil when unavailable.
    var centroid: [Double]?
    /// Learned prior: which app categories this niche tends to fire in.
    var appCategoryPriors: [String: Double] = [:]
    var firstSeenUnix: Double
    var lastSeenUnix: Double
    var sessionCount: Int = 0

    var key: String { id.key }
}

/// One learned term within a niche, carrying the evidence counts the confidence
/// model is computed from. `confidence` is intentionally **not** stored — it is a
/// pure function of these counts + time (`NicheConfidence.score`), so the on-disk
/// file stays canonical and never drifts from the formula.
struct NicheTerm: Codable, Sendable, Hashable, Identifiable {
    /// The canonical surface spelling to bias toward.
    var term: String
    var nicheKey: String
    /// Times harvested from a finalized transcript in this niche (frequency prior).
    var occurrences: Int = 0
    /// Times the user explicitly typed this spelling over Talkie's output — the
    /// strongest signal (graduates the term immediately).
    var userConfirmed: Int = 0
    /// Times we surfaced/biased it and the user corrected *away* from it.
    var rejections: Int = 0
    /// Log-odds "rareness" z-score at first admission (filled by a later phase; 0 now).
    var rarenessZ: Double = 0
    var firstSeenUnix: Double
    var lastSeenUnix: Double
    /// Capped recent provenance ("why is this here?").
    var provenance: [Provenance] = []

    /// Stable identity: niche + normalized spelling. `\u{1}` can't occur in a word,
    /// so it's a safe composite-key separator.
    var id: String { nicheKey + "\u{1}" + term.lowercased() }
}

/// Tunable constants for the confidence model. Centralized so the offline replay
/// harness (a later phase) can sweep them without hunting through call sites.
enum NicheTuning {
    /// Sigmoid midpoint `k`: the `raw` score that maps to 0.5 confidence.
    static let confidenceMidpoint = 1.5
    /// Sigmoid slope `s`: larger = gentler ramp.
    static let confidenceSlope = 2.0
    /// Days for a term's confidence to halve through disuse.
    static let halfLifeDays = 45.0
    /// Confidence at/above which a candidate becomes eligible to bias ("boosted").
    static let graduationThreshold = 0.50
    /// Weight of one explicit user confirmation in the raw score.
    static let userConfirmedWeight = 3.0
    /// Penalty per rejection in the raw score.
    static let rejectionWeight = 2.0
    /// Below this confidence AND older than `pruneAgeDays`, a term is dropped at save.
    static let pruneFloor = 0.05
    static let pruneAgeDays = 180.0
}

/// The confidence model — pure, deterministic, time-passed-in so it is trivially
/// testable and never reads a wall clock implicitly. Confidence answers: *"how
/// sure am I this spelling is real jargon worth forcing the recognizer toward?"*
enum NicheConfidence {
    /// `[0,1]` confidence for a term at a given instant.
    static func score(_ term: NicheTerm, nowUnix: Double) -> Double {
        let raw = NicheTuning.userConfirmedWeight * Double(term.userConfirmed)
            + log2(1 + Double(term.occurrences))
            - NicheTuning.rejectionWeight * Double(term.rejections)
        let logistic = sigmoid((raw - NicheTuning.confidenceMidpoint) / NicheTuning.confidenceSlope)
        let ageDays = max(0, (nowUnix - term.lastSeenUnix) / 86_400)
        let recency = exp(-log(2.0) * ageDays / NicheTuning.halfLifeDays)
        return clamp01(logistic * recency)
    }

    /// A term is **boosted** (eligible to enter the bias set) once its confidence
    /// clears the graduation threshold, OR immediately on a single explicit user
    /// confirmation. Below that it is a tracked-but-not-injected **candidate**, so
    /// unproven guesses never corrupt a transcript.
    static func isBoosted(_ term: NicheTerm, nowUnix: Double) -> Bool {
        if term.userConfirmed >= 1 { return true }
        return score(term, nowUnix: nowUnix) >= NicheTuning.graduationThreshold
    }

    private static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }
    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
}
