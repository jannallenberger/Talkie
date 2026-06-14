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

    /// Returns the fused body, or nil if there's nothing to work with / the model
    /// is unavailable (the caller then falls back to the plain summary path).
    func fuse(notes: String, transcript: String, using summarizer: any Summarizer) async -> Result? {
        let userNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        // Bound the input like MeetingSummarizer; map-reduce for very long meetings
        // is a follow-up that layers above the Summarizer seam.
        let cappedTranscript = String(body.prefix(8000))
        let input = """
        ROUGH NOTES:
        \(userNotes.isEmpty ? "(none)" : userNotes)

        TRANSCRIPT:
        \(cappedTranscript)
        """
        guard let out = await summarizer.generate(instructions: Self.instructions, input: input),
              !out.isEmpty else { return nil }
        return Result(bodyMarkdown: out)
    }
}
