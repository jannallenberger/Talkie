import Combine
import Foundation

/// The published "what's being discussed right now" label the meeting pill shows.
/// `nil` until the engine is *certain* of a topic — the pill stays neutral
/// (REC + timer) rather than ever displaying a guess. Once a topic is accepted it
/// persists and only ever *updates* to another confident topic; it never blanks
/// back out mid-meeting (that would read as a glitch).
@MainActor
final class MeetingSubtopicModel: ObservableObject {
    @Published var current: String?

    /// A one-sentence gloss of the CURRENT topic (e.g. "Discussing the Q3 budget
    /// rollover and hiring freeze"), for DISPLAY only. Set alongside `current` on the
    /// same accept transition — never instead of it. `current` (the short phrase)
    /// stays the sole source of truth for gating and for `Chapter(title:)`, so
    /// chapter titles are unaffected no matter what this holds; this is purely
    /// additive. Falls back to `current` itself when the model's gloss line is
    /// missing, empty, or overflows the bounds — a full sentence would jitter the
    /// gate if it were keyed on directly, hence the separate short phrase for gating.
    @Published var currentGloss: String?

    /// The OTHER person's most recent question, shown the instant a far-end
    /// segment matches `Interrogative.isQuestion` — no LLM confidence, no
    /// hysteresis wait, unlike `current`. Ephemeral: the wiring layer auto-clears
    /// it a few seconds after it's set (see `AppDelegate.setupMeetingDetection`),
    /// so a lull in the conversation doesn't leave a stale question on the pill.
    @Published var liveQuestion: String?
}

