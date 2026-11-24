import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in design-conformance evidence (docs/DESIGN_GUIDELINES.md): every surface added
/// since 0.2.0, rendered on its own — popovers and panels hosted directly — in light and
/// dark. Skipped unless TALKIE_UI_SNAPSHOT_DIR is set. Stores use throwaway temp dirs.
@MainActor
final class UIConformanceSnapshotTests: XCTestCase {
    private var dir: URL!
    private var tmp: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_UI_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_UI_SNAPSHOT_DIR to render UI snapshots")
        }
        _ = NSApplication.shared
        dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-ui-conform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: Fixtures

    private func meetingFixture() throws -> (MeetingStore, MeetingRecorder, [Meeting]) {
        var meetings = UISnapshotTests.fixtureMeetings()
        meetings[1].speakerNames = ["Speaker 1": SpeakerName(name: "Dana", source: .conversation)]
        try JSONEncoder().encode(meetings).write(to: tmp.appendingPathComponent("meetings.json"))
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        let recorder = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store)
        return (store, recorder, store.meetings)
    }

    private func importer(_ store: MeetingStore) -> FileImportCoordinator {
        FileImportCoordinator(
            meetingStore: store, contextGraph: ContextGraphStore(directory: tmp),
            primaryLocale: { "en-US" }, spokenLanguages: { ["en-US"] },
            isDictating: { false }, isProcessing: { false }, isRecording: { false },
            summarize: { _, _ in "" })
    }

    // MARK: Rendering

    /// Hosts `view` in an offscreen borderless window (so AppKit-backed controls —
    /// text fields, switches, menus — draw for real) and writes light + dark PNGs.
    /// `height: nil` sizes to the view's fitting height.
    private func shot<V: View>(_ name: String, width: CGFloat, height: CGFloat? = nil,
                               background: Color = Theme.canvas, padding: CGFloat = 16,
                               @ViewBuilder _ view: () -> V) throws {
        let content = view()
        for (scheme, an) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let appearance = NSAppearance(named: an)!
            let root = content
                .padding(padding)
                .frame(width: width, height: height, alignment: .topLeading)
                .background(background)
                .environment(\.colorScheme, scheme)
                .buttonStyle(.talkie(.secondary))
            let host = NSHostingView(rootView: root)
            host.appearance = appearance
            let fitting = host.fittingSize
            let size = NSSize(width: width, height: height ?? max(40, fitting.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), "no rep: \(name)")
            appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
            window.orderOut(nil)
            window.close()
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "render failed: \(name)")
            try data.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private var popoverBackground: Color { Color(nsColor: .windowBackgroundColor) }

    // MARK: Meetings

    func testMeetingSurfaces() throws {
        let (store, recorder, meetings) = try meetingFixture()
        let settings = AppSettings()
        let diarized = meetings[1]
        let naming = SpeakerNamingContext(meetingID: diarized.id, names: diarized.speakerNames ?? [:],
                                          recorder: recorder)

        // The naming popover: an unnamed speaker and a speaker named from the conversation.
        try shot("speaker-popover-unnamed", width: 360, background: popoverBackground, padding: 0) {
            SpeakerNamePopover(label: "Speaker 2", context: naming)
        }
        try shot("speaker-popover-named", width: 360, background: popoverBackground, padding: 0) {
            SpeakerNamePopover(label: "Speaker 1", context: naming)
        }
        // Speaker labels + the Speakers row, with naming wired (clickable).
        try shot("speakers-row", width: 620) {
            SpeakersRow(meeting: diarized).environment(\.speakerNaming, naming)
        }
        try shot("speaker-turns", width: 620) {
            SpeakerTurnsView(segments: diarized.segments ?? []).environment(\.speakerNaming, naming)
        }
        try shot("speaker-playback-rows", width: 620) {
            MeetingPlaybackView(segments: diarized.segments ?? [], audioFiles: ["Me": "a.m4a", "Them": "b.m4a"],
                                folderURL: tmp, showsSpeakerLabels: true)
                .environment(\.speakerNaming, naming)
        }
        // Gear quick-settings popover.
        try shot("meetings-quick-settings", width: 380, background: popoverBackground, padding: 0) {
            MeetingQuickSettingsPopover(settings: settings) {}
        }
        // Recording panel: notes editor + "Mark this moment" + the "So far" list.
        recorder.liveSummary.reset(.listening)
        recorder.liveSummary.update(LiveSummarySnapshot(
            topics: ["Launch checklist", "Migration rehearsal"],
            decisions: ["Ship after one dry run"],
            actions: ["Run the dry run this week (Speaker 2)"], chunks: 3))
        try shot("meetings-recording-panel", width: 900) {
            MeetingRecordingPanel(recorder: recorder, draftBox: NotesDraftBox())
        }
        recorder.liveSummary.reset(.listening)
        try shot("meetings-recording-panel-waiting", width: 900) {
            MeetingRecordingPanel(recorder: recorder, draftBox: NotesDraftBox())
        }
        // Whole page: header, list, detail (Speakers row, action row incl. Export menu).
        recorder.markSummarizingForTesting(meetings[0].id)
        var page = MeetingsView(recorder: recorder, store: store, settings: settings,
                                profileImage: ProfileImageStore(), importer: importer(store),
                                contextGraph: nil, router: SettingsRouter())
        page.initialSelection = diarized.id
        try shot("meetings-page", width: 1100, height: 720, padding: 0) { page }
        // Known voices + Your voice.
        let voices = [KnownVoice(name: "Dana", embedding: [], speechSeconds: 40, createdUnix: 1),
                      KnownVoice(name: "Sam", embedding: [], speechSeconds: 31, createdUnix: 2)]
        try shot("known-voices-card", width: 720) {
            VStack(alignment: .leading, spacing: 18) {
                VoiceProfileCard(onForget: {})
                KnownVoicesCard(voices: voices, onDelete: { _ in }, onForgetAll: {})
            }
        }
    }

    // MARK: Commands, Settings, Memory, Dictionary, Dashboard

    func testSettingsAndPageSurfaces() throws {
        let settings = AppSettings()
        let (store, _, _) = try meetingFixture()
        try shot("commands-page", width: 900, height: 1500, padding: 0) {
            CommandsView(settings: settings, macros: MacroStore(), commandRouter: CommandRouter(macros: MacroStore()),
                         hud: HUDController(), meetingStore: store)
        }
        try shot("settings-dictation-key", width: 820) {
            ActivationSettings(settings: settings)
        }
        try shot("settings-version-replay", width: 820) {
            VStack(alignment: .leading, spacing: 18) {
                ReplayIntroductionCard(settings: settings)
                VersionRow()
            }
        }
        try shot("dashboard-update-line", width: 900) {
            UpdateReminderLine(days: 140, onDismiss: {})
        }
        let now = Date().timeIntervalSince1970
        let entries = ["Let's move the planning review to Thursday afternoon.",
                       "Remind me to send the revised budget before the end of the week."]
            .enumerated().map { i, t in
                DictationEntry(timestampUnix: now - Double(i) * 5400 - 600, text: t,
                               wordCount: t.split(separator: " ").count, durationSec: 8,
                               appName: "Notes", appCategory: nil, bundleID: nil)
            }
        try JSONEncoder().encode(entries).write(to: tmp.appendingPathComponent("history.json"))
        let history = HistoryStore(retentionDays: 0, maxCount: 0, directory: tmp)
        try shot("memory-page", width: 900, height: 520, padding: 0) {
            MemoryView(settings: settings, contextGraph: ContextGraphStore(directory: tmp), history: history,
                       searchEngine: SearchEngine(), meetingStore: store, wordFreq: WordFrequencyStore(),
                       scratchpad: ScratchpadStore())
        }
        let dictionary = DictionaryStore()
        try shot("dictionary-page", width: 1000, height: 640, padding: 0) {
            DictionarySettings(settings: settings, dictionary: dictionary, nicheVocab: NicheVocabStore())
        }
    }

    // MARK: Onboarding

    func testOnboardingSurfaces() throws {
        let settings = AppSettings()
        let permissions = PermissionsModel()
        try shot("onboarding-permission-rows", width: 480, background: Theme.canvas) {
            VStack(spacing: 9) {
                OnboardPermissionRow(icon: "IconMic", title: "Microphone", why: "Granted while you tried it out.",
                                     action: .granted) {}
                OnboardPermissionRow(icon: "IconKeyboard", title: "Input Monitoring",
                                     why: "Only to notice your dictation key.",
                                     action: .request) {}
                OnboardPermissionRow(icon: "IconAccessibility", title: "Accessibility",
                                     why: "To type the text into the app you're using.",
                                     action: .openSettings) {}
            }
        }
        try shot("onboarding-permissions-step", width: 760, height: 760, padding: 0) {
            OnboardingView(settings: settings, permissions: permissions, onRetryHotKey: { true },
                           initialStep: OnboardingView.permissionsStepIndex)
        }
        try shot("onboarding-final-step", width: 760, height: 760, padding: 0) {
            OnboardingView(settings: settings, permissions: permissions, onRetryHotKey: { true },
                           initialStep: OnboardingView.readyStepIndex)
        }
    }
}
