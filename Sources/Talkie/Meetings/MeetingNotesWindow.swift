import AppKit
import SwiftUI

// The small meeting-notes window: jot notes during a call without opening the whole
// app. It floats beside the call, takes typing without pulling Talkie's main window
// forward, and shows what has been said so far under the notes — the live topic,
// the provisional summary and the last lines of the transcript.
//
// It edits the SAME notes as the Meetings page (`MeetingRecorder.notesDraft`): the
// lines keep their time stamps and go into the summary word for word.

/// A panel that takes the keyboard without activating the app, so writing a note
/// never brings Talkie's main window (or its Dock icon) in front of the call.
private final class MeetingNotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MeetingNotesWindowController: NSObject, NSWindowDelegate {
    private var panel: MeetingNotesPanel?
    private let recorder: MeetingRecorder
    private let subtopic: MeetingSubtopicModel
    private let settings: AppSettings
    private let onOpenMeetings: () -> Void

    /// The window opened itself for this recording (nobody asked for it), so it also
    /// closes itself once the recording is saved — unless the user wrote in it.
    private(set) var openedAutomatically = false

    static let defaultSize = NSSize(width: 420, height: 680)
    static let minSize = NSSize(width: 340, height: 440)
    private static let pinnedKey = "meetingNotesWindowPinned"

    init(recorder: MeetingRecorder, subtopic: MeetingSubtopicModel, settings: AppSettings,
         onOpenMeetings: @escaping () -> Void) {
        self.recorder = recorder
        self.subtopic = subtopic
        self.settings = settings
        self.onOpenMeetings = onOpenMeetings
        super.init()
        UserDefaults.standard.register(defaults: [Self.pinnedKey: true])
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    #if DEBUG
    /// Test-only seam: the real-window snapshot grabs the panel by its number.
    var windowNumberForTesting: Int? { panel?.windowNumber }
    func setAppearanceForTesting(_ appearance: NSAppearance) { panel?.appearance = appearance }
    #endif

    /// Stay above other windows (the call).
    var isPinned: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pinnedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.pinnedKey)
            panel?.level = newValue ? .floating : .normal
        }
    }

    /// Show the window. `automatic`: it appears beside the call without taking the
    /// keyboard; otherwise (the user asked) it also becomes the key window.
    func show(automatic: Bool = false) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // The SwiftUI content is mounted only while the window is on screen (the
        // recording dot pulses; nothing may animate in a hidden window).
        if !(panel.contentView is NSHostingView<MeetingNotesWindowView>) {
            panel.contentView = NSHostingView(rootView: MeetingNotesWindowView(
                recorder: recorder, subtopic: subtopic, controller: self))
        }
        if !panel.isVisible { openedAutomatically = automatic }
        else if !automatic { openedAutomatically = false }
        if automatic {
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        panel?.close()
    }

    /// Called when a recording has been saved: an automatically opened window that
    /// holds no notes steps out of the way again.
    func recordingFinished() {
        guard openedAutomatically, isVisible else { return }
        close()
    }

    func openMeetings() { onOpenMeetings() }

    private func makePanel() -> MeetingNotesPanel {
        let panel = MeetingNotesPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Meeting notes".loc
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        // Not movable by its background: that also grabbed drags meant for the
        // notes editor (selecting text moved the window). It moves by its title
        // band and the gaps around the cards (`TalkieWindowDragArea`).
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = isPinned ? .floating : .normal
        // Beside a full-screen call too, and on whichever Space the call is on.
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = Self.minSize
        panel.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x050506) : NSColor(hex: 0xFFFFFF)
        }
        panel.delegate = self
        // First time: the right edge of the screen, clear of the call in the middle.
        if !panel.setFrameUsingName("MeetingNotesWindow"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.defaultSize.width - 24,
                                         y: visible.midY - Self.defaultSize.height / 2))
        }
        panel.setFrameAutosaveName("MeetingNotesWindow")
        return panel
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Unmount, so nothing in the window keeps animating while it is closed. The
        // editor commits its draft as it disappears.
        panel?.contentView = NSView()
        openedAutomatically = false
    }

    /// Whether a recording that just started should bring the notes window up: the
    /// setting is on and the main window is not already in front showing the same
    /// editor. Pure, so the rule is unit-tested.
    nonisolated static func shouldOpenAutomatically(settingOn: Bool, mainWindowInFront: Bool,
                                                    alreadyVisible: Bool) -> Bool {
        settingOn && !mainWindowInFront && !alreadyVisible
    }
}

// MARK: - Content

