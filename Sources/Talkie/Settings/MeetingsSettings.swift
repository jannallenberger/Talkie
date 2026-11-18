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
    /// The one watched-inbox folder (D6), moved here from the Meetings page with its
    /// card. Plain absolute path, no bookmark — the app isn't sandboxed. Empty = OFF;
    /// the watcher is never seeded with a default.
    @ObservedObject private var inboxWatch = InboxWatchPreferences.shared

    /// Moved verbatim from `MeetingsView` with the allowlist card: the app-picker
    /// sheet toggle.
    @State private var showingAppPicker = false

    /// Whether a locally learned voice profile exists (read once on appear; presence
    /// only — the profile's contents are never shown or logged).
    @State private var hasVoiceProfile = false

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
                keepAudioCard
                watchedInboxCard
                allowlistCard
                if !settings.mutedMeetingApps.isEmpty { mutedCard }

                // Calendar context — reading the event you're in to title the note and
                // bias attendee names — is meetings-only, so it lives here (L6c), no
                // longer floating under Apps.
                CalendarSettings()

                destinationReferenceRow
                if hasVoiceProfile { voiceProfileCard }
            }
        }
        .onAppear { hasVoiceProfile = OwnVoiceProfileStore.shared.exists }
    }

    // MARK: Voice profile (privacy control, shown only when one exists)

    private var voiceProfileCard: some View {
        VoiceProfileCard {
            OwnVoiceProfileStore.shared.delete()
            hasVoiceProfile = false
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

    // MARK: Keep audio & watched folder (moved from the Meetings page)

    /// Keep-audio toggle (D9). Default OFF — retaining raw call audio is a genuine
    /// privacy + disk decision, so the subtitle says the cost in plain words and the
    /// choice is snapshotted at recording start (flipping it mid-call doesn't change a
    /// recording already underway). When on, each recording writes per-stream `.m4a`
    /// files beside its note, and clicking a transcript line plays that exact moment.
    @ViewBuilder
    private var keepAudioCard: some View {
        SettingsCard(
            header: "Audio",
            footer: "Off by default. Kept audio stays in ~/Talkie Meetings/ next to the note, never leaves your Mac, and is deleted with the meeting. Roughly 30 MB per hour for each side of the call. Dictation audio is never kept.".loc
        ) {
            SettingsToggleRow(
                title: "Keep audio with meeting notes".loc,
                subtitle: "Save each recording’s audio so you can click any line of the transcript to hear that exact moment.".loc,
                isOn: $settings.keepMeetingAudio)
        }
    }

    /// The watched-inbox folder (D6): pick ONE folder and any audio/video file that lands
    /// there is transcribed into a note, then moved into a `Transcribed/` subfolder. Off
    /// until you choose a folder (no default is ever set), and the copy says exactly what
    /// will happen — this is a privacy-sensitive capability, so it's opt-in and explicit.
    @ViewBuilder
    private var watchedInboxCard: some View {
        SettingsCard(
            header: "Watch a folder",
            footer: inboxWatch.folderPath.isEmpty
                ? "Off. Pick a folder and any audio or video file that lands in it — an AirDropped voice memo, an iCloud recording — is transcribed into a note on your Mac, then moved into a “Transcribed” subfolder inside it. Talkie only reads local files and never opens a connection.".loc
                : "Files that land here are transcribed on-device and moved into “Transcribed”. Talkie watches only this folder (not its subfolders), reads local files only, and never opens a connection.".loc
        ) {
            SettingsRow(
                title: "Watched folder".loc,
                subtitle: inboxWatch.folderPath.isEmpty
                    ? "No folder — this feature is off".loc
                    : inboxWatch.folderPath
            ) {
                HStack(spacing: 8) {
                    Button(inboxWatch.folderPath.isEmpty ? "Choose…".loc : "Change…".loc,
                           action: pickInboxFolder)
                    if !inboxWatch.folderPath.isEmpty {
                        Button("Stop watching".loc, action: stopWatchingInbox)
                    }
                }
            }
            if !inboxWatch.folderPath.isEmpty, !inboxWatch.folderIsAccessible {
                SettingsDivider(leadingInset: 0)
                SettingsNote(
                    text: "That folder isn’t reachable right now — nothing will be watched until it’s back.".loc,
                    tone: Theme.warning, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Pick the single folder to watch. Directories only; the app isn't sandboxed, so we
    /// store the plain path (no security-scoped bookmark), matching `ExportPreferences`.
    private func pickInboxFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Pick a folder to watch. Audio and video files that land in it will be transcribed into notes and moved into a “Transcribed” subfolder."
        if !inboxWatch.folderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: inboxWatch.folderPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            inboxWatch.folderPath = url.path
        }
    }

    /// Turn watching off by clearing the path — the watcher disarms on the next change.
    private func stopWatchingInbox() {
        inboxWatch.folderPath = ""
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
                HStack(spacing: 8) {
                    // Moved from the Meetings page's folder row: opens the folder notes
                    // ACTUALLY land in (the same resolution as the line above).
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([resolvedNotesFolder])
                    }
                    Button("Open Notes & export".loc) { openNotesAndExport() }
                }
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

    /// The folder where notes actually land: a reachable custom folder, else the
    /// ~/Talkie Meetings default (the same fallback `resolvedDestination()` applies), so
    /// Reveal never points at a folder notes aren't in.
    private var resolvedNotesFolder: URL {
        if exportPrefs.destination == .folder,
           !exportPrefs.folderPath.isEmpty, exportPrefs.folderIsAccessible {
            return URL(fileURLWithPath: exportPrefs.folderPath)
        }
        return AppPaths.meetingsDirectory()
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

/// The "Your voice" privacy card: one plain button plus one line of explanation.
/// Internal so the opt-in UI snapshot test can render it standalone.
struct VoiceProfileCard: View {
    let onForget: () -> Void

    var body: some View {
        SettingsCard {
            SettingsRow(
                title: "Your voice".loc,
                subtitle: "A small voice profile is kept on this Mac to recognise you in meetings. Forgetting it removes it; it is learned again from future meetings.".loc
            ) {
                Button("Forget my voice".loc, action: onForget)
            }
        }
    }
}
