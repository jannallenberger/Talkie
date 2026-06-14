import Foundation

/// The flagship cross-surface command (feature 09): turns a spoken request that
/// references the user's *own* meetings and commitments — e.g. "email Sarah the
/// action items from my last meeting" or "what did I commit to this week" — into a
/// drafted, previewable text block injected at the cursor via the shared
/// `TextInjector`.
///
/// It is "cross-surface" because it joins the two voice surfaces — dictation and
/// meetings — through the single on-device Context Graph: retrieval is *purely*
/// from the immutable `ContextGraphSnapshot` carried in `CommandContext` (plus an
/// injected, Sendable read model of recorded meetings), and the prose is drafted
/// through the shared `Summarizer`. Nothing leaves the Mac; the intent only drafts
/// and inserts — it NEVER sends a message.
///
/// `needsSelection == false` (it pulls from the graph, not the current selection)
/// and `isMutating == false` (it inserts a fresh draft rather than transforming
/// existing text), yet it always returns `preview: true` so the user reviews and
/// confirms the draft before it lands.
struct CrossSurfaceIntent: CommandIntent {
    let id = "cross-surface"
    let needsSelection = false
    let isMutating = false

    /// An injected, Sendable read model of recorded meetings (newest first), so the
    /// intent stays off the main actor and never touches the `@MainActor`
    /// `MeetingStore`. Mirrors the `ContextGraphSnapshot` convention.
    let meetings: MeetingSnapshot

    init(meetings: MeetingSnapshot) {
        self.meetings = meetings
    }

    func run(_ ctx: CommandContext) async -> CommandResult? {
        guard let request = CrossSurfaceParser.parse(ctx.spokenCommand) else { return nil }

        switch request.subject {
        case .meetingContent(let kind, let meetingRef):
            return await draftFromMeeting(kind: kind, meetingRef: meetingRef,
                                          request: request, ctx: ctx)
        case .commitments(let scope):
            return await draftCommitments(scope: scope, request: request, ctx: ctx)
        }
    }

    // MARK: - Meeting-content path ("…the action items from my last meeting")

    private func draftFromMeeting(
        kind: ContentKind,
        meetingRef: MeetingRef,
        request: CrossSurfaceRequest,
        ctx: CommandContext
    ) async -> CommandResult? {
        switch MeetingResolver.resolve(meetingRef, graph: ctx.graph, meetings: meetings) {
        case .none:
            // Honest, never fabricated: no usable meeting → a plain note, still previewed.
            let note = meetings.meetings.isEmpty
                ? "You don't have any meetings recorded yet."
                : "I couldn't find that meeting."
            return CommandResult(replacement: note, preview: true, undoToken: ctx.selection)

        case .ambiguous(let candidates):
            // Never silently guess which meeting. Offer the choices in the preview so the
            // user can re-issue the command naming the one they meant.
            let list = candidates.prefix(3).enumerated()
                .map { "\($0.offset + 1). \($0.element.title) — \(Self.relativeAttribution(for: $0.element))" }
                .joined(separator: "\n")
            let note = "You have more than one matching meeting — which one?\n\(list)"
            return CommandResult(replacement: note, preview: true, undoToken: ctx.selection)

        case .one(let meeting):
            let payload = ActionItemSource.gather(kind, meeting: meeting, graph: ctx.graph)
            let recipient = resolveRecipient(request.recipientHint, graph: ctx.graph)
            let draft = await Drafter.draft(
                channel: request.channel,
                recipient: recipient,
                payload: payload,
                target: ctx.target,
                summarizer: ctx.summarizer
            )
            return CommandResult(replacement: draft, preview: true, undoToken: ctx.selection)
        }
    }

    // MARK: - Commitment path ("what did I commit to this week")

