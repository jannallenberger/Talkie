import Foundation
import FoundationModels
import os

/// One timed transcript segment of a meeting: who spoke, the audio-clock span
/// (seconds from recording start), and the text. Lives only in the index JSON so
/// captions / click-to-play / chapters have real timings to stand on — the rendered
/// transcript string and the exported `.md` stay byte-identical without it. Optional
/// per-meeting (`Meeting.segments`) so pre-D2 notes decode unchanged.
struct MeetingSegment: Codable, Hashable, Sendable {
    /// The speaker's raw label ("Me" / "Them" / "Imported"), matching `participants`.
    var speaker: String
    /// Audio-clock start/end in seconds from the recording's start.
    var start: Double
    var end: Double
    var text: String
}

/// One topic boundary in a meeting: a short section-heading label and the
/// audio-clock offset (seconds from recording start) at which it was *accepted*
/// by the live subtopic engine. The timestamp is honestly the accept time, which
/// lags the true topic shift by the engine's confidence + hysteresis window
/// (~24s+ by design) — it is not backdated to guess where the shift "really"
/// began. Built only from live recordings; never inferred for imported files or
/// retrofitted onto old meetings. Lives only in the index JSON (like `segments`),
/// so the rendered transcript stays byte-identical without it.
struct Chapter: Codable, Hashable, Sendable {
    /// The accepted topic label (original casing), e.g. "Budget review".
    var title: String
    /// Seconds from the recording's start at which this topic was accepted.
    var start: Double
}

extension Meeting {
    /// Whether this meeting can offer click-to-play: it has BOTH timed segments (D2)
    /// AND at least one kept audio file (D9). Pre-D2 notes, and any meeting whose audio
    /// wasn't kept, return false — so the playback UI never appears with nothing behind
    /// it. Pure so the row can gate on it and tests can assert it.
    var hasPlayableAudio: Bool {
        guard let segments, !segments.isEmpty else { return false }
        guard let audioFiles, !audioFiles.isEmpty else { return false }
        return true
    }

    /// The audio file basename that plays a given segment's speaker, or a single-file
    /// fallback. Resolution, in order:
    /// 1. An exact speaker match (`audioFiles["Them"]` for a "Them" segment) — the
    ///    two-stream case where Me and Them are separate files.
    /// 2. When there's exactly one kept file, that file — the solo/import case where
    ///    every segment plays the same recording regardless of its speaker label.
    /// 3. Otherwise nil (a speaker with no matching file and no unambiguous single
    ///    file), so the row can disable that segment's play button rather than seek the
    ///    wrong stream. Pure/`nonisolated` for direct unit testing.
    nonisolated static func audioFileName(
        forSpeaker speaker: String, in audioFiles: [String: String]?
    ) -> String? {
        guard let audioFiles, !audioFiles.isEmpty else { return nil }
        if let exact = audioFiles[speaker] { return exact }
        if audioFiles.count == 1, let only = audioFiles.values.first { return only }
        return nil
    }

    /// Index of the segment that is "playing" at audio-clock time `t` (seconds) for the
    /// file named `fileName`, or nil when none is. A segment is active from its `start`
    /// until the next same-file segment's `start` (so the highlight moves continuously,
    /// not just during each segment's literal span — real transcripts have gaps), and
    /// only segments whose speaker maps to `fileName` are considered (two-stream files
    /// don't highlight each other's turns). Returns the LAST segment once `t` passes its
    /// start. Pure/`nonisolated` so the timer-driven highlight is unit-testable without
    /// an `AVAudioPlayer`.
    nonisolated static func activeSegmentIndex(
        at t: Double, segments: [MeetingSegment], fileName: String, audioFiles: [String: String]?
    ) -> Int? {
        // The subset of segments that belong to this file, keeping original indices so
        // the caller can map the result straight back onto `segments`.
        let mine = segments.enumerated().filter {
            audioFileName(forSpeaker: $0.element.speaker, in: audioFiles) == fileName
        }
        guard !mine.isEmpty else { return nil }
        var current: Int?
        for entry in mine {
            if t + 0.001 >= entry.element.start { current = entry.offset } else { break }
        }
        return current
    }

