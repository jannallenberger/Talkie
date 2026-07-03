import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingsView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var store: MeetingStore
    @ObservedObject var settings: AppSettings
    /// The drop-to-transcribe coordinator. Defaulted from the shared AppDelegate so the
    /// existing `MeetingsView(recorder:store:settings:)` call site stays untouched (the
    /// composition root is owned elsewhere); nil only in previews/tests, where the import
    /// affordances simply don't render.
    var importer: FileImportCoordinator? = AppDelegate.shared?.fileImporter

    @State private var showingAppPicker = false
    /// Flashes the drop zone briefly when a non-audio file is rejected.
    @State private var rejectedDrop = false
    /// True while a supported file is hovering over the drop target.
    @State private var dropTargeting = false

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
                if let importer { ImportControls(importer: importer) }
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
                            onDelete: { store.delete(meeting) },
                            onRegenerate: { await regenerateSummary(meeting) }
                        )
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dropDestination(for: URL.self) { urls, _ in handleDrop(urls) }
        isTargeted: { hovering in
            // Only light up for files we can actually take; a hover of anything else
            // leaves the zone calm (the rejection flash fires on drop, not hover).
            dropTargeting = hovering
        }
        .overlay {
            if dropTargeting || rejectedDrop {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(
                        rejectedDrop ? Theme.featherRed : Theme.coral,
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                    )
                    .padding(10)
                    .overlay(alignment: .top) {
                        Text(rejectedDrop
                             ? "That file isn’t audio or video".loc
                             : "Drop audio, video, or a folder to transcribe".loc)
                            .font(.talkieEyebrow)
                            .foregroundStyle(rejectedDrop ? Theme.featherRed : Theme.coral)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Theme.surface))
                            .padding(.top, 18)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: dropTargeting)
        .animation(.easeInOut(duration: 0.2), value: rejectedDrop)
    }

    /// Route a dropped batch: expand any dropped folders (shallow, sorted) and hand the
    /// supported files to the importer, flashing the zone red for a moment if nothing in
    /// the drop was importable (a visible rejection, never a silent no-op). Returns whether
    /// anything was accepted.
    @discardableResult
    private func handleDrop(_ urls: [URL]) -> Bool {
        let supported = ImportableMedia.expand(urls)
        guard !supported.isEmpty else {
            rejectedDrop = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                rejectedDrop = false
            }
            return false
        }
        importer?.enqueue(supported)
        return true
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

    private func reveal(_ meeting: Meeting) {
        let url = store.folderURL.appendingPathComponent(meeting.fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ meeting: Meeting) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(meeting.transcript, forType: .string)
    }

    /// Re-runs on-device summarization for one past meeting and persists the
    /// result — the fix for meetings recorded before the map-reduce change (or
    /// while the on-device model briefly wasn't ready), which are otherwise
    /// stuck with an empty or generic summary forever.
    private func regenerateSummary(_ meeting: Meeting) async {
        guard let summary = await MeetingSummarizer().summarize(meeting.transcript) else { return }
        var updated = meeting
        updated.summary = summary
        store.update(updated)
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
    let onRegenerate: () async -> Void
    @State private var expanded = false
    @State private var hovering = false
    @State private var regenerating = false

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
                if regenerating {
                    ProgressView().controlSize(.small)
                } else if hovering {
                    if !meeting.transcript.isEmpty, MeetingSummarizer.isAvailable {
                        Button {
                            Task { regenerating = true; await onRegenerate(); regenerating = false }
                        } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help("Regenerate summary")
                    }
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

    /// The installed app's real icon, when it's still on disk; falls back to a
    /// tier glyph (e.g. for a bundle id the user picked whose app was later
    /// removed).
    private var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: app.tier == .browser ? "globe" : "video.fill")
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 13, height: 13)
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

/// The drop-to-transcribe affordances: an "Import…" button (an `NSOpenPanel` counterpart
/// to dropping onto the tab — files or a whole folder) plus, while a batch runs, a "3 of
/// 12" progress row with the current filename, percent, and Cancel, and a once-at-end
/// completion summary. Observes the coordinator so progress, the "waiting for dictation to
/// finish" state, and the summary stay live. Rendered only when the importer exists (nil in
/// previews).
private struct ImportControls: View {
    @ObservedObject var importer: FileImportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    importViaPanel()
                } label: {
                    Label("Import…".loc, systemImage: "square.and.arrow.down")
                }
                .controlSize(.large)
                .disabled(!FileImportEngine.isAvailable)

                Text("…or drop audio, video, or a folder onto this tab.".loc)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
                Spacer()
            }

            if let active = importer.active {
                progressRow(fileName: active.fileName)
            } else if importer.waitingForSession {
                waitingRow
            }

            if let completion = importer.lastCompletion {
                completionRow(completion)
            }

            if let error = importer.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.featherRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Batch position ("3 of 12") shown only when more than one file is in play; a single
    /// import just shows the filename and percent.
    private var batchLabel: String? {
        guard importer.batchTotal > 1 else { return nil }
        // 1-based position of the file being worked on: files already finished + this one.
        let position = min(importer.batchDone + 1, importer.batchTotal)
        return String(format: "%d of %d".loc, position, importer.batchTotal)
    }

    private func progressRow(fileName: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.coral)
                    if let batchLabel {
                        Text(batchLabel)
                            .font(.talkieEyebrow)
                            .foregroundStyle(Theme.coral)
                    }
                    Text(fileName)
                        .font(.talkieHeading(13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(Int((importer.progress * 100).rounded()))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.inkSecondary)
                }
                ProgressView(value: importer.progress)
                    .tint(Theme.coral)
            }
            Button("Cancel".loc) { importer.cancel() }
                .controlSize(.small)
        }
        .talkieCard(padding: 12)
    }

    private var waitingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for dictation to finish…".loc)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
            Button("Cancel".loc) { importer.cancel() }
                .controlSize(.small)
        }
        .talkieCard(padding: 12)
    }

    /// The once-at-end batch summary ("11 imported, 1 skipped: foo.mp3"), dismissible.
    private func completionRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.coral)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                importer.dismissCompletion()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss".loc)
        }
        .talkieCard(padding: 12)
    }

    /// Pick audio/video files or a folder and enqueue them. Folders are shallow-enumerated
    /// by the coordinator. On-device only — reads what the user chose; nothing leaves the
    /// machine.
    private func importViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = ImportableMedia.allExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Import".loc
        panel.message = "Choose audio or video files — or a folder of them — to transcribe into meetings.".loc
        if panel.runModal() == .OK {
            importer.enqueue(panel.urls)
        }
    }
}
