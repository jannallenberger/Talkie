import Foundation

// Incrementally builds a meeting's summarizable "map" facts + graph candidates DURING
// the recording, chunk by chunk, so MeetingRecorder.stop() only pays for a final reduce
// instead of re-running the whole map phase over the complete transcript at stop time.
//
// A plain class guarded by an `NSLock`, NOT an actor -- mirroring `StreamingCleanup` /
// `TurnLog.add` exactly, not just "in shape". `ingest()` is genuinely synchronous and
// safe to call directly from the transcriber's `@Sendable` segment-handler closures (off
// the main actor), so the ordering-critical buffer append happens AT THE CALL SITE,
// before `ingest` returns -- no unstructured `Task` is needed to bridge into it. An
// earlier actor-based version required exactly that bridging Task per call, which gave
// no ordering guarantee between segments (unrelated Tasks reaching an actor's queue in
// creation order isn't promised) and no happens-before guarantee against a later
// `finish()` call racing a straggler's ingest -- both real, reviewer-caught bugs this
// shape closes by construction. Only the two genuinely async pieces -- `mapExcerpt` and
// `GraphLLMExtractor.extract` -- run in background Tasks, tracked and awaited IN ORDER at
// `finish()`, exactly like `StreamingCleanup.finishCleaned()`.
//
// Reuses MeetingSummarizer's existing mapExcerpt/reduceWithFallback/mapAll so the
// prompts, retry-on-transient-error logic, and guardrails are identical to the stop-time
// path this replaces -- only the SCHEDULING moves earlier.
final class MeetingDigestBuilder: @unchecked Sendable {
    private let summarizer: MeetingSummarizer
    private let graphExtractor: GraphLLMExtractor?
    private let lock = NSLock()

    /// One buffered, speaker-tagged (or bare -- see `ingest`) live segment, stamped with
    /// its audio-clock elapsed time so a sealed chunk can be joined in chronological
    /// order even when the two streams' segments arrive out of order (their recognizer
    /// sessions finalize independently, so wall-clock arrival order isn't guaranteed to
    /// match the audio clock). Guarded by `lock`.
    private var pendingBuffer: [(elapsed: TimeInterval, text: String)] = []
    private var pendingChars = 0
    private var excerptIndex = 0
    private var mapTasks: [Task<String, Never>] = []
    private var graphTasks: [Task<[ContextGraphExtractor.Candidate], Never>] = []
    /// Every distinct speaker heard so far. A meeting that's only ever heard "Me" (the
    /// common mic-only case) stays untagged -- matching `MeetingTranscriptRenderer`'s
    /// solo branch, which emits bare untagged prose for a single-speaker transcript --
    /// instead of always stamping "Me:"/"Them:" regardless of speaker count.
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
            // Bare text until a second speaker has actually been heard: a mic-only
            // meeting never sees `.them`, so this stays bare for the whole recording,
            // matching the renderer exactly. A genuine two-party call typically hears
            // the far end within the first couple of turns, so at most a few opening
            // lines go untagged before this switches on for the rest -- cosmetic, and
            // harmless either way for the map prompt's own bullet extraction.
            let tagged = seenSpeakers.count > 1
                ? ((speaker == .me ? "Me" : "Them") + ": " + t)
                : t
            pendingBuffer.append((elapsed, tagged))
            pendingChars += tagged.count + 1
            if pendingChars >= MeetingSummarizer.chunkChars, mapTasks.count < Self.maxSealedChunks {
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
        let excerpt = pendingBuffer.sorted { $0.elapsed < $1.elapsed }
            .map(\.text).joined(separator: " ")
        pendingBuffer.removeAll()
        pendingChars = 0
        excerptIndex += 1
        let index = excerptIndex
        let summarizer = self.summarizer
        mapTasks.append(Task<String, Never> {
            let facts = await summarizer.mapExcerpt(excerpt)
            return "Excerpt " + String(index) + ": " + facts
        })
        if let graphExtractor {
            graphTasks.append(Task<[ContextGraphExtractor.Candidate], Never> {
                await graphExtractor.extract(from: excerpt)
            })
        }
    }

