import AppKit
import SwiftUI

/// "Meeting settings" (L6c) — the one place every surviving meeting setting lives.
/// Consolidates what used to be four cards embedded on the Meetings PAGE
/// (`MeetingsView`): auto-detect, the live pill, and the meeting-apps allowlist +
/// muted lists — plus the relocated `CalendarSettings`, and an honest destination
/// REFERENCE row that deep-links to the root "Notes & export" card (the real
/// control, which governs dictation notes too, so it is NOT moved here).
///
/// Reached two ways, both landing on this same subpage: the "Meeting settings" row
/// on the Settings root pushes `SettingsPage.meetings`, and the Meetings tab asks
/// for it via `SettingsRouter.pendingPage`. The meeting toggles keep their existing
/// `AppSettings` bindings verbatim (whose `didSet`s call `notifyChanged()`), so the
/// live detector rebind and the mid-recording pill toggle keep working — this is a
/// pure relocation, no behavior change.
struct MeetingsSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var router: SettingsRouter
    /// Observed so the destination reference row reflects a folder/vault change (and
    /// its reachability) live, exactly like the real control on the root.
    @ObservedObject private var exportPrefs = ExportPreferences.shared

    /// Moved verbatim from `MeetingsView` with the allowlist card: the app-picker
    /// sheet toggle.
    @State private var showingAppPicker = false

    /// Pops this pushed subpage back to the Settings root, where the "Notes & export"
    /// card lives inline. Used by the destination reference button, alongside a tab
    /// switch, so the deep-link degrades gracefully (see `openNotesAndExport`).
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubPage(title: "Meeting settings",
                subtitle: "Recording, transcription, and calendar context — all in one place.") {
            VStack(alignment: .leading, spacing: 18) {
                detectionCard
                livePillCard
                allowlistCard
                if !settings.mutedMeetingApps.isEmpty { mutedCard }

                // Calendar context — reading the event you're in to title the note and
                // bias attendee names — is meetings-only, so it lives here (L6c), no
                // longer floating under Apps.
                CalendarSettings()

                destinationReferenceRow
            }
        }
    }

    // MARK: Auto-detect & live pill

    /// Auto-detect (the surviving toggle after H9 removed the any-mic toggle). Its
    /// `$settings.autoDetectMeetings` binding is unchanged, so the `notifyChanged()`
    /// `didSet` still rebinds the live detector.
    @ViewBuilder
    private var detectionCard: some View {
        SettingsCard(
            header: "Auto-detect",
            footer: "When any app starts using your mic, Talkie offers to record — it never records on its own. Dismiss an app’s offer twice and Talkie stops offering for it (your dedicated meeting apps are never silenced).".loc
        ) {
            SettingsToggleRow(
                title: "Detect meetings & offer to record".loc,
                subtitle: "When a call app starts using your mic, Talkie offers to record. It never records on its own.".loc,
                isOn: $settings.autoDetectMeetings)
        }
    }

    /// The live pill toggle. Its `$settings.showMeetingPill` binding is unchanged, so
    /// its `notifyChanged()` `didSet` still toggles the pill of a recording already in
    /// progress (AppDelegate's mid-recording observer).
    @ViewBuilder
    private var livePillCard: some View {
        SettingsCard(header: "Live pill") {
            SettingsToggleRow(
                title: "Show the meeting pill".loc,
                subtitle: "A small indicator under the camera while recording, with a live timer and the current topic when Talkie is confident.".loc,
                isOn: $settings.showMeetingPill)
        }
    }

    // MARK: Meeting apps allowlist + muted

    private var allowlistCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Meeting apps")
            Text("Talkie offers to record when one of these apps starts using your microphone.".loc)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            Button {
                showingAppPicker = true
            } label: {
                Label("Browse installed apps…".loc, systemImage: "square.grid.2x2")
            }
            .controlSize(.large)
            if settings.meetingAllowlist.isEmpty {
                Text("No apps yet — browse your installed apps above.".loc)
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(settings.meetingAllowlist, id: \.bundleID) { app in
                        MeetingAppChip(app: app) { removeApp(app) }
                    }
                }
            }
        }
        .talkieCard()
        .sheet(isPresented: $showingAppPicker) {
            MeetingAppPickerSheet(settings: settings) { showingAppPicker = false }
        }
    }

    private var mutedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Muted")
            Text("You dismissed these enough times that Talkie stopped offering. Tap to un-mute.".loc)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            FlowLayout(spacing: 8) {
                ForEach(settings.mutedMeetingApps, id: \.self) { id in
                    MutedAppChip(name: appDisplayName(for: id)) { unmute(id) }
                }
            }
        }
        .talkieCard()
    }

    private func removeApp(_ app: MeetingApp) {
        settings.meetingAllowlist.removeAll { $0.bundleID == app.bundleID }
    }

    private func unmute(_ id: String) {
        settings.mutedMeetingApps.removeAll { $0 == id }
    }

    private func appDisplayName(for id: String) -> String {
        settings.meetingAllowlist.first(where: { $0.bundleID == id })?.displayName ?? id
    }

    // MARK: Destination reference (points at the real control, never a copy)

    /// A read-only reference to where notes land, plus a button to the real control.
    /// The destination is owned by `ExportPreferences` (the "Notes & export" card on
    /// the Settings root, which governs DICTATION notes too), so this pane never
    /// duplicates that knob — it states the resolved truth and links to it.
    private var destinationReferenceRow: some View {
        SettingsCard(
            header: "Where notes are saved",
            footer: "Meeting notes and dictation notes share one destination, set in Notes & export.".loc
        ) {
            SettingsRow(
                title: "Notes are saved to".loc,
                subtitle: destinationDescription
            ) {
                Button("Open Notes & export".loc) { openNotesAndExport() }
            }
            if exportPrefs.destination == .folder,
               !exportPrefs.folderPath.isEmpty, !exportPrefs.folderIsAccessible {
                // Honest fallback: mirror the warning the real control shows when a
                // custom folder is unreachable — notes fall back to ~/Talkie Meetings.
                SettingsDivider(leadingInset: 0)
                SettingsNote(
                    text: "That folder isn’t reachable right now — notes fall back to ~/Talkie Meetings until it’s back.".loc,
                    tone: Theme.warning, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    /// The resolved destination, in plain words: the Talkie folder, a reachable
    /// custom folder's path, or — when a custom folder is unreachable — the honest
    /// `~/Talkie Meetings` fallback (never a path that isn't actually being written).
    private var destinationDescription: String {
        switch exportPrefs.destination {
        case .talkieFolder:
            return "~/Talkie Meetings".loc
        case .folder:
            if exportPrefs.folderPath.isEmpty { return "~/Talkie Meetings".loc }
            return exportPrefs.folderIsAccessible
                ? exportPrefs.folderPath
                : "~/Talkie Meetings".loc
        }
    }

    /// Deep-link to the root "Notes & export" card (the real control). This subpage is
    /// pushed inside the Settings (`.general`) tab, so popping to root reveals that
    /// card inline; we also assert the `.general` tab so the jump is correct even when
    /// reached from the Meetings tab — the graceful-degradation contract: land on the
    /// right tab even if the pop is a no-op.
    private func openNotesAndExport() {
        router.selectedTab = .general
        dismiss()
    }
}

/// The compact row mounted in the Settings root "Meetings" group (L6c) that pushes
/// the `MeetingsSettings` subpage. A real `NavigationLink(value:)` because the root
/// is itself inside the Settings `NavigationStack`; styled as a full-width settings
/// row (icon → title/subtitle → chevron) on the shared brand surface so it reads
/// like the rest of the index.
struct MeetingsSettingsLinkRow: View {
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: SettingsPage.meetings) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.coral)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting settings")
                        .font(.talkieHeading(14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("Auto-detect, the live pill, meeting apps, and calendar context.")
                        .font(.talkieHeading(12, weight: .regular))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .talkieSurface()
            .scaleEffect(hovering ? 1.005 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
