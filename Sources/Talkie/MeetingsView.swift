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
    /// The shared memory graph, so deleting a meeting also purges the provenance the
    /// graph extracted from its transcript. Defaulted from the composition root (like
    /// `importer`) so the existing `MeetingsView(recorder:store:settings:)` call site
    /// stays untouched; nil only in previews/tests, where there is nothing to purge.
    var contextGraph: ContextGraphStore? = AppDelegate.shared?.contextGraph

    /// The one watched-inbox folder (D6). Its own shared store (plain absolute path, no
    /// bookmark — the app isn't sandboxed), observed so the row reflects pick/clear live.
    /// Empty path = OFF; the watcher is never seeded with a default.
    @ObservedObject private var inboxWatch = InboxWatchPreferences.shared

    @State private var showingAppPicker = false
    /// Flashes the drop zone briefly when a non-audio file is rejected.
    @State private var rejectedDrop = false
    /// True while a supported file is hovering over the drop target.
    @State private var dropTargeting = false
    /// The meeting awaiting delete confirmation. Deleting a meeting overwrites its
    /// transcript file and forgets what the graph learned from it, so we confirm first.
    @State private var pendingDelete: Meeting?

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
                watchedInboxCard
                detectionCard

                if store.meetings.isEmpty {
                    emptyState
                } else {
                    ForEach(store.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            onReveal: { reveal(meeting) },
                            onCopy: { copy(meeting) },
                            onDelete: { pendingDelete = meeting },
                            onRegenerate: { await regenerateSummary(meeting) },
                            onSaveTranscript: { edited in saveTranscript(meeting, edited: edited) },
                            onLearn: { from, to in learnCorrection(from: from, to: to, in: meeting) }
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
        .confirmationDialog("Delete this meeting?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingDelete) { meeting in
            Button("Delete", role: .destructive) { deleteMeeting(meeting) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Deletes the transcript and everything Talkie's memory extracted from this meeting. Talkie overwrites the file before deleting it. For protection if your Mac is lost or seized, keep FileVault on.")
        }
    }

    /// Delete a meeting everywhere: the store overwrites-then-removes its `.md`
    /// transcript, and we purge the graph provenance the meeting's transcript produced
    /// (matched by the meeting id). Wiring the graph purge here keeps `MeetingStore`
    /// single-purpose, per the package spec.
    private func deleteMeeting(_ meeting: Meeting) {
        store.delete(meeting)
        contextGraph?.purge(source: .meeting, sourceID: meeting.id.uuidString)
        pendingDelete = nil
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
        SettingsCard(
            header: "Auto-detect",
            footer: "When any app starts using your mic, Talkie offers to record — it never records on its own. Dismiss an app’s offer twice and Talkie stops offering for it (your dedicated meeting apps are never silenced).".loc
        ) {
            SettingsToggleRow(
                title: "Detect meetings & offer to record".loc,
                subtitle: "When a call app starts using your mic, Talkie offers to record. It never records on its own.".loc,
                isOn: $settings.autoDetectMeetings)
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

    /// Persist a hand-edited transcript back into the meeting (A8). `store.update`
    /// replaces the entry in place, rewrites the `.md` file, and re-exports through
    /// the user's destination — the same durable path a regenerated summary takes —
    /// so the list, the note on disk, and MCP `get_meeting` all serve the edited text.
    /// No-ops gracefully if the meeting was evicted by the retention cap (`update`
    /// only touches an entry it still holds by id). The user's segment timings are
    /// left untouched: hand-editing the prose doesn't invalidate the audio clock, and
    /// re-aligning it is explicitly out of scope.
    private func saveTranscript(_ meeting: Meeting, edited: String) {
        guard edited != meeting.transcript else { return }
        var updated = meeting
        updated.transcript = edited
        store.update(updated)
    }

    /// Route an accepted learn chip to BOTH stores, exactly like the live
    /// field-watcher's confirm path in `AppDelegate.applyLearnedCorrection`: add the
    /// dictionary rule (the always-on user-curated correction) AND record the niche
    /// confirmation (the strongest signal that graduates the term for the post-hoc
    /// corrector). Returns whether a NEW dictionary rule was added so the chip can
    /// show a confirmation and latch. Editing Talkie's own transcript UI is not
    /// AX-blind, so there's no reject/undo dance — the tap IS the explicit consent.
    @discardableResult
    private func learnCorrection(from: String, to: String, in meeting: Meeting) -> Bool {
        guard let app = AppDelegate.shared else { return false }
        let added = app.dictionary.addLearnedReplacement(from: from, to: to)
        // Record the confirmation even if the dictionary rule already existed — a
        // second explicit confirmation is still real evidence for the niche store.
        app.nicheVocab.recordUserConfirmed(
            to,
            provenance: Provenance(source: .meeting, sourceID: meeting.id.uuidString,
                                   dateUnix: Date().timeIntervalSince1970,
                                   snippet: String(meeting.transcript.prefix(120)))
        )
        return added
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
    /// Persist a hand-edited transcript (A8). Called on Save with the new text.
    let onSaveTranscript: (String) -> Void
    /// Accept a learn chip: add the dictionary rule + record the niche confirmation.
    /// Returns whether a NEW rule was added (false if it was already known), so the
    /// chip can show the right confirmation.
    let onLearn: (_ from: String, _ to: String) -> Bool
    @State private var expanded = false
    @State private var hovering = false
    @State private var regenerating = false
    /// A8 transcript edit mode: nil when viewing; the working draft while editing.
    @State private var draft: String?
    /// The learn chips offered after a save, and which have been accepted/added.
    @State private var learnable: [LearnCandidate] = []

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
                    // Edit the transcript (A8) — fixing a misrecognition here fixes the
                    // note AND can teach the dictionary. Only for meetings that actually
                    // have transcript text (recovered/notes-only entries have none).
                    if !meeting.transcript.isEmpty {
                        Button { beginEditing() } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain)
                            .help("Edit transcript")
                    }
                    Button(action: onCopy) { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy transcript")
                    // Timestamped exports (D3) — only when this meeting actually has
                    // timed segments (recorded/imported after D2). Pre-D2 notes simply
                    // don't show the menu, so there's no dead UI and no migration.
                    if let segments = meeting.segments, !segments.isEmpty {
                        Menu {
                            Button("Subtitles (.srt)") { export(segments, as: .srt) }
                            Button("Subtitles (.vtt)") { export(segments, as: .vtt) }
                            Button("Spreadsheet (.csv)") { export(segments, as: .csv) }
                            Button("Data (.json)") { export(segments, as: .json) }
                            // Chapter list (D8) — offered ONLY when the meeting shifted
                            // topics (≥2 chapters); a lone/absent topic shows nothing.
                            if let chapters = meeting.chapters, chapters.count >= 2 {
                                Button("Chapters (.txt)") { exportChapters(chapters) }
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("Export…")
                    }
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
                if draft != nil {
                    transcriptEditor
                } else {
                    Text(meeting.transcript)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            } label: {
                Text(expanded ? "Hide transcript" : "Show transcript")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.coral)
            }
        }
        .talkieCard(padding: 14)
        .onHover { hovering = $0 }
    }

    // MARK: Transcript edit mode (A8)

    /// The inline editor shown in place of the read-only transcript: a `TextEditor`
    /// bound to the working draft, Save / Cancel, and — after a save that found
    /// respellings — a stack of "Learn …" chips. `⌘↩` saves, `esc` cancels. Bound to
    /// the optional `draft` with a non-nil fallback; only rendered while editing, so
    /// the fallback never actually shows.
    @ViewBuilder
    private var transcriptEditor: some View {
        let editing = Binding(get: { draft ?? "" }, set: { draft = $0 })
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: editing)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 320)
                .padding(8)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onExitCommand { cancelEditing() }

            HStack(spacing: 8) {
                Text("Fixing a word here also teaches your dictionary.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
                Spacer()
                Button("Cancel") { cancelEditing() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitEditing(editing.wrappedValue) }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(editing.wrappedValue == meeting.transcript)
            }

            if !learnable.isEmpty {
                learnChips
            }
        }
        .padding(.top, 6)
    }

    /// One chip per extracted respelling. Tapping "Learn" adds the rule; the chip
    /// then shows a confirmation and is disabled. Honest copy names the exact term
    /// and what accepting does — no auto-learn, no invented benefit.
    private var learnChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(learnable) { candidate in
                HStack(spacing: 8) {
                    Image(systemName: candidate.added ? "checkmark.circle.fill" : "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(candidate.added ? Theme.featherGreen : Theme.coral)
                    if candidate.added {
                        Text(String(format: "Added “%@” — it’ll be fixed automatically next time.".loc, candidate.to))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.inkSecondary)
                    } else {
                        Text(String(format: "Learn “%@”?".loc, candidate.to))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink)
                        Text(String(format: "was “%@”".loc, candidate.from))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer(minLength: 6)
                    if !candidate.added {
                        Button("Learn") { accept(candidate) }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.surfaceSunken))
            }
        }
    }

    private func beginEditing() {
        expanded = true
        learnable = []
        draft = meeting.transcript
    }

    private func cancelEditing() {
        draft = nil
        learnable = []
    }

    /// Persist the edit, then offer a learn chip for each respelling the region
    /// splitter found. Leaves edit mode but keeps the chips visible (the editor is
    /// gone; the chips sit under the now-read-only transcript until dismissed by the
    /// next edit or a collapse). Non-respelling edits produce no chips.
    private func commitEditing(_ edited: String) {
        onSaveTranscript(edited)
        let found = TranscriptEditCorrections.extract(before: meeting.transcript, after: edited)
        learnable = found.map { LearnCandidate(from: $0.from, to: $0.to) }
        draft = nil
    }

    private func accept(_ candidate: LearnCandidate) {
        _ = onLearn(candidate.from, candidate.to)
        // Mark accepted regardless of whether the rule was brand-new: either way the
        // term is now curated + confirmed, so the chip should read as done.
        if let idx = learnable.firstIndex(where: { $0.id == candidate.id }) {
            learnable[idx].added = true
        }
    }

    // MARK: Timestamped export (D3)

    /// The four sidecar formats offered by the row's Export menu, each paired with
    /// its file extension and the UTI hint the save panel uses to name the file.
    private enum ExportFormat {
        case srt, vtt, csv, json

        var fileExtension: String {
            switch self {
            case .srt: return "srt"
            case .vtt: return "vtt"
            case .csv: return "csv"
            case .json: return "json"
            }
        }
    }

    /// Render `segments` to the chosen format and write them via a save panel. The
    /// default filename reuses the meeting's `.md` basename (so a "2026-07-03-…-meeting"
    /// note exports "2026-07-03-…-meeting.srt"), which keeps the sidecar sitting next
    /// to whatever the user named the note. Pure render → disk write; nothing leaves
    /// the machine.
    private func export(_ segments: [MeetingSegment], as format: ExportFormat) {
        let contents: String
        switch format {
        case .srt:
            contents = TimedTranscriptExport.srt(segments)
        case .vtt:
            contents = TimedTranscriptExport.vtt(segments)
        case .csv:
            contents = TimedTranscriptExport.csv(segments)
        case .json:
            let header = TimedTranscriptExport.Header(
                title: meeting.title,
                date: meeting.date,
                durationSec: meeting.durationSec
            )
            contents = TimedTranscriptExport.json(segments, header: header)
        }

        let panel = NSSavePanel()
        // `NSSavePanel.title` is a runtime String, so it doesn't auto-localize the way
        // a SwiftUI `Text`/`Button` literal does — route it through `.loc` (the key
        // already ships in all 10 .lproj from the dictionary-export button).
        panel.title = "Export…".loc
        panel.nameFieldStringValue = "\(exportBaseName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? Data(contents.utf8).write(to: url, options: .atomic)
        }
    }

    /// Export the meeting's chapter list (D8) as a plain `.txt` file in the
    /// YouTube-description format (`M:SS Topic` per line) — the exact shape that
    /// becomes clickable chapters when pasted into a video description. Same pure
    /// render → save-panel → disk-write path as `export`; nothing leaves the machine.
    /// Only reached from a menu item that already requires ≥2 chapters, and
    /// `chapterList` re-checks that itself.
    private func exportChapters(_ chapters: [Chapter]) {
        let contents = TimedTranscriptExport.chapterList(chapters)
        let panel = NSSavePanel()
        panel.title = "Export…".loc
        panel.nameFieldStringValue = "\(exportBaseName)-chapters.txt"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: "txt") {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? Data(contents.utf8).write(to: url, options: .atomic)
        }
    }

    /// The meeting's `.md` file basename (without extension) — the default stem for
    /// an exported sidecar. Falls back to a slug of the title when the filename
    /// is somehow empty.
    private var exportBaseName: String {
        let stem = (meeting.fileName as NSString).deletingPathExtension
        return stem.isEmpty ? NoteTemplate.slug(meeting.title) : stem
    }
}

/// One offered dictionary rule under the transcript editor (A8). Identifiable so the
/// chip list animates cleanly and each chip latches its own accepted state.
private struct LearnCandidate: Identifiable {
    let id = UUID()
    let from: String
    let to: String
    var added = false
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
