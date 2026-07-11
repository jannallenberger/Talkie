import Foundation

/// A14 — **on-device LLM jargon repair (dark spike).**
///
/// `NicheCorrector` is purely phonetic: it only rescues a known term when the
/// recognizer's mistake is within a skeleton edit-distance of ~1 ("Cubernets" →
/// "Kubernetes"). It structurally CANNOT catch a badly mangled novel term — when
/// Apple hears "claude.md" as "cloud MD" the skeletons already diverge, and a
/// term the recognizer shatters into unrelated words ("Higgsfield" → "Higgs
/// field" it catches; "idempotent" → "it depends on it" it does not) is out of
/// reach entirely.
///
/// This pass adds a second, orthogonal lever: hand the recognized text **plus the
/// user's KNOWN jargon list** to the on-device model and ask it to swap a mangled
/// run back to the listed spelling — but ONLY that. An unconstrained LLM
/// rewriting a transcript will hallucinate and over-correct, so the model's
/// output is never trusted directly. It is run through a **diff kill-switch**
/// (`guardedResult`) that admits a rewrite only when every changed span resolves
/// to inserting one of the known terms and nothing else moved. Worst case is a
/// no-op — over-correction is made structurally impossible, not merely unlikely.
///
/// ⚠️ Built DARK: gated behind `Dev.llmJargonRepair` (dev-only, default OFF).
/// With the flag off the `endDictation` path never calls this, so output is
/// byte-identical to today. Wiring it to the live default path is explicitly
/// gated on a jargon-corpus WER benchmark that has not been recorded yet.
///
/// The LLM call lives in `repair`; ALL of the safety logic (`guardedResult`) is a
/// pure static function that takes the model's output as a parameter, so the
/// guard is fully unit-testable without a live model.
struct LLMJargonRepair: Sendable {
    /// The wall-guarded on-device summarizer seam. Injected so tests can supply a
    /// fake, and so the privacy wall (feature 15) trips if a networked backend is
    /// ever wired into a local build (same discipline as `CommandRouter`).
    let model: any Summarizer

    init(model: any Summarizer = PrivacyWall.assertLocal(OnDeviceLLM())) {
        self.model = model
    }

    /// Whether the pass could run at all right now (on-device model available).
    static var isAvailable: Bool { OnDeviceLLM.isAvailable }

    // MARK: - Live pass (LLM call + guards)

    /// Repair mangled jargon in `text` against `knownTerms`, returning the repaired
    /// text — or `text` UNCHANGED whenever anything is off (model unavailable, empty
    /// input/terms, a refusal, a language flip, or the diff guard rejecting the
    /// rewrite). This is the only method that touches the model; everything it can
    /// return is either the input verbatim or the input with one-or-more known terms
    /// swapped in.
    func repair(_ text: String, knownTerms: [String]) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = Self.normalizedTerms(knownTerms)
        guard !trimmed.isEmpty, !terms.isEmpty, Self.isAvailable else { return text }