    /// Render the "## Chapters" note section — `[mm:ss] Topic` bullets sorted by
    /// time — or `""` when there is nothing to show. A meeting must have shifted
    /// topics at least once (≥ 2 chapters) to earn the section: a single chapter is
    /// noise, so it is omitted (matching the pill, which shows one steady topic).
    /// Pure and `nonisolated static` so it's unit-testable and reused by
    /// `MeetingStore.writeMarkdown`. Timecodes reuse `MeetingTranscriptRenderer`.
    static func chaptersMarkdown(_ chapters: [Chapter]?) -> String {
        guard let chapters, chapters.count >= 2 else { return "" }
        let bullets = chapters
            .sorted { $0.start < $1.start }
            .map { "- [\(MeetingTranscriptRenderer.timecode($0.start))] \($0.title)" }
            .joined(separator: "\n")
        return "## Chapters\n\n\(bullets)"
    }
}

/// One recorded meeting: when, how long, the transcript, and an on-device summary.
struct Meeting: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var startUnix: Double
    var durationSec: Double
    var transcript: String
    var summary: String
    /// Who appears in the transcript — `[Me]` for a solo recording, `[Me, Them]`
    /// when the far end was captured too.
    var participants: [String] = ["Me"]
    /// How the audio was captured (e.g. "talkie (mic + system audio)").
    var source: String = "talkie (mic-only)"
    /// The `.md` file written into ~/Talkie Meetings/.
    var fileName: String
    /// Per-segment audio-clock timings (captions / click-to-play / chapters). Nil for
    /// notes saved before D2 and for recovered/notes-only meetings that have no timed
    /// transcript. Evicted with the meeting by the 200-entry retention cap, so this
    /// never grows `meetings.json` unboundedly.
    var segments: [MeetingSegment]? = nil
    /// Topic boundaries derived from the live subtopic engine (D8), in accept order.
    /// Nil for notes saved before D8, for imported files, and for recordings where
    /// the live-topic engine was off or never accepted a topic. Evicted with the
    /// meeting like `segments`, so it never grows `meetings.json` unboundedly.
    var chapters: [Chapter]? = nil
    /// Audio kept beside this meeting's note (D9), keyed by the speaker/source label
    /// → the audio file's basename inside ~/Talkie Meetings/ (a visible, files-you-own
    /// folder, NEVER Application Support). An import records `["Imported": "<stem>.<ext>"]`
    /// (the original file copied, not re-encoded); a live recording with "Keep audio"
    /// on records `["Me": "<stem>-me.m4a"]` and, when the far end was captured,
    /// `"Them": "<stem>-them.m4a"`. Nil for every meeting recorded before D9, and for
    /// recordings made with the (default-off) keep-audio toggle disabled — so the
    /// common case persists no call audio and old notes decode unchanged. The files
    /// are removed with the meeting by `MeetingStore.delete`, and clicking a transcript
    /// segment seeks the matching stream's file to that moment (`MeetingsView`).
    var audioFiles: [String: String]? = nil

    var date: Date { Date(timeIntervalSince1970: startUnix) }
}

extension Meeting {
    /// Custom decode so notes saved before Phase 2 (no `participants` / `source`
    /// keys), before D2 (no `segments` key), and before D8 (no `chapters` key) still
    /// load — every added field uses `decodeIfPresent`, so old JSON decodes unchanged
    /// and an older app build simply ignores the newer key. Declared in an extension
    /// so the memberwise initializer is still synthesized for callers.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        startUnix = try c.decode(Double.self, forKey: .startUnix)
        durationSec = try c.decode(Double.self, forKey: .durationSec)
        transcript = try c.decode(String.self, forKey: .transcript)
        summary = try c.decode(String.self, forKey: .summary)
        participants = try c.decodeIfPresent([String].self, forKey: .participants) ?? ["Me"]
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "talkie (mic-only)"
        fileName = try c.decode(String.self, forKey: .fileName)
        segments = try c.decodeIfPresent([MeetingSegment].self, forKey: .segments)
        chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters)
        audioFiles = try c.decodeIfPresent([String: String].self, forKey: .audioFiles)
    }
}

