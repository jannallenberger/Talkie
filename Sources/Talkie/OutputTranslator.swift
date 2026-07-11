import Foundation

/// Dictate-in-L1, insert-in-L2 (E8). When an app carries a per-app *output
/// language* override (`AppProfile.outputLanguageCode`, e.g. Slack → English), the
/// finished dictation is translated ON-DEVICE into that language just before
/// insertion — so a German speaker drafts English messages by voice, zero network,
/// zero new global settings.
///
/// This is the deliberate INVERSE of `CleanupEngine`'s translation guard: cleanup
/// must *never* flip the language (it only polishes), whereas this pass *must* flip
/// it — but only when it can prove it did so faithfully. The LLM runs through the
/// same `PrivacyWall.assertLocal(OnDeviceLLM())` seam the command copilot uses
/// (`CommandRouter`), so a networked summarizer can never quietly defeat the wall.
///
/// FOUR guards, every one of which falls back to the UNtranslated text — the honest
/// failure mode is "we inserted your words as spoken", never a refusal string and
/// never the silently-wrong language:
///   (a) **language mismatch** — the model's output must actually read as the
///       target language (the inverse of cleanup's guard). If it didn't translate,
///       keep the spoken text.
///   (b) **refusal** — reuse `CleanupEngine.isRefusal`; a safety refusal is never
///       inserted in place of the user's words.
///   (c) **jargon survival** — every dictionary/vocabulary term present in the
///       input must survive VERBATIM in the output ("claude.md", "Higgsfield" must
///       never be translated or mangled). If any is lost, keep the spoken text.
///   (d) **already the target language** — if the input is already in the target
///       language, there is nothing to translate: return it unchanged with ZERO
///       LLM calls (the cheap common case for a native speaker of that app's
///       language).
///
/// The guard logic ((a)/(c)/(d)) is a pure, deterministic `decision(...)` core so
/// the gate — a deterministic-fallback test suite — can exercise it without the
/// model.
enum OutputTranslator {

    /// The outcome of the pure guard core: either accept the model's translation or
    /// fall back to the untranslated text (with the reason, for the debug log).
    enum Decision: Equatable {
        /// The input is already in the target language — skip the model entirely and
        /// insert the original text (guard (d)).
        case skipAlreadyTarget
        /// The translation cleared every guard — insert `text`.
        case accept(String)
        /// A guard tripped — insert the ORIGINAL untranslated text. `reason` is a
        /// short marker for the opt-in debug log (`talkieDebugLog`), never shown
        /// to the user.
        case fallback(reason: String)
    }

