import Foundation

/// Routes a spoken phrase to the matching `CommandIntent` and runs it — the single
/// entry point voice commands (08), macros (11), edit-by-voice (12), and
/// cross-surface (09) share, so safety (preview/undo) and selection handling live
/// in one place rather than forking per feature.
///
/// The *live* layer — the gesture entry (`HotKeyMonitor`), the AX selection read,
/// the preview UI (`HUD`), and injection (`TextInjector`) — is wired in the
/// integration pass (those files have live WIP). This owns the pure routing + run.
@MainActor
final class CommandRouter {
    private let macros: MacroStore
    private let summarizer: any Summarizer

    init(macros: MacroStore, summarizer: any Summarizer = PrivacyWall.assertLocal(OnDeviceLLM())) {
        self.macros = macros
        self.summarizer = summarizer
    }

    /// Verbs that signal an imperative rewrite command — the "parsed leading
    /// imperative" entry that needs no new gesture (roadmap §4, conflict 2).
    private static let rewriteVerbs: Set<String> = [
        "make", "fix", "rewrite", "translate", "summarize", "shorten", "expand",
        "rephrase", "improve", "polish", "format", "convert", "turn", "correct",
        "simplify", "bulletize", "capitalize", "lowercase",
    ]

    /// Pick the intent for a spoken phrase, or nil if it isn't a command. A
    /// whole-utterance macro match wins over a spelling command, which wins over a
    /// cross-surface request, which wins over an imperative rewrite. `meetings` is a
    /// fresh per-call snapshot (like `ContextGraphSnapshot`) — never cached on the
    /// router — because meetings mutate continuously and a stale snapshot would resolve
    /// "my last meeting" against whatever was last when the router happened to be
    /// constructed. `crossSurfaceEnabled` gates the one branch that's still
    /// dark-launched: it touches the live dictation-finalize path for every user, so it
    /// stays off by default until it's dogfooded (see
    /// `AppSettings.crossSurfaceCommandsEnabled`).
    ///
    /// Spelling ("spell kilo-8-sierra" → "k8s") is checked before the imperative
    /// rewrite so a leading "spell" is treated as the command, not the verb — but the
    /// parser is conservative (requires ≥2 spellable tokens after the trigger), so prose
    /// like "spell it out for the team" still fails the parse and falls through to
    /// normal dictation. It runs always-on (no flag): it's fully deterministic and
    /// on-device, touches no selection, and can't fire mid-sentence.
    func intent(for spoken: String, meetings: MeetingSnapshot = .empty, crossSurfaceEnabled: Bool = false) -> (any CommandIntent)? {
        if let expansion = macros.match(spoken) { return MacroIntent(expansion: expansion) }
        if let spelled = SpellingParser.parse(spoken) { return SpellingIntent(output: spelled) }
        if crossSurfaceEnabled, CrossSurfaceParser.parse(spoken) != nil {
            return CrossSurfaceIntent(meetings: meetings)
        }
        if isImperative(spoken) { return RewriteIntent() }
        return nil
    }

    /// Route + run in one call. `selection` / `target` / `graph` / `meetings` are
    /// supplied by the live layer (AX selection read + `ContextCapture` +
    /// `graph.snapshot()` + `MeetingSnapshot(meetings:)`); this is fully
    /// unit-testable in isolation.
    func run(
        spoken: String,
        selection: String?,
        target: TargetApp,
        graph: ContextGraphSnapshot,
        meetings: MeetingSnapshot = .empty,
        crossSurfaceEnabled: Bool = false
    ) async -> CommandResult? {
        guard let intent = intent(for: spoken, meetings: meetings, crossSurfaceEnabled: crossSurfaceEnabled) else { return nil }
        let ctx = CommandContext(
            spokenCommand: spoken,
            selection: selection,
            target: target,
            graph: graph,
            summarizer: summarizer
        )
        return await intent.run(ctx)
    }

    private func isImperative(_ spoken: String) -> Bool {
        guard let first = spoken.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first else { return false }
        return Self.rewriteVerbs.contains(String(first))
    }
}