/// Derives a live "subtopic" — a short, section-heading-style label of the topic
/// being discussed *right now* — from a meeting's transcript as it streams in, and
/// surfaces it through `MeetingSubtopicModel` for the pill.
///
/// Modeled directly on `GraphLLMExtractor`: a guard-railed on-device LLM call
/// (through the `Summarizer` seam, 100% local), a cheap pipe/line grammar instead
/// of JSON, defensive parsing, and a hard "do not invent" instruction. The crucial
/// extra is **confidence gating + hysteresis** so the label never misrepresents the
/// conversation:
///
///   1. The model must self-report `CONFIDENCE|HIGH` *and* name a concrete topic;
///      any doubt → `TOPIC|NONE` / `CONFIDENCE|LOW`, which is ignored.
///   2. Two-tier hysteresis (`step`): the FIRST topic (nothing shown yet) is accepted
///      eagerly on a single high-confidence hit, so the pill doesn't sit empty for
///      the better part of a minute. Once a topic IS shown, *replacing* it still
///      needs **two consecutive** high-confidence evaluations — one-off blips never
///      surface; the current topic holds until a genuinely new one is sustained.
///
/// Evaluation is throttled (a slow poll loop that only fires once enough new speech
/// has accumulated) so the shared on-device model isn't hammered. The `actor` alone
/// does NOT guarantee only one evaluation runs at a time -- `tick()` suspends at its
/// `await summarizer.generate(...)` call, which is a reentrancy point, so a second
/// `tick()` (woken by `ingest`'s adaptive poll, or the timer loop) could otherwise
/// start a second, overlapping on-device call while the first is still in flight.
/// `isEvaluating` (below) closes that gap explicitly.
actor MeetingSubtopicEngine {

    // MARK: Tunables

    /// Rolling transcript window kept in memory; older speech falls off the front.
    private static let maxWindowChars = 2000
    /// The model only sees the tail of the window (the recent conversation).
    private static let maxInputChars = 1800
    /// Don't evaluate until at least this much *new* speech has arrived since the
    /// last evaluation — avoids re-labeling identical text and bounds model calls.
    private static let minNewCharsToEval = 90
    /// How often the loop wakes to consider an evaluation. `ingest(_:)` also wakes
    /// the evaluator early once `minNewCharsToEval` is reached, so this interval is
    /// really just the ceiling on latency during a quiet stretch of the meeting —
    /// a fast-moving conversation gets evaluated sooner via that adaptive poll.
    private static let evalInterval: Duration = .seconds(5)
    /// Consecutive high-confidence evaluations needed to *replace* an already-shown
    /// topic. Does NOT gate the very first topic — see `step`'s eager-first-accept.
    static let requiredStreak = 2

    // MARK: State

    private let summarizer: any Summarizer
    private let model: MeetingSubtopicModel

    /// Fired exactly when a NEW topic clears the confidence + hysteresis bar and
    /// becomes the shown topic — the same instant `model.current` updates. The
    /// wiring layer uses it to record a chapter boundary, stamping the topic with
    /// the recorder's live elapsed time. Purely additive: the pill's behavior is
    /// unchanged whether or not this is set. Kept `@Sendable` because it's invoked
    /// from the actor and hops to the main actor at the call site.
    private let onAccepted: (@Sendable (String) -> Void)?

    private var window: [String] = []
    private var windowChars = 0
    private var charsSinceEval = 0
    private var gate = GateState()
    private var loop: Task<Void, Never>?
    /// True while a `tick()` is between its synchronous guard/reset and the return
    /// from `summarizer.generate(...)`. Actor isolation alone only serializes the
    /// SYNCHRONOUS stretches of `tick()`; once it suspends at that `await`, the actor
    /// is reentrant and would otherwise happily start a second `tick()` (from either
    /// the timer loop or `ingest`'s adaptive wake) with its own overlapping in-flight
    /// model call. This flag makes "at most one evaluation in flight" an explicit
    /// invariant instead of an accidental one that reentrancy quietly breaks.
    private var isEvaluating = false

    init(summarizer: any Summarizer = PrivacyWall.assertLocal(OnDeviceLLM(temperature: 0.2)),
         model: MeetingSubtopicModel,
         onAccepted: (@Sendable (String) -> Void)? = nil) {
        self.summarizer = summarizer
        self.model = model
        self.onAccepted = onAccepted
    }

    /// Usable only when the on-device language model is available; otherwise the
    /// engine no-ops and the pill simply shows REC + timer (the subtopic is additive).
    static var isAvailable: Bool { OnDeviceLLM.isAvailable }

    // MARK: Lifecycle

    /// Begin watching. Idempotent; a no-op when the model is unavailable.
    func start() {
        guard Self.isAvailable, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.evalInterval)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    /// Stop and fully reset, clearing the displayed topic. Called when a recording ends.
    func stop() {
        loop?.cancel()
        loop = nil
        window.removeAll()
        windowChars = 0
        charsSinceEval = 0
        gate = GateState()
        // This instance is reused across recordings (AppDelegate builds it once), so
        // a `tick()` still in flight when `stop()` lands must not leave the actor
        // permanently believing an evaluation is running -- that would silently wedge
        // every future `tick()` for the rest of the app's lifetime.
        isEvaluating = false
        let m = model
        Task { @MainActor in
            m.current = nil
            m.currentGloss = nil
            m.liveQuestion = nil   // no stale question can linger into the next recording
        }
    }

    /// Feed one finalized transcript segment (speaker-tagged upstream). Cheap and
    /// non-blocking; just appends to the rolling window and trims it to budget.
    func ingest(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        window.append(t)
        windowChars += t.count + 1
        charsSinceEval += t.count + 1
        while windowChars > Self.maxWindowChars, window.count > 1 {
            let dropped = window.removeFirst()
            windowChars -= dropped.count + 1
        }
        // Adaptive poll: don't make a fast-moving conversation wait out the rest of
        // `evalInterval` once there's already enough fresh speech to evaluate. Skip
        // spawning while an evaluation is already in flight -- `tick()`'s
        // `isEvaluating` guard would just no-op it anyway, and `charsSinceEval` keeps
        // accumulating untouched (it's only reset when a `tick()` actually proceeds),
        // so the backlog is picked up by the next `ingest` once the in-flight call
        // finishes, or by the periodic timer loop. This also avoids spawning a Task
        // per segment while a call is running, which would otherwise pile up no-ops.
        if charsSinceEval >= Self.minNewCharsToEval, !isEvaluating {
            Task { await self.tick() }
        }
    }

    // MARK: Evaluation

    private func tick() async {
        // `isEvaluating` is checked and set synchronously here, before the only
        // suspension point below (`summarizer.generate`) -- so this whole guard+set
        // is atomic from the actor's perspective and a second `tick()` racing in via
        // reentrancy during the `await` can never pass it while this one is in flight.
        guard !isEvaluating, charsSinceEval >= Self.minNewCharsToEval else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        charsSinceEval = 0

        let input = String(window.joined(separator: " ").suffix(Self.maxInputChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        guard let raw = await summarizer.generate(instructions: Self.instructions, input: input)
        else { return }

        apply(raw)
    }

    /// Fold one raw model response into the gate, publishing to the pill and firing
    /// `onAccepted` on (and only on) an accept transition. Split out of `tick()` so
    /// the accept/publish/hook sequence can be driven deterministically in tests
    /// (`evaluateForTesting`) without the timer or the new-chars gate.
    private func apply(_ raw: String) {
        let parsed = Self.parse(raw)
        let before = gate.accepted
        gate = Self.step(gate, topic: parsed.topic, high: parsed.high)
        if gate.accepted != before, let now = gate.accepted {
            // The gloss is display-only: fall back to the short phrase itself when
            // the model's gloss line is missing/empty/overflows, so the pill always
            // has *something* sentence-shaped to show rather than going blank.
            let gloss = parsed.gloss ?? now
            let m = model
            Task { @MainActor in
                m.current = now
                m.currentGloss = gloss
            }
            // Same instant the pill updates: notify the chapter collector. The
            // callback stamps the accept time itself, so the engine stays free of
            // any clock/recorder dependency and the pill behavior is untouched.
            // Carries the SHORT phrase only — chapters must never see the gloss.
            onAccepted?(now)
        }
    }

    /// Test seam: run a single evaluation from a canned model response, exercising
    /// the real parse → hysteresis → publish/`onAccepted` path (no timer, no model,
    /// no new-chars gate). Lets a test prove the accept hook fires exactly on the
    /// accept transition — the ordering guarantee chapters rely on. Not used in
    /// production; the live path goes through `tick()`.
    func evaluateForTesting(_ raw: String) { apply(raw) }

    /// The guard-railed system prompt. Two hard gates against misrepresentation: it
    /// must answer `NONE` whenever it can't tell, and `HIGH` only when the recent
    /// lines unambiguously center on one topic.
    private static let instructions = """
    You are labeling the topic of a LIVE meeting as it unfolds. You are given a \
    rolling window of the most recent transcript (turns may be labeled Me / Them). \
    Identify the SINGLE subject being discussed in the MOST RECENT part of the \
    conversation — a short, section-heading-style noun phrase.

    Respond with EXACTLY three lines and nothing else:
    TOPIC|<2 to 5 word phrase, or NONE>
    GLOSS|<one sentence, max ~12-14 words, describing what's being discussed right now>
    CONFIDENCE|<HIGH or LOW>

    Rules:
    - Only name a TOPIC you are certain is actually being discussed in the latest \
    lines. For greetings, small talk, scattered chatter, or anything unclear, output \
    TOPIC|NONE.
    - CONFIDENCE is HIGH only when the recent lines clearly and unambiguously center \
    on one topic. If there is any doubt at all, output LOW.
    - Describe the CURRENT topic, not the whole meeting. Do NOT summarize. Do NOT \
    invent or guess a plausible-sounding topic.
    - Keep TOPIC short (max 5 words), a plain noun phrase: no punctuation, no quotes, \
    no trailing period.
    - GLOSS is a natural sentence (not a heading) describing the same current topic in \
    a bit more detail — same rules as TOPIC: only what's actually being discussed right \
    now, never a summary of the whole meeting, never invented or guessed.
    """

    // MARK: - Pure logic (independently testable, no model / no I/O)

    /// The hysteresis state. `accepted` is what the pill currently shows; `candidate`
    /// is a normalized topic that has cleared the confidence bar but not yet the
    /// consecutive-evaluation bar.
    struct GateState: Equatable, Sendable {
        var accepted: String?           // displayed topic (original casing)
        var candidate: String?          // normalized pending topic
        var candidateOriginal: String?  // original casing of the pending topic
        var streak: Int = 0             // consecutive high-confidence hits for `candidate`
    }

    /// Parse the model's three-line response. Tolerant: unknown lines are ignored, a
    /// `TOPIC` that's empty, `NONE`, or out of bounds yields `nil` (no topic), and a
    /// missing/empty/overflowing `GLOSS` line yields `nil` (the caller falls back to
    /// the topic phrase) rather than breaking parsing — callers that only ever sent
    /// TOPIC+CONFIDENCE (older prompts, existing tests) must keep parsing cleanly.
    static func parse(_ response: String) -> (topic: String?, gloss: String?, high: Bool) {
        var topic: String?
        var gloss: String?
        var high = false
        for rawLine in response.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let pipe = line.firstIndex(of: "|") else { continue }
            let key = line[..<pipe].trimmingCharacters(in: .whitespaces).uppercased()
            let value = String(line[line.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "TOPIC":
                let cleaned = cleanTopic(value)
                if !cleaned.isEmpty, cleaned.uppercased() != "NONE" { topic = cleaned }
            case "GLOSS":
                let cleaned = cleanGloss(value)
                if !cleaned.isEmpty { gloss = cleaned }
            case "CONFIDENCE":
                high = value.uppercased().hasPrefix("HIGH")
            default:
                continue
            }
        }
        return (topic, gloss, high)
    }

    /// Tidy a topic: strip wrapping quotes / trailing punctuation, then bound it to a
    /// short noun phrase (≤ 6 words, ≤ 48 chars). Returns "" if it fails the bounds,
    /// so a runaway sentence is treated as "no usable topic" rather than shown.
    static func cleanTopic(_ value: String) -> String {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, let f = s.first, let l = s.last,
           (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            s = String(s.dropFirst().dropLast())
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"' "))
        let words = s.split(whereSeparator: \.isWhitespace)
        guard !s.isEmpty, s.count <= 48, words.count <= 6 else { return "" }
        return s
    }

    /// Tidy a gloss: same quote-stripping as `cleanTopic` but a looser bound (≤ 14
    /// words, ≤ 80 chars) since it's a full sentence, not a noun phrase. Returns ""
    /// (→ `nil`) if it's empty or overflows, so a runaway/missing gloss just means
    /// "no gloss, fall back to the topic phrase" rather than a garbled label ever
    /// showing on the pill.
    static func cleanGloss(_ value: String) -> String {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, let f = s.first, let l = s.last,
           (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            s = String(s.dropFirst().dropLast())
        }
        s = s.trimmingCharacters(in: .whitespaces)
        let words = s.split(whereSeparator: \.isWhitespace)
        guard !s.isEmpty, s.count <= 80, words.count <= 14 else { return "" }
        return s
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Advance the hysteresis state by one evaluation result. Two-tier:
    ///
    /// - A low-confidence or topic-less result is a "miss": it clears the pending
    ///   candidate streak but never disturbs the already-accepted topic.
    /// - A high-confidence topic equal to what's shown is a no-op (resets the streak).
    /// - A high-confidence *new* topic builds a streak. If nothing is accepted yet,
    ///   ONE hit is enough — the empty pill shouldn't wait through a hysteresis
    ///   window for its very first label. If a topic is already shown, *replacing*
    ///   it still needs `requiredStreak` (2) consecutive hits, so genuine topic-shift
    ///   detection stays damped against flicker.
    static func step(_ state: GateState, topic: String?, high: Bool,
                     requiredStreak: Int = MeetingSubtopicEngine.requiredStreak) -> GateState {
        var s = state
        guard high, let topic, !topic.isEmpty else {
            s.candidate = nil; s.candidateOriginal = nil; s.streak = 0
            return s
        }
        let norm = normalize(topic)
        if let accepted = s.accepted, normalize(accepted) == norm {
            s.candidate = nil; s.candidateOriginal = nil; s.streak = 0
            return s
        }
        if s.candidate == norm {
            s.streak += 1
            s.candidateOriginal = topic
        } else {
            s.candidate = norm
            s.candidateOriginal = topic
            s.streak = 1
        }
        // Eager first accept: nothing is shown yet, so don't make the user wait through
        // a hysteresis window for the FIRST label -- one confident hit fills the empty
        // pill immediately. Replacing an already-accepted topic still needs the full
        // streak below, so a genuine topic shift stays damped against flicker.
        let effectiveStreak = (s.accepted == nil) ? 1 : requiredStreak
        if s.streak >= effectiveStreak {
            s.accepted = s.candidateOriginal
            s.candidate = nil; s.candidateOriginal = nil; s.streak = 0
        }
        return s
    }
}
