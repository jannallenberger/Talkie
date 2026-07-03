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
///   2. A new topic must clear that bar on **two consecutive** evaluations before it
///      replaces what's shown (`step`). One-off blips never surface; the current
///      topic holds until a genuinely new one is sustained.
///
/// Evaluation is throttled (a slow poll loop that only fires once enough new speech
/// has accumulated) so the shared on-device model isn't hammered, and the `actor`
/// serializes everything so at most one evaluation runs at a time.
actor MeetingSubtopicEngine {

    // MARK: Tunables

    /// Rolling transcript window kept in memory; older speech falls off the front.
    private static let maxWindowChars = 2000
    /// The model only sees the tail of the window (the recent conversation).
    private static let maxInputChars = 1800
    /// Don't evaluate until at least this much *new* speech has arrived since the
    /// last evaluation — avoids re-labeling identical text and bounds model calls.
    private static let minNewCharsToEval = 180
    /// How often the loop wakes to consider an evaluation. With the new-chars gate
    /// this yields an effective cadence of ~12 s+ of fresh speech per model call.
    private static let evalInterval: Duration = .seconds(12)
    /// Consecutive high-confidence evaluations a *new* topic needs before it shows.
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
        let m = model
        Task { @MainActor in m.current = nil }
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
    }

    // MARK: Evaluation

    private func tick() async {
        guard charsSinceEval >= Self.minNewCharsToEval else { return }
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
            let m = model
            Task { @MainActor in m.current = now }
            // Same instant the pill updates: notify the chapter collector. The
            // callback stamps the accept time itself, so the engine stays free of
            // any clock/recorder dependency and the pill behavior is untouched.
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

    Respond with EXACTLY two lines and nothing else:
    TOPIC|<2 to 5 word phrase, or NONE>
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

    /// Parse the model's two-line response. Tolerant: unknown lines are ignored, and
    /// a `TOPIC` that's empty, `NONE`, or out of bounds yields `nil` (no topic).
    static func parse(_ response: String) -> (topic: String?, high: Bool) {
        var topic: String?
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
            case "CONFIDENCE":
                high = value.uppercased().hasPrefix("HIGH")
            default:
                continue
            }
        }
        return (topic, high)
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

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Advance the hysteresis state by one evaluation result.
    ///
    /// - A low-confidence or topic-less result is a "miss": it clears the pending
    ///   candidate streak but never disturbs the already-accepted topic.
    /// - A high-confidence topic equal to what's shown is a no-op (resets the streak).
    /// - A high-confidence *new* topic builds a streak; once it reaches
    ///   `requiredStreak` consecutive hits it's accepted and becomes what's shown.
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
        if s.streak >= requiredStreak {
            s.accepted = s.candidateOriginal
            s.candidate = nil; s.candidateOriginal = nil; s.streak = 0
        }
        return s
    }
}
