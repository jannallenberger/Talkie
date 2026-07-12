import Foundation

/// A personal record that broke on one dictation — "your only competitor is
/// yourself" (K3). Small and `Sendable` so K4's record-preen mood and K10's
/// Wrapped narration can consume it across actors without ceremony. The
/// associated value is the NEW record value (the one that just broke), ready to
/// drop into a chip string.
///
///   .fastestWPM       — a new best honest words-per-minute (StatsStore guards).
///   .longestDictation — a new longest single dictation, in words.
///   .biggestWordDay   — today's word total just cleared the previous all-time
///                       daily max (detected by `ActivityStore`).
enum PersonalRecord: Equatable, Sendable {
    case fastestWPM(Double)
    case longestDictation(Int)
    case biggestWordDay(Int)

    /// Chip priority when more than one record breaks on the same dictation: a
    /// biggest-word-day is the rarest and most emotionally resonant, then a raw
    /// speed record, then a longest single take. Higher wins. The pill only ever
    /// shows ONE chip (per the one-honest-event-tier cap), so this decides which.
    private var chipPriority: Int {
        switch self {
        case .biggestWordDay: return 3
        case .fastestWPM: return 2
        case .longestDictation: return 1
        }
    }

    /// Given every record that broke this dictation, pick the single one to show
    /// in the HUD chip — biggest-word-day > fastest-WPM > longest-dictation — or
    /// nil when nothing broke. Pure so the priority is unit-testable without a HUD.
    static func chipPick(from broken: [PersonalRecord]) -> PersonalRecord? {
        broken.max { $0.chipPriority < $1.chipPriority }
    }
}

