import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The Meetings page: the shared page header (language, Record, Import, settings), an
/// optional status line and live-recording panel under it, then two panes — the
/// meeting list on a card at the left and the selected meeting's detail on the right. Persistent preferences (keep
/// audio, watched folder, where notes land) live on the Meeting settings page.
struct MeetingsView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var store: MeetingStore
    @ObservedObject var settings: AppSettings
    /// L7: the optional profile picture, shown in the detail meta line (only when a
    /// photo is set — no avatar noise otherwise). In-app display only; the image is
    /// never written into exported meeting notes. Threaded from the composition root
    /// via `MainView`, like the other stores.
    @ObservedObject var profileImage: ProfileImageStore
    /// The drop-to-transcribe coordinator. Defaulted from the shared AppDelegate so
    /// call sites needn't pass it (the composition root is owned elsewhere); nil only
    /// in previews/tests, where the import affordances simply don't render.
    var importer: FileImportCoordinator? = AppDelegate.shared?.fileImporter
    /// The shared memory graph, so deleting a meeting also purges the provenance the
    /// graph extracted from its transcript. Defaulted from the composition root (like
    /// `importer`) so call sites needn't pass it; nil only in previews/tests, where
    /// there is nothing to purge.
    var contextGraph: ContextGraphStore? = AppDelegate.shared?.contextGraph
    /// The Settings router (L6c), so the gear can switch to the Settings tab and
    /// deep-link the Meetings subpage via `pendingPage`. Threaded from the composition
    /// root (`MainView.content`); nil only in previews/tests, where the gear is hidden.
    var router: SettingsRouter? = nil
    /// The meeting to show first, when it exists (else the newest). Snapshot tests use it.
    var initialSelection: UUID? = nil

    /// The gear's quick-settings popover is open.
    @State private var showQuickSettings = false
    /// Flashes the drop zone briefly when a non-audio file is rejected.
    @State private var rejectedDrop = false
    /// True while a supported file is hovering over the drop target.
    @State private var dropTargeting = false
    /// The meeting awaiting delete confirmation. Deleting a meeting overwrites its
    /// transcript file and forgets what the graph learned from it, so we confirm first.
    @State private var pendingDelete: Meeting?
    /// The meeting shown in the detail pane (see `MeetingSelection`).
    @State private var selectedID: UUID?
    /// Keyboard focus on the list, so Delete and the arrow keys act on the selection.
    @FocusState private var listFocused: Bool
    /// Bridges the live-notes draft (owned by `RecordingNotesEditor`, an isolated
    /// child view so per-keystroke typing doesn't republish through `recorder` and
    /// re-diff this whole page) back to the "Stop & summarize" button, so stopping
    /// can flush the latest keystroke into `recorder.notes` synchronously — before
    /// `MeetingRecorder.stop()` reads it — without the editor's typing ever
    /// publishing through SwiftUI itself. Held via `@State` only so its IDENTITY
    /// survives across body re-evaluations; it is deliberately NOT an
    /// `ObservableObject` — mutating `.text` is silent by design.
    @State private var notesDraftBox = NotesDraftBox()

    private static let listWidth: CGFloat = 256
    private static let pagePadding: CGFloat = Theme.Space.pageSide

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            if let importer {
                ImportStatusLine(importer: importer)
                    .padding(.horizontal, Self.pagePadding)
            }
            if recorder.isRecording {
                MeetingRecordingPanel(recorder: recorder, draftBox: notesDraftBox)
                    .padding(.horizontal, Self.pagePadding)
                    .padding(.bottom, 14)
            }
            if store.meetings.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Two panes, no hairlines: the list sits on its own card; the detail
                // scrolls on the canvas with its sections on cards. The detail's
                // ScrollView runs to the window edge (its content carries the trailing
                // inset) so card shadows aren't clipped at the scroll bounds.
                HStack(alignment: .top, spacing: Theme.Space.gridGap - 4) {
                    meetingList
                        .frame(width: Self.listWidth)
                        .frame(maxHeight: .infinity)
                        .talkieSurface()
                        .padding(.bottom, Self.pagePadding)
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.leading, Self.pagePadding)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .contentShape(Rectangle())
        .onAppear {
            selectedID = MeetingSelection.resolve(current: selectedID ?? initialSelection, old: [], new: meetingIDs)
        }
        .onChange(of: meetingIDs) { old, new in
            selectedID = MeetingSelection.resolve(current: selectedID, old: old, new: new)
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

    private var meetingIDs: [UUID] { store.meetings.map(\.id) }

    /// The selected meeting, falling back to the newest for the single render before
    /// `onAppear`/`onChange` settles the selection.
    private var selectedMeeting: Meeting? {
        if let selectedID, let m = store.meetings.first(where: { $0.id == selectedID }) { return m }
        return store.meetings.first
    }

    /// Delete a meeting everywhere: the store overwrites-then-removes its `.md`
    /// transcript, and we purge the graph provenance the meeting's transcript produced
    /// (matched by the meeting id). Wiring the graph purge here keeps `MeetingStore`
    /// single-purpose, per the package spec. The neighbour is selected by `onChange`.
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

    // MARK: Top bar

    private var topBar: some View {
        TalkiePageHeader(title: "Meetings") {
            languagePicker
            recordControl
            if let importer {
                Button {
                    ImportPanel.run(importer)
                } label: {
                    Label("Import…".loc, systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.talkie(.secondary))
                .disabled(!FileImportEngine.isAvailable)
                .help("…or drop audio, video, or a folder onto this tab.".loc)
            }
            if let router {
                Button {
                    showQuickSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.talkie(.quiet))
                .help("Meeting settings")
                .accessibilityLabel("Meeting settings")
                .popover(isPresented: $showQuickSettings, arrowEdge: .bottom) {
                    MeetingQuickSettingsPopover(settings: settings) {
                        showQuickSettings = false
                        router.selectedTab = .general
                        router.pendingPage = .meetings
                    }
                }
            }
        }
        .padding(.top, Theme.Space.pageTop)
        .padding(.horizontal, Self.pagePadding)
        .padding(.bottom, 18)
    }

    /// Auto (multilingual) or pin transcription to one of the user's languages. Read
    /// when a recording starts, so it sits next to Record and is locked while one runs.
    private var languagePicker: some View {
        TalkieMenuPicker(selection: $settings.meetingLanguageMode) {
            Text("Auto (multilingual)").tag("auto")
            ForEach(settings.spokenLanguages, id: \.self) { id in
                Text(Self.languageName(id)).tag(id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .foregroundStyle(Theme.inkSecondary)
                if settings.meetingLanguageMode == "auto" {
                    Text("Auto (multilingual)")
                } else {
                    Text(Self.languageName(settings.meetingLanguageMode))
                }
            }
        }
        .disabled(recorder.isRecording)
        .help("Transcription language")
        .accessibilityLabel("Transcription language")
    }

    private static func languageName(_ id: String) -> String {
        talkieLanguageCatalog.first(where: { $0.id == id })?.name ?? id
    }

    /// Record → (recording dot, elapsed, Stop & summarize) → (finishing spinner).
    @ViewBuilder
    private var recordControl: some View {
        if recorder.isRecording {
            HStack(spacing: 8) {
                RecordingDot()
                // Isolated so the 1 Hz tick only invalidates this one Text.
                RecordingElapsedText(recorder: recorder)
            }
            .padding(.horizontal, 4)
            Button("Stop & summarize") {
                // Flush the notes draft synchronously BEFORE stop() reads
                // `recorder.notes` — `stop()` reads it a few lines after setting
                // `isRecording = false`, with no `await` in between, so a
                // debounce-driven commit reacting to `isRecording` flipping would
                // always be too late. See `NotesDraftBox`.
                recorder.notes = notesDraftBox.text
                recorder.noteLines = notesDraftBox.lines
                Task { await recorder.stop() }
            }
            .buttonStyle(.talkie(.primary, tint: Theme.featherRed))
        } else if recorder.isFinishing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing & summarizing…")
                    .font(.talkieHeading(13, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
            }
        } else {
            Button { Task { await recorder.start() } } label: {
                Label("Record".loc, systemImage: "record.circle")
            }
            .buttonStyle(.talkie(.primary))
            .disabled(!MeetingSummarizer.isAvailable && !TranscriptionEngine.isAvailable)
            .help("Captures you and the other participants on the call (Zoom, Meet, Teams) — and tells each person apart automatically.")
        }
    }

    // MARK: Live recording panel

    // MARK: List pane

    private var meetingList: some View {
        let groups = MeetingDateBucket.group(store.meetings, date: \.date, now: Date())
        let current = selectedMeeting?.id
        return ScrollViewReader { proxy in
            ScrollView {
                // Lazy: only rows near the visible region are built, and `.equatable()`
                // lets an unchanged row skip its body on the 1 Hz recording tick.
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        Text(group.bucket.title().uppercased())
                            .font(.talkieEyebrow)
                            .tracking(0.8)
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(group.items) { meeting in
                            MeetingListRow(
                                meeting: meeting,
                                isSelected: meeting.id == current,
                                isBusy: recorder.summarizingMeetingIDs.contains(meeting.id)
                                    || recorder.diarizingMeetingIDs.contains(meeting.id),
                                onSelect: {
                                    selectedID = meeting.id
                                    listFocused = true
                                },
                                onDelete: { pendingDelete = meeting }
                            )
                            .equatable()
                            .id(meeting.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollEdgeEffectHidden(true, for: .top)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onDeleteCommand { requestDeleteSelected() }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                requestDeleteSelected()
                return .handled
            }
            .onMoveCommand { direction in
                switch direction {
                case .up: selectedID = MeetingSelection.step(from: current, in: meetingIDs, by: -1)
                case .down: selectedID = MeetingSelection.step(from: current, in: meetingIDs, by: 1)
                default: break
                }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    private func requestDeleteSelected() {
        if let meeting = selectedMeeting { pendingDelete = meeting }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let meeting = selectedMeeting {
            ScrollView {
                MeetingDetail(
                    meeting: meeting,
                    isSummarizing: recorder.summarizingMeetingIDs.contains(meeting.id),
                    isDiarizing: recorder.diarizingMeetingIDs.contains(meeting.id),
                    profileImage: profileImage,
                    folderURL: store.folderURL,
                    onReveal: { reveal(meeting) },
                    onCopy: { copy(meeting) },
                    onDelete: { pendingDelete = meeting },
                    onRegenerate: { recorder.regenerateSummary(id: meeting.id) },
                    onSaveTranscript: { edited in saveTranscript(meeting, edited: edited) },
                    onLearn: { from, to in learnCorrection(from: from, to: to, in: meeting) }
                )
                .equatable()
                // Speaker labels in this pane show names and open the naming popover.
                .environment(\.speakerNaming, SpeakerNamingContext(
                    meetingID: meeting.id, names: meeting.speakerNames ?? [:], recorder: recorder))
                // Fresh per-meeting state (edit draft, learn chips, playback) on switch.
                .id(meeting.id)
                .padding(.leading, 4)
                .padding(.trailing, Self.pagePadding)
                .padding(.bottom, Self.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectHidden(true, for: .top)
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
            Text("Record a meeting; Talkie transcribes and summarizes it on-device, and saves a note you can point your AI agent at.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
            Text("Press Record before your next call, or drop audio or video here to transcribe it.".loc)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 420)
        .padding(40)
    }

    private func reveal(_ meeting: Meeting) {
        let url = store.folderURL.appendingPathComponent(meeting.fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copy(_ meeting: Meeting) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(meeting.namedTranscript, forType: .string)
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
}

/// The gear's popover: the one meeting preference worth flipping from here (keep
/// audio — the same `AppSettings.keepMeetingAudio` the Settings page binds, so
/// there is one source of truth) and the deep link to the full Meeting settings.
struct MeetingQuickSettingsPopover: View {
    @ObservedObject var settings: AppSettings
    let onOpenAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggleRow(
                title: "Keep audio with meeting notes".loc,
                subtitle: "Save each recording’s audio so you can click any line of the transcript to hear that exact moment.".loc,
                isOn: $settings.keepMeetingAudio)
            HStack {
                Spacer()
                Button("All meeting settings…") { onOpenAll() }
                .buttonStyle(.talkie(.secondary, size: .small))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(width: 340)
    }
}

/// What's being captured plus the live notes editor and the provisional "So far"
/// list, as one calm panel under the bar. Both are their own views: typing never
/// re-diffs this page, and a live summary update re-renders only its list.
struct MeetingRecordingPanel: View {
    @ObservedObject var recorder: MeetingRecorder
    let draftBox: NotesDraftBox

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: recorder.capturingFarEnd ? "person.2.wave.2" : "mic")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.featherRed)
                Text(recorder.capturingFarEnd ? "Recording you + the call…" : "Recording (mic only)…")
                    .font(.talkieHeading(14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            HStack(alignment: .top, spacing: 16) {
                RecordingNotesEditor(recorder: recorder, draftBox: draftBox)
                LiveSoFarView(state: recorder.liveSummary)
            }
        }
        .talkieCard(padding: 16)
    }
}

private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Theme.featherRed)
            .frame(width: 12, height: 12)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// The elapsed-time readout during a recording, isolated into its own tiny view
/// so the once-a-second tick (`MeetingRecorder.elapsed`, driven by a 1 Hz
/// `Timer`) only invalidates this one `Text` instead of the whole `MeetingsView`
/// page — which, before this, re-laid-out (and, pre-caching, re-word-counted)
/// every retained meeting row every second while recording.
private struct RecordingElapsedText: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        Text(Self.timeString(recorder.elapsed))
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Theme.inkSecondary)
    }

    private static func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// A plain (non-observed) box holding the in-progress notes draft, shared
/// between `RecordingNotesEditor` and `MeetingsView`'s "Stop & summarize" button.
/// Deliberately NOT an `ObservableObject`: `RecordingNotesEditor` updates `.text`
/// on every keystroke, and that mutation must stay silent (no `objectWillChange`)
/// so typing never republishes to `MeetingsView`. The button reads `.text`
/// synchronously right before calling `recorder.stop()`, so the very last
/// keystroke — which may still be sitting in the debounce below — is never lost
/// to a stop triggered from the in-app button.
final class NotesDraftBox {
    var text: String = ""
    /// Per line, the meeting time it was started (kept in step with `text`).
    var lines: [MeetingNoteStamper.Line] = []
}

/// Live notes during a recording. Every line keeps the meeting time at which it was
/// started; "Mark this moment" adds a time-stamped line to write into later. On stop
/// the notes go into the summary word for word, with their times, and each one
/// points the summary at what was said around its moment.
///
/// Used to be a `TextEditor` bound directly to `$recorder.notes` inline in
/// `MeetingsView.body`; every keystroke published through `recorder` (an
/// `@ObservedObject` the whole page observes), forcing a full-page re-diff per
/// character typed — expensive once the meetings list below it holds ~200 rows.
/// Pulling the editor out into its own view with a LOCAL `@State` draft means a
/// keystroke only invalidates this small view: the draft is committed back to
/// `recorder.notes` on a short debounce (so `MeetingRecorder`'s own 1 Hz
/// crash-recovery flush stays reasonably fresh), on blur, and when this view
/// disappears (recording stopped via a path other than the in-app button, or the
/// user switches tabs mid-recording) — never silently dropped.
struct RecordingNotesEditor: View {
    @ObservedObject var recorder: MeetingRecorder
    let draftBox: NotesDraftBox

    @State private var draft: String = ""
    @FocusState private var isFocused: Bool
    @State private var commitTask: Task<Void, Never>?

    /// Debounce before an in-progress edit reaches `recorder.notes`. Short
    /// enough that `MeetingRecorder`'s periodic crash-recovery flush (which reads
    /// `notes`) never lags typing by more than a fraction of a second, and that a
    /// recording stopped via a path OTHER than this page's button (a global
    /// hotkey, a Shortcut) — which this view can't intercept synchronously —
    /// only risks losing, at most, this little.
    private static let commitDebounce: Duration = .milliseconds(400)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
                Text("Your notes")
                    .font(.talkieEyebrow)
                    .foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("Kept word for word in the summary, with times".loc)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
                Button {
                    draft = MeetingNoteStamper.appendingMarker(to: draft, at: recorder.elapsed)
                    isFocused = true
                } label: {
                    Label("Mark this moment".loc, systemImage: "bookmark")
                }
                .buttonStyle(.talkie(.secondary, size: .small))
                .help("Adds a time-stamped line to your notes".loc)
            }
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 88, maxHeight: 150)
                .padding(8)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Jot key points — each line keeps the moment you started it…".loc)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .focused($isFocused)
        }
        // The surrounding recording panel draws the card.
        .frame(maxWidth: .infinity)
        .onAppear {
            // Seed from whatever `recorder.notes` already holds — a recording
            // started before this page was opened, or recovered mid-flight —
            // so re-opening the Meetings tab never shows a blank editor over
            // real notes.
            // Lines first, so seeding the text doesn't re-stamp them as new.
            draftBox.lines = recorder.noteLines.map(\.text) == recorder.notes.components(separatedBy: "\n")
                ? recorder.noteLines
                : MeetingNoteStamper.lines(text: recorder.notes, notes: recorder.noteItems)
            draft = recorder.notes
            draftBox.text = draft
        }
        .onChange(of: draft) { _, newValue in
            draftBox.text = newValue
            // A line gets the meeting time at which the user started it.
            draftBox.lines = MeetingNoteStamper.restamp(draftBox.lines, text: newValue, now: recorder.elapsed)
            scheduleCommit(newValue)
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commitNow() }
        }
        .onDisappear { commitNow() }
    }

    private func scheduleCommit(_ text: String) {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: Self.commitDebounce)
            guard !Task.isCancelled else { return }
            recorder.noteLines = draftBox.lines
            recorder.notes = text
        }
    }

    private func commitNow() {
        commitTask?.cancel()
        commitTask = nil
        recorder.noteLines = draftBox.lines
        recorder.notes = draft
    }
}

