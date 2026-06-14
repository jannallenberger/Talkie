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

    init(macros: MacroStore, summarizer: any Summarizer = OnDeviceLLM()) {
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
    /// whole-utterance macro match wins over an imperative rewrite.
    func intent(for spoken: String) -> (any CommandIntent)? {
        if let expansion = macros.match(spoken) { return MacroIntent(expansion: expansion) }
        if isImperative(spoken) { return RewriteIntent() }
        return nil
    }

    /// Route + run in one call. `selection` / `target` / `graph` are supplied by the
    /// live layer (AX selection read + `ContextCapture` + `graph.snapshot()`) once
    /// wired; until then this is fully unit-testable in isolation.
    func run(
        spoken: String,
        selection: String?,
        target: TargetApp,
        graph: ContextGraphSnapshot
    ) async -> CommandResult? {
        guard let intent = intent(for: spoken) else { return nil }
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
