import EventKit
import Foundation

/// EventKit-backed `MeetingContextProvider` (feature 04). Read-only, on-device:
/// given the instant a recording starts, it finds the calendar event that best
/// overlaps that moment and returns the event's title, attendee display names,
/// and identifier as a `Sendable` `MeetingEventContext`.
///
/// Why a `struct` (not the actor the plan sketches): the spine protocol requires
/// `MeetingContextProvider: Sendable`, and `EKEventStore`/`EKEvent` are *not*
/// `Sendable`. We keep this type a value with no stored EventKit objects — each
/// call spins up a fresh, local `EKEventStore` (cheap; it is just a handle onto
/// `calaccessd`), reads what it needs *synchronously inside the call*, and
/// converts everything to plain `String`s before returning. No `EKEvent` ever
/// crosses an isolation boundary, so Swift 6 strict concurrency stays clean
/// without confining the whole provider to one actor.
///
/// Authorization: EventKit on macOS 14+ has no "read-only events" tier, so we
/// request **full access** but only ever call read APIs (we never create, edit,
/// or delete an event). If access is `.notDetermined`/`.denied`/`.restricted`,
/// `eventContext(at:)` returns `nil` and the caller falls back to its existing
/// timestamp title and capture-derived participants — the feature is purely
/// additive and can only improve a note, never break one.
struct CalendarMeetingContext: MeetingContextProvider {

    // MARK: Tunables (the §4.2 zero-config defaults)

    /// How far back/forward from the recording instant to fetch events.
    var lookBack: TimeInterval = 90 * 60
    var lookAhead: TimeInterval = 90 * 60
    /// You hit record a few minutes early.
    var graceBefore: TimeInterval = 5 * 60
    /// You joined late / it ran over.
    var graceAfter: TimeInterval = 10 * 60
    /// Large invites get truncated so we don't blow the recognizer bias cap.
    var maxAttendees: Int = 25

    /// Optional allowlist of `EKCalendar.calendarIdentifier`s the user opted into.
    /// Empty (the default) = all calendars, zero-config.
    var enabledCalendarIDs: [String] = []

    init(
        lookBack: TimeInterval = 90 * 60,
        lookAhead: TimeInterval = 90 * 60,
        graceBefore: TimeInterval = 5 * 60,
        graceAfter: TimeInterval = 10 * 60,
        maxAttendees: Int = 25,
        enabledCalendarIDs: [String] = []
    ) {
        self.lookBack = lookBack
        self.lookAhead = lookAhead
        self.graceBefore = graceBefore
        self.graceAfter = graceAfter
        self.maxAttendees = maxAttendees
        self.enabledCalendarIDs = enabledCalendarIDs
    }

    // MARK: Authorization (read-only; full-access grant used read-only)

    /// Current calendar (event) authorization. Re-read on every `eventContext`
    /// call so a mid-session revoke degrades to `nil` immediately.
    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// `true` once the user has granted full access. (`.writeOnly` is useless to
    /// us — it cannot read events — so it counts as "not authorized" here.)
    static var isAuthorized: Bool { authorizationStatus == .fullAccess }

    /// Request full calendar access (used strictly read-only). Triggered only by
    /// a deliberate user action (the "Enable" button) — never at launch. Returns
    /// whether access was granted. Safe to call when already authorized.
    @discardableResult
    func requestAccess() async -> Bool {
        if Self.isAuthorized { return true }
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    // MARK: MeetingContextProvider

    /// Feature 03 owns auto-detection; this provider never claims a meeting is
    /// active on its own.
    func detectActiveMeeting() async -> MeetingSignal? { nil }

    /// Find the calendar event best overlapping `date` and project it into a
    /// `MeetingEventContext`. Returns `nil` when access is missing or no event
    /// matches — the caller treats `nil` as "use the existing behavior".
    func eventContext(at date: Date) async -> MeetingEventContext? {
        guard Self.isAuthorized else { return nil }

        // Fresh, local store per call — never stored, never crosses isolation.
        let store = EKEventStore()
        let calendars = resolveCalendars(in: store)
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-lookBack),
            end: date.addingTimeInterval(lookAhead),
            calendars: calendars
        )

        // Convert each `EKEvent` to a plain `Sendable` candidate *here*, inside
        // the call, so the EventKit objects never escape.
        let candidates = store.events(matching: predicate).map(CandidateEvent.init(event:))
        guard let best = CalendarMatcher.bestMatch(
            among: candidates,
            around: date,
            graceBefore: graceBefore,
            graceAfter: graceAfter
        ) else { return nil }