    private func draftCommitments(
        scope: CommitmentScope,
        request: CrossSurfaceRequest,
        ctx: CommandContext
    ) async -> CommandResult? {
        let commitments = ActionItemSource.commitments(scope: scope, graph: ctx.graph)
        let recipient = resolveRecipient(request.recipientHint, graph: ctx.graph)
        let payload = DraftPayload(
            title: scope.headline,
            date: Date(),
            items: commitments,
            attribution: "from your context graph"
        )
        let draft = await Drafter.draft(
            channel: request.channel,
            recipient: recipient,
            payload: payload,
            target: ctx.target,
            summarizer: ctx.summarizer
        )
        return CommandResult(replacement: draft, preview: true, undoToken: ctx.selection)
    }

    /// Resolve a spoken recipient hint to a canonical Person display name via the
    /// graph (alias-aware). Zero hits → keep the raw hint so the draft still
    /// addresses them correctly; it just doesn't dedupe/canonicalize.
    private func resolveRecipient(_ hint: String?, graph: ContextGraphSnapshot) -> String? {
        guard let hint, !hint.isEmpty else { return nil }
        if let entity = graph.lookup(hint), entity.kind == .person {
            return entity.displayName
        }
        return hint
    }

    /// "from your 2:00 PM meeting on Tue" — used in disambiguation lists.
    static func relativeAttribution(for meeting: Meeting) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a 'on' EEE"
        return f.string(from: meeting.date)
    }
}

// MARK: - Read model

/// A small, `Sendable` snapshot of recorded meetings (newest first), copied at
/// snapshot time so consumers can run off the main actor without touching the
/// `@MainActor` `MeetingStore`. Mirrors the `ContextGraphSnapshot` convention; other
/// off-main consumers (search, the MCP server) may reuse it.
struct MeetingSnapshot: Sendable {
    let meetings: [Meeting]

    /// `meetings` must be newest-first (as `MeetingStore` keeps them).
    init(meetings: [Meeting]) {
        self.meetings = meetings
    }

    static let empty = MeetingSnapshot(meetings: [])

    var last: Meeting? { meetings.first }

    func byID(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    /// Meetings on the same calendar day as `date` (user's current calendar).
    func onDate(_ date: Date) -> [Meeting] {
        let cal = Calendar.current
        return meetings.filter { cal.isDate($0.date, inSameDayAs: date) }
    }

    /// Meetings whose title fuzzily contains the query (case-insensitive).
    func matchingTitle(_ query: String) -> [Meeting] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return meetings.filter { $0.title.lowercased().contains(q) }
    }

    /// Meetings that involve a person matching `name` — via the meeting's
    /// `participants`, then a transcript scan as a fallback (alias-aware matching is
    /// the caller's job via the graph).
    func involvingPerson(_ name: String) -> [Meeting] {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return [] }
        return meetings.filter { meeting in
            if meeting.participants.contains(where: { $0.lowercased().contains(n) }) { return true }
            return meeting.transcript.lowercased().contains(n)
        }
    }
}

// MARK: - Parsed request

/// What kind of content the user is asking to draft.
enum ContentKind: Sendable {
    case actionItems
    case decisions
    case summary
}

/// How the user referenced the meeting.
enum MeetingRef: Sendable {
    case last
    case withPerson(String)
    case onDate(Date)
    case byTitle(String)
    case byID(UUID)
}

/// "this week" / "today" / everything — the window for a commitment roundup.
enum CommitmentScope: Sendable {
    case thisWeek
    case today
    case all

    var headline: String {
        switch self {
        case .thisWeek: return "What you committed to this week"
        case .today: return "What you committed to today"
        case .all: return "Your open commitments"
        }
    }

    /// Earliest instant a commitment may have been last seen to count (nil = no floor).
    var sinceUnix: Double? {
        let now = Date()
        let cal = Calendar.current
        switch self {
        case .all: return nil
        case .today:
            return cal.startOfDay(for: now).timeIntervalSince1970
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
            return start.timeIntervalSince1970
        }
    }
}

/// What is being asked for: meeting-derived content, or a roundup of commitments.
enum CrossSurfaceSubject: Sendable {
    case meetingContent(ContentKind, MeetingRef)
    case commitments(CommitmentScope)
}

