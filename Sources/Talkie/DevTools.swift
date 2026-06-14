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
}
