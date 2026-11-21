import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in visual evidence without launching the app: renders the diarization UI to PNGs
/// with `ImageRenderer`. Skipped unless TALKIE_UI_SNAPSHOT_DIR is set. The app bundles no
/// font files (system fonts), so nothing needs registering.
@MainActor
final class UISnapshotTests: XCTestCase {
    private func seg(_ who: String, _ s: Double, _ text: String) -> MeetingSegment {
        MeetingSegment(speaker: who, start: s, end: s + 6, text: text)
    }

    private var sample: [MeetingSegment] {
        [seg("Me", 0, "Thanks everyone for joining. I want to walk through the launch plan and then leave plenty of time for questions."),
         seg("Speaker 1", 14, "Sure. From the design side we are on track, the last open item is the onboarding flow which should land by Thursday."),
         seg("Speaker 1", 29, "I would like a second review pass on the empty states before we ship."),
         seg("Speaker 2", 41, "Engineering is fine with that. The only risk I see is the migration, we have not rehearsed it on a large account yet."),
         seg("Me", 58, "Good point. Can you own a dry run this week and report back on Friday?"),
         seg("Speaker 3", 70, "I can help with that, I have a staging copy of a big account from last month."),
         seg("Speaker 2", 83, "Great, then let us plan the rehearsal for Wednesday afternoon.")]
    }

