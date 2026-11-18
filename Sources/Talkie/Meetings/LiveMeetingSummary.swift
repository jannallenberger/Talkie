import Foundation

// The meeting summary, built up DURING the recording (W2).
//
// Every interval the recorder hands the engine the transcript that can no longer
// change (single-language: segments that ended well before "now"; multi-language:
// the spans of finished language-vote windows) and the user's notes. The engine cuts
// that text exactly like the batch pipeline, extracts the chunks that are complete
// and not yet extracted (a few per pass, one call at a time, each time-boxed), and
// keeps the results keyed by content. At Stop the pipeline reuses every one whose
// text is unchanged and extracts only the rest (`MeetingSummaryPipeline.run(live:)`).
//
// Recognition comes first: the recorder starts a pass only when none is running, at
// background priority; a failed or skipped chunk is simply retried on a later pass or
// left for Stop.

/// What the recording panel's provisional "So far" list shows.
struct LiveSummarySnapshot: Equatable, Sendable {
    var topics: [String] = []
    var decisions: [String] = []
    var actions: [String] = []
    /// Chunks extracted so far (for the eval and the panel's empty state).
    var chunks = 0
    var isEmpty: Bool { topics.isEmpty && decisions.isEmpty && actions.isEmpty }

    /// At most this many entries per list: the panel is a glance, not the note.
    static let maxPerList = 5

    /// The most recent entries of each list (chronological), owners in front of tasks.
    static func from(_ merged: MergedNotes, chunks: Int) -> LiveSummarySnapshot {
        func last(_ items: [SummaryItem]) -> [SummaryItem] { Array(items.suffix(maxPerList)) }
        return LiveSummarySnapshot(
            topics: last(merged.topics).map(\.text),
            decisions: last(merged.decisions).map(\.text),
            actions: last(merged.actionItems).map { item in
                if let owner = item.owner, !owner.isEmpty { return "\(owner): \(item.text)" }
                return item.text
            },
            chunks: chunks)
    }
}

/// The live view's state, published only when a pass lands (never per second), so
/// only the "So far" list re-renders.
@MainActor
final class LiveSummaryState: ObservableObject {
    enum Phase: Equatable {
        /// No live summary for this recording (model unavailable, or a language setup
        /// whose text is only final at Stop).
        case off
        /// Single-language: waiting for enough settled conversation.
        case listening
        /// Multi-language: text is final only when a language window closes.
        case waitingForLanguageWindow
        case active
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var snapshot = LiveSummarySnapshot()
    /// The recording's text settles per language window (stays true once active).
    @Published private(set) var multilingual = false

    func reset(_ phase: Phase) {
        if self.phase != phase { self.phase = phase }
        let multi = phase == .waitingForLanguageWindow
        if phase != .off, multilingual != multi { multilingual = multi }
        if snapshot != LiveSummarySnapshot() { snapshot = LiveSummarySnapshot() }
    }

    func update(_ new: LiveSummarySnapshot) {
        guard phase != .off else { return }
        if !new.isEmpty, phase != .active { phase = .active }
        if new != snapshot { snapshot = new }
    }
}

actor LiveSummaryEngine {
    nonisolated let pipeline: MeetingSummaryPipeline
    private var cache = LiveChunkCache()
    /// Failed attempts per chunk content; after `maxFailures` the chunk is left for Stop.
    private var failures: [String: Int] = [:]
    private var stopped = false
    private(set) var calls = 0

    /// Most extraction calls one pass makes (a pass must never run long).
    static let maxCallsPerPass = 3
    static let maxFailures = 2
    /// Live calls get a tighter bound than at Stop: a wedged call must not hold the
    /// model for long while the meeting is still running.
    static let livePerCallSeconds: Double = 60

    init(model: any MeetingSummaryModel) {
        var p = MeetingSummaryPipeline(model: model)
        p.perCallSeconds = Self.livePerCallSeconds
        pipeline = p
    }

    init(pipeline: MeetingSummaryPipeline) { self.pipeline = pipeline }

    /// No new calls after this; the one in flight finishes and is kept.
    func stop() { stopped = true }

    /// The extractions so far, for Stop.
    func results() -> LiveChunkCache { cache }

    /// One interval: cut the stable text (segments ending by `stableUntil`) into
    /// chunks, extract up to `maxCalls` complete chunks that have no current result,
    /// and return the provisional merge of everything extracted. Nil when there is
    /// not enough settled text yet (shorter than a long-form meeting).
    func pass(segments: [MeetingSegment], stableUntil: Double, notes: [MeetingNote],
              maxCalls: Int = maxCallsPerPass) async -> LiveSummarySnapshot? {
        guard !stopped, pipeline.model.isAvailable else { return nil }
        let stable = segments.filter { $0.end <= stableUntil }
        guard !stable.isEmpty else { return nil }
        let transcript = MeetingTranscriptRenderer.render(segments: stable)
        let language = SummaryLanguage.detect(transcript: transcript)
        // Below the long-form threshold the final note is prose from the whole text.
        guard !SummaryRenderer.isShort(words: SummaryRenderer.wordCount(transcript, language: language)) else { return nil }
        let units = SummaryUnits.dropEchoes(SummaryUnits.build(transcript: "", segments: stable), language: language)
        let speakers = SummaryUnits.showsSpeakers(units)
        let entries = cache.entries(language: language.code)
        let plan = SummaryChunkPlanner.plan(units, cache: entries, budgetChars: pipeline.chunkBudgetChars,
                                            speakers: speakers)
        let hints = NoteHints.assign(notes, chunks: plan.map(\.units))
        var fresh: [Int: [(chunk: [SummaryUnit], notes: ChunkNotes)]] = [:]
        var made = 0
        for i in plan.indices where i < plan.count - 1 {
            let hint = SummaryPrompts.noteHint(language, notes: hints[i] ?? [])
            if let c = plan[i].cached, entries[c].hint == hint, entries[c].speakers == speakers { continue }
            guard made < maxCalls, !stopped else { break }
            let key = plan[i].units.map(LiveChunkCache.key).joined(separator: "\u{1E}")
            guard failures[key, default: 0] < Self.maxFailures else { continue }
            made += 1
            calls += 1
            let (pieces, _) = await pipeline.extractAdaptive(plan[i].units, language: language, speakers: speakers,
                                                             hint: hint, depth: 0)
            if pieces.isEmpty { failures[key, default: 0] += 1; continue }
            cache.store(.init(units: plan[i].units, pieces: pieces, language: language.code,
                              speakers: speakers, hint: hint))
            fresh[i] = pieces
        }
        var gathered: [(chunk: [SummaryUnit], notes: ChunkNotes)] = []
        var chunks = 0
        for i in plan.indices {
            if let f = fresh[i] { gathered += f; chunks += 1 }
            else if let c = plan[i].cached { gathered += SummaryChunkPlanner.remap(entries[c], onto: plan[i].units); chunks += 1 }
        }
        let merged = SummaryMerger.merge(gathered, language: language, speakers: speakers)
        return LiveSummarySnapshot.from(merged, chunks: chunks)
    }
}

/// When live text counts as final, per recording setup.
enum LiveSummaryTiming {
    /// Single-language: a finalized segment can still arrive late (the far end lags,
    /// a long utterance finalizes at its pause), so only text that ended this long
    /// before "now" is treated as stable. A late arrival inside an extracted chunk is
    /// harmless: the chunk's content changes and Stop re-extracts it.
    static let singleLanguageLag: Double = 45
    /// Seconds between live passes.
    static let interval: Double = 60

    static func stableUntil(elapsed: Double) -> Double { max(0, elapsed - singleLanguageLag) }
}