/// Lifetime dictation stats for the scoreboard. Persisted SEPARATELY from the
/// 7-day history so the totals keep accumulating even as old entries are pruned.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var totalWords = 0
    @Published private(set) var totalDictations = 0
    @Published private(set) var totalDurationSec = 0.0
    @Published private(set) var bestWPM = 0.0
    /// The longest single dictation ever recorded, in words, with the duration it
    /// took (for an honest "N words in M:SS" display). Both surface on the
    /// Dashboard's Records card and drive the `.longestDictation` HUD chip. Zero
    /// until the first qualifying dictation.
    @Published private(set) var longestDictationWords = 0
    @Published private(set) var longestDictationDurationSec = 0.0

    // Fixes Talkie has made for you (drives the "Fixes by Talkie" card).
    /// Replacement / vocabulary substitutions applied (e.g. "get hub" → "GitHub").
    @Published private(set) var dictionaryFixes = 0
    /// Filler words stripped ("um", "uh", …).
    @Published private(set) var fillersRemoved = 0
    /// Words changed by the on-device AI cleanup (grammar, self-corrections).
    @Published private(set) var aiWordsChanged = 0

    /// K5 — per-term fix tally ("Words you taught me"). How many distinct dictations
    /// each term was rescued in (one increment per term per dictation), plus the
    /// first-seen unix time for a stable tie-break / "since" display. On-device only,
    /// in stats.json (same privacy class as dictionary.json). Capped at
    /// `maxTrackedTerms` with lowest-count eviction so the file can't grow unbounded.
    @Published private(set) var termFixCounts: [String: Int] = [:]
    private(set) var termFirstFixedUnix: [String: Double] = [:]
    static let maxTrackedTerms = 500

    private let fileURL: URL

    /// `directory` defaults to the real support dir; tests pass a temp dir so they
    /// neither read the developer's real `stats.json` (non-deterministic) nor let
    /// `save()` clobber it. Mirrors `HistoryStore(directory:)`.
    init(directory: URL? = nil) {
        fileURL = (directory ?? AppPaths.supportDirectory()).appendingPathComponent("stats.json")
        load()
    }

    /// How many lifetime dictations must already be on the board before a broken
    /// record earns a HUD chip — so day-one use (when every value is a "record" by
    /// definition) isn't a confetti storm. Paired with the "had a prior non-zero
    /// value" guard below: BOTH must hold for a record to count as broken.
    static let recordMinLifetimeDictations = 10

    /// Record one dictation and report which personal records it broke this call —
    /// `[]` when none (the common case). The returned records feed the single HUD
    /// "personal best" chip (K3) and, later, K4's preen and K10's Wrapped.
    ///
    /// HONESTY GUARD: a value counts as "broken" only when there was already a
    /// prior non-zero value to beat AND the user has at least
    /// `recordMinLifetimeDictations` dictations behind them. First-ever values and
    /// ties never celebrate — your first dictation isn't a personal best, it's just
    /// your first. This reuses the same spirit as `bestWPM`'s existing sample
    /// guards (≥1.5 s, ≥4 words, <400 WPM), which still gate whether a WPM sample is
    /// even eligible to be a record.
    @discardableResult
    func record(words: Int, durationSec: Double) -> [PersonalRecord] {
        guard words > 0 else { return [] }
        // Snapshot the pre-mutation state so the honesty guard measures history
        // that existed BEFORE this dictation (this call is the (priorDictations+1)-th).
        let priorDictations = totalDictations
        let priorBestWPM = bestWPM
        let priorLongestWords = longestDictationWords
        let eligibleForChip = priorDictations >= Self.recordMinLifetimeDictations

        totalWords += words
        totalDictations += 1
        totalDurationSec += max(0, durationSec)

        var broken: [PersonalRecord] = []

        // Only count a "best WPM" for meaningful samples (avoids 1-word bursts
        // producing absurd rates).
        if durationSec >= 1.5, words >= 4 {
            let wpm = Double(words) / (durationSec / 60)
            if wpm.isFinite, wpm > 0, wpm < 400 {
                if wpm > bestWPM { bestWPM = wpm }
                // A broken speed record needs a prior non-zero best to beat and
                // enough history to have earned the celebration.
                if eligibleForChip, priorBestWPM > 0, wpm > priorBestWPM {
                    broken.append(.fastestWPM(wpm))
                }
            }
        }

        // Longest single dictation — tracked here (ActivityStore only knows daily
        // totals). Every dictation with words > 0 is eligible (no WPM sample floor);
        // the honesty guard still applies to whether it earns a chip.
        if words > longestDictationWords {
            longestDictationWords = words
            longestDictationDurationSec = max(0, durationSec)
            if eligibleForChip, priorLongestWords > 0 {
                broken.append(.longestDictation(words))
            }
        }

        save()
        return broken
    }

    /// Tally the corrections Talkie made on one dictation.
    func recordFixes(dictionary: Int, fillers: Int, aiWords: Int) {
        dictionaryFixes += max(0, dictionary)
        fillersRemoved += max(0, fillers)
        aiWordsChanged += max(0, aiWords)
        save()
    }

    /// K5 — record which specific terms were rescued on one dictation. `terms` is
    /// already de-duplicated per dictation by the caller, so each counts once here
    /// ("rescued N times" == N distinct dictations). Enforces the term cap by
    /// evicting the lowest-count entries (oldest first-fixed breaks ties) so a heavy
    /// user never grows stats.json without bound.
    func recordTermFixes(_ terms: [String]) {
        guard !terms.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var changed = false
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            termFixCounts[term, default: 0] += 1
            if termFirstFixedUnix[term] == nil { termFirstFixedUnix[term] = now }
            changed = true
        }
        guard changed else { return }
        evictIfNeeded()
        save()
    }

    /// Keep only the `maxTrackedTerms` most-fixed terms; drop the lowest-count ones
    /// (oldest first-fixed as the tiebreak) along with their first-seen timestamps.
    private func evictIfNeeded() {
        guard termFixCounts.count > Self.maxTrackedTerms else { return }
        let keep = Set(rankedTerms().prefix(Self.maxTrackedTerms).map(\.term))
        termFixCounts = termFixCounts.filter { keep.contains($0.key) }
        termFirstFixedUnix = termFirstFixedUnix.filter { keep.contains($0.key) }
    }

    /// Terms ranked highest-count first, oldest first-fixed breaking ties.
    private func rankedTerms() -> [(term: String, count: Int)] {
        termFixCounts.sorted {
            $0.value != $1.value
                ? $0.value > $1.value
                : (termFirstFixedUnix[$0.key] ?? 0) < (termFirstFixedUnix[$1.key] ?? 0)
        }.map { (term: $0.key, count: $0.value) }
    }

    /// The most-taught terms for the "Words you taught me" card (K5).
    func topTaughtWords(limit: Int) -> [(term: String, count: Int)] {
        Array(rankedTerms().prefix(limit))
    }

    /// Lifetime average speaking speed.
    var averageWPM: Double {
        guard totalDurationSec > 0 else { return 0 }
        return Double(totalWords) / (totalDurationSec / 60)
    }

    /// Words Talkie rewrote for you (fillers + AI grammar/self-correction edits).
    var wordsCorrected: Int { fillersRemoved + aiWordsChanged }
    /// All fixes combined — the headline number on the "Fixes by Talkie" card.
    var totalFixes: Int { wordsCorrected + dictionaryFixes }

    func reset() {
        totalWords = 0
        totalDictations = 0
        totalDurationSec = 0
        bestWPM = 0
        longestDictationWords = 0
        longestDictationDurationSec = 0
        dictionaryFixes = 0
        fillersRemoved = 0
        aiWordsChanged = 0
        termFixCounts = [:]
        termFirstFixedUnix = [:]
        save()
    }

    // MARK: Persistence

    private struct Payload: Codable {
        var totalWords: Int
        var totalDictations: Int
        var totalDurationSec: Double
        var bestWPM: Double
        // Optional for back-compat with files written before fix-tracking.
        var dictionaryFixes: Int?
        var fillersRemoved: Int?
        var aiWordsChanged: Int?
        // Optional for back-compat with files written before K3's records — an old
        // stats.json without these decodes cleanly (both default to 0).
        var longestDictationWords: Int?
        var longestDictationDurationSec: Double?
        // K5 — optional for back-compat with files written before per-term tallying.
        var termFixCounts: [String: Int]?
        var termFirstFixedUnix: [String: Double]?
    }

    private func load() {
        guard let p = StoreLoad.loadJSONWithQuarantine(Payload.self, from: fileURL) else { return }
        totalWords = p.totalWords
        totalDictations = p.totalDictations
        totalDurationSec = p.totalDurationSec
        bestWPM = p.bestWPM
        dictionaryFixes = p.dictionaryFixes ?? 0
        fillersRemoved = p.fillersRemoved ?? 0
        aiWordsChanged = p.aiWordsChanged ?? 0
        longestDictationWords = p.longestDictationWords ?? 0
        longestDictationDurationSec = p.longestDictationDurationSec ?? 0
        termFixCounts = p.termFixCounts ?? [:]
        termFirstFixedUnix = p.termFirstFixedUnix ?? [:]
    }

    private func save() {
        let p = Payload(
            totalWords: totalWords,
            totalDictations: totalDictations,
            totalDurationSec: totalDurationSec,
            bestWPM: bestWPM,
            dictionaryFixes: dictionaryFixes,
            fillersRemoved: fillersRemoved,
            aiWordsChanged: aiWordsChanged,
            longestDictationWords: longestDictationWords,
            longestDictationDurationSec: longestDictationDurationSec,
            termFixCounts: termFixCounts,
            termFirstFixedUnix: termFirstFixedUnix
        )
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Shared word-count helper.
enum WordCounter {
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