/// Where the draft is headed — tunes tone, not destination (it always drafts into
/// whatever app is frontmost; `.note`/`.inPlace` just means "no recipient").
enum DraftChannel: Sendable {
    case email
    case chat
    case note
    case inPlace
}

/// The parsed shape of a cross-surface command. Pure + Sendable.
struct CrossSurfaceRequest: Sendable {
    var subject: CrossSurfaceSubject
    var channel: DraftChannel
    var recipientHint: String?
}

// MARK: - Parser (heuristic, deterministic, offline)

/// Heuristic, deterministic parse of a spoken cross-surface command. Mirrors the
/// codebase's "free deterministic pass first" pattern (`PhraseMiner`). Returns nil
/// when the phrase isn't a cross-surface command, so the router can try other
/// intents or report "no command."
enum CrossSurfaceParser {
    static func parse(_ spoken: String) -> CrossSurfaceRequest? {
        let lower = spoken.lowercased()
        let tokens = lower.split { $0.isWhitespace }.map(String.init)
        guard !tokens.isEmpty else { return nil }

        let channel = channel(forFirst: tokens[0])
        let recipient = recipientHint(channel: channel, tokens: tokens, original: spoken)

        // "what did I commit to (this week|today)" — a commitment roundup.
        if let scope = commitmentScope(in: lower) {
            return CrossSurfaceRequest(subject: .commitments(scope),
                                       channel: channel, recipientHint: recipient)
        }

        // Otherwise it must reference a meeting AND a content kind to qualify.
        guard lower.contains("meeting"), let kind = contentKind(in: lower) else {
            // A meeting-less "action items" with an explicit meeting ref via title still counts.
            if let kind = contentKind(in: lower), let ref = meetingRef(in: lower, original: spoken),
               isMeetingRefExplicit(ref) {
                return CrossSurfaceRequest(subject: .meetingContent(kind, ref),
                                           channel: channel, recipientHint: recipient)
            }
            return nil
        }
        let ref = meetingRef(in: lower, original: spoken) ?? .last
        return CrossSurfaceRequest(subject: .meetingContent(kind, ref),
                                   channel: channel, recipientHint: recipient)
    }

    private static func isMeetingRefExplicit(_ ref: MeetingRef) -> Bool {
        if case .last = ref { return false }
        return true
    }

    private static func channel(forFirst verb: String) -> DraftChannel {
        switch verb {
        case "email", "mail": return .email
        case "message", "slack", "dm", "tell", "send", "text", "ping": return .chat
        case "note", "jot", "write": return .note
        default: return .inPlace
        }
    }

    private static let stopAfterVerb: Set<String> = [
        "the", "a", "an", "about", "from", "with", "my", "our", "regarding", "on",
    ]

    /// The token(s) right after a channel verb and before a stopword, e.g.
    /// "email **Sarah** the…". Returns the original-cased slice for display.
    private static func recipientHint(channel: DraftChannel, tokens: [String], original: String) -> String? {
        guard channel == .email || channel == .chat, tokens.count > 1 else { return nil }
        var names: [String] = []
        for token in tokens.dropFirst() {
            if stopAfterVerb.contains(token) || contentKindWords.contains(token) { break }
            names.append(token)
            if names.count >= 2 { break } // at most a first + last name
        }
        guard !names.isEmpty else { return nil }
        // Recover original casing from the source string for a clean recipient name.
        let joined = names.joined(separator: " ")
        if let range = original.lowercased().range(of: joined) {
            return String(original[range])
        }
        return joined.capitalized
    }

    private static let contentKindWords: Set<String> = [
        "action", "items", "item", "action-items", "actionitems", "to-dos", "todos",
        "todo", "next", "steps", "summary", "recap", "notes", "overview", "decisions",
        "decision",
    ]

    private static func contentKind(in lower: String) -> ContentKind? {
        if lower.contains("action item") || lower.contains("action-item")
            || lower.contains("to-do") || lower.contains("todo")
            || lower.contains("to do") || lower.contains("next step") { return .actionItems }
        if lower.contains("decision") { return .decisions }
        if lower.contains("summary") || lower.contains("recap")
            || lower.contains("overview") || lower.contains("notes") { return .summary }
        return nil
    }

