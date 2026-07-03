import Foundation

/// L3a — a rolling record of the *software* latency of each completed dictation:
/// how long the post-release pipeline (finalize → optional re-transcribe →
/// cleanup → insert) actually took. Persisted to `latency.json` under Application
/// Support (atomic write; a decode failure yields an empty store).
///
/// This is a PURE NUMERIC store — it holds only stage durations, a character
/// count, and a few boolean/enum flags. It never stores transcript text, app
/// names, or any other content. Because it is a numeric aggregate with no user
/// text, it rides the tolerated numeric-aggregate exception to true-delete: the
/// rolling cap (and `reset()`) are sufficient; there is nothing here that a
/// history purge would need to shred.
///
/// Note: `totalMs`/`finalizeMs`/… are PROCESSING latency (wall-clock around the
/// awaits on the dictation path), NOT speaking time. Speaking time lives on
/// `durationSec` elsewhere and is never mixed in here.
@MainActor
final class LatencyStore: ObservableObject {
    /// One completed dictation's software latency, in milliseconds, plus the
    /// small amount of context needed to interpret it. Numeric only.
    struct Record: Codable, Equatable {
        /// Wall-clock time the record was written (`Date().timeIntervalSince1970`).
        var unix: Double
        /// Total post-release processing time (finalize → insert), milliseconds.
        var totalMs: Double
        /// Speech finalization stage (`engine.finishSessionDetailed`), ms.
        var finalizeMs: Double
        /// Multilingual re-transcription stage (0 when it didn't run), ms.
        var reTxMs: Double
        /// On-device cleanup / de-seam stage, ms.
        var cleanupMs: Double
        /// Text-injection stage, ms.
        var insertMs: Double
        /// Length of the final inserted text, in characters.
        var chars: Int
        /// Whether cleanup used the streamed (already-running) result.
        var streamed: Bool
        /// Whether optimistic insertion dropped interim text before cleanup finished.
        var optimistic: Bool
        /// True only for the FIRST record since app launch (first-dictation warm-up).
        var coldStart: Bool
        /// Insertion mode string (`"paste"`/`"type"`), or "" when unavailable.
        var mode: String
        /// Terminal outcome, e.g. "inserted" / "leftOnClipboard" / "empty".
        var outcome: String

        // Per-stage values default to 0 when missing from an older file, so an
        // early `latency.json` still decodes cleanly.
        init(
            unix: Double, totalMs: Double,
            finalizeMs: Double = 0, reTxMs: Double = 0,
            cleanupMs: Double = 0, insertMs: Double = 0,
            chars: Int, streamed: Bool, optimistic: Bool,
            coldStart: Bool, mode: String, outcome: String
        ) {
            self.unix = unix
            self.totalMs = totalMs
            self.finalizeMs = finalizeMs
            self.reTxMs = reTxMs
            self.cleanupMs = cleanupMs
            self.insertMs = insertMs
            self.chars = chars
            self.streamed = streamed
            self.optimistic = optimistic
            self.coldStart = coldStart
            self.mode = mode
            self.outcome = outcome
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            unix = try c.decode(Double.self, forKey: .unix)
            totalMs = try c.decode(Double.self, forKey: .totalMs)
            finalizeMs = try c.decodeIfPresent(Double.self, forKey: .finalizeMs) ?? 0
            reTxMs = try c.decodeIfPresent(Double.self, forKey: .reTxMs) ?? 0
            cleanupMs = try c.decodeIfPresent(Double.self, forKey: .cleanupMs) ?? 0
            insertMs = try c.decodeIfPresent(Double.self, forKey: .insertMs) ?? 0
            chars = try c.decodeIfPresent(Int.self, forKey: .chars) ?? 0
            streamed = try c.decodeIfPresent(Bool.self, forKey: .streamed) ?? false
            optimistic = try c.decodeIfPresent(Bool.self, forKey: .optimistic) ?? false
            coldStart = try c.decodeIfPresent(Bool.self, forKey: .coldStart) ?? false
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
            outcome = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        }
    }

    /// Newest last. Held to `maxRecords` — the oldest is dropped on save.
    @Published private(set) var records: [Record] = []

