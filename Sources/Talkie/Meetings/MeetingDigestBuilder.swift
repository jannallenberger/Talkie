import Foundation

// Incrementally extracts a meeting's context-graph candidates DURING the recording,
// chunk by chunk, so MeetingRecorder.stop() doesn't pay for the whole extraction pass
// at stop time.
//
// It used to also map each chunk to "decision / action item" facts that a final reduce
// turned into the summary. That path is gone (W1): the summary is now written from the
// FINAL, diarized transcript by `MeetingSummaryPipeline`, which reads every speaker turn
// with structured extraction and grounding. The live digest only feeds the graph.
//
// A plain class guarded by an `NSLock`, NOT an actor -- mirroring `StreamingCleanup` /
// `TurnLog.add`. `ingest()` is genuinely synchronous and safe to call directly from the
// transcriber's `@Sendable` segment-handler closures (off the main actor), so the
// ordering-critical buffer append happens AT THE CALL SITE. Only
// `GraphLLMExtractor.extract` runs in background Tasks, awaited IN ORDER at `finish()`.
final class MeetingDigestBuilder: @unchecked Sendable {
    private let summarizer: MeetingSummarizer
    private let graphExtractor: GraphLLMExtractor?
    private let lock = NSLock()

    /// One buffered, speaker-tagged (or bare -- see `ingest`) live segment, stamped with
    /// its audio-clock elapsed time so a sealed chunk can be joined in chronological
    /// order even when the two streams' segments arrive out of order (their recognizer
    /// sessions finalize independently, so wall-clock arrival order isn't guaranteed to
    /// match the audio clock). Guarded by `lock`.
    private struct Entry {
        let elapsed: TimeInterval
        let lane: MeetingSpeaker
        let text: String
        /// The diarized speaker label, set by `remapSpeakers`; nil = the lane label.
        var label: String?
    }
    private var pendingBuffer: [Entry] = []
    /// Set by `remapSpeakers`: tag every line (a diarized meeting has >= 2 people).
    private var tagAll = false
    private var pendingChars = 0
    private var excerptIndex = 0
    private var graphTasks: [Task<[ContextGraphExtractor.Candidate], Never>] = []
    /// Every distinct speaker heard so far. A meeting that's only ever heard "Me" (the
    /// common mic-only case) stays untagged in the digest: the summary model gains
    /// nothing from "Me:" on every line. (The saved transcript labels it all the same.)
    private var seenSpeakers: Set<MeetingSpeaker> = []

    /// Hard ceiling on LIVE map/graph-extract calls, mirroring `MeetingSummarizer`'s own
    /// `maxChunks` cap on `mapAll` (`Meeting.swift`) -- so a multi-hour meeting can't
    /// spin up an unbounded number of background model calls, one every ~4000 chars.
    /// Once the cap is hit, `ingest` stops sealing new chunks and keeps buffering; the
    /// (now unbounded) tail is sealed as a single excerpt at `finish()`, where
    /// `mapExcerpt`'s own recursive overflow-halving keeps it safe regardless of size.
    private static let maxSealedChunks = 16

    init(summarizer: MeetingSummarizer, graphExtractor: GraphLLMExtractor?) {
        self.summarizer = summarizer
        self.graphExtractor = graphExtractor
    }

