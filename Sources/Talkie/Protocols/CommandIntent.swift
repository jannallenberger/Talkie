import Foundation

/// The voice-copilot intent layer (the 5th spine protocol). Turns a spoken
/// command + the current selection into a safe, previewable, undoable text
/// transform. Voice commands (08), edit-by-voice (12), macros (11), and
/// cross-surface (09) are all `CommandIntent`s behind one `CommandRouter`, so they
/// share entry, the safety contract, and injection (always via `TextInjector`).
protocol CommandIntent: Sendable {
    var id: String { get }
    /// true → read the AX selection before running.
    var needsSelection: Bool { get }
    /// true → must produce a preview/undo (safety is in the protocol, not each feature).
    var isMutating: Bool { get }

    /// Produce the replacement text (or nil = no-op).
    func run(_ ctx: CommandContext) async -> CommandResult?
}

/// Everything an intent needs: the spoken command, the current selection, the
/// target app, the graph snapshot (so commands can pull people/commitments — 09),
/// and a summarizer (on-device by default; the opt-in bridge when enabled).
struct CommandContext: Sendable {
    var spokenCommand: String
    var selection: String?
    var target: TargetApp
    var graph: ContextGraphSnapshot
    var summarizer: any Summarizer
    /// The just-dictated entry, when one is still eligible to be edited in place —
    /// same app, ≤45s old, and its insertion actually landed (B9). Populated at the
    /// dispatch site from `ImplicitSelectionGate.eligible(...)`, gated on the last
    /// outcome being `.inserted`. `nil` in every other case (including all callers
    /// predating B9), so edit intents ("scratch that", "replace X with Y") that depend
    /// on it simply never route when there's nothing safe to edit — fail-closed.
    /// Defaulted so call sites predating B9 (the rewrite / macro / cross-surface
    /// dispatch) keep constructing `CommandContext` unchanged.
    var lastInserted: DictationEntry? = nil
}

struct CommandResult: Sendable {
    var replacement: String
    /// true → show a preview/confirm before injecting.
    var preview: Bool
    /// Restores the prior selection on undo.
    var undoToken: String?
}
