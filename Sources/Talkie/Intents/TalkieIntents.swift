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

/// Search your Talkie memory — dictations, meetings, and the entities Talkie has
/// picked up from them — from Shortcuts / Spotlight / Raycast, and get the top
/// matches back as text. This is the same on-device semantic+keyword `SearchEngine`
/// that powers the in-app Memory surface, so a query here returns the same ranking;
/// we just take the top few and render them as plain lines a shortcut can read,
/// speak, or pass on (no custom entity type — text is the least-surprising thing
/// for Raycast/Spotlight to display).
struct SearchMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Memory"
    static let description = IntentDescription(
        "Search what you've said, your meetings, and what Talkie has learned from them."
    )

    // A pure read of the on-device index; no reason to bring Talkie forward.
    static let openAppWhenRun = false

    @Parameter(title: "Query")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let app = AppDelegate.shared else {
            throw TalkieIntentError.talkieNotRunning
        }
        // Top 5 is plenty for a text read-back; the ranking is identical to the
        // app's Memory surface (which uses the same engine), so these are its top
        // hits, just capped and flattened to lines.
        let hits = app.searchEngine.search(query, limit: 5)
        guard !hits.isEmpty else {
            // Mirror the Memory surface's empty state so behaviour matches the app.
            return .result(value: "No matches".loc)
        }
        let lines = hits.map { hit in
            "\(Self.kindLabel(hit.kind)) — \(Self.dateLabel(hit.dateUnix)) — \(hit.snippet)"
        }
        return .result(value: lines.joined(separator: "\n"))
    }

    /// A human label for a hit's source, localized. The raw `SearchRecordKind`
    /// cases are lowercase identifiers, not display copy.
    private static func kindLabel(_ kind: SearchRecordKind) -> String {
        switch kind {
        case .dictation: return "Dictation".loc
        case .meeting: return "Meeting".loc
        case .entity: return "Note".loc
        }
    }

    /// A short, locale-aware date for the line (the index stores Unix seconds).
    private static func dateLabel(_ dateUnix: Double) -> String {
        let date = Date(timeIntervalSince1970: dateUnix)
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Start or stop a meeting recording from Shortcuts / Spotlight / Raycast. If a
/// meeting is in progress it ends (finalize + summarize + save the note),
/// otherwise it begins. The begin-vs-end decision and the private recorder live
/// in `AppDelegate`, so this hops there — mirroring `ToggleDictationIntent`.
struct ToggleMeetingRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Meeting Recording"
    static let description = IntentDescription(
        "Start recording a meeting, or stop and save the notes for the one in progress."
    )

    // Same rule as dictation: never activate Talkie. The meeting pill and
    // system-audio capture run off-screen; bringing Talkie forward would only
    // steal focus from whatever the user is actually in.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let app = AppDelegate.shared else {
            throw TalkieIntentError.talkieNotRunning
        }
        // Throws `meetingCouldNotStart` if `start()` refuses (mic denied, speech
        // unavailable, or a meeting/dictation already holds the mic engine) — the
        // intent surfaces that as an error rather than a silent no-op.
        try await app.toggleMeetingRecordingFromIntent()
        return .result()
    }
}

/// Errors surfaced to Shortcuts/Spotlight when an intent can't run. The
/// `CustomLocalizedStringResourceConvertible` conformance is what Shortcuts
/// shows the user in the error banner.
enum TalkieIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case talkieNotRunning
    case meetingCouldNotStart

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .talkieNotRunning:
            return "Talkie isn’t running. Open Talkie, then try again."
        case .meetingCouldNotStart:
            // Deliberately covers every `start() == false` reason at once — the
            // recorder doesn't tell us which, and any of them means "not now".
            return "Couldn’t start a meeting — Talkie may be busy dictating, or microphone or speech access isn’t available."
        }
    }
}

/// Groups Talkie's intents under one heading in the Shortcuts library. The full
/// suite now ships: Toggle Dictation, Get Last Dictation, Search Memory, and
/// Toggle Meeting Recording, with spoken/Spotlight phrases in `AppShortcuts.swift`.
struct TalkieIntentsPackage: AppIntentsPackage {}