        let instructions = Self.instructions(for: terms)
        guard let raw = await model.generate(instructions: instructions, input: text) else {
            return text
        }
        return Self.guardedResult(input: text, llmOutput: raw, knownTerms: terms)
    }

    // MARK: - Pure guard (the kill-switch) — no model, fully testable

    /// The load-bearing safety property. Given the original `input`, a candidate
    /// `llmOutput`, and the `knownTerms` list, return the output ONLY if it is a
    /// safe repair; otherwise return `input` unchanged. "Safe" means ALL of:
    ///
    ///   1. Not a model refusal (reuses `CleanupEngine.isRefusal`).
    ///   2. Same dominant language as the input (no translation / language flip).
    ///   3. **Diff guard:** every changed span, compared token-by-token against the
    ///      input, resolves to *inserting exactly one known term* over a non-empty
    ///      run of input words. If any span inserts something that is not a known
    ///      term — or inserts a term where the user said nothing — the WHOLE output
    ///      is rejected. The pass may only ever introduce known terms.
    ///
    /// Because rejection falls back to `input`, the worst case is a no-op.
    static func guardedResult(input: String, llmOutput: String, knownTerms: [String]) -> String {
        let candidate = llmOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return input }

        // Identical (ignoring only leading/trailing whitespace) → nothing to guard.
        if candidate == input.trimmingCharacters(in: .whitespacesAndNewlines) { return input }

        // (1) Refusal guard — the model declined and returned boilerplate.
        if CleanupEngine.isRefusal(candidate) { return input }

        // (2) Diff guard — the kill-switch, and the only structural gate needed.
        //
        // There used to be a language guard here that rejected any candidate whose
        // dominant language differed from the input's, to stop the model translating.
        // It's removed for two reasons. It was NON-DETERMINISTIC: it relied on open-set
        // `NLLanguageRecognizer`, which scores short strings differently across
        // environments — on CI it read "open the cloud MD file" and "open the
        // Claude.md file" as different languages and dropped a valid fix, though both
        // score as English on a normal Mac. And it was REDUNDANT: a real translation
        // rewrites the words *around* any known term, so its multi-token, non-known-term
        // hunks already fail the diff guard below. `testLanguageFlipFallsBack` pins this
        // — an English→German rewrite is still rejected with the language guard gone.
        return diffGuardAccepts(input: input, candidate: candidate, terms: knownTerms) ? candidate : input
    }

    /// True iff `candidate` differs from `input` ONLY by replacing whole runs of
    /// input words with a single known term each (and every such term is in
    /// `terms`). Pure and allocation-cheap; runs on whitespace tokens via Swift's
    /// `CollectionDifference`.
    ///
    /// Rationale for whitespace tokens: a mangled novel term is typically heard as
    /// several ordinary words ("cloud MD" ← "claude.md"), so the misrecognition is
    /// multi-token while the correct spelling is one token. Splitting on whitespace
    /// makes the removed side (the mistake) and the inserted side (the fix) fall out
    /// as adjacent remove/insert hunks that we can validate independently.
    static func diffGuardAccepts(input: String, candidate: String, terms: [String]) -> Bool {
        let before = whitespaceTokens(input)
        let after = whitespaceTokens(candidate)
        // A pure whitespace/formatting change with identical tokens is not a repair
        // we asked for — reject so the untouched input is what ships.
        if before == after { return false }

        let termKeys = Set(terms.map(canonicalKey))
        // Every accepted insertion must be a *single* known term. Precompute their
        // canonical keys so an inserted token like "claude.md" matches term
        // "Claude.md" and a hyphen/case variant of a listed term still resolves.
        guard !termKeys.isEmpty else { return false }

        // Group the CollectionDifference into aligned change hunks keyed by the
        // contiguous region of the *input* they touch. `.difference(from:)` reports
        // removals at offsets into `before` and insertions at offsets into `after`;
        // we walk both sequences in lockstep so each hunk pairs the removed input
        // run with the inserted output run at the same position.
        let diff = after.difference(from: before)
        var removedByOffset: [Int: Bool] = [:]
        var insertedByOffset: [Int: String] = [:]
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removedByOffset[offset] = true
            case let .insert(offset, element, _): insertedByOffset[offset] = element
            }
        }
        guard !removedByOffset.isEmpty || !insertedByOffset.isEmpty else { return false }

        // Reconstruct the edit as ordered hunks. Walk `before` and `after` together
        // using the classic two-cursor merge over the sorted diff offsets.
        var bi = 0, ai = 0
        while bi < before.count || ai < after.count {
            let removedHere = removedByOffset[bi] == true
            let insertedHere = insertedByOffset[ai] != nil
            if !removedHere && !insertedHere {
                // Unchanged token — it MUST match on both sides (a mismatch would mean
                // an edit the diff attributed elsewhere; be conservative and reject).
                if bi >= before.count || ai >= after.count || before[bi] != after[ai] {
                    return false
                }
                bi += 1; ai += 1
                continue
            }
            // Start of a change hunk: consume the maximal run of removed input tokens
            // and inserted output tokens that are adjacent here.
            var removedRun: [String] = []
            while bi < before.count, removedByOffset[bi] == true {
                removedRun.append(before[bi]); bi += 1
            }
            var insertedRun: [String] = []
            while ai < after.count, insertedByOffset[ai] != nil {
                insertedRun.append(after[ai]); ai += 1
            }
            if !hunkIsKnownTermSubstitution(removed: removedRun, inserted: insertedRun, termKeys: termKeys) {
                return false
            }
        }
        return true
    }

    /// A single change hunk is legal iff it REPLACES a non-empty run of input words
    /// with exactly one known term. Pure insertion (nothing removed) is rejected —
    /// the pass may only *repair* words the user actually said, never conjure a term
    /// into a gap. Pure deletion (nothing inserted) is rejected — dropping the user's
    /// words is not a jargon repair. A multi-token insertion is rejected — a known
    /// term is one token, so several inserted tokens signal free-form rewriting.
    private static func hunkIsKnownTermSubstitution(removed: [String], inserted: [String], termKeys: Set<String>) -> Bool {
        guard !removed.isEmpty, inserted.count == 1 else { return false }
        return termKeys.contains(canonicalKey(inserted[0]))
    }

    // MARK: - Helpers

    /// Whitespace-delimited tokens, preserving punctuation attached to each word so
    /// "retry back." and "retry back" are distinguishable and unchanged spans are
    /// compared verbatim.
    static func whitespaceTokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// A comparison key that ignores case and non-alphanumerics, so an inserted
    /// "claude.md" matches the listed term "Claude.md" and "Higgs-field" matches
    /// "Higgsfield". Deliberately loose on punctuation ONLY — it still requires the
    /// letters/digits to match a listed term exactly, so it can't admit an arbitrary
    /// word.
    static func canonicalKey(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Dedup + trim the incoming term list, dropping empties. Case-insensitive by
    /// canonical key so the same term listed twice doesn't bloat the prompt.
    static func normalizedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = canonicalKey(t)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(t)
        }
        return out
    }

    /// The strict, conservative system prompt. It names the ONLY permitted edit
    /// (swap a misrecognized run to a listed term) and forbids everything else. The
    /// diff guard enforces this regardless, but a tighter prompt means fewer
    /// rewrites get thrown away, so the pass is more useful when it is eventually
    /// measured.
    static func instructions(for terms: [String]) -> String {
        let list = terms.map { "- \($0)" }.joined(separator: "\n")
        return """
        You proofread dictated text for misrecognized technical terms. You are given \
        a list of KNOWN TERMS. Your ONLY job: when a run of words in the text is an \
        obvious misrecognition of one of the KNOWN TERMS, replace that run with the \
        term exactly as it appears in the list. Do NOTHING else.

        Rules:
        - Change a run of words ONLY when it clearly sounds like one of the KNOWN TERMS \
        (e.g. "cloud MD" → "Claude.md", "Higgs field" → "Higgsfield").
        - Never introduce a term that is not in the list. Never add, remove, reorder, \
        translate, rephrase, summarize, or re-punctuate anything else.
        - Preserve every other word, and all identifiers, file paths, code, numbers, \
        casing, and punctuation, EXACTLY as given.
        - Keep the same language.
        - If nothing clearly matches a KNOWN TERM, return the text completely unchanged.
        - Output ONLY the resulting text — no preamble, quotes, or explanation.

        KNOWN TERMS:
        \(list)
        """
    }
}