    private static func commitmentScope(in lower: String) -> CommitmentScope? {
        // "what did I commit to…", "what have I committed to…", "my commitments…".
        let mentionsCommit = lower.contains("commit to") || lower.contains("committed to")
            || lower.contains("commitment") || lower.contains("did i promise")
        guard mentionsCommit else { return nil }
        if lower.contains("this week") || lower.contains("the week") { return .thisWeek }
        if lower.contains("today") { return .today }
        return .all
    }

    private static func meetingRef(in lower: String, original: String) -> MeetingRef? {
        if lower.contains("last meeting") || lower.contains("latest meeting")
            || lower.contains("recent meeting") || lower.contains("just had")
            || lower.contains("previous meeting") { return .last }
        if lower.contains("today") {
            return .onDate(Date())
        }
        if lower.contains("yesterday") {
            return .onDate(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        }
        // "the meeting with Sarah" / "Sarah's meeting".
        if let person = personAfter("with", in: lower, original: original) {
            return .withPerson(person)
        }
        // "the X meeting" / "meeting about X".
        if let title = titleReference(in: lower, original: original) {
            return .byTitle(title)
        }
        return nil
    }

    private static func personAfter(_ marker: String, in lower: String, original: String) -> String? {
        let tokens = lower.split { $0.isWhitespace }.map(String.init)
        guard let idx = tokens.firstIndex(of: marker), idx + 1 < tokens.count else { return nil }
        let name = tokens[idx + 1]
        guard !stopAfterVerb.contains(name), !contentKindWords.contains(name) else { return nil }
        if let range = original.lowercased().range(of: name) {
            return String(original[range])
        }
        return name.capitalized
    }

    private static func titleReference(in lower: String, original: String) -> String? {
        guard let range = lower.range(of: "meeting about ") else { return nil }
        let tail = lower[range.upperBound...].split { $0.isWhitespace }.prefix(3).joined(separator: " ")
        guard !tail.isEmpty else { return nil }
        if let r = original.lowercased().range(of: tail) {
            return String(original[r])
        }
        return tail
    }
}

// MARK: - Meeting resolution

/// Resolves a `MeetingRef` to a concrete meeting (or surfaces ambiguity) over the
/// injected snapshot + graph. Pure + Sendable. Never silently guesses when more than
/// one strong candidate exists — it returns `.ambiguous` so the caller can ask.
enum MeetingResolver {
    enum Resolution: Sendable {
        case none
        case one(Meeting)
        case ambiguous([Meeting])
    }

    static func resolve(
        _ ref: MeetingRef,
        graph: ContextGraphSnapshot,
        meetings: MeetingSnapshot
    ) -> Resolution {
        switch ref {
        case .byID(let id):
            return meetings.byID(id).map(Resolution.one) ?? .none

        case .last:
            guard let last = meetings.last else { return .none }
            // Ambiguous only if a second meeting sits within a tight window of the latest
            // (e.g. two meetings the same day) — then ask rather than assume "last".
            let sameDay = meetings.onDate(last.date)
            if sameDay.count > 1 { return .ambiguous(sameDay) }
            return .one(last)

        case .withPerson(let name):
            let candidates = rankByPerson(name, graph: graph, meetings: meetings)
            return disambiguate(candidates)

        case .onDate(let date):
            return disambiguate(meetings.onDate(date))

        case .byTitle(let query):
            return disambiguate(meetings.matchingTitle(query))
        }
    }

    /// Meetings involving a person, preferring the graph's alias-aware identity when
    /// the name resolves to a Person entity, then falling back to the snapshot's own
    /// participant/transcript scan.
    private static func rankByPerson(
        _ name: String,
        graph: ContextGraphSnapshot,
        meetings: MeetingSnapshot
    ) -> [Meeting] {
        var names = [name]
        if let entity = graph.lookup(name), entity.kind == .person {
            names = [entity.displayName] + entity.aliases
        }
        var seen = Set<UUID>()
        var out: [Meeting] = []
        for candidate in names {
            for meeting in meetings.involvingPerson(candidate) where seen.insert(meeting.id).inserted {
                out.append(meeting)
            }
        }
        return out
    }

