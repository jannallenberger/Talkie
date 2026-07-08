import AppKit

/// Pauses now-playing media for the duration of a dictation, then resumes exactly
/// what it paused.
///
/// macOS has no public API to pause arbitrary apps' audio (there's no AppKit
/// equivalent of iOS's `AVAudioSession` "other audio" interruption). So we drive
/// the two players that cover the overwhelming majority of cases — Apple Music and
/// Spotify — via AppleScript, **state-aware**: only pause what's actually playing,
/// only resume what we paused, and only ever touch a player that's already
/// running — this can never launch either app.
///
/// There used to also be a blind system-media-key fallback for everything else
/// (browsers, podcast apps). It's gone: macOS's documented behavior for an
/// unclaimed play/pause key is to launch Music.app and make it frontmost, and the
/// "is something else playing" signal it was gated on (any process with an active
/// CoreAudio output stream) false-positives constantly — a muted video tab, a
/// call app's idle audio session, anything holding output IO open. The result was
/// Music.app launching on essentially every dictation, stealing focus, and (worse)
/// leaving it as the frontmost app while it's still cold-launching — exactly the
/// state where the pipeline's synchronous, no-timeout AX reads of "whatever's
/// frontmost" (`AXFieldReader`, `hasEditableFocus`) can hang indefinitely, which is
/// what made `isProcessing` get stuck. Losing the browser/podcast ducking is the
/// right trade for never doing that again.
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

    /// Pause whatever is currently playing. Returns immediately; the work runs off
    /// the main thread. Idempotent: a second call while already paused does nothing.
    func pauseForDictation() {
        queue.async { [weak self] in
            guard let self, self.pausedPlayers.isEmpty else { return }
            for player in Player.allCases where self.isRunning(player) {
                if self.pauseIfPlaying(player) {
                    self.pausedPlayers.insert(player)
                }
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