    /// Rolling cap: only the most recent `maxRecords` dictations are kept.
    static let maxRecords = 50

    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("latency.json")
        load()
    }

    /// Append one completed dictation's latency, dropping the oldest if we're over
    /// the cap, then persist. Numeric only — no transcript text is passed in.
    func record(
        totalMs: Double,
        finalizeMs: Double,
        reTxMs: Double,
        cleanupMs: Double,
        insertMs: Double,
        chars: Int,
        streamed: Bool,
        optimistic: Bool,
        coldStart: Bool,
        mode: String,
        outcome: String
    ) {
        records.append(Record(
            unix: Date().timeIntervalSince1970,
            totalMs: totalMs,
            finalizeMs: finalizeMs,
            reTxMs: reTxMs,
            cleanupMs: cleanupMs,
            insertMs: insertMs,
            chars: chars,
            streamed: streamed,
            optimistic: optimistic,
            coldStart: coldStart,
            mode: mode,
            outcome: outcome
        ))
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
        save()
    }

    /// Clear the rolling record.
    func reset() {
        records = []
        save()
    }

    // MARK: Reads (L3b — pure aggregates over the stored array)

    /// The per-stage medians of a set of records, in milliseconds. Each stage is
    /// medianed INDEPENDENTLY over the same sample set (so a stage that's usually
    /// zero — re-transcription — reports ~0 without dragging the others). Returned
    /// as a small value so the waterfall can lay them out proportionally.
    struct StageMedians: Equatable {
        var finalizeMs: Double
        var reTxMs: Double
        var cleanupMs: Double
        var insertMs: Double

        /// The four stages summed — the width the waterfall bars tile.
        var sumMs: Double { finalizeMs + reTxMs + cleanupMs + insertMs }

        static let zero = StageMedians(finalizeMs: 0, reTxMs: 0, cleanupMs: 0, insertMs: 0)

        /// A stage duration's share of the total, clamped to [0, 1] — the fraction
        /// of the bar width the waterfall paints for that stage. A zero (or missing)
        /// total yields 0 for every stage rather than dividing by zero. Pure, so the
        /// waterfall's proportion math is unit-testable without any view.
        static func proportion(ms: Double, total: Double) -> Double {
            guard total > 0 else { return 0 }
            return min(1, max(0, ms / total))
        }
    }

    /// Median end-to-end `totalMs` over the retained records, optionally dropping
    /// cold-start and/or optimistic samples first. Returns nil when nothing is left
    /// to median (no data, or every sample was excluded) so the caller can show an
    /// honest empty state rather than a fabricated 0.
    ///
    /// The speed card calls this with BOTH exclusions on: a cold start (first
    /// dictation after launch — pays the model load) and an optimistic insertion
    /// (raw text dropped before cleanup finished, so `totalMs` isn't the felt
    /// latency) are both unrepresentative of steady-state speed and would skew the
    /// grade. They're surfaced separately on the detail page instead.
    func medianTotalMs(excludingColdStart: Bool = false,
                       excludingOptimistic: Bool = false) -> Double? {
        Self.median(sampled(excludingColdStart: excludingColdStart,
                            excludingOptimistic: excludingOptimistic).map(\.totalMs))
    }

    /// Per-stage medians over the retained records, with the same optional
    /// exclusions as `medianTotalMs`. `.zero` when no sample survives the filter.
    func stageMedians(excludingColdStart: Bool = false,
                      excludingOptimistic: Bool = false) -> StageMedians {
        let rows = sampled(excludingColdStart: excludingColdStart,
                           excludingOptimistic: excludingOptimistic)
        guard !rows.isEmpty else { return .zero }
        return StageMedians(
            finalizeMs: Self.median(rows.map(\.finalizeMs)) ?? 0,
            reTxMs:     Self.median(rows.map(\.reTxMs)) ?? 0,
            cleanupMs:  Self.median(rows.map(\.cleanupMs)) ?? 0,
            insertMs:   Self.median(rows.map(\.insertMs)) ?? 0
        )
    }

    /// The most recent `count` records, newest FIRST (the store holds them
    /// newest-last, so this reverses a suffix). For the detail page's recent list.
    func recentSamples(_ count: Int) -> [Record] {
        Array(records.suffix(count).reversed())
    }

    /// The number of steady-state samples the grade is computed over — the count
    /// left after both exclusions. Drives the honest "median of your last N" line.
    var steadyStateSampleCount: Int {
        sampled(excludingColdStart: true, excludingOptimistic: true).count
    }

    /// The single cold-start sample, if this session recorded one and it's still in
    /// the rolling window. Shown as its own labeled row, never mixed into the median.
    var coldStartSample: Record? {
        records.last(where: { $0.coldStart })
    }

    /// The retained records after the requested exclusions, newest-last order kept.
    private func sampled(excludingColdStart: Bool,
                         excludingOptimistic: Bool) -> [Record] {
        records.filter { r in
            if excludingColdStart, r.coldStart { return false }
            if excludingOptimistic, r.optimistic { return false }
            return true
        }
    }

    /// The median of a set of values, or nil when empty. Even counts average the
    /// two middle samples. A pure helper — no I/O, safe to unit-test directly.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else { return }
        // Defensively hold to the cap in case a hand-edited file exceeds it.
        records = decoded.count > Self.maxRecords
            ? Array(decoded.suffix(Self.maxRecords))
            : decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