struct MeetingNotesWindowView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var subtopic: MeetingSubtopicModel
    let controller: MeetingNotesWindowController

    /// Which view of "what has been said" is showing.
    enum ContextTab: String, CaseIterable, Identifiable {
        case soFar, transcript
        var id: String { rawValue }
        var title: String { self == .soFar ? "So far".loc : "Said just now".loc }
    }

    @AppStorage("meetingNotesWindowContextTab") private var contextTabRaw = ContextTab.soFar.rawValue
    @State private var pinned = true
    @ObservedObject private var appearance = AppearanceStore.shared

    private var contextTab: ContextTab { ContextTab(rawValue: contextTabRaw) ?? .soFar }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if recorder.isRecording {
                notesCard
                contextCard
            } else {
                idleCard
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        // Clears the traffic lights: the header row sits in the titlebar band.
        .padding(.top, 10)
        .frame(minWidth: MeetingNotesWindowController.minSize.width,
               minHeight: MeetingNotesWindowController.minSize.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            TalkieBackdrop(turn: 2)
            // Behind the cards: the title band and the gaps move the window.
            TalkieWindowDragArea()
        }
        .ignoresSafeArea(.container, edges: .top)
        .buttonStyle(.talkie(.secondary))
        .id(appearance.look.paintKey)
        .onAppear { pinned = controller.isPinned }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            // Room for the close button.
            Color.clear.frame(width: 22, height: 1)
            statusLine
            Spacer(minLength: 8)
            Button {
                pinned.toggle()
                controller.isPinned = pinned
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.talkie(.quiet, size: .small, tint: pinned ? Theme.brand : nil))
            .help(pinned ? "Stays on top of other windows".loc : "Keep on top of other windows".loc)
            .accessibilityLabel("Keep on top of other windows".loc)
            .accessibilityAddTraits(pinned ? .isSelected : [])
            Button { controller.openMeetings() } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.talkie(.quiet, size: .small))
            .help(String(format: "Open %@".loc, Brand.displayName))
            .accessibilityLabel(String(format: "Open %@".loc, Brand.displayName))
        }
        .frame(height: 30)
    }

    @ViewBuilder private var statusLine: some View {
        if recorder.isRecording {
            HStack(spacing: 7) {
                NotesWindowRecordingDot()
                Text(recorder.capturingFarEnd ? "Recording you + the call".loc : "Recording (mic only)".loc)
                    .font(.talkieHeading(12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                NotesWindowElapsed(recorder: recorder)
            }
        } else {
            Text("Meeting notes".loc)
                .font(.talkieHeading(12.5, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
        }
    }

    // MARK: Recording

    private var notesCard: some View {
        RecordingNotesEditor(recorder: recorder, draftBox: recorder.notesDraft, fillsHeight: true)
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
            .talkieCard(padding: 14)
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(ContextTab.allCases) { tab in
                    Button(tab.title) { contextTabRaw = tab.rawValue }
                        .buttonStyle(.talkieChip(selected: contextTab == tab))
                        .accessibilityAddTraits(contextTab == tab ? .isSelected : [])
                }
                Spacer(minLength: 8)
                Button("Stop & summarize".loc) { Task { await recorder.stop() } }
                    .buttonStyle(.talkie(.primary, size: .small, tint: Theme.featherRed))
            }
            if let topic = subtopic.currentGloss ?? subtopic.current {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .accessibilityHidden(true)
                    Text(verbatim: topic)
                        .font(.talkieHeading(12.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(String(format: "Current topic: %@".loc, topic)))
            }
            Group {
                switch contextTab {
                case .soFar:
                    NotesWindowSoFar(state: recorder.liveSummary)
                case .transcript:
                    NotesWindowTranscriptTail(tail: recorder.liveTail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 262, alignment: .top)
        .talkieCard(padding: 14)
    }

    // MARK: Idle / finishing

    private var idleCard: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "note.text")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
            if recorder.isFinishing {
                TalkieStatusLine(text: "Transcribing & summarizing…".loc, tone: .progress)
            } else {
                Text("Notes for your next meeting".loc)
                    .font(.talkieHeading(15, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                Text("Start recording, then write here. Every line keeps the moment you wrote it and goes into the summary word for word.".loc)
                    .font(.talkieHeading(13, weight: .regular))
                    .foregroundStyle(Theme.inkTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
                Button { Task { await recorder.start() } } label: {
                    Label("Record".loc, systemImage: "record.circle")
                }
                .buttonStyle(.talkie(.primary))
                .disabled(recorder.isStarting || (!MeetingSummarizer.isAvailable && !TranscriptionEngine.isAvailable))
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .talkieCard(padding: 20, fill: true)
    }
}

// MARK: - Pieces

/// The provisional summary, or what to expect while there is none yet.
private struct NotesWindowSoFar: View {
    @ObservedObject var state: LiveSummaryState

    var body: some View {
        if state.phase == .off {
            Text("A running summary isn’t available for this recording. The full summary is written when you stop.".loc)
                .font(.talkieHeading(12, weight: .regular))
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LiveSoFarView(state: state, fills: true)
        }
    }
}

/// The last lines of the live transcript, newest at the bottom and kept in view.
private struct NotesWindowTranscriptTail: View {
    @ObservedObject var tail: LiveTranscriptTail

    var body: some View {
        if tail.lines.isEmpty {
            TalkieStatusLine(text: "What is said appears here a few seconds after it is spoken.".loc, tone: .progress)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(tail.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Circle()
                                    .fill(line.speaker == .me ? Theme.brand : Theme.featherGold)
                                    .frame(width: 6, height: 6)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: "\(line.speaker.rawValue.loc) · \(MeetingTranscriptRenderer.timecode(line.seconds))")
                                        .font(.talkieHeading(11, weight: .semibold))
                                        .foregroundStyle(Theme.inkTertiary)
                                        .monospacedDigit()
                                    Text(verbatim: line.text)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Theme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .talkieScrollEdgeFades(top: 6, bottom: 6)
                .onAppear { if let last = tail.lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: tail.lines.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

/// The pulsing red dot. Mounted only while the window is on screen (the controller
/// unmounts the content on close), so its repeat never runs in a hidden window.
private struct NotesWindowRecordingDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Theme.featherRed)
            .frame(width: 9, height: 9)
            .opacity(on || reduceMotion ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// Elapsed time, isolated so the 1 Hz tick re-renders only this text.
private struct NotesWindowElapsed: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        Text(verbatim: MeetingTranscriptRenderer.timecode(recorder.elapsed))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Theme.inkSecondary)
            .monospacedDigit()
    }
}