    private static func disambiguate(_ candidates: [Meeting]) -> Resolution {
        switch candidates.count {
        case 0: return .none
        case 1: return .one(candidates[0])
        default: return .ambiguous(candidates)
        }
    }
}

// MARK: - Content gathering

/// The plain facts handed to the drafter. The drafter dresses these in prose but
/// never adds to them.
struct DraftPayload: Sendable {
    var title: String
    var date: Date
    /// Already-plain bullets (no leading markers).
    var items: [String]
    /// "from your 2:00 PM meeting on Tue" — always cited in the draft (provenance).
    var attribution: String
}

/// Gathers the content to draft — preferring the graph's structured `.commitment`
/// entities, and falling back to parsing the markdown blocks the on-device
/// `MeetingSummarizer` already emits ("**Action items:**" / "**Decisions:**"). The
/// single seam means swapping onto richer structured data later is a localized
/// change. Pure + Sendable; never fabricates content.
enum ActionItemSource {
    static func gather(_ kind: ContentKind, meeting: Meeting, graph: ContextGraphSnapshot) -> DraftPayload {
        let attribution = "from your \(CrossSurfaceIntent.relativeAttribution(for: meeting))"
        switch kind {
        case .summary:
            // The overview line(s): everything before the first "**…:**" heading.
            let overview = overviewLines(from: meeting.summary)
            return DraftPayload(title: meeting.title, date: meeting.date,
                                items: overview, attribution: attribution)
        case .actionItems:
            let structured = structuredCommitments(for: meeting, graph: graph)
            let items = structured.isEmpty
                ? section("action items", in: meeting.summary)
                : structured
            return DraftPayload(title: meeting.title, date: meeting.date,
                                items: items, attribution: attribution)
        case .decisions:
            return DraftPayload(title: meeting.title, date: meeting.date,
                                items: section("decisions", in: meeting.summary),
                                attribution: attribution)
        }
    }

    /// A standalone roundup of open commitments from the graph for a time scope.
    static func commitments(scope: CommitmentScope, graph: ContextGraphSnapshot) -> [String] {
        let floor = scope.sinceUnix
        return graph.commitments(limit: 50)
            .filter { floor == nil || $0.lastSeenUnix >= floor! }
            .map(commitmentLine)
    }

    // MARK: Graph-backed commitments for a meeting

    /// Commitments whose provenance ties them to this meeting (preferred over
    /// summary parsing when the graph is populated).
    private static func structuredCommitments(for meeting: Meeting, graph: ContextGraphSnapshot) -> [String] {
        let mid = meeting.id.uuidString
        return graph.commitments(limit: 50)
            .filter { entity in
                entity.provenance.contains { $0.source == .meeting && $0.sourceID == mid }
            }
            .map(commitmentLine)
    }

    /// A clean one-line rendering of a commitment entity, preferring the provenance
    /// snippet (the actual quote) over the bare display name.
    private static func commitmentLine(_ entity: Entity) -> String {
        if let snippet = entity.provenance.first?.snippet,
           !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return entity.displayName
    }

    // MARK: Summary-block parsing (graceful fallback onto today's summaries)

    /// Plain bullet lines under a "**Heading:**" section of a meeting summary.
    /// Tolerates older summaries with no such heading (returns []).
    static func section(_ name: String, in summary: String) -> [String] {
        let lines = summary.components(separatedBy: .newlines)
        var collecting = false
        var out: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isHeading(line) {
                // Entering the wanted section, or leaving it for the next heading.
                collecting = headingMatches(line, name: name)
                continue
            }
            guard collecting else { continue }
            if line.isEmpty { continue }
            if let bullet = bulletText(line) { out.append(bullet) }
        }
        return out
    }

