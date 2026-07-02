import Foundation

/// Fuses the user's sparse live notes with the meeting transcript into a polished
/// note — the "Granola magic" people actually pay for (feature 02). It expands the
/// bullets using the transcript WITHOUT inventing facts, via the on-device
/// `Summarizer` seam (the opt-in bridge when enabled). The live notes pane and the
/// `MeetingRecorder` wiring are the serial integration pass; this is the engine.
actor MeetingNotesFusion {
    struct Result: Sendable {
        /// Composed Markdown: a refined "## Notes" section then a "## Summary"
        /// section. The caller appends the "## Transcript" section and hands the
        /// whole thing to a `NoteDestination` via `ExportableNote`.
        var bodyMarkdown: String
    }

    private static let instructions = """
    You merge a person's rough live meeting notes with the meeting transcript. \
    Expand and clarify their notes using ONLY facts supported by the transcript — \
    never invent anything not in it. Output markdown: a one or two sentence overview, \
    then their points cleaned and expanded into bullets with transcript detail, then \
    "**Decisions:**" and "**Action items:**" bullets (with owners) only if present. \
    Do NOT add section headings (no "## Notes" / "## Summary") — this text is placed \
    under an existing heading. Output only the markdown.
    """

    /// Map instruction for the digest pass over an over-long transcript: reduce one
    /// excerpt to terse facts that PRESERVE the load-bearing detail the fusion prompt
    /// must not invent — names, decisions, and action items with owners. Mirrors the
    /// intent of `MeetingSummarizer.mapInstructions` so digested transcript text is a
    /// faithful (if compressed) stand-in for the raw text the fusion prompt would
    /// otherwise see.
    private static let digestInstructions = """
    You are compressing one excerpt of a longer meeting transcript so it can be \
    merged with someone's notes. Preserve, as terse bullets, every name, decision, \
    and action item (naming the owner if the excerpt names one), plus any concrete \
    fact a reader would need. Do NOT invent anything that isn't in the excerpt, and \
    do not summarize away specifics. If the excerpt is genuinely empty of content, \
    output exactly "None". Output only the bullets (or "None").
    """

    /// Single-pass input size and per-excerpt chunk size for the digest, matched to
    /// `MeetingSummarizer.chunkChars` (the on-device model's 4096-*token* window is
    /// shared by instructions + input + output, and token density varies enough by
    /// language that 8000 chars overflowed for dense text). The digest keeps the
    /// fusion prompt's transcript within this same tested-safe budget while covering
    /// the WHOLE meeting instead of just its first 8000 chars.
    private static let chunkChars = 4000
    /// Hard ceiling on digest map calls for one meeting, so a pathologically long
    /// recording can't spin up an unbounded number of model calls. Matches
    /// `MeetingSummarizer.maxChunks`; chunk size grows past `chunkChars` before this
    /// ceiling is hit, so coverage isn't silently dropped for realistic lengths.
    private static let maxChunks = 16

    /// Retained for the digest's fallback path: when the transcript is over-long but
    /// the digest is unavailable, we degrade to exactly today's behavior — the first
    /// `fusionCap` characters — rather than dropping to nothing. Kept equal to the
    /// historical fusion cap so short-transcript behavior is byte-identical.
    private static let fusionCap = 8000

    /// Returns the fused body, or nil if there's nothing to work with / the model
    /// is unavailable (the caller then falls back to the plain summary path).
    func fuse(notes: String, transcript: String, using summarizer: any Summarizer) async -> Result? {
        let userNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        // Fit the transcript into the fusion prompt's budget. A short transcript is
        // used verbatim (byte-identical to before this change, zero extra model
        // calls). A long one is map-only digested — chunked, each chunk reduced to
        // terse fact bullets, joined — so the fusion prompt sees material from the
        // WHOLE meeting rather than just its first 8000 chars (feature 02 / plan 18:
        // map-reduce layers ABOVE the Summarizer seam, per `Summarizer` protocol).
        // If the digest is unavailable (model not ready / returns nil), degrade to
        // exactly today's `prefix` cap so a note-taker is never worse off than before.
        let transcriptForPrompt: String
        if body.count > Self.chunkChars {
            transcriptForPrompt = await Self.digest(body, using: summarizer)
                ?? String(body.prefix(Self.fusionCap))
        } else {
            transcriptForPrompt = body
        }
        let input = """
        ROUGH NOTES:
        \(userNotes.isEmpty ? "(none)" : userNotes)

        TRANSCRIPT:
        \(transcriptForPrompt)
        """
        guard let out = await summarizer.generate(instructions: Self.instructions, input: input),
              !out.isEmpty else { return nil }
        return Result(bodyMarkdown: out)
    }

    /// Map-only compression of an over-long transcript to fit the fusion prompt's
    /// budget while covering the whole meeting. Chunks the text, maps each chunk to
    /// terse fact bullets via the injected `summarizer` (so it works with either the
    /// on-device model or the opt-in cloud bridge), and loop-compresses the joined
    /// result until it's within `chunkChars` — bounded, so it can't loop forever.
    ///
    /// Returns the input unchanged (zero model calls) when it already fits, or `nil`
    /// if the model is unavailable / fails, so the caller can fall back to today's
    /// truncated behavior rather than losing the note. Single shared on-device model:
    /// chunks are mapped sequentially, never in parallel.
    static func digest(_ transcript: String, using summarizer: any Summarizer) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= chunkChars { return trimmed }

        guard var combined = await mapAll(trimmed, using: summarizer) else { return nil }
        // The on-device model doesn't always keep extraction as terse as asked; if the
        // gathered facts are themselves too long, compress again (bounded so this can't
        // loop forever). A pass that yields nil means the model went unavailable
        // mid-digest — surface nil so the caller degrades to the prefix cap.
        var passes = 0
        while combined.count > chunkChars, passes < 3 {
            guard let next = await mapAll(combined, using: summarizer) else { return nil }
            combined = next
            passes += 1
        }
        // Guarantee the fusion prompt's transcript is within the tested-safe budget
        // even if the model never compressed enough — better a truncated digest that
        // still spans the meeting than a fusion call that overflows the window.
        if combined.count > chunkChars { combined = String(combined.prefix(chunkChars)) }
        return combined
    }

    /// Chunk `text` and map each piece to terse fact bullets, joined back together.
    /// Returns nil if the model is unavailable for a chunk (so the whole digest can
    /// fail cleanly to the prefix fallback rather than emit a partial that silently
    /// dropped the meeting's tail).
    private static func mapAll(_ text: String, using summarizer: any Summarizer) async -> String? {
        let chunks = chunk(text, maxChars: chunkChars, maxChunks: maxChunks)
        var notes: [String] = []
        for (index, excerpt) in chunks.enumerated() {
            guard let mapped = await summarizer.generate(instructions: digestInstructions, input: excerpt) else {
                return nil
            }
            notes.append("Excerpt \(index + 1): \(mapped)")
        }
        return notes.joined(separator: "\n\n")
    }

    /// Greedily pack lines into chunks, sized so the whole text fits in at most
    /// `maxChunks` pieces (growing past `maxChars` only if it must) — so a long
    /// meeting gets every excerpt mapped rather than losing its tail. Mirrors
    /// `MeetingSummarizer.chunk` (kept a private copy here rather than reaching into
    /// that actor's private helpers, which live in the READ-ONLY `Meeting.swift`).
    static func chunk(_ text: String, maxChars: Int, maxChunks: Int) -> [String] {
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
}
