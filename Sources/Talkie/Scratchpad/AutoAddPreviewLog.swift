import Foundation

/// **L2-b — the "added by Talkie" auto-add lane, in LOG-ONLY / PREVIEW mode.**
///
/// This is a *calibration artifact*, NOT the live feature. It records, for every
/// extracted commitment, what `AutoAddGate` WOULD decide — the verdict plus the
/// reasons each condition passed or failed — so Jann can tune the gate's threshold
/// against real dictations before a single line is ever auto-added. It deliberately
/// does **not**:
///   • call `ScratchpadStore.addLine` / `suggest` (it writes to its OWN file only),
///   • surface anything in the UI (no card, no "added by Talkie" chip, no badge),
///   • change any user-visible behavior.
/// The live auto-add lane is a separate follow-up that ships only after Jann approves
/// the threshold these logs inform.
///
/// **Honesty about what it stores.** Unlike `LatencyStore` (pure numbers, exempt from
/// true-delete), this log stores the commitment TEXT — it is content-derived. So it
/// MUST honor true-delete and must not become an un-purgeable transcript store. It
/// does that by carrying each record's `sourceDictationID` and joining the existing
/// purge cascade in `MemoryView`:
///   • deleting one dictation → `purge(sourceID:)` drops that dictation's records,
///   • "Clear everything"      → `purgeAllDictationSourced()` drops all of them,
/// exactly mirroring how `ScratchpadStore` treats its rescued lines. Records with no
/// `sourceDictationID` (never produced by the live seam today, but tolerated) are
/// treated as ephemeral and are cleared by `purgeAll` / `reset`.
///
/// A "Private" app (I1 `neverStore`) produces NO records at all — the caller does not
/// even run the gate for a `neverStore` dictation, so nothing about a Private session
/// is ever written here (verified at the AppDelegate ingest seam).
///
/// `@MainActor`, `ObservableObject`, constructor-injected like the other stores.
/// Rolling cap of `maxRecords`; a corrupt/missing file decodes to empty.
@MainActor
final class AutoAddPreviewLog: ObservableObject {

    /// One gate evaluation. Holds the commitment text (hence content-derived, hence
    /// purgeable), the metadata needed to interpret the decision, and the gate's
    /// verdict + reasons.
    struct Record: Codable, Equatable, Sendable {
        /// Wall-clock time the record was written (`Date().timeIntervalSince1970`).
        var unixTime: Double
        /// The commitment clause the gate judged. This is the content that makes the
        /// record purgeable.
        var commitmentText: String
        /// Bundle id of the app the dictation went into, or `nil` when context
        /// awareness was off (the fail-closed case — still logged, on purpose).
        var frontAppBundleID: String?
        /// Which extractor produced the commitment (`"llmExtractor"` / `"heuristic"`).
        var source: String
        /// What the gate WOULD do — the whole reason this log exists.
        var wouldSuggest: Bool
        /// The per-condition pass/fail reasons from the gate, for calibration.
        var reasons: [String]
        /// The dictation this commitment came from. Drives true-delete: deleting that
        /// dictation purges this record. `nil` only for non-dictation callers (none
        /// today) — those are treated as ephemeral by `purgeAll`.
        var sourceDictationID: String?

        // Tolerant decode so an older/hand-edited file still loads.
        init(
            unixTime: Double,
            commitmentText: String,
            frontAppBundleID: String?,
            source: String,
            wouldSuggest: Bool,
            reasons: [String],
            sourceDictationID: String?
        ) {
            self.unixTime = unixTime
            self.commitmentText = commitmentText
            self.frontAppBundleID = frontAppBundleID
            self.source = source
            self.wouldSuggest = wouldSuggest
            self.reasons = reasons
            self.sourceDictationID = sourceDictationID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            unixTime = try c.decode(Double.self, forKey: .unixTime)
            commitmentText = try c.decodeIfPresent(String.self, forKey: .commitmentText) ?? ""
            frontAppBundleID = try c.decodeIfPresent(String.self, forKey: .frontAppBundleID)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            wouldSuggest = try c.decodeIfPresent(Bool.self, forKey: .wouldSuggest) ?? false
            reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
            sourceDictationID = try c.decodeIfPresent(String.self, forKey: .sourceDictationID)
        }
    }

    /// Newest last. Held to `maxRecords` — the oldest is dropped on append.
    @Published private(set) var records: [Record] = []

    /// Rolling cap. ~200 keeps a meaningful calibration window without the file
    /// growing unbounded; the oldest entries fall off first.
    static let maxRecords = 200

    private let fileURL: URL

    /// Default init uses `scratchpad_ai_preview.json` under Application Support —
    /// alongside `scratchpad.json`, but a distinct file (this is calibration data,
    /// never the live scratchpad).
    convenience init() {
        self.init(fileURL: AppPaths.supportDirectory().appendingPathComponent("scratchpad_ai_preview.json"))
    }

    /// Constructor injection of the backing file — tests point this at a temp URL so
    /// they never touch a developer's real calibration log.
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Record

    /// Append one gate evaluation, dropping the oldest if over the cap, then persist.
    /// This is the ONLY write path — it writes to `scratchpad_ai_preview.json` and
    /// nothing else. It never calls into `ScratchpadStore`.
    func record(
        commitmentText: String,
        frontAppBundleID: String?,
        source: AutoAddGate.CommitmentSource,
        decision: AutoAddGate.Decision,
        sourceDictationID: String?,
        nowUnix: Double = Date().timeIntervalSince1970
    ) {
        records.append(Record(
            unixTime: nowUnix,
            commitmentText: commitmentText,
            frontAppBundleID: frontAppBundleID,
            source: source.rawValue,
            wouldSuggest: decision.suggest,
            reasons: decision.reasons,
            sourceDictationID: sourceDictationID
        ))
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
        save()
    }

    // MARK: - True-delete (paired with MemoryView, mirrors ScratchpadStore)

    /// Remove every record derived from one dictation — called when that dictation is
    /// deleted from history, so a deleted transcript's commitments can't linger here.
    func purge(sourceID: String) {
        guard records.contains(where: { $0.sourceDictationID == sourceID }) else { return }
        records.removeAll { $0.sourceDictationID == sourceID }
        save()
    }

    /// Remove every dictation-sourced record. Called from "Clear everything": these
    /// records are extracted from dictation history and go with it. (Records with no
    /// `sourceDictationID` — none are produced today — are handled by `purgeAll`.)
    func purgeAllDictationSourced() {
        guard records.contains(where: { $0.sourceDictationID != nil }) else { return }
        records.removeAll { $0.sourceDictationID != nil }
        save()
    }

    /// Wipe the entire calibration log (used by resets/tests).
    func purgeAll() {
        guard !records.isEmpty else { return }
        records = []
        save()
    }

    func reset() { purgeAll() }

    // MARK: - Persistence

    private func load() {
        guard let decoded = StoreLoad.loadJSONWithQuarantine([Record].self, from: fileURL) else { return }
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