    /// The overview = non-empty, non-heading, non-bullet lines before the first heading.
    private static func overviewLines(from summary: String) -> [String] {
        var out: [String] = []
        for raw in summary.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isHeading(line) { break }
            if line.isEmpty { continue }
            if let bullet = bulletText(line) { out.append(bullet) } else { out.append(line) }
        }
        return out
    }

    private static func isHeading(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.hasPrefix("**") && l.contains(":")
    }

    private static func headingMatches(_ line: String, name: String) -> Bool {
        line.lowercased().contains(name.lowercased())
    }

    /// Strip a leading bullet marker ("-", "*", "•", "1.") if present; return the
    /// text, or the trimmed line if it wasn't a bullet but we're inside the section.
    private static func bulletText(_ line: String) -> String? {
        let markers = ["- ", "* ", "• ", "– "]
        for marker in markers where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        // Numbered "1. " / "2) " style.
        if let first = line.first, first.isNumber,
           let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
           line.distance(from: line.startIndex, to: dot) <= 2 {
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        // A plain line inside a section (some models omit bullets) — keep it.
        return line.isEmpty ? nil : line
    }
}

// MARK: - Drafting

/// Turns a `DraftPayload` into channel-appropriate prose through the shared
/// `Summarizer` (on-device by default; the opt-in bridge when enabled). It always
/// cites the source (provenance / honesty) and never invents items beyond the
/// payload. When the model is unavailable it falls back to a deterministic template
/// so a draft still appears.
enum Drafter {
    static func draft(
        channel: DraftChannel,
        recipient: String?,
        payload: DraftPayload,
        target: TargetApp,
        summarizer: any Summarizer
    ) async -> String {
        // Empty content → an honest, non-fabricated note rather than a hollow draft.
        guard !payload.items.isEmpty else {
            return "No \(emptyNoun(channel)) were recorded \(payload.attribution)."
        }

        let bullets = payload.items.map { "- \($0)" }.joined(separator: "\n")
        let input = """
        Source: \(payload.attribution)
        Title: \(payload.title)
        \(recipient.map { "Recipient: \($0)" } ?? "Recipient: (none)")
        Items:
        \(bullets)
        """

        if let generated = await summarizer.generate(
            instructions: instructions(channel: channel, recipient: recipient),
            input: input
        ), !generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return generated.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Deterministic fallback (model off / unavailable) — still a usable draft.
        return template(channel: channel, recipient: recipient, payload: payload, bullets: bullets)
    }

    private static func emptyNoun(_ channel: DraftChannel) -> String {
        "items"
    }

    private static func instructions(channel: DraftChannel, recipient: String?) -> String {
        let toneLine: String
        switch channel {
        case .email:
            toneLine = "Write a short, warm, professional email. Open with a greeting (use the recipient's name if given), one brief framing sentence, then the items as a tidy bullet list, then a short sign-off."
        case .chat:
            toneLine = "Write a brief, friendly chat message — no greeting boilerplate, just a one-line lead-in then the items as bullets."
        case .note, .inPlace:
            toneLine = "Write a clean note: a one-line heading then the items as bullets. No greeting or sign-off."
        }
        return """
        You draft a message FROM the user, in the second person on their behalf. \(toneLine) \
        Cite the source exactly once near the top (it is provided as "Source:"). \
        Use ONLY the items provided — do NOT invent, merge, or add any item, name, date, \
        or commitment that is not in the input. Do not send anything; you are only \
        drafting text for the user to review. Output ONLY the draft — no preamble, no \
        quotes, no explanation.
        """
    }

    private static func template(
        channel: DraftChannel,
        recipient: String?,
        payload: DraftPayload,
        bullets: String
    ) -> String {
        switch channel {
        case .email:
            let greeting = recipient.map { "Hi \($0)," } ?? "Hi,"
            return """
            \(greeting)

            Here are the action items \(payload.attribution):

            \(bullets)

            Best,
            """
        case .chat:
            let lead = recipient.map { "\($0) — " } ?? ""
            return "\(lead)action items \(payload.attribution):\n\(bullets)"
        case .note, .inPlace:
            return "\(payload.title) — \(payload.attribution)\n\(bullets)"
        }
    }
}