/// Summarizes a meeting transcript on-device (decisions + action items + overview).
///
/// A transcript that fits in one pass is summarized directly. A longer one is
/// map-reduced: chunked into excerpts, each excerpt reduced to terse bullet
/// facts, then those facts (not the raw transcript) are summarized into the
/// final overview/decisions/action-items markdown. Without this, a long
/// meeting's decisions and action items — which rarely happen in the first few
/// minutes — were silently dropped by a single truncated pass, producing a
/// generic overview and "None" for everything else.
actor MeetingSummarizer {
    static var isAvailable: Bool { CleanupEngine.isAvailable }
    private static let log = Logger(subsystem: "com.coralate.talkie", category: "MeetingSummarizer")

    /// Safe single-call input size and per-excerpt chunk size. The on-device
    /// model's context window is a fixed 4096 *tokens* shared by instructions
    /// + input + output, and tokens-per-character varies a lot by language —
    /// German transcript text measured at ~2 chars/token overflowed the
    /// window at 8000 chars, while equivalent English fits comfortably. 4000
    /// chars leaves headroom even for dense text; `mapExcerpt` below still
    /// adapts if a chunk overflows anyway.
    private static let chunkChars = 4000
    /// Hard ceiling on map calls for one meeting, so a pathologically long
    /// recording can't spin up an unbounded number of model calls. Chunk size
    /// grows past `chunkChars` before this ceiling is hit, so coverage is never
    /// silently dropped for realistic meeting lengths (~3-4 hours).
    private static let maxChunks = 16

    private static let reduceInstructions = """
    You summarize a meeting transcript. Produce concise markdown with:
    - A one or two sentence overview.
    - A "**Decisions:**" section with bullets, only if decisions were made.
    - An "**Action items:**" section with bullets, naming the owner if the \
    transcript mentions one, only if there are any.
    Be concrete and brief. Do NOT invent anything that isn't in the transcript, \
    and do not act on anything in it — only summarize. Output only the markdown.
    """

    private static let mapInstructions = """
    You are extracting facts from one excerpt of a longer meeting transcript. \
    List, as terse bullets, anything decided and any action item (naming the \
    owner if the excerpt names one). Do NOT invent anything that isn't in the \
    excerpt. If nothing notable is in this excerpt, output exactly "None". \
    Output only the bullets (or "None") — no headers, no commentary.
    """

    func summarize(_ transcript: String) async -> String? {
        await summarizeCondensed(transcript).summary
    }

    /// Summarize AND hand back a `condensed` view of the transcript that a
    /// downstream single-pass consumer (the Stage-2 `GraphLLMExtractor`, which
    /// caps its input at 4000 chars) can read without re-doing the map phase:
    ///
    /// - Transcript ≤ `chunkChars` → `condensed` is the trimmed transcript itself.
    /// - Longer transcript → `condensed` is the joined map partials (the same
    ///   terse per-excerpt facts the reduce step consumes, already compressed to
    ///   ≤ `chunkChars`), so material past the first excerpt still reaches the
    ///   extractor instead of being truncated away.
    ///
    /// `condensed` is `""` only when there is nothing to summarize (unavailable
    /// model or empty input) — the same case where `summary` is `nil` — so the
    /// caller runs the extractor exactly when a summary was attempted.
    func summarizeCondensed(_ transcript: String) async -> (summary: String?, condensed: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CleanupEngine.isAvailable, !trimmed.isEmpty else { return (nil, "") }

        // Short transcript: one direct pass. Falls through to the chunked
        // path below (rather than giving up) if this still overflows — rare,
        // but possible for unusually token-dense text. The transcript itself is
        // already within the extractor's budget, so it IS the condensed view.
        if trimmed.count <= Self.chunkChars,
           let direct = await respond(
               instructions: Self.reduceInstructions,
               prompt: "Transcript:\n\n\(trimmed)\n\nWrite the summary."
           ) {
            return (direct, trimmed)
        }

        var combined = await mapAll(trimmed)
        // The on-device model doesn't always keep extraction as terse as
        // asked; if the gathered facts are themselves too long to reduce
        // safely, compress them again (bounded, so this can't loop forever).
        var compressionPasses = 0
        while combined.count > Self.chunkChars, compressionPasses < 3 {
            combined = await mapAll(combined)
            compressionPasses += 1
        }
        // Guarantee the final call's input is within the size that's tested
        // safe, rather than risk the whole map phase's work being silently
        // discarded by one last context-window overflow. The same bounded
        // `combined` is what we hand back as `condensed`.
        if combined.count > Self.chunkChars {
            combined = String(combined.prefix(Self.chunkChars))
        }
        let result = await reduceWithFallback(combined)
        if result == nil {
            Self.log.error("summarize: gave up after full map-reduce pass over \(trimmed.count) chars")
        }
        // Even if the final reduce failed, `combined` still holds the map
        // partials — hand them to the extractor so a failed overview doesn't
        // also starve the graph.
        return (result, combined)
    }

    /// Reduce `notes` into the final summary. Character count alone doesn't
    /// guarantee this fits the model's *token* window — the on-device model
    /// occasionally emits degenerate, highly repetitive text for one excerpt
    /// (e.g. a run-on list that keeps appending "and X" clauses) that tokenizes
    /// far denser than normal prose, overflowing even well under `chunkChars`.
    /// If that happens, shrink and retry rather than discard the whole map
    /// phase's work — this can't loop forever since `notes` strictly shrinks.
    private func reduceWithFallback(_ notes: String) async -> String? {
        do {
            return try await rawRespond(
                instructions: Self.reduceInstructions,
                prompt: "Notes gathered from the full transcript, in chronological order:\n\n\(notes)\n\nWrite the summary."
            )
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error, notes.count > 500 else { return nil }
            return await reduceWithFallback(String(notes[..<Self.splitPoint(notes)]))
        } catch {
            return nil
        }
    }

    /// Chunk `text` and map each piece to terse facts, joined back together.
    private func mapAll(_ text: String) async -> String {
        let chunks = Self.chunk(text, maxChars: Self.chunkChars, maxChunks: Self.maxChunks)
        var notes: [String] = []
        for (index, excerpt) in chunks.enumerated() {
            notes.append("Excerpt \(index + 1): \(await mapExcerpt(excerpt))")
        }
        return notes.joined(separator: "\n\n")
    }

    /// Extracts terse facts from one excerpt. If the excerpt alone overflows
    /// the model's context window — the per-chunk budget above is sized for
    /// the worst language observed, not a guarantee — splits it in half and
    /// maps each half, halving again if needed, instead of losing the excerpt.
    private func mapExcerpt(_ excerpt: String) async -> String {
        do {
            let text = try await rawRespond(instructions: Self.mapInstructions,
                                             prompt: "Excerpt:\n\n\(excerpt)\n\nList the facts.")
            return text ?? "None"
        } catch let error as LanguageModelSession.GenerationError {
            Self.log.error("mapExcerpt: GenerationError on \(excerpt.count) chars: \(String(describing: error), privacy: .public)")
            guard case .exceededContextWindowSize = error, excerpt.count > 400 else { return "None" }
            let mid = Self.splitPoint(excerpt)
            let first = await mapExcerpt(String(excerpt[..<mid]))
            let second = await mapExcerpt(String(excerpt[mid...]))
            let joined = [first, second].filter { $0 != "None" }.joined(separator: "\n")
            return joined.isEmpty ? "None" : joined
        } catch {
            Self.log.error("mapExcerpt: OTHER error on \(excerpt.count) chars: \(String(describing: error), privacy: .public)")
            return "None"
        }
    }

    private func respond(instructions: String, prompt: String) async -> String? {
        do {
            return try await rawRespond(instructions: instructions, prompt: prompt)
        } catch {
            Self.log.error("respond: threw on \(prompt.count)-char prompt: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A meeting summary makes many consecutive on-device model calls (14+
    /// chunks isn't unusual for an hour-long meeting), which surfaced
    /// `.rateLimited` / `.concurrentRequests` / `.assetsUnavailable` — transient
    /// resource contention (e.g. another app also using Apple Intelligence at
    /// that instant), not a problem with the content. Retrying after a short
    /// backoff clears these; content errors like `exceededContextWindowSize`
    /// or `guardrailViolation` are NOT retried since retrying can't fix them.
    private func rawRespond(instructions: String, prompt: String) async throws -> String? {
        var lastTransientError: LanguageModelSession.GenerationError?
        for attempt in 0...3 {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(sampling: .greedy, temperature: 0.3)
                let response = try await session.respond(to: prompt, options: options)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .rateLimited, .concurrentRequests, .assetsUnavailable:
                    lastTransientError = error
                    Self.log.notice("rawRespond: transient \(String(describing: error)), attempt \(attempt)/3")
                    try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
                default:
                    throw error
                }
            }
        }
        throw lastTransientError!
    }

    /// Greedily pack lines into chunks, sized so the whole text fits in at
    /// most `maxChunks` pieces (growing past `maxChars` only if it must) — so
    /// a long meeting gets every excerpt mapped rather than losing its tail.
    private static func chunk(_ text: String, maxChars: Int, maxChunks: Int) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let size = max(maxChars, Int((Double(text.count) / Double(maxChunks)).rounded(.up)))
        var chunks: [String] = []
        var current = ""
        for line in lines {
            let candidate = current.isEmpty ? String(line) : current + "\n" + line
            if candidate.count > size, !current.isEmpty {
                chunks.append(current)
                current = String(line)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// The single-pass input budget (chars), exposed so a downstream consumer
    /// (the Stage-2 graph extractor) can size its own chunks to match the size
    /// this summarizer already treats as context-window-safe.
    nonisolated static var singlePassCharBudget: Int { chunkChars }

    /// Split a body into ≤`singlePassCharBudget`-char pieces for a downstream
    /// single-pass consumer, reusing the SAME greedy line-packing chunker the map
    /// phase uses. `nonisolated` + pure so callers off the actor (the recorder's
    /// finalize) can chunk `condensed` for `GraphLLMExtractor` without an actor
    /// hop. A body already within budget returns a single chunk unchanged; an
    /// empty body returns `[]`.
    nonisolated static func chunkForSinglePass(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return chunk(text, maxChars: chunkChars, maxChunks: maxChunks)
    }

    /// A split point near the middle of `text`, preferring a nearby newline
    /// so the emergency fallback split doesn't cut a sentence in half.
    private static func splitPoint(_ text: String) -> String.Index {
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        if let newline = text[..<mid].lastIndex(of: "\n") { return text.index(after: newline) }
        return mid
    }
}

/// Serializes the encode+write off the main actor so mutating a meeting (adding
/// one, editing a transcript, renaming, deleting) never blocks the UI encoding
/// the full retained index — up to `MeetingStore.maxRetainedMeetings` meetings
/// with full transcripts and timed segments inlined, which can run 10-30 MB.
/// Each `write` carries a monotonic `generation`; a write whose generation is
/// already stale (a newer snapshot arrived first) is dropped, so a burst of
/// saves collapses to the last state and writes can't reorder. The `[Meeting]`
/// snapshot is a value type (Sendable — every stored field is a Sendable value
/// type, so `Meeting` gets implicit `Sendable` conformance same as
/// `DictationEntry`), so handing it across the actor boundary copies, never
/// shares. Mirrors `HistoryFileWriter` exactly, except it does NOT add
/// `.sortedKeys` to the encoder — that would change the on-disk byte layout of
/// `meetings.json`, and the fix here is scoped to moving the existing encode
/// off the main actor, not to changing its output.
actor MeetingIndexWriter {
    private let fileURL: URL
    private var latestWritten = 0

    init(fileURL: URL) { self.fileURL = fileURL }

    func write(_ meetings: [Meeting], generation: Int) {
        guard generation > latestWritten else { return }
        latestWritten = generation
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Persisted list of meetings + their markdown files in ~/Talkie Meetings/.
@MainActor
final class MeetingStore: ObservableObject {
    /// Hard retention cap: the index inlines full data (incl. transcripts) only for
    /// the most-recent N meetings. Beyond N, the oldest are EVICTED from the index —
    /// the `.md` files in the meetings folder stay as the durable copy (and a corrupt
    /// index self-heals from them, see `load`). This bounds `meetings.json` growth and
    /// the O(total) cost of every `save`. We do NOT lazily read an external `.md` to
    /// re-inflate evicted entries: PR #26 lets meetings export to arbitrary Obsidian
    /// vaults, so the `.md` is not always at a known internal path — the index must be
    /// self-sufficient.
    static let maxRetainedMeetings = 200

    @Published private(set) var meetings: [Meeting] = [] // newest first

    private let indexURL: URL
    private let meetingsDirectoryURL: URL

    /// Off-main JSON encode + atomic write. Callers are unchanged: `save()` still
    /// looks synchronous to them, but it only schedules — the cost moves here.
    private let writer: MeetingIndexWriter
    /// Debounce so a burst of mutations (e.g. the retention-cap sweep during a
    /// bulk import) coalesces into one disk write.
    private let saveDebounce: Duration = .milliseconds(250)
    private var pendingSave: Task<Void, Never>?
    /// Monotonic save token; the writer drops any write older than the newest.
    private var saveGeneration = 0

    init(supportDirectory: URL = AppPaths.supportDirectory(),
         meetingsDirectory: URL = AppPaths.meetingsDirectory()) {
        let url = supportDirectory.appendingPathComponent("meetings.json")
        indexURL = url
        meetingsDirectoryURL = meetingsDirectory
        writer = MeetingIndexWriter(fileURL: url)
        load()
    }

    var folderURL: URL { meetingsDirectoryURL }

    func add(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
        writeMarkdown(meeting)
        enforceRetentionCap()
        save()
    }

    func delete(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
        // Overwrite-then-delete the `.md` transcript (best effort, see FileShredder)
        // rather than a plain unlink that leaves the transcript bytes intact-but-
        // unlinked on disk. The graph provenance sourced from this meeting is purged at
        // the caller (MeetingsView) so this store stays single-purpose.
        let url = meetingsDirectoryURL.appendingPathComponent(meeting.fileName)
        FileShredder.shred(url)
        // Delete honesty (D9): a meeting that kept its audio beside the note must not
        // leave that audio behind when the note is deleted — the whole point of the
        // feature is user-owned files, so removing the meeting removes ALL of them.
        // Only bare basenames are stored, so resolve each inside the meetings folder;
        // a value that somehow isn't a plain filename (contains a path separator) is
        // ignored rather than allowed to escape the folder. Best-effort + failure-
        // tolerant, exactly like the `.md`: a partial m4a from a crashed recording, or
        // an already-missing file, simply falls through FileShredder's unlink.
        for name in (meeting.audioFiles?.values).map(Array.init) ?? []
        where !name.isEmpty && !name.contains("/") {
            FileShredder.shred(meetingsDirectoryURL.appendingPathComponent(name))
        }
        save()
    }

    /// Replace an existing meeting in place (same id/position) — used to store a
    /// freshly regenerated summary — and rewrite its markdown copy to match.
    func update(_ meeting: Meeting) {
        guard let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[index] = meeting
        writeMarkdown(meeting)
        save()
    }

    /// L15-b: rename a meeting, matched by full id or an 8-char id prefix (how the MCP
    /// tools surface ids). `fileName` is stored (not title-derived), so this rewrites
    /// the SAME `.md` with the new title in its content — no orphaned files. Returns
    /// the id + prior title so the confirm-with-Undo pill can restore it; nil when no
    /// meeting matches, the title is blank, or it's unchanged (a graceful no-op).
    func retitle(idOrPrefix: String, to newTitle: String) -> (id: UUID, oldTitle: String)? {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = idOrPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, let index = meetings.firstIndex(where: {
            let u = $0.id.uuidString.lowercased()
            return u == key || u.hasPrefix(key)
        }) else { return nil }
        let old = meetings[index].title
        guard old != trimmed else { return nil }
        meetings[index].title = trimmed
        writeMarkdown(meetings[index])
        save()
        return (meetings[index].id, old)
    }

    /// Restore a meeting's title — the Undo of `retitle`. No-op if the meeting is gone.
    func restoreTitle(id: UUID, to oldTitle: String) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].title = oldTitle
        writeMarkdown(meetings[index])
        save()
    }

    /// Keep full data for only the most-recent `maxRetainedMeetings`, evicting the
    /// oldest beyond that from the in-memory/on-disk index. Sorting by date first
    /// makes "most recent N" well-defined regardless of insertion order.
    private func enforceRetentionCap() {
        meetings.sort { $0.startUnix > $1.startUnix } // newest first
        if meetings.count > Self.maxRetainedMeetings {
            meetings.removeLast(meetings.count - Self.maxRetainedMeetings)
        }
    }
    /// A filesystem-safe, collision-proof `.md` filename for a meeting. Minute
    /// granularity alone collided (two meetings in the same minute clobbered the
    /// earlier `.md` via the `.atomic` write, while the JSON index kept both), so we
    /// add seconds AND a short id fragment — unique per meeting even within a second.
    static func fileName(for date: Date, id: UUID) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let frag = id.uuidString.prefix(4).lowercased()
        return "\(f.string(from: date))-\(frag)-meeting.md"
    }

    // MARK: Markdown

    private func writeMarkdown(_ m: Meeting) {
        // Build the neutral note (feature 10's seam — one source of truth for the
        // Markdown), then route it through the user's chosen export destination
        // instead of the hardcoded ~/Talkie Meetings/ folder. `resolvedDestination()`
        // reads the @Published export prefs, so it MUST run on the main actor; the
        // destination value it returns is `Sendable`, so the blocking disk write is
        // handed off to a detached task and never touches @MainActor state.
        let minutes = Int((m.durationSec / 60).rounded())
        let summary = m.summary.isEmpty ? "_(no summary)_" : m.summary
        // Insert a "## Chapters" section between Summary and Transcript, but only when
        // the meeting actually shifted topics (≥2 chapters) — a lone chapter is noise.
        let chaptersSection = Meeting.chaptersMarkdown(m.chapters)
        let body = chaptersSection.isEmpty
            ? "## Summary\n\n\(summary)\n\n## Transcript\n\n\(m.transcript)"
            : "## Summary\n\n\(summary)\n\n\(chaptersSection)\n\n## Transcript\n\n\(m.transcript)"
        let note = ExportableNote(
            kind: .meeting,
            title: m.title,
            date: m.date,
            bodyMarkdown: body,
            frontMatter: [
                "duration_min": "\(minutes)",
                "participants": "[\(m.participants.joined(separator: ", "))]",
                "source": m.source,
            ],
            suggestedFileName: m.fileName
        )
        let url = meetingsDirectoryURL.appendingPathComponent(m.fileName)
        try? Data(TalkieFolderDestination.render(note).utf8).write(to: url, options: .atomic)
        // Resolve ON the main actor (reads @Published prefs); `resolvedDestination()`
        // already falls back to the Talkie folder for an inaccessible custom path.
        let destination = ExportPreferences.shared.resolvedDestination()
        // Read the optional on-save Shortcut here too (it's @Published) so the detached
        // task doesn't touch the main actor. nil = off = today's behaviour exactly. (G8.)
        let postSaveShortcut = ExportPreferences.shared.postSaveShortcutName
        // The on-disk write is fire-and-forget: the in-memory `meetings` list and the
        // JSON index the UI reads are the authority, so the note is never lost to a
        // slow or failed write. A SECOND, independent fallback writes to the default
        // ~/Talkie Meetings/ folder if the chosen destination throws — honouring the
        // "never lose a note" contract even when the resolved destination is healthy
        // at resolve-time but fails mid-write (e.g. a vault unmounts).
        Task.detached {
            // The URL the note actually landed at — the chosen destination's, or the
            // fallback folder's — so a post-save Shortcut receives the real file.
            let writtenURL: URL?
            do {
                writtenURL = try await destination.write(note)
            } catch {
                writtenURL = try? await TalkieFolderDestination().write(note)
            }
            // Post-save automation: only when the user picked a Shortcut, and only after
            // the note actually wrote. Exact-name match inside `run`; a stale/renamed
            // choice simply no-ops (`.noMatch`) without disturbing the save.
            if let name = postSaveShortcut, !name.isEmpty, let url = writtenURL {
                _ = await ShortcutsRunner.run(name: name, inputPath: url.path)
            }
        }
    }

    // MARK: Persistence (lightweight index; the .md files are the durable copy)

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Meeting].self, from: data) else {
            // The index is missing or corrupt, but the `.md` files in the meetings
            // folder are the durable copy — rebuild from them rather than orphaning
            // them behind an empty list. Best-effort and non-fatal.
            meetings = Self.recoverFromMarkdown(in: meetingsDirectoryURL)
            enforceRetentionCap()
            return
        }
        meetings = decoded
        enforceRetentionCap()
    }

    /// Best-effort self-heal: scan `directory` for `*.md` meeting notes and rebuild
    /// index entries from what's reliably parseable (title + date from the YAML
    /// front-matter, falling back to the filename). Transcripts/summaries are left
    /// empty — the durable `.md` remains the full record — so a corrupt index never
    /// orphans the folder. Never throws; returns `[]` if the folder is unreadable.
    static func recoverFromMarkdown(in directory: URL) -> [Meeting] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var recovered: [Meeting] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let front = parseFrontMatter(text)
            let date = front["date"].flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? dateFromFileName(url.lastPathComponent)
                ?? Date(timeIntervalSince1970: 0)
            let parsedTitle = front["title"].map(unquoteYAML)?
                .trimmingCharacters(in: .whitespaces)
            let title = (parsedTitle?.isEmpty == false)
                ? parsedTitle!
                : url.deletingPathExtension().lastPathComponent
            recovered.append(Meeting(
                title: title,
                startUnix: date.timeIntervalSince1970,
                durationSec: 0,
                transcript: "",
                summary: "",
                fileName: url.lastPathComponent
            ))
        }
        return recovered.sorted { $0.startUnix > $1.startUnix } // newest first
    }

    /// Pull the simple `key: value` pairs out of a leading `---`-fenced YAML block.
    /// Only the keys we need (`title`, `date`) matter; deliberately minimal — not a
    /// full YAML parser — and tolerant of a missing/garbled block.
    private static func parseFrontMatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var pairs: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { pairs[key] = value }
        }
        return pairs
    }

    /// Derive a date from a `yyyy-MM-dd-HHmm-…` filename (the default naming), so a
    /// note without a usable front-matter date still recovers a sensible timestamp.
    private static func dateFromFileName(_ name: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let prefix = name.split(separator: "-").prefix(4).joined(separator: "-")
        return f.date(from: prefix)
    }

    /// Strip the surrounding quotes a YAML scalar may carry (the renderer quotes
    /// titles containing reserved characters).
    private static func unquoteYAML(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Schedule a coalesced, off-main persist. Synchronous to callers — it only
    /// snapshots the current meetings and debounces; the JSON encode + atomic write
    /// run on `MeetingIndexWriter`, never on the main actor. Mirrors
    /// `HistoryStore.save()`.
    private func save() {
        saveGeneration += 1
        let generation = saveGeneration
        let snapshot = meetings          // value-type copy — Sendable across the hop
        let writer = self.writer
        let delay = saveDebounce
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await writer.write(snapshot, generation: generation)
            // Only clear the handle if a newer save hasn't already replaced it.
            if let self, self.saveGeneration == generation { self.pendingSave = nil }
        }
    }

    /// Force any pending debounced save to complete now (app teardown / tests that
    /// need the on-disk file to reflect the latest mutation without waiting out the
    /// debounce). Writes the latest snapshot synchronously-from-the-caller's-await;
    /// the encode + disk write still happen off the main actor on the writer.
    /// Mirrors `HistoryStore.flush()`. Not yet wired to app teardown — nothing
    /// currently calls it, same as `HistoryStore.flush()` before this change.
    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        saveGeneration += 1
        await writer.write(meetings, generation: saveGeneration)
    }
}