    private func render<V: View>(_ view: V, name: String, dir: URL, width: CGFloat = 560) throws {
        for (scheme, appearanceName) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            var png: Data?
            appearance.performAsCurrentDrawingAppearance {
                let content = view
                    .padding(16)
                    .frame(width: width, alignment: .topLeading)
                    .background(Theme.canvas)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff) {
                    png = rep.representation(using: .png, properties: [:])
                }
            }
            let data = try XCTUnwrap(png, "render failed: \(name)")
            try data.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    func testRenderDiarizationUI() throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_UI_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_UI_SNAPSHOT_DIR to render UI snapshots")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try render(SpeakerTurnsView(segments: sample), name: "speaker-turns", dir: dir)
        try render(MeetingPlaybackView(segments: sample, audioFiles: ["Me": "a-me.m4a", "Them": "a-them.m4a"],
                                       folderURL: dir, showsSpeakerLabels: true),
                   name: "playback-rows", dir: dir)
        try render(VoiceProfileCard(onForget: {}), name: "your-voice-card", dir: dir)
    }

    // MARK: Whole Meetings page (before/after evidence for the two-pane redesign)

    /// Six invented, neutral meetings: one diarized with three speakers and turns, one
    /// imported, one still summarizing (marked on the recorder by the caller).
    static func fixtureMeetings(now: Date = Date()) -> [Meeting] {
        let cal = Calendar.current
        let today = max(cal.startOfDay(for: now).addingTimeInterval(60), now.addingTimeInterval(-3600))
        func daysAgo(_ d: Int, hour: Int) -> Date {
            let day = cal.date(byAdding: .day, value: -d, to: cal.startOfDay(for: now))!
            return day.addingTimeInterval(TimeInterval(hour * 3600))
        }
        func seg(_ who: String, _ s: Double, _ text: String) -> MeetingSegment {
            MeetingSegment(speaker: who, start: s, end: s + 6, text: text)
        }
        let turns = [seg("Me", 0, "Thanks for joining. Let us walk through the launch checklist."),
                     seg("Speaker 1", 12, "Design is on track; the onboarding screens land on Thursday."),
                     seg("Speaker 2", 27, "Engineering wants one rehearsal of the migration first."),
                     seg("Me", 41, "Agreed. Can you run that dry run this week?"),
                     seg("Speaker 2", 50, "Yes, I will report back on Friday.")]
        let plainSegs = [seg("Me", 0, "Quick check-in on the roadmap and the open hiring loop."),
                         seg("Them", 9, "The roadmap draft is ready for review tomorrow.")]
        func m(_ title: String, _ date: Date, _ minutes: Double, summary: String,
               transcript: String, source: String = "talkie (mic + system audio)",
               segments: [MeetingSegment]? = nil, speakers: Int? = nil, state: String? = nil) -> Meeting {
            Meeting(title: title, startUnix: date.timeIntervalSince1970, durationSec: minutes * 60,
                    transcript: transcript, summary: summary, participants: ["Me", "Them"],
                    source: source, fileName: NoteTemplate.slug(title) + ".md",
                    segments: segments, speakerCount: speakers, diarizationState: state)
        }
        return [
            m("Weekly product sync", today, 32,
              summary: "", transcript: MeetingTranscriptRenderer.render(segments: plainSegs),
              segments: plainSegs),
            m("Launch checklist review", today.addingTimeInterval(-5400), 47,
              summary: "The team reviewed the launch checklist.\n\n**Decisions:**\n- Ship after one migration rehearsal\n\n**Action items:**\n- Run the dry run this week (Speaker 2)",
              transcript: MeetingTranscriptRenderer.render(segments: turns),
              segments: turns, speakers: 3, state: "applied"),
            m("Design critique: settings screen", daysAgo(1, hour: 15), 25,
              summary: "Reviewed the settings layout; agreed to group preferences by task.",
              transcript: "We looked at the settings screen and agreed to group the preferences by task rather than by feature."),
            m("Customer interview recording", daysAgo(2, hour: 10), 58,
              summary: "A customer described their weekly reporting routine and where it slows down.",
              transcript: "The customer walked through how they prepare the weekly report and which steps take the longest.",
              source: "talkie (imported: interview.m4a)"),
            m("Quarterly planning", daysAgo(35, hour: 9), 74,
              summary: "Set three goals for the quarter and named an owner for each.",
              transcript: "We agreed on three goals for the quarter and assigned an owner to each one."),
            m("One-on-one", daysAgo(40, hour: 14), 18,
              summary: "Talked about growth areas and the next review cycle.",
              transcript: "We talked about growth areas and how the next review cycle will work."),
        ]
    }

    func testRenderMeetingsPage() throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_UI_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_UI_SNAPSHOT_DIR to render UI snapshots")
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Seed the store through its JSON index (not `add`, which also exports notes).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-ui-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let meetings = Self.fixtureMeetings()
        try JSONEncoder().encode(meetings).write(to: tmp.appendingPathComponent("meetings.json"))
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        XCTAssertEqual(store.meetings.count, 6)
        let recorder = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: store)
        recorder.markSummarizingForTesting(meetings[0].id)
        let importer = FileImportCoordinator(
            meetingStore: store, contextGraph: ContextGraphStore(directory: tmp),
            primaryLocale: { "en-US" }, spokenLanguages: { ["en-US"] },
            isDictating: { false }, isProcessing: { false }, isRecording: { false },
            summarize: { _, _ in "" })
        let page = MeetingsView(recorder: recorder, store: store, settings: AppSettings(),
                                profileImage: ProfileImageStore(), importer: importer, contextGraph: nil,
                                router: SettingsRouter())
        try renderPage(page, name: "meetings-page", dir: dir)
        // The same page with the three-speaker meeting selected (summary + speaker turns).
        var turnsPage = page
        turnsPage.initialSelection = meetings[1].id
        try renderPage(turnsPage, name: "meetings-page-speakers", dir: dir)
        // No meetings: the empty state, centred.
        let emptyDir = tmp.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyStore = MeetingStore(supportDirectory: emptyDir, meetingsDirectory: emptyDir)
        try renderPage(MeetingsView(recorder: recorder, store: emptyStore, settings: AppSettings(),
                                    profileImage: ProfileImageStore(), importer: importer,
                                    contextGraph: nil, router: SettingsRouter()),
                       name: "meetings-page-empty", dir: dir)
        // Where the page's preference cards now live (keep audio, watched folder, reveal).
        try renderPage(MeetingsSettings(settings: AppSettings(), router: SettingsRouter()),
                       name: "meeting-settings", dir: dir)
    }

    /// ImageRenderer can't draw ScrollView / AppKit-backed controls (it paints a
    /// placeholder), so the whole page is hosted in an offscreen window and captured
    /// with `cacheDisplay`, which draws the real AppKit view tree.
    private func renderPage<V: View>(_ view: V, name: String, dir: URL) throws {
        let size = NSSize(width: 1000, height: 680)
        for (scheme, appearanceName) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            let host = NSHostingView(rootView: view
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Theme.canvas)
                .environment(\.colorScheme, scheme))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            // Far off-screen so nothing flashes on the desktop while it renders.
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            // Let SwiftUI lay out, load lazy rows and settle onAppear state.
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), "no rep: \(name)")
            appearance.performAsCurrentDrawingAppearance {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
            window.orderOut(nil)
            window.close()
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "render failed: \(name)")
            try data.write(to: dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
