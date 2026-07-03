import AppIntents
import Foundation

// Talkie's App Intents surface. These make Talkie's two core actions —
// toggle dictation, read back the last dictation — discoverable in Shortcuts,
// Spotlight, and Raycast (which reads the system App Intents registry, so it
// gets them with zero extension code). This is the foundation the rest of the
// intents suite (G7+) rides on: it proves the metadata pipeline works from a
// hand-assembled SwiftPM build (there is no Xcode build phase here, so
// `scripts/build_app.sh` runs `appintentsmetadataprocessor` itself to emit the
// `Metadata.appintents` bundle Shortcuts/Spotlight discovery requires).
//
// Concurrency: every `perform()` hops to `@MainActor` explicitly — App Intents
// enter through framework callbacks off the main actor, and everything they
// touch (`AppDelegate`, `HistoryStore`) is main-actor-isolated. This is the
// exact framework-callback boundary the `-disable-dynamic-actor-isolation`
// frontend flag in Package.swift exists for; the hop keeps us statically
// correct regardless.
//
// On-device only: no network symbols here, nothing leaves the Mac. This file
// lives under Sources/Talkie and is scanned by scripts/check-no-network.sh.

/// Start or stop dictation from Shortcuts / Spotlight / Raycast. Mirrors a
/// hotkey press: if a dictation is in flight it ends (polish + insert into the
/// frontmost app), otherwise it begins.
struct ToggleDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription(
        "Start dictating into whatever app is in front, or stop and insert what you said."
    )

    // CRITICAL: never open or activate Talkie. Talkie dictates into the
    // *frontmost* app; if this intent brought Talkie forward, ContextCapture
    // would target Talkie itself and inject into its own window. Dictation is
    // driven entirely off-screen, so there is nothing to show.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let app = AppDelegate.shared else {
            // The action fired but Talkie isn't running, so there is no engine,
            // no hotkey, nothing to toggle. Say so plainly rather than silently
            // no-op'ing (which would look like a broken shortcut).
            throw TalkieIntentError.talkieNotRunning
        }
        app.toggleDictationFromIntent()
        return .result()
    }
}

/// Return the text of your most recent dictation — the newest row on the
/// History tab. Handy as a Shortcuts step ("paste my last dictation", "send my
/// last dictation to …").
struct GetLastDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Dictation"
    static let description = IntentDescription(
        "Return the text of your most recent dictation."
    )

    // Pure read of the on-disk history; no reason to bring Talkie forward.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let app = AppDelegate.shared else {
            throw TalkieIntentError.talkieNotRunning
        }
        // `entries` is newest-first, so `.first` is the most recent dictation.
        let text = app.history.entries.first?.text ?? ""
        return .result(value: text)
    }
}

/// Errors surfaced to Shortcuts/Spotlight when an intent can't run. The
/// `CustomLocalizedStringResourceConvertible` conformance is what Shortcuts
/// shows the user in the error banner.
enum TalkieIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case talkieNotRunning

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .talkieNotRunning:
            return "Talkie isn’t running. Open Talkie, then try again."
        }
    }
}

/// Groups Talkie's intents under one heading in the Shortcuts library. G7 adds
/// the remaining actions + `AppShortcuts` phrases; this package ships only the
/// two foundation intents.
struct TalkieIntentsPackage: AppIntentsPackage {}
