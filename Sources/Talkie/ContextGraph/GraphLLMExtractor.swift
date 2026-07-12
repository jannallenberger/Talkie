import Foundation

/// Stage-2 **LLM** extraction for the context graph — the refinement pass that
/// layers on top of `ContextGraphExtractor`'s Stage-1 heuristics. Given a body of
/// text (a dictation or a meeting transcript) and an injected `any Summarizer`, it
/// asks the on-device model for a constrained, line-delimited list of the people,
/// projects, terms, and explicit commitments actually present in the text, and
/// parses that response back into `[ContextGraphExtractor.Candidate]` (the same
/// candidate type the heuristic stage and `ContextGraphStore.ingest` already use).
///
/// Design constraints honored from the 05 plan:
/// - **Reuses the spine type** (`ContextGraphExtractor.Candidate` + `EntityKind`)
///   so the output drops straight into `ContextGraphStore.ingest` — no new model.
/// - **Pipe-grammar, not JSON.** `KIND|name` records are cheap to parse defensively
///   and degrade to "skip the malformed line" instead of failing the whole batch.
/// - **Hard "do not invent" guardrail** in the prompt (mirrors `ContextSummary` /
///   `MeetingSummarizer`): the model lists only what the text supports.
/// - **Robust to model-unavailable.** If the `Summarizer` returns `nil` (Apple
///   Intelligence off, empty input, or failure), `extract` returns `[]` so callers
///   transparently fall back to the Stage-1 heuristic candidates.
///
/// `actor` (holds no mutable shared state beyond the injected `Summarizer`, but the
/// plan specifies extractors that drive the LLM are actors so the shared model is
/// never contended off the main actor). 100% on-device; nothing leaves the Mac.
actor GraphLLMExtractor {

    /// The system prompt: a tight, guard-railed extraction instruction. The model
    /// must emit one record per line in `KIND|surface form` shape and nothing else.
    private static let instructions = """
    You extract structured facts from a transcript of the user's own speech or a \
    meeting. Read the text and list ONLY the entities it actually mentions, one per \
    line, using EXACTLY this pipe format:

    PERSON|<name>
    PROJECT|<name or product/codebase identifier>
    TERM|<domain term, jargon, or proper noun worth remembering>
    COMMITMENT|<the action the user committed to, as a short clause>

    Rules:
    - Output ONLY these records, nothing else — no prose, no headings, no numbering, \
    no blank explanations.
    - Use the surface form as written in the text (keep real capitalization for names).
    - A COMMITMENT is an explicit promise or task the speaker takes on \
    ("I'll send the deck Friday", "I need to follow up with Sarah"). Keep it under \
    one sentence. Do NOT fabricate due dates — only include a date if the text states it.
    - Do NOT invent anything. If a person/project/term/commitment is not clearly in \
    the text, do not list it. If the text contains none of a kind, simply omit it.
    - One entity per line. Do not duplicate the same entity.
    """

    /// Cap on the input length per call. Foundation Models has a bounded context; we
    /// keep the head of the text (the spine's `ContextSummary` uses the same prefix
    /// strategy). Longer corpora are handled by the caller batching inputs.
    private static let maxInputChars = 4000

    /// Defensive cap on how many candidates we accept from a single response, so a
    /// runaway / repetitive model can't flood the graph.
    private static let maxCandidates = 60

    private let summarizer: any Summarizer

    init(summarizer: any Summarizer) {
        self.summarizer = summarizer
    }

    /// Refine `text` into graph candidates via the LLM. Returns `[]` when the model
    /// is unavailable or produces nothing parseable, so the caller falls back to the
    /// Stage-1 heuristic candidates from `ContextGraphExtractor.candidates(from:)`.
    func extract(from text: String) async -> [ContextGraphExtractor.Candidate] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let input = String(trimmed.prefix(Self.maxInputChars))
        guard let raw = await summarizer.generate(instructions: Self.instructions, input: input),
              !raw.isEmpty else {
            return []
        }
        return Self.parse(raw)
    }

    // MARK: - Parsing

    /// Parse the model's line-delimited response into candidates. Each line is
    /// `KIND|surface form`; anything that doesn't match a known kind or has an empty
    /// surface form is dropped silently (so a single malformed line never sinks the
    /// batch). Duplicates (case-insensitive, per kind) are collapsed. Exposed as a
    /// `static` pure function so it is independently testable without a live model.
    static func parse(_ response: String) -> [ContextGraphExtractor.Candidate] {
        var out: [ContextGraphExtractor.Candidate] = []
        var seen = Set<String>()

        for rawLine in response.split(whereSeparator: \.isNewline) {
            guard out.count < maxCandidates else { break }

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Split on the FIRST pipe only — commitment clauses may contain more.
            guard let pipe = line.firstIndex(of: "|") else { continue }
            let kindToken = line[..<pipe].trimmingCharacters(in: .whitespaces)
            guard let kind = mapKind(kindToken) else { continue }

            let surface = cleanSurface(String(line[line.index(after: pipe)...]), kind: kind)
            guard isAcceptable(surface, kind: kind) else { continue }

            let dedupeKey = "\(kind.rawValue)|\(surface.lowercased())"
            guard seen.insert(dedupeKey).inserted else { continue }

            out.append(ContextGraphExtractor.Candidate(kind: kind, displayName: surface))
        }
        return out
    }

    /// Map a leading kind token (case-insensitive) to an `EntityKind`. The graph's
    /// `EntityKind` has no `organization` case, so organizations fold into `.project`
    /// (the closest "thing you work on / with" bucket); unknown tokens are rejected.
    private static func mapKind(_ token: String) -> EntityKind? {
        switch token.uppercased() {
        case "PERSON", "PEOPLE": return .person
        case "PROJECT", "PRODUCT", "CODEBASE", "ORG", "ORGANIZATION", "COMPANY": return .project
        case "TERM", "TOPIC", "VOCAB", "VOCABULARY": return .term
        case "COMMITMENT", "ACTION", "TASK", "TODO": return .commitment
        default: return nil
        }
    }

    /// Tidy a parsed surface form: trim, strip wrapping quotes/markdown bullets, and
    /// drop any "field=value" tail the model may append to a commitment line. For
    /// non-commitment kinds we also strip a trailing description after a secondary
    /// pipe or " - " so "GitHub - the PM tool" stores just "GitHub".
    private static func cleanSurface(_ value: String, kind: EntityKind) -> String {
        var s = value.trimmingCharacters(in: .whitespaces)

        // Strip a leading list bullet the model sometimes emits despite the rules.
        for bullet in ["- ", "* ", "• "] where s.hasPrefix(bullet) {
            s = String(s.dropFirst(bullet.count))
        }

        // Strip matching wrapping quotes.
        if s.count >= 2 {
            let first = s.first!, last = s.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                s = String(s.dropFirst().dropLast())
            }
        }

        if kind != .commitment {
            // For names/terms, keep only the head; drop any "| extra" or " - desc" tail.
            if let pipe = s.firstIndex(of: "|") { s = String(s[..<pipe]) }
            if let range = s.range(of: " - ") { s = String(s[..<range.lowerBound]) }
        }

        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Bounds a parsed surface form. Commitments may be longer clauses; names/terms
    /// are short. Rejects empties, over-long strings, and obvious non-answers.
    private static func isAcceptable(_ surface: String, kind: EntityKind) -> Bool {
        guard !surface.isEmpty else { return false }
        switch kind {
        case .commitment:
            return surface.count >= 4 && surface.count <= 200
        case .person, .project, .term:
            return surface.count >= 2 && surface.count <= 80
        }
    }
}
