import AppKit

/// Tiny wrapper around system sounds for start/stop/insert/abort cues.
@MainActor
enum Feedback {
    static var enabled = true

    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func done() { play("Morse") }
    static func abort() { play("Funk") }

    private static func play(_ name: String) {
        guard enabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
