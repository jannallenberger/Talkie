import AppIntents

// The spoken/Spotlight phrase surface for Talkie's App Intents. Declaring an
// `AppShortcutsProvider` is what makes the actions show up as *predictable*
// Spotlight suggestions and gives them Siri phrases — without it the intents are
// only reachable by hand inside the Shortcuts app. Each `AppShortcut` binds one
// intent to a set of natural-language phrases.
//
// House rules for the phrases (enforced by the framework at build time):
//   • Every phrase MUST contain `\(.applicationName)` — the system needs the app
//     name in the utterance to disambiguate which app to route to. We keep it at
//     the end ("… with Talkie") so the phrases read naturally.
//   • The app name resolves from the bundle, so these localize with the app's
//     display name automatically. The `.appintents` metadata step in
//     `scripts/build_app.sh` picks this provider up alongside the intents (it
//     globs all of Sources/Talkie), so no build wiring is needed.
//
// `SearchMemoryIntent` takes a free-text `query`. App Shortcut phrases can't bind
// arbitrary free text at the phrase level, so these phrases *launch* the search
// action and Shortcuts/Siri then asks for the query — the honest, non-magical
// behaviour for an open-ended parameter. (Parameterized phrases are only for
// fixed, enumerable option sets, which a search box is not.)
//
// On-device only: no network symbols, nothing leaves the Mac. Scanned by
// scripts/check-no-network.sh under Sources/Talkie.
struct TalkieAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Toggle dictation with \(.applicationName)",
                "Start dictation with \(.applicationName)",
                "Dictate with \(.applicationName)"
            ],
            shortTitle: "Toggle Dictation",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: GetLastDictationIntent(),
            phrases: [
                "Get my last dictation from \(.applicationName)",
                "What was my last dictation in \(.applicationName)"
            ],
            shortTitle: "Get Last Dictation",
            systemImageName: "text.quote"
        )
        AppShortcut(
            intent: SearchMemoryIntent(),
            phrases: [
                "Search my \(.applicationName) memory",
                "Search \(.applicationName) memory",
                "Look it up in \(.applicationName)"
            ],
            shortTitle: "Search Memory",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: ToggleMeetingRecordingIntent(),
            phrases: [
                "Toggle meeting recording with \(.applicationName)",
                "Record a meeting with \(.applicationName)",
                "Start a meeting with \(.applicationName)"
            ],
            shortTitle: "Toggle Meeting Recording",
            systemImageName: "waveform"
        )
    }
}