/// The provisional "So far" list beside the notes while recording: the topics,
/// decisions and action items the live summary has extracted from the settled part
/// of the conversation. Observes only `LiveSummaryState`, which publishes when a pass
/// lands (about once a minute), so it never re-renders on the 1 Hz tick.
struct LiveSoFarView: View {
    @ObservedObject var state: LiveSummaryState

    var body: some View {
        if state.phase != .off {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                    Text("So far".loc)
                        .font(.talkieEyebrow)
                        .foregroundStyle(Theme.inkSecondary)
                    Spacer()
                    Text("Provisional".loc)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkTertiary)
                }
                if state.snapshot.isEmpty {
                    Text(waitingText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            group("Topics".loc, state.snapshot.topics)
                            group("Decisions".loc, state.snapshot.decisions)
                            group("Action items".loc, state.snapshot.actions)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                    Text(footerText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 300, alignment: .topLeading)
        }
    }

    private var multilingual: Bool { state.multilingual }

    private var waitingText: String {
        multilingual
            ? "With several languages, the text settles every 10 minutes — the first items appear then.".loc
            : "Topics, decisions and tasks appear here after a few minutes of conversation.".loc
    }

    private var footerText: String {
        multilingual
            ? "Updates every 10 minutes, when the languages settle. The final summary is written when you stop.".loc
            : "Updates every minute. The final summary is written when you stop.".loc
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.talkieEyebrow)
                    .tracking(0.8)
                    .foregroundStyle(Theme.inkTertiary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• " + item)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One compact row in the meeting list: title, then "date · duration · N speakers",
/// with a small spinner while the summary or speaker pass is still running.
///
/// Perf: `.equatable()` (applied at the call site) lets SwiftUI skip this body when
/// the parent re-renders with unchanged inputs — the 1 Hz recording tick or a notes
/// keystroke never touch `store.meetings`. Closures aren't compared.
private struct MeetingListRow: View, Equatable {
    // nonisolated: `View` is @MainActor, but `Equatable.==` must be nonisolated.
    // Safe here — it only reads Sendable `let`s.
    nonisolated static func == (lhs: MeetingListRow, rhs: MeetingListRow) -> Bool {
        lhs.meeting.id == rhs.meeting.id && lhs.meeting.title == rhs.meeting.title
            && lhs.meeting.startUnix == rhs.meeting.startUnix
            && lhs.meeting.durationSec == rhs.meeting.durationSec
            && lhs.meeting.speakerCount == rhs.meeting.speakerCount
            && lhs.isSelected == rhs.isSelected && lhs.isBusy == rhs.isBusy
    }

    let meeting: Meeting
    let isSelected: Bool
    /// Summarizing or identifying speakers.
    let isBusy: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var meta: String {
        let date = meeting.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return [date, MeetingMeta.duration(meeting.durationSec), MeetingMeta.speakers(meeting.speakerCount)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title)
                        .font(.talkieHeading(13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(meta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView().controlSize(.mini)
                        .padding(.top, 2)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isSelected ? Theme.coralWash : (hovering ? Theme.surfaceSunken : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

/// The selected meeting in full: title, meta line, one row of actions, then the
/// summary and the always-visible transcript (click-to-play lines when audio was kept,
/// speaker turns when diarization applied, else the plain text).
///
/// Perf: `.equatable()` at the call site — only `meeting`, `folderURL` and the two
/// progress flags are compared, so the recording tick doesn't re-render this pane.
/// `profileImage` (an `@ObservedObject`) keeps its own reactivity.
private struct MeetingDetail: View, Equatable {
    nonisolated static func == (lhs: MeetingDetail, rhs: MeetingDetail) -> Bool {
        lhs.meeting == rhs.meeting && lhs.folderURL == rhs.folderURL && lhs.isSummarizing == rhs.isSummarizing
            && lhs.isDiarizing == rhs.isDiarizing
    }

    let meeting: Meeting
    /// The note is saved; its AI summary is still being written in the background.
    let isSummarizing: Bool
    /// The background speaker-separation pass is still pending or running for this note.
    let isDiarizing: Bool
    /// L7: the user's profile picture, shown leading the meta line ONLY when a photo
    /// is set. In-app display only — never written into the exported note.
    @ObservedObject var profileImage: ProfileImageStore
    /// ~/Talkie Meetings/ — where this meeting's kept audio (D9) lives, so the
    /// transcript can resolve a segment's file for click-to-play.
    let folderURL: URL
    let onReveal: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    /// Queues the regeneration on the recorder (it outlives this view).
    let onRegenerate: () -> Void
    /// Persist a hand-edited transcript (A8). Called on Save with the new text.
    let onSaveTranscript: (String) -> Void
    /// Accept a learn chip: add the dictionary rule + record the niche confirmation.
    /// Returns whether a NEW rule was added (false if it was already known), so the
    /// chip can show the right confirmation.
    let onLearn: (_ from: String, _ to: String) -> Bool
    /// Gates "Regenerate summary" behind an explicit confirmation whenever there's an
    /// existing summary to lose. `regenerateSummary` replaces the WHOLE `summary`
    /// field with a fresh transcript-only pass — and that field is also where the
    /// user's live meeting notes end up (fused into the prose via the Granola-style
    /// fusion, or verbatim under a "## Your notes" heading when fusion was
    /// unavailable). Neither form is separable back out of `summary` after the fact,
    /// so silently regenerating used to discard real user-typed content with no
    /// warning and no undo. Shown only when `meeting.summary` isn't already empty —
    /// nothing to lose for a genuinely blank summary.
    @State private var confirmRegenerate = false
    /// A8 transcript edit mode: nil when viewing; the working draft while editing.
    @State private var draft: String?
    /// The learn chips offered after a save, and which have been accepted/added.
    @State private var learnable: [LearnCandidate] = []
    /// Cached so the pane doesn't re-count the (potentially long) transcript on every
    /// render — populated once on `onAppear` and refreshed only when
    /// `meeting.transcript` actually changes (a transcript edit).
    @State private var cachedWordCount: Int?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .short; return f
    }()

    private var wordCount: Int {
        cachedWordCount ?? WordCounter.count(meeting.transcript)
    }

    private var canRegenerate: Bool {
        !meeting.transcript.isEmpty && MeetingSummarizer.isAvailable && !isSummarizing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            actions
            status
            if !meeting.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Summary")
                    MarkdownText(markdown: meeting.namedSummary, bulletColor: Theme.coral)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .talkieCard(padding: 16)
                }
            }
            transcriptSection
        }
        .frame(maxWidth: 760, alignment: .leading)
        .onAppear {
            if cachedWordCount == nil { cachedWordCount = WordCounter.count(meeting.transcript) }
        }
        .onChange(of: meeting.transcript) { _, newValue in
            cachedWordCount = WordCounter.count(newValue)
        }
        .confirmationDialog(
            "Regenerate summary?",
            isPresented: $confirmRegenerate,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) {
                onRegenerate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if meeting.notes?.isEmpty == false {
                Text("This replaces the summary with a fresh one. Your notes are kept. This can't be undone.".loc)
            } else {
                Text("This replaces the whole summary — including any notes fused into it during the meeting — with a fresh, transcript-only summary. This can't be undone.")
            }
        }
    }

    // MARK: Header + actions

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title)
                .font(.talkieDisplay(22))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                // L7: the profile picture, only when one is set.
                if profileImage.image != nil {
                    AvatarView(store: profileImage, size: 18)
                }
                Text([Self.dateFormatter.string(from: meeting.date),
                      MeetingMeta.duration(meeting.durationSec),
                      MeetingMeta.source(meeting.source),
                      MeetingMeta.speakers(meeting.speakerCount)]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkSecondary)
            }
            SpeakersRow(meeting: meeting)
                .padding(.top, 2)
        }
    }

