import AppKit
import EventKit
import SwiftUI

/// "Calendar" — opt in (by a deliberate tap, never at launch) to let Talkie read
/// your calendar so a meeting recording gets the event's real title and biases the
/// attendees' names so they spell right. Read-only: Talkie never creates, edits,
/// or deletes an event.
///
/// State is read live from `CalendarMeetingContext.authorizationStatus` so a grant
/// or a System Settings revoke reflects immediately. Reuses the shared `SubPage` /
/// `SettingsCard` / `SettingsRow` vocabulary.
struct CalendarSettings: View {
    /// Mirrors the live authorization status; refreshed on appear and after a request.
    @State private var status: EKAuthorizationStatus = CalendarMeetingContext.authorizationStatus
    @State private var requesting = false

    private var isAuthorized: Bool { status == .fullAccess }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // L6c: the "What it does" bullets used to float in their own ownerless
            // card below this one; they now live INSIDE the Calendar-context card
            // (access row → divider → bullets), footer last, so the explainer has a
            // visible owner instead of reading as a stray, un-headed list.
            SettingsCard(
                header: "Calendar context",
                footer: "Read-only. Talkie reads the event you’re in to title the note and bias attendee names — it never creates, edits, or deletes anything on your calendar. Everything stays on your Mac."
            ) {
                SettingsRow(
                    title: "Calendar access",
                    subtitle: statusSubtitle
                ) {
                    statusTrailing
                }
                SettingsDivider(leadingInset: 0)
                BulletNote(icon: "textformat", text: "Titles a recording with the meeting’s real name instead of a timestamp.")
                SettingsDivider(leadingInset: 0)
                BulletNote(icon: "person.2", text: "Biases recognition toward attendee names so they’re spelled correctly.")
                SettingsDivider(leadingInset: 0)
                BulletNote(icon: "lock", text: "Falls back to the timestamp title whenever access is off — nothing breaks.")
            }
        }
        .onAppear { status = CalendarMeetingContext.authorizationStatus }
    }

    private var statusSubtitle: String {
        switch status {
        case .fullAccess: return "Connected"
        case .denied, .restricted: return "Denied in System Settings"
        case .writeOnly: return "Write-only — Talkie needs read access"
        case .notDetermined: return "Off"
        @unknown default: return "Off"
        }
    }

    @ViewBuilder
    private var statusTrailing: some View {
        if isAuthorized {
            HStack(spacing: 7) {
                ClayIcon(name: "IconSeal", size: 20)
                Text("Connected")
                    .font(.talkieHeading(13, weight: .semibold))
                    .foregroundStyle(Theme.positive)
            }
        } else if status == .denied || status == .restricted {
            Button("Open Settings") { openCalendarSettings() }
        } else {
            Button(requesting ? "Requesting…" : "Enable") { requestAccess() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.coral)
                .disabled(requesting)
        }
    }

    private func requestAccess() {
        requesting = true
        Task {
            _ = await CalendarMeetingContext().requestAccess()
            status = CalendarMeetingContext.authorizationStatus
            requesting = false
        }
    }

    private func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A small icon + explanatory line, full width, matching `SettingsNote`'s padding.
private struct BulletNote: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.coral)
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
