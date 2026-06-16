import AppKit

/// Pauses now-playing media for the duration of a dictation, then resumes exactly
/// what it paused.
///
/// macOS has no public API to pause arbitrary apps' audio (there's no AppKit
/// equivalent of iOS's `AVAudioSession` "other audio" interruption). So we drive
/// the two players that cover the overwhelming majority of cases — Apple Music and
/// Spotify — via AppleScript, **state-aware**: only pause what's actually playing,
/// only resume what we paused. An opt-in media-key fallback covers everything else
/// (browsers, podcast apps), but it only fires when some other process is genuinely
/// playing output, so it can never *start* silent playback.
///
/// All AppleScript runs on a private serial queue, never the main thread:
/// `NSAppleScript.executeAndReturnError` blocks until the event completes, and the
/// first call raises a modal Automation permission prompt — neither of which may
/// stall the dictation pipeline. The queue also serializes pause/resume so resume
/// always sees the state pause left behind. State is therefore confined to that
/// queue, which is what makes `@unchecked Sendable` accurate here.
final class MusicController: @unchecked Sendable {

    private enum Player: CaseIterable {
        case appleMusic, spotify

        var bundleID: String {
            switch self {
            case .appleMusic: return "com.apple.Music"
            case .spotify: return "com.spotify.client"
            }
        }
        /// The AppleScript application name (scriptable target).
        var appName: String {
            switch self {
            case .appleMusic: return "Music"
            case .spotify: return "Spotify"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.coralate.talkie.music")
    /// Players we paused for the current dictation — resume touches only these.
    /// Confined to `queue`.
    private var pausedPlayers: Set<Player> = []
    /// Set when we used the blind media-key fallback, so resume re-sends the key.
    /// Confined to `queue`.
    private var usedMediaKeyFallback = false

    /// Pause whatever is currently playing. Returns immediately; the work runs off
    /// the main thread. Idempotent: a second call while already paused does nothing.
    /// `allowMediaKeyFallback` enables the system play/pause key for non-scriptable
    /// players.
    func pauseForDictation(allowMediaKeyFallback: Bool) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        queue.async { [weak self] in
            guard let self, self.pausedPlayers.isEmpty, !self.usedMediaKeyFallback else { return }

            var pausedAny = false
            for player in Player.allCases where self.isRunning(player) {
                if self.pauseIfPlaying(player) {
                    self.pausedPlayers.insert(player)
                    pausedAny = true
                }
            }

            // Nothing scriptable was playing. If enabled, nudge the system
            // play/pause key — but only when some other app is genuinely outputting
            // audio, so we never start playback that wasn't there.
            guard !pausedAny, allowMediaKeyFallback else { return }
            if AudioDevices.isOtherProcessPlayingOutput(excludingPID: selfPID) {
                MediaKey.sendPlayPause()
                self.usedMediaKeyFallback = true
            }
        }
    }

    /// Resume exactly what we paused. Returns immediately. Idempotent: a no-op if we
    /// paused nothing.
    func resumeAfterDictation() {
        queue.async { [weak self] in
            guard let self else { return }
            for player in self.pausedPlayers where self.isRunning(player) {
                _ = self.runScript("tell application \"\(player.appName)\" to play")
            }
            self.pausedPlayers.removeAll()
            if self.usedMediaKeyFallback {
                MediaKey.sendPlayPause()
                self.usedMediaKeyFallback = false
            }
        }
    }

    // MARK: - Helpers (all on `queue`)

    private func isRunning(_ player: Player) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty == false
    }

    /// Returns true iff the player was playing and we paused it.
    private func pauseIfPlaying(_ player: Player) -> Bool {
        let source = """
        tell application "\(player.appName)"
            if player state is playing then
                pause
                return true
            end if
            return false
        end tell
        """
        return runScript(source)?.booleanValue ?? false
    }

    @discardableResult
    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { talkieDebugLog("MusicController AppleScript error: \(error)") }
        return result
    }
}

/// Posts the system "Play/Pause" media key. This is a blind toggle (it can't read
/// or target a specific player), so callers gate it on actual output activity.
private enum MediaKey {
    /// The NX system-defined "play/pause" key code (from `ev_keymap.h`). Hardcoded
    /// to avoid an IOKit import for a single constant.
    private static let playPauseKey = 16

    static func sendPlayPause() {
        post(keyDown: true)
        post(keyDown: false)
    }

    private static func post(keyDown: Bool) {
        let flagsValue: UInt = keyDown ? 0xA00 : 0xB00
        let data1 = (playPauseKey << 16) | ((keyDown ? 0xA : 0xB) << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flagsValue),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
