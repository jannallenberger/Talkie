import AppKit

/// Talkie's feedback channel (K2): a small family of earcons plus trackpad haptics
/// for the start / stop / lock / insert / clipboard / learn moments. Each cue
/// resolves a bundled `.caf` from `Resources/Sounds/` FIRST, falling back to the
/// same-purpose macOS system sound when the asset is absent — so a missing earcon is
/// a graceful downgrade, never a crash or silence. The bundled earcons are gentle
/// synthesized placeholders (see `Resources/Sounds/PROVENANCE.md`); the final set is
/// a macaw-derived sound-design pass.
@MainActor
enum Feedback {
    static var enabled = true

    static func start()     { play("chirp-start",     fallback: "Tink") }
    static func stop()      { play("chirp-stop",      fallback: "Pop") }
    static func done()      { play("chirp-done",      fallback: "Morse"); haptic(.alignment) }
    static func abort()     { play(nil,               fallback: "Funk") }
    /// A tap-tap latched hands-free recording — a distinct "it's locked, you can let
    /// go" cue, kept clearly apart from start/stop so the lock is audible, plus a
    /// firmer trackpad tap so the latch is *felt*, not only heard.
    static func locked()    { play("chirp-lock",      fallback: "Bottle"); haptic(.levelChange) }
    /// Distinct alert for when dictation couldn't be pasted (no editable field
    /// focused) — the text was left on the clipboard instead.
    static func notPasted() { play("chirp-clipboard", fallback: "Submarine") }
    /// Gentle chime when Talkie auto-adds a learned correction to the dictionary.
    static func learned()   { play("chirp-learn",     fallback: "Glass") }

    /// A single trackpad haptic tap (a no-op on Macs without a Force Touch trackpad).
    /// Honors the same `enabled` flag as the earcons — haptics are one feedback channel.
    static func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Play a cue: a bundled Talkie earcon (`Resources/Sounds/<bundled>.caf`) when it
    /// exists, else the macOS system sound named `fallback`. `bundled == nil` skips
    /// straight to the system sound.
    private static func play(_ bundled: String?, fallback: String) {
        guard enabled else { return }
        if let bundled,
           let url = Bundle.main.url(forResource: bundled, withExtension: "caf", subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
            return
        }
        NSSound(named: NSSound.Name(fallback))?.play()
    }
}
