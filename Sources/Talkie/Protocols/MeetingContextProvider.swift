import Foundation

/// Supplies the *surrounding facts* of a meeting — is one happening, what's it
/// called, who's in it — decoupled from how the meeting is captured. Feature 03
/// implements `detectActiveMeeting()` (Core Audio process-list scan + allowlist +
/// consent banner; never silently records). Feature 04 implements
/// `eventContext(at:)` (EventKit, read-only). `MeetingRecorder` consumes a
/// provider to title the note and pre-bias attendee names instead of a
/// timestamp-only title.
protocol MeetingContextProvider: Sendable {
    /// Is a meeting likely in progress right now? (feature 03)
    func detectActiveMeeting() async -> MeetingSignal?
    /// Naming / attendees from the calendar for a given time window. (feature 04)
    func eventContext(at date: Date) async -> MeetingEventContext?
}

struct MeetingSignal: Sendable {
    /// mic-hot-by-another-process (low) → +allowlisted app (high).
    var confidence: Double
    var appBundleID: String?
    /// Friendly name for banner copy ("Zoom"), resolved from the allowlist; nil when
    /// the mic-hot process isn't a known app.
    var appName: String?
    /// The matched allowlist tier (meeting app vs browser); nil for an unknown
    /// mic-hot process. Drives the banner's softer browser copy.
    var tier: MeetingApp.Tier?
    var startedAtUnix: Double
}

struct MeetingEventContext: Sendable {
    /// → meeting note title.
    var title: String?
    /// → Person entities (feature 05) AND recognizer bias (feature 04).
    var attendeeNames: [String]
    /// → `Provenance(.calendar)`.
    var eventID: String?
}
