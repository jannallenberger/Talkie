import Foundation

/// Developer affordances (replaying onboarding, etc.) that should never reach a
/// normal user but need to be reachable while building Talkie.
///
/// Enabled when EITHER:
///   • this is a Debug build (`swift build -c debug` / `./scripts/run.sh debug`), or
///   • `TalkieDevMode` is set in defaults — useful on a Release build:
///       `defaults write com.coralate.talkie TalkieDevMode -bool YES`
enum Dev {
    static let devModeKey = "TalkieDevMode"

    static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: devModeKey)
        #endif
    }

    /// A14 — the on-device LLM jargon-repair spike (`LLMJargonRepair`). DARK by
    /// default: this is an unproven measurement prototype whose live wiring is
    /// gated on a jargon-corpus WER benchmark that has not been recorded, so it
    /// must NEVER change default dictation output. Unlike `isEnabled` it is OFF
    /// even in Debug builds — it is opt-in ONLY via an explicit defaults key AND
    /// only honored while dev mode is on:
    ///     defaults write com.coralate.talkie TalkieLLMJargonRepair -bool YES
    /// When this is `false`, `endDictation` skips the pass entirely and the
    /// inserted text is byte-identical to a build without A14.
    static let llmJargonRepairKey = "TalkieLLMJargonRepair"

    /// The phonetic `NicheCorrector` pass on dictation. OFF by default since
    /// 2026-09-22: a stage-by-stage trace of a real German paragraph showed 6 of
    /// its 7 "fixes" were wrong — it dropped articles ("die Wörter" → "Wörter"),
    /// merged words ("Bild ein" → "Bilder") and bent ordinary words toward learned
    /// terms ("Modell" → "Modelle"). Exact dictionary rules stay on. Opt back in:
    ///     defaults write com.coralate.talkie NicheCorrectorOn -bool YES
    static let nicheCorrectorKey = "NicheCorrectorOn"

    static var nicheCorrector: Bool {
        UserDefaults.standard.bool(forKey: nicheCorrectorKey)
    }

    static var llmJargonRepair: Bool {
        isEnabled && UserDefaults.standard.bool(forKey: llmJargonRepairKey)
    }
}
