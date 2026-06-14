import AppKit

/// Tiny wrapper around system sounds for start/stop/insert/abort cues.
@MainActor
enum Feedback {
    static var enabled = true

    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func done() { play("Morse") }
    static func abort() { play("Funk") }
    /// Distinct alert for when dictation couldn't be pasted (no editable field
    /// focused) — the text was left on the clipboard instead.
    static func notPasted() { play("Submarine") }

    private static func play(_ name: String) {
        guard enabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