    /// Feed one finalized, speaker-tagged live segment stamped with its audio-clock
    /// elapsed time. Cheap and genuinely synchronous -- safe to call directly from the
    /// transcriber's `@Sendable` segment handler with no `Task` wrapper (see the type's
    /// doc comment). Buffers until a chunk's worth has accumulated, then seals it
    /// (kicking off the map + graph-extract calls in the background) and keeps
    /// buffering the next one.
    func ingest(_ speaker: MeetingSpeaker, _ text: String, at elapsed: TimeInterval) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lock.withLock {
            seenSpeakers.insert(speaker)
            // Tags are applied when a chunk is sealed (`render`), not here, so the
            // diarization remap can still relabel everything that is buffered. Bare
            // text until a second speaker has actually been heard: a mic-only meeting
            // never sees `.them`, so it stays bare for the whole recording, matching
            // the renderer's solo branch.
            pendingBuffer.append(Entry(elapsed: elapsed, lane: speaker, text: t, label: nil))
            let tagged = (speaker == .me ? "Me" : "Them") + ": " + t // length estimate only
            pendingChars += tagged.count + 1
            if pendingChars >= MeetingSummarizer.chunkChars, excerptIndex < Self.maxSealedChunks {
                sealChunkLocked()
            }
        }
    }

    /// Seals the current buffer into a new excerpt and kicks off its map + graph-extract
    /// Tasks. Caller must hold `lock`.
    private func sealChunkLocked() {
        guard !pendingBuffer.isEmpty else { return }
        // Sort by audio-clock elapsed (not arrival order) before joining, so a sealed
        // excerpt interleaves the two speakers the same way the final persisted
        // transcript does (`MeetingTranscriptRenderer.render` also sorts by `elapsed`).
        let excerpt = renderPendingLocked()
        pendingBuffer.removeAll()
        pendingChars = 0
        excerptIndex += 1
        if let graphExtractor {
            graphTasks.append(Task<[ContextGraphExtractor.Candidate], Never> {
                await graphExtractor.extract(from: excerpt)
            })
        }
    }

    /// Seal whatever's left in the tail buffer and await every in-flight graph task IN
    /// ORDER, returning the de-duplicated candidates. `summary` is always nil and
    /// `condensed` empty: the summary is written from the final transcript (see the
    /// type comment). The shape is kept so callers read the same fields.
    func finish() async -> (summary: String?, condensed: String, graphCandidates: [ContextGraphExtractor.Candidate]) {
        let tasks = lock.withLock { () -> [Task<[ContextGraphExtractor.Candidate], Never>] in
            sealChunkLocked()
            return graphTasks
        }
        var seen = Set<String>()
        var candidates: [ContextGraphExtractor.Candidate] = []
        for t in tasks {
            for c in await t.value {
                let key = c.kind.rawValue + "|" + c.displayName.lowercased()
                if seen.insert(key).inserted { candidates.append(c) }
            }
        }
        return (nil, "", candidates)
    }

    /// The pending lines, in audio-clock order, tagged per `tagAll` / speakers heard.
    /// Caller must hold `lock`.
    private func renderPendingLocked() -> String {
        let tag = tagAll || seenSpeakers.count > 1
        return pendingBuffer.sorted { $0.elapsed < $1.elapsed }
            .map { tag ? ($0.label ?? $0.lane.rawValue) + ": " + $0.text : $0.text }
            .joined(separator: " ")
    }

    /// The tagged, ordered unsealed text (tests).
    func pendingTextForTesting() -> String { lock.withLock { renderPendingLocked() } }

    // MARK: Speaker remap (after diarization)

    /// Make the digest's unsealed tail speak the diarized labels instead of the lane
    /// labels (every buffered line must match a segment's start, else false and the
    /// caller drops the digest). Sealed excerpts are already in flight to the graph
    /// extractor and carry nothing the summary reads, so they need no remap.
    func remapSpeakers(_ map: DigestSpeakerRemap) async -> Bool {
        lock.withLock {
            var updated = pendingBuffer
            for i in updated.indices {
                guard let label = map.label(lane: updated[i].lane, at: updated[i].elapsed) else { return false }
                updated[i].label = label
            }
            pendingBuffer = updated
            tagAll = true
            return true
        }
    }

    private static func tokenRegex() -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "\\b(Me|Them)\\b")
    }

    static func mentions(_ name: String, in text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)\\b") else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func substituteLabels(in text: String, with subs: [String: String]) -> String {
        guard !subs.isEmpty, let re = tokenRegex() else { return text }
        var out = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range, in: out), let new = subs[String(out[r])] else { continue }
            out.replaceSubrange(r, with: new)
        }
        return out
    }

    /// Drop all in-flight work without awaiting it -- used when a recording is
    /// discarded (nothing transcribed) so background model calls for a note that will
    /// never be saved don't keep running pointlessly. Mirrors StreamingCleanup.cancel().
    func cancel() {
        let snapshot = lock.withLock { () -> [Task<[ContextGraphExtractor.Candidate], Never>] in
            let g = graphTasks
            graphTasks.removeAll()
            return g
        }
        for t in snapshot { t.cancel() }
    }
}