    /// Seal whatever's left in the tail buffer, await every in-flight map/graph task IN
    /// ORDER (so the joined partials read in chronological order like mapAll's output
    /// does today), compress if the joined partials overflow (mirroring
    /// summarizeCondensed's own compression loop), and reduce to the final summary.
    /// Returns the same shape summarizeCondensed does, plus deduped graph candidates.
    func finish() async -> (summary: String?, condensed: String, graphCandidates: [ContextGraphExtractor.Candidate]) {
        // Short transcript: mirror summarizeCondensed's own direct-pass branch. A
        // transcript that never crossed one chunk during the whole recording
        // (excerptIndex == 0 -- ingest() never sealed a background chunk) skips the map
        // phase entirely and reduces the raw text directly. Without this, a short,
        // no-decision meeting's mapExcerpt call would legitimately answer "None" (it's
        // prompted to extract decisions/action items from an EXCERPT of a LARGER
        // meeting) and the final reduce would be writing "the summary" from that bare
        // sentinel instead of from the actual conversation.
        let (isShort, rawTail) = lock.withLock { () -> (Bool, String) in
            let short = excerptIndex == 0 && !pendingBuffer.isEmpty
                && pendingChars <= MeetingSummarizer.chunkChars
            let raw = pendingBuffer.sorted { $0.elapsed < $1.elapsed }
                .map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if short { pendingBuffer.removeAll(); pendingChars = 0 }
            return (short, raw)
        }
        if isShort {
            let summary = await summarizer.reduceWithFallback(rawTail)
            var seen = Set<String>()
            var candidates: [ContextGraphExtractor.Candidate] = []
            if let graphExtractor {
                for c in await graphExtractor.extract(from: rawTail) {
                    let key = c.kind.rawValue + "|" + c.displayName.lowercased()
                    if seen.insert(key).inserted { candidates.append(c) }
                }
            }
            return (summary, rawTail, candidates)
        }

        let snapshot = lock.withLock { () -> ([Task<String, Never>], [Task<[ContextGraphExtractor.Candidate], Never>]) in
            sealChunkLocked()
            return (mapTasks, graphTasks)
        }
        var partials: [String] = []
        for t in snapshot.0 { partials.append(await t.value) }
        var combined = partials.joined(separator: "\n\n")

        var compressionPasses = 0
        while combined.count > MeetingSummarizer.chunkChars, compressionPasses < 3 {
            combined = await summarizer.mapAll(combined)
            compressionPasses += 1
        }
        if combined.count > MeetingSummarizer.chunkChars {
            combined = String(combined.prefix(MeetingSummarizer.chunkChars))
        }
        let summary = await summarizer.reduceWithFallback(combined)

        var seen = Set<String>()
        var candidates: [ContextGraphExtractor.Candidate] = []
        for t in snapshot.1 {
            for c in await t.value {
                let key = c.kind.rawValue + "|" + c.displayName.lowercased()
                if seen.insert(key).inserted { candidates.append(c) }
            }
        }
        return (summary, combined, candidates)
    }

    /// Drop all in-flight work without awaiting it -- used when a recording is
    /// discarded (nothing transcribed) so background model calls for a note that will
    /// never be saved don't keep running pointlessly. Mirrors StreamingCleanup.cancel().
    func cancel() {
        let snapshot = lock.withLock { () -> ([Task<String, Never>], [Task<[ContextGraphExtractor.Candidate], Never>]) in
            let m = mapTasks, g = graphTasks
            mapTasks.removeAll()
            graphTasks.removeAll()
            return (m, g)
        }
        for t in snapshot.0 { t.cancel() }
        for t in snapshot.1 { t.cancel() }
    }
}