    /// The pure pre-flight check run BEFORE the model: is there anything to
    /// translate at all? Returns `.skipAlreadyTarget` when guard (d) fires (input
    /// already in the target language, or too short to tell apart — treated as "keep
    /// as spoken" so a two-word utterance never burns an LLM pass), otherwise `nil`
    /// meaning "go run the model, then call `decideOutput`".
    ///
    /// `inputCode` is the language the dictation was pinned to for this session
    /// (the recognizer's chosen locale via `cleanupLangCode`), falling back to
    /// content detection when that's absent — we never re-detect the input beyond
    /// this. `target` is the base code the app wants ("en").
    static func preflight(input: String, inputCode: String?, target: String) -> Decision? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetCode = base(target)
        guard !trimmed.isEmpty, !targetCode.isEmpty else {
            // Nothing to translate, or no meaningful target — keep as spoken.
            return .skipAlreadyTarget
        }
        // Guard (d): already the target language ⇒ no LLM call. Prefer the session's
        // pinned input code (do NOT re-detect); fall back to content detection only
        // when the session had none. A too-short utterance we can't language-ID is
        // also skipped — translating "okay thanks" round-trips to noise as often as
        // not, and the honest default is to insert what was said.
        let resolvedInput = base(inputCode).flatMap { $0.isEmpty ? nil : $0 }
            ?? LanguageDetector.dominantLanguageCode(trimmed)
        if let resolvedInput, resolvedInput == targetCode {
            return .skipAlreadyTarget
        }
        if resolvedInput == nil, !LanguageDetector.canScore(trimmed) {
            // Can't tell the input language and it's too short to detect — don't
            // gamble a translation on a fragment.
            return .skipAlreadyTarget
        }
        return nil
    }

    /// The pure post-flight guard core: given the model's candidate `output`, the
    /// original `input`, the target code, and the jargon terms that must survive,
    /// decide whether to accept the translation or fall back. Deterministic and
    /// model-free so the gate suite can exercise every guard.
    ///
    /// - guard (b) refusal: an `isRefusal` output falls back.
    /// - guard (a) mismatch: the output must read as `target`; if it still reads as
    ///   another language the model didn't translate — fall back.
    /// - guard (c) jargon: every term in `mustSurvive` that occurred in the input
    ///   must occur (case-insensitively) in the output; a lost term falls back.
    static func decideOutput(
        input: String,
        output: String,
        target: String,
        mustSurvive: [String]
    ) -> Decision {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetCode = base(target)
        guard !cleaned.isEmpty else { return .fallback(reason: "empty") }

        // (b) Refusal: reuse cleanup's detector — never insert "I cannot comply…".
        if CleanupEngine.isRefusal(cleaned) {
            return .fallback(reason: "refusal")
        }

        // (c) Jargon survival: a term the user actually said (dictionary/vocabulary)
        // must come out verbatim. Only terms that were IN the input are required —
        // a translation legitimately won't invent terms that weren't spoken. Checked
        // before the language guard so a mangled "Higgsfield" fails for the right
        // reason in the logs.
        let lowerInput = input.lowercased()
        let lowerOutput = cleaned.lowercased()
        for term in mustSurvive {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !t.isEmpty, lowerInput.contains(t) else { continue }
            if !lowerOutput.contains(t) {
                return .fallback(reason: "jargon-lost:\(term)")
            }
        }

        // (a) Language mismatch (the INVERSE of cleanup's guard): the output must
        // read as the target language. If it's too short to score we accept it (the
        // jargon + refusal guards already passed and there's nothing better to do);
        // if it scores as a DIFFERENT language the model failed to translate.
        if LanguageDetector.canScore(cleaned),
           let outCode = LanguageDetector.dominantLanguageCode(cleaned),
           outCode != targetCode {
            return .fallback(reason: "not-target:\(outCode)≠\(targetCode)")
        }

        return .accept(cleaned)
    }

    /// The system instruction for the translate pass. Kept deliberately minimal —
    /// chasing quality with a bigger prompt is out of scope (the guards make failure
    /// safe); the one thing it MUST insist on is preserving identifiers verbatim, so
    /// the jargon guard rarely has to fire.
    static func instructions(targetName: String) -> String {
        """
        You are a translator. Translate the user's dictated text into \(targetName).
        Output ONLY the translation — no quotes, no preamble, no commentary, no notes.
        Preserve every code identifier, file path, URL, @handle, and product or brand \
        name EXACTLY as written — never translate, transliterate, or reformat them \
        (e.g. keep "claude.md", "Higgsfield", "SwiftUI" character-for-character). \
        Keep the meaning, tone, and any line breaks.
        """
    }

    /// Translate `text` into `target` on-device, or return the original text when
    /// any guard trips (never a refusal, never the wrong language). `inputCode` is
    /// the session's pinned language (do not re-detect); `mustSurvive` is the
    /// dictionary/vocabulary/niche terms that have to come through verbatim. The
    /// `summarizer` is injected (defaults to the on-device model behind the privacy
    /// wall) so the guard suite and the app share one code path.
    ///
    /// Returns `(text, translated)` — `translated` is `true` only when a real,
    /// guard-cleared translation was applied, so the caller can SKIP arming
    /// learn-from-edits (an edit to translated text is not a recognition
    /// correction and would poison `CorrectionExtractor`).
    static func translate(
        _ text: String,
        to target: String,
        inputCode: String?,
        mustSurvive: [String] = [],
        summarizer: any Summarizer = PrivacyWall.assertLocal(OnDeviceLLM())
    ) async -> (text: String, translated: Bool) {
        // Guard (d) + trivial cases, before we ever touch the model.
        switch preflight(input: text, inputCode: inputCode, target: target) {
        case .skipAlreadyTarget:
            return (text, false)
        case .accept, .fallback, nil:
            break
        }
        guard let targetName = LanguageDetector.displayName(forLanguageCode: base(target)),
              type(of: summarizer).isAvailable else {
            // No model (Apple Intelligence off) or an unnameable target — insert as
            // spoken. Never block dictation on translation being available.
            talkieDebugLog("translate[→\(target)]: model/target unavailable — keeping spoken text")
            return (text, false)
        }

        let out = await summarizer.generate(
            instructions: instructions(targetName: targetName),
            input: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let out else {
            talkieDebugLog("translate[→\(target)]: model returned nothing — keeping spoken text")
            return (text, false)
        }

        switch decideOutput(input: text, output: out, target: target, mustSurvive: mustSurvive) {
        case .accept(let translated):
            // Lengths + language only — never the dictated/translated text
            // itself, even in the opt-in debug sink (see talkieDebugLog).
            talkieDebugLog("translate[→\(target)]: in=\(text.count) out=\(translated.count) lang=\(target)")
            return (translated, true)
        case .fallback(let reason):
            talkieDebugLog("translate[→\(target)]: rejected (\(reason)) — keeping spoken text")
            return (text, false)
        case .skipAlreadyTarget:
            // Unreachable from decideOutput, but exhaustive: keep spoken.
            return (text, false)
        }
    }

    /// The base language code of a code or locale id ("de-DE" → "de", "en" → "en"),
    /// lowercased. Accepts either a bare code or a full locale id so the field can
    /// hold either shape.
    private static func base(_ code: String) -> String {
        if let c = LanguageDetector.languageCode(of: code) { return c.lowercased() }
        return code.lowercased()
    }

    private static func base(_ code: String?) -> String? {
        code.map { base($0) }
    }
}