    /// Icon + label when the pane is wide enough; icons only (with tooltips) when not,
    /// so a narrow window never truncates a label mid-word.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionButtons.labelStyle(.titleAndIcon)
            actionButtons.labelStyle(.iconOnly)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            Button(action: onCopy) { Label("Copy".loc, systemImage: "doc.on.doc") }
                .help("Copy transcript")
            // Timestamped exports (D3) — only when this meeting actually has timed
            // segments (recorded/imported after D2) — plus the kept audio files.
            // A meeting with neither shows no menu, so there's no dead UI.
            let segments = meeting.segments ?? []
            let audioItems = MeetingAudioExport.items(
                audioFiles: meeting.audioFiles, baseName: exportBaseName,
                fileExists: { FileManager.default.fileExists(atPath: folderURL.appendingPathComponent($0).path) })
            if !segments.isEmpty || !audioItems.isEmpty {
                Menu {
                    if !segments.isEmpty {
                        Button("Subtitles (.srt)") { export(segments, as: .srt) }
                        Button("Subtitles (.vtt)") { export(segments, as: .vtt) }
                        Button("Spreadsheet (.csv)") { export(segments, as: .csv) }
                        Button("Data (.json)") { export(segments, as: .json) }
                        // Chapter list (D8) — offered ONLY when the meeting shifted
                        // topics (≥2 chapters); a lone/absent topic shows nothing.
                        if let chapters = meeting.chapters, chapters.count >= 2 {
                            Button("Chapters (.txt)") { exportChapters(chapters) }
                        }
                        Divider()
                    }
                    // Kept audio, one file per side, copied as-is (never mixed).
                    if audioItems.isEmpty {
                        Button("No audio was kept for this meeting") {}
                            .disabled(true)
                    } else {
                        ForEach(audioItems, id: \.fileName) { item in
                            Button(item.title) { exportAudio(item) }
                        }
                    }
                } label: {
                    Label("Export…".loc, systemImage: "square.and.arrow.up")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Export…")
            }
            Button(action: onReveal) { Label("Show in Finder".loc, systemImage: "folder") }
                .help("Reveal note in Finder")
            // Edit the transcript (A8) — fixing a misrecognition here fixes the note
            // AND can teach the dictionary. Only for meetings that actually have
            // transcript text (recovered/notes-only entries have none).
            if !meeting.transcript.isEmpty {
                Button { beginEditing() } label: { Label("Edit transcript".loc, systemImage: "pencil") }
                    .help("Edit transcript")
                    .disabled(draft != nil)
            }
            if canRegenerate {
                Button {
                    // Nothing to lose when the summary is already blank — skip the
                    // confirmation and regenerate straight away (the original
                    // "meetings stuck with an empty summary" fix). Otherwise the
                    // existing summary may hold fused/typed notes that a regenerate
                    // would silently replace, so confirm first.
                    if meeting.summary.isEmpty {
                        onRegenerate()
                    } else {
                        confirmRegenerate = true
                    }
                } label: {
                    Label("Regenerate".loc, systemImage: "arrow.clockwise")
                }
                .help("Regenerate summary")
            }
            Spacer(minLength: 12)
            Button(role: .destructive, action: onDelete) {
                Label("Delete".loc, systemImage: "trash")
            }
            .buttonStyle(.talkie(.destructive, size: .small))
            .help("Delete")
        }
        .buttonStyle(.talkie(.secondary, size: .small))
    }

    @ViewBuilder
    private var status: some View {
        if isDiarizing {
            // Transient: `isDiarizing` flips off when the pass finishes or fails, so
            // this disappears on its own. Wins over the summary line because the
            // summary waits for the pass.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Identifying speakers…".loc)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .transition(.opacity)
        } else if isSummarizing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Writing the summary… the transcript is already saved.".loc)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    // MARK: Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow(text: "Transcript")
                if draft == nil, meeting.hasPlayableAudio, meeting.segments != nil {
                    Text("Click a line to hear that moment".loc)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Text(String(format: "%d words".loc, wordCount))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
            transcriptBody
                .talkieCard(padding: 16)
        }
    }

    /// The transcript itself, on a card under the section label: the editor, the
    /// click-to-play lines, speaker turns, or the plain text, plus any learn chips.
    @ViewBuilder
    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft != nil {
                transcriptEditor
            } else if meeting.hasPlayableAudio, let segments = meeting.segments {
                // D9 click-to-play: the transcript becomes a list of tappable
                // segments, each seeking the kept audio to that exact moment, with the
                // playing segment highlighted. Shown ONLY when both timed segments AND
                // kept audio exist. Editing takes precedence (draft branch above) so a
                // fix isn't fighting a playhead.
                MeetingPlaybackView(segments: segments,
                                    audioFiles: meeting.audioFiles,
                                    folderURL: folderURL,
                                    showsSpeakerLabels: SpeakerPresentation.showsTurns(for: meeting))
            } else if SpeakerPresentation.showsTurns(for: meeting), let segments = meeting.segments {
                SpeakerTurnsView(segments: segments)
            } else {
                Text(meeting.namedTranscript)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if draft == nil, !learnable.isEmpty {
                learnChips
            }
        }
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
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .onExitCommand { cancelEditing() }

            HStack(spacing: 8) {
                Text("Fixing a word here also teaches your dictionary.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
                Spacer()
                Button("Cancel") { cancelEditing() }
                    .buttonStyle(.talkie(.secondary, size: .small))
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitEditing(editing.wrappedValue) }
                    .buttonStyle(.talkie(.primary, size: .small))
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
                            .buttonStyle(.talkie(.primary, size: .small))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.surfaceSunken))
            }
        }
    }

    private func beginEditing() {
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

    /// Copy one kept audio file out through a save panel. A byte-for-byte copy of the
    /// file beside the note (no re-encode); the panel already confirmed any overwrite,
    /// so an existing file at the destination is replaced. Local disk only.
    private func exportAudio(_ item: MeetingAudioExport.Item) {
        let source = folderURL.appendingPathComponent(item.fileName)
        let panel = NSSavePanel()
        panel.title = "Export…".loc
        panel.nameFieldStringValue = item.defaultName
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: item.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                try fm.copyItem(at: source, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't export the audio.".loc
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
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

/// D9 — click-to-play synced transcript. Lists a meeting's timed segments; tapping one
/// seeks the kept audio to that segment's start and plays, and a ~12 Hz timer highlights
/// whichever segment is currently sounding. For a two-stream meeting (separate `-me` /
/// `-them` files) each segment plays the file matching its speaker, swapping the loaded
/// `AVAudioPlayer` when you cross from one speaker to the other; for a solo import (one
/// file) every segment plays that one recording.
///
/// The quote-verification feature for people who structurally can't put a call in a
/// cloud tool: the audio never leaves the Mac, and you can hear the exact moment behind
/// any line of the transcript. Only ever rendered when `meeting.hasPlayableAudio`, so
/// there's always a real file behind every play button.
///
/// All state is main-actor `@State`; `AVAudioPlayer` is created, seeked, and polled on
/// the main actor (no background audio thread of ours), and torn down on disappear so a
/// collapsed row isn't left holding an open file.
struct MeetingPlaybackView: View {
    let segments: [MeetingSegment]
    let audioFiles: [String: String]?
    let folderURL: URL
    /// Per-speaker labels only for a meeting diarization actually relabelled and whose
    /// transcript is unedited (`SpeakerPresentation.showsTurns`); any other meeting
    /// plays back exactly as it did before speaker labels existed.
    var showsSpeakerLabels = false

    init(segments: [MeetingSegment], audioFiles: [String: String]?, folderURL: URL,
         showsSpeakerLabels: Bool = false) {
        self.segments = segments
        self.audioFiles = audioFiles
        self.folderURL = folderURL
        self.showsSpeakerLabels = showsSpeakerLabels
    }

    /// The loaded player, or nil before the first tap. Recreated when a tap targets a
    /// different file than the one currently loaded (two-stream Me↔Them switch).
    @State private var player: AVAudioPlayer?
    /// Basename the `player` has loaded, so we know whether a tap needs a reload.
    @State private var currentFile: String?
    @State private var isPlaying = false
    /// The player's last-polled `currentTime` (audio-clock seconds), driving the
    /// highlight. Only meaningful together with `currentFile`.
    @State private var currentTime: Double = 0
    /// A file that failed to load (missing / partial m4a from a crashed recording), so
    /// the row shows an honest one-line notice instead of silently doing nothing.
    @State private var loadError = false

    /// ~12 Hz is smooth enough for a moving highlight without busy-spinning; it only
    /// does work while something is actually playing.
    private let ticker = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    /// The segment currently sounding (for the highlight), or nil when paused/stopped or
    /// playing a different file's stream. Pure function over the polled time.
    private var activeIndex: Int? {
        guard isPlaying, let currentFile else { return nil }
        return Meeting.activeSegmentIndex(
            at: currentTime, segments: segments, fileName: currentFile, audioFiles: audioFiles)
    }

    private var showLabels: Bool { showsSpeakerLabels && SpeakerPresentation.showsLabels(segments) }
    private var colorSlots: [String: Int] { SpeakerPresentation.colorIndices(for: segments.map(\.speaker)) }
    private var turnStarts: [Bool] { SpeakerPresentation.turnStarts(segments) }

    var body: some View {
        let slots = colorSlots
        let starts = turnStarts
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if showLabels, starts[index] {
                    SpeakerLabel(speaker: segment.speaker, slot: slots[segment.speaker] ?? 0)
                        .padding(.leading, 6)
                        .padding(.top, index == 0 ? 0 : 8)
                }
                segmentRow(index: index, segment: segment)
            }
            if loadError {
                Text("That audio couldn’t be played — the file may be missing or incomplete.".loc)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.top, 4)
            }
        }
        .onReceive(ticker) { _ in tick() }
        .onDisappear(perform: teardown)
    }

    @ViewBuilder
    private func segmentRow(index: Int, segment: MeetingSegment) -> some View {
        let playable = Meeting.audioFileName(forSpeaker: segment.audioKey, in: audioFiles) != nil
        let isActive = activeIndex == index
        Button {
            toggle(segment: segment)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(playable ? Theme.coral : Theme.inkTertiary)
                    .frame(width: 12)
                Text(MeetingTranscriptRenderer.timecode(segment.start))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(width: 40, alignment: .leading)
                Text(segment.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isActive ? Theme.ink : Theme.inkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(isActive ? Theme.coralWash : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!playable)
        .help(playable ? "Play from here".loc : "")
    }

    /// Tapping a segment: pause if it's the one already playing; otherwise seek this
    /// segment's file to its start and play. Crossing to a segment on a different stream
    /// (Me↔Them) loads that file first.
    private func toggle(segment: MeetingSegment) {
        guard let name = Meeting.audioFileName(forSpeaker: segment.audioKey, in: audioFiles) else { return }
        // Already playing this exact moment's stream → treat the tap as pause.
        if isPlaying, currentFile == name,
           Meeting.activeSegmentIndex(at: currentTime, segments: segments,
                                      fileName: name, audioFiles: audioFiles) == indexOf(segment) {
            player?.pause()
            isPlaying = false
            return
        }
        guard let ready = ensurePlayer(for: name) else { return }
        ready.currentTime = max(0, min(segment.start, ready.duration))
        ready.play()
        currentTime = ready.currentTime
        isPlaying = true
    }

    /// Load (or reuse) the player for `name`, returning it ready to seek — or nil if the
    /// file can't be opened (a partial/missing recording), latching `loadError` so the
    /// row explains itself. Swapping files stops the previous stream so two never sound
    /// at once.
    private func ensurePlayer(for name: String) -> AVAudioPlayer? {
        if currentFile == name, let player { return player }
        player?.stop()
        let url = folderURL.appendingPathComponent(name)
        guard let fresh = try? AVAudioPlayer(contentsOf: url) else {
            player = nil
            currentFile = nil
            isPlaying = false
            loadError = true
            return nil
        }
        fresh.prepareToPlay()
        player = fresh
        currentFile = name
        loadError = false
        return fresh
    }

    /// Poll the player each tick while it's playing, mirroring its clock into
    /// `currentTime` (drives the highlight) and noticing when playback reaches the end
    /// so the highlight clears. Does nothing when paused/stopped — no idle churn.
    private func tick() {
        guard isPlaying, let player else { return }
        if player.isPlaying {
            currentTime = player.currentTime
        } else {
            // Reached the end (or was stopped by the system) — clear the playing state.
            isPlaying = false
        }
    }

    private func teardown() {
        player?.stop()
        player = nil
        currentFile = nil
        isPlaying = false
    }

    private func indexOf(_ segment: MeetingSegment) -> Int? {
        segments.firstIndex(of: segment)
    }
}

/// A small speaker name above a turn: tinted by the speaker's stable accent slot. Reads
/// as a caption — no pill, no fill — so it aids scanning without decorating.
struct SpeakerLabel: View {
    let speaker: String
    let slot: Int
    /// Set only inside the meeting detail: names + the naming popover.
    @Environment(\.speakerNaming) private var naming
    @State private var editing = false
    @State private var hovering = false

    static func color(slot: Int) -> Color {
        let palette: [Color] = [Theme.coral, Theme.featherGold, Theme.featherGreen,
                                Theme.featherPlum, Theme.featherCoral, Theme.featherBlue]
        return palette[max(0, slot) % palette.count]
    }

    var body: some View {
        let named = naming?.names[speaker]
        let title = SpeakerNames.name(for: speaker, in: naming?.names) ?? SpeakerPresentation.displayName(for: speaker)
        let text = HStack(spacing: 3) {
            Text(title)
            // A name that came from a remembered voice is marked as such.
            if named?.source == .voice {
                Image(systemName: "waveform").font(.system(size: 9, weight: .semibold))
                    .accessibilityLabel("Recognised by voice".loc)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Self.color(slot: slot))
        if let naming, SpeakerNames.isNameable(speaker) {
            Button { editing = true } label: {
                text
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(hovering ? Theme.surfaceSunken : .clear))
                    // The whole label (padding included) is the hit area, not just the glyphs.
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .padding(.horizontal, -4)
                .onHover { hovering = $0 }
                .pointerStyle(.link)
                .help(named?.source == .voice ? "Recognised by voice. Click to change the name.".loc
                                              : "Name this speaker".loc)
                .accessibilityAddTraits(.isHeader)
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    SpeakerNamePopover(label: speaker, context: naming)
                }
        } else {
            text.accessibilityAddTraits(.isHeader)
        }
    }
}

/// The read-only transcript for a meeting with two or more speakers (no kept audio):
/// consecutive same-speaker segments merged into one turn under a single label.
struct SpeakerTurnsView: View {
    let segments: [MeetingSegment]

    var body: some View {
        let slots = SpeakerPresentation.colorIndices(for: segments.map(\.speaker))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(SpeakerPresentation.turns(segments).enumerated()), id: \.offset) { _, turn in
                VStack(alignment: .leading, spacing: 1) {
                    SpeakerLabel(speaker: turn.speaker, slot: slots[turn.speaker] ?? 0)
                    Text(turn.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
/// at a glance. Internal (not `private`) so the relocated allowlist card in
/// `MeetingsSettings` (L6c) reuses the exact same chip.
struct MeetingAppChip: View {
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
            .accessibilityLabel(String(format: "Remove %@".loc, app.displayName))
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surfaceSunken))
    }
}

/// A muted-app chip; tapping it un-mutes (Talkie will offer for it again).
/// Internal (not `private`) so the relocated muted card in `MeetingsSettings` (L6c)
/// reuses the exact same chip.
struct MutedAppChip: View {
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
        .accessibilityLabel(String(format: "Un-mute %@".loc, name))
    }
}

/// The import status line under the top bar: a "3 of 12" progress row with the current
/// filename, percent and Cancel; the "waiting for dictation to finish" state; the
/// once-at-end completion summary; or an error. Renders nothing when there's nothing to
/// say. Observes the coordinator so every state stays live.
private struct ImportStatusLine: View {
    @ObservedObject var importer: FileImportCoordinator

    var body: some View {
        let hasActivity = importer.active != nil || importer.waitingForSession
        if hasActivity || importer.lastCompletion != nil || importer.lastError != nil {
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(.bottom, 14)
        }
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
            .buttonStyle(.talkie(.quiet, size: .small))
            .help("Dismiss".loc)
            .accessibilityLabel("Dismiss".loc)
        }
        .talkieCard(padding: 12)
    }
}

/// The "Import…" open panel: pick audio/video files or a folder and enqueue them.
/// Folders are shallow-enumerated by the coordinator. On-device only — reads what the
/// user chose; nothing leaves the machine.
@MainActor
private enum ImportPanel {
    static func run(_ importer: FileImportCoordinator) {
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
