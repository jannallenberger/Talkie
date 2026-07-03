import AppKit

/// Tiny wrapper around system sounds for start/stop/insert/abort cues.
@MainActor
enum Feedback {
    static var enabled = true

    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func done() { play("Morse") }
    static func abort() { play("Funk") }
    /// A tap-tap latched recording hands-free — a distinct "it's locked, you can let
    /// go" cue, kept clearly apart from the start/stop earcons so the lock is audible.
    static func locked() { play("Bottle") }
    /// Distinct alert for when dictation couldn't be pasted (no editable field
    /// focused) — the text was left on the clipboard instead.
    static func notPasted() { play("Submarine") }
    /// Gentle chime when Talkie auto-adds a learned correction to the dictionary.
    static func learned() { play("Glass") }

    private static func play(_ name: String) {
        guard enabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