        let names = attendeeNames(eventID: best.eventID, in: store)
        let title = best.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingEventContext(
            title: (title?.isEmpty == false) ? title : nil,
            attendeeNames: names,
            eventID: best.eventID
        )
    }

    // MARK: Calendars

    /// Map the user's allowlist to `[EKCalendar]`, or `nil` (= all calendars).
    /// Unknown ids in the allowlist are silently dropped; an allowlist that maps
    /// to nothing falls back to all calendars rather than matching zero events.
    private func resolveCalendars(in store: EKEventStore) -> [EKCalendar]? {
        guard !enabledCalendarIDs.isEmpty else { return nil }
        let wanted = Set(enabledCalendarIDs)
        let matched = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
        return matched.isEmpty ? nil : matched
    }

    // MARK: Attendees (§4.3)

    /// Display names of the event's organizer + attendees, dropping the current
    /// user (that's "Me") and anyone without a real display name (raw emails are
    /// not spell-worthy and would pollute the bias set). Deduped, capped.
    ///
    /// Re-fetches the concrete `EKEvent` by id inside the call so we never hold a
    /// reference to a non-`Sendable` EventKit object.
    private func attendeeNames(eventID: String?, in store: EKEventStore) -> [String] {
        guard let eventID, let event = store.event(withIdentifier: eventID) else { return [] }

        var participants: [EKParticipant] = []
        if let organizer = event.organizer { participants.append(organizer) }
        if let attendees = event.attendees { participants.append(contentsOf: attendees) }

        var seen = Set<String>()
        var out: [String] = []
        for participant in participants {
            if participant.isCurrentUser { continue }            // that's "Me"
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, looksLikeName(name) else { continue }
            if seen.insert(name.lowercased()).inserted {
                out.append(name)
                if out.count >= maxAttendees { break }
            }
        }
        return out
    }

    /// A display name worth biasing: contains a letter and isn't just a raw email
    /// address (some providers fall back to the email when no name is set).
    private func looksLikeName(_ name: String) -> Bool {
        guard name.contains(where: \.isLetter) else { return false }
        if name.contains("@"), !name.contains(" ") { return false }   // bare email
        return true
    }
}

// MARK: - Pure, EventKit-free matching (unit-testable)

/// A plain, `Sendable` snapshot of just the event facts the matcher needs. Lifted
/// out of `EKEvent` so the scoring is testable without an `EKEventStore` and so no
/// EventKit object crosses an isolation boundary.
struct CandidateEvent: Sendable, Equatable {
    var eventID: String?
    var title: String?
    var startDate: Date?
    var endDate: Date?
    var isAllDay: Bool
    var isCanceled: Bool

    var durationSec: TimeInterval {
        guard let startDate, let endDate else { return .greatestFiniteMagnitude }
        return max(0, endDate.timeIntervalSince(startDate))
    }
}

extension CandidateEvent {
    /// Project an `EKEvent` into the pure snapshot. Called inside the provider, so
    /// the `EKEvent` never escapes.
    init(event: EKEvent) {
        self.init(
            eventID: event.eventIdentifier,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            isCanceled: event.status == .canceled
        )
    }
}

/// The §4.2 scoring, factored out as a pure `enum` (codebase convention for pure
/// helpers). Picks the event whose window best contains the recording instant.
enum CalendarMatcher {

    /// From `candidates`, return the one best overlapping `date`:
    /// - excludes all-day, canceled, and untitled events;
    /// - keeps events whose `[start - graceBefore, end + graceAfter]` window
    ///   contains `date`;
    /// - picks the one minimizing `|date - start|`, tie-breaking by shortest
    ///   duration (a 30-min standup beats an all-day block that slipped in).
    static func bestMatch(
        among candidates: [CandidateEvent],
        around date: Date,
        graceBefore: TimeInterval,
        graceAfter: TimeInterval
    ) -> CandidateEvent? {
        let viable = candidates.filter { candidate in
            guard !candidate.isAllDay, !candidate.isCanceled,
                  let title = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let start = candidate.startDate, let end = candidate.endDate
            else { return false }
            let windowStart = start.addingTimeInterval(-graceBefore)
            let windowEnd = end.addingTimeInterval(graceAfter)
            return date >= windowStart && date <= windowEnd
        }

        return viable.min { lhs, rhs in
            let lhsDelta = abs((lhs.startDate ?? date).timeIntervalSince(date))
            let rhsDelta = abs((rhs.startDate ?? date).timeIntervalSince(date))
            if lhsDelta != rhsDelta { return lhsDelta < rhsDelta }
            return lhs.durationSec < rhs.durationSec        // tie-break: shorter wins
        }
    }
}

// MARK: - Recognizer-bias tokens (§4.3)

extension MeetingEventContext {
    /// Spell-worthy tokens (full names + each name part) for the recognizer's
    /// `setContextualStrings`. Tokenizing on top of the full name matters: people
    /// say "Sarah said…" far more than "Sarah Chen said…", and the recognizer
    /// biases per phrase — so both lock the spelling. Diacritics are preserved;
    /// sub-2-char and letter-free fragments are dropped; results are deduped
    /// case-insensitively while keeping the first-seen casing.
    var biasTokens: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in attendeeNames {
            let parts = [name] + name.split(whereSeparator: \.isWhitespace).map(String.init)
            for token in parts where token.count >= 2 && token.contains(where: \.isLetter) {
                if seen.insert(token.lowercased()).inserted { out.append(token) }
            }
        }
        return out
    }
}
