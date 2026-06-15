import AppKit
import SwiftUI

struct MeetingsView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var store: MeetingStore
    @ObservedObject var settings: AppSettings

    @State private var newAppBundleID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Meetings")
                        .font(.talkieDisplay(26))
                        .foregroundStyle(Theme.ink)
                    Text("Record a meeting; Talkie transcribes and summarizes it on-device, and saves a note you can point Claude at.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkSecondary)
                }

                recordCard
                languageModeRow
                if recorder.isRecording { notesCard }
                folderRow
                detectionCard

                if store.meetings.isEmpty {
                    emptyState
                } else {
                    ForEach(store.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            onReveal: { reveal(meeting) },
                            onCopy: { copy(meeting) },
                            onDelete: { store.delete(meeting) }
                        )
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Language mode

    /// Auto (multilingual) or pin transcription to one of the user's languages.
    private var languageModeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
            Text("Transcription language")
                .font(.talkieEyebrow)
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
            Picker("", selection: $settings.meetingLanguageMode) {
                Text("Auto (multilingual)").tag("auto")
                ForEach(settings.spokenLanguages, id: \.self) { id in
                    Text(Self.languageName(id)).tag(id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 4)
    }

    private static func languageName(_ id: String) -> String {
        talkieLanguageCatalog.first(where: { $0.id == id })?.name ?? id
    }

    // MARK: Record card

    @ViewBuilder
    private var recordCard: some View {
        HStack(spacing: 16) {
            if recorder.isRecording {
                RecordingDot()
                VStack(alignment: .leading, spacing: 2) {
                    Text(recorder.capturingFarEnd ? "Recording you + the call…" : "Recording (mic only)…")
                        .font(.talkieHeading(15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(timeString(recorder.elapsed))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Button("Stop & summarize") { Task { await recorder.stop() } }
                    .controlSize(.large)
            } else if recorder.isFinishing {
                ProgressView().controlSize(.small)
                Text("Transcribing & summarizing…")
                    .font(.talkieHeading(14, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
            } else {
                ClayIcon(name: "IconMic", size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record a meeting")
                        .font(.talkieHeading(15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Captures you and the other participants on the call (Zoom, Meet, Teams) — labeled Me / Them.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Button("Start recording") { Task { await recorder.start() } }
                    .controlSize(.large)
                    .disabled(!MeetingSummarizer.isAvailable && !TranscriptionEngine.isAvailable)
            }
        }
        .talkieCard()
        .frame(maxWidth: .infinity)
    }

    // Live notes during a recording — fused with the transcript on stop (the
    // "Granola magic"). Jot sparse points; Talkie expands them from what was said.
    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
                Text("Your notes")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("Fused with the transcript when you stop")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
            TextEditor(text: $recorder.notes)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 88, maxHeight: 170)
                .padding(8)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if recorder.notes.isEmpty {
                        Text("Jot key points — Talkie expands them with the transcript…")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
        }
        .talkieCard()
        .frame(maxWidth: .infinity)
    }

    private var folderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
            Text("Saved to ~/Talkie Meetings/ as markdown")
                .font(.talkieEyebrow)
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.folderURL])
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 28))
                .foregroundStyle(Theme.inkTertiary)
            Text("No meetings yet")
                .font(.talkieHeading(15, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
            Text("Hit Start recording before your next call.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: Auto-detect & live pill

    @ViewBuilder
    private var detectionCard: some View {
        SettingsCard(header: "Auto-detect") {
            SettingsToggleRow(
                title: "Detect meetings & offer to record".loc,
                subtitle: "When a call app starts using your mic, Talkie offers to record. It never records on its own.".loc,
                isOn: $settings.autoDetectMeetings)
            if settings.autoDetectMeetings {
                SettingsDivider()
                SettingsToggleRow(
                    title: "Offer for any mic app".loc,
                    subtitle: "Also offer when an app that isn’t in your list starts recording. Noisier.".loc,
                    isOn: $settings.offerMeetingForAnyMicApp)
            }
        }

        SettingsCard(header: "Live pill") {
            SettingsToggleRow(
                title: "Show the meeting pill".loc,
                subtitle: "A small indicator under the camera while recording, with a live timer.".loc,
                isOn: $settings.showMeetingPill)
            if settings.showMeetingPill {
                SettingsDivider()
                SettingsToggleRow(
                    title: "Show the live topic".loc,
                    subtitle: "Surfaces what’s being discussed right now — shown only when Talkie is confident.".loc,
                    isOn: $settings.meetingLiveTopic)
            }
        }

        allowlistCard
        if !settings.mutedMeetingApps.isEmpty { mutedCard }
    }

    private var allowlistCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Meeting apps")
            Text("Talkie offers to record when one of these apps starts using your microphone.".loc)
                .font(.talkieHeading(13, weight: .regular))
                .foregroundStyle(Theme.inkSecondary)
            HStack(spacing: 8) {
                TextField("Add an app’s bundle id…".loc, text: $newAppBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addApp)
                Button("Add".loc, action: addApp)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.coral)
                    .disabled(newAppBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
            if settings.meetingAllowlist.isEmpty {
                Text("No apps yet — add one by bundle id (e.g. us.zoom.xos).".loc)
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

    private func addApp() {
        let id = newAppBundleID.trimmingCharacters(in: .whitespaces)
        newAppBundleID = ""
        guard !id.isEmpty, !settings.meetingAllowlist.contains(where: { $0.bundleID == id }) else { return }
        // A user-added app defaults to the strong "meeting app" tier; name = bundle id.
        settings.meetingAllowlist.append(MeetingApp(bundleID: id, displayName: id, tier: .meetingApp))
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

    private func reveal(_ meeting: Meeting) {
        let url = store.folderURL.appendingPathComponent(meeting.fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ meeting: Meeting) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(meeting.transcript, forType: .string)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 12, height: 12)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var expanded = false
    @State private var hovering = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.dateFormatter.string(from: meeting.date))
                        .font(.talkieHeading(14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("\(Int((meeting.durationSec / 60).rounded())) min · \(WordCounter.count(meeting.transcript)) words")
                        .font(.talkieEyebrow)
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                if hovering {
                    Button(action: onCopy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy transcript")
                    Button(action: onReveal) { Image(systemName: "folder") }.buttonStyle(.plain).help("Reveal note in Finder")
                }
            }

            if !meeting.summary.isEmpty {
                MarkdownText(markdown: meeting.summary, bulletColor: Theme.coral)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
            }

            DisclosureGroup(isExpanded: $expanded) {
                Text(meeting.transcript)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text(expanded ? "Hide transcript" : "Show transcript")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.coral)
            }
        }
        .talkieCard(padding: 14)
        .onHover { hovering = $0 }
    }
}

/// A removable chip for one app in the meeting-detection allowlist. A glyph marks
/// the tier (browser vs dedicated meeting app) so the weaker browser signal reads
/// at a glance.
private struct MeetingAppChip: View {
    let app: MeetingApp
    let onRemove: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: app.tier == .browser ? "globe" : "video.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
            Text(app.displayName)
                .font(.talkieHeading(12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surfaceSunken))
    }
}

/// A muted-app chip; tapping it un-mutes (Talkie will offer for it again).
private struct MutedAppChip: View {
    let name: String
    let onUnmute: () -> Void
    var body: some View {
        Button(action: onUnmute) {
            HStack(spacing: 6) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                Text(name)
                    .font(.talkieHeading(12.5, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.surfaceSunken))
        }
        .buttonStyle(.plain)
        .help("Un-mute".loc)
    }
}
