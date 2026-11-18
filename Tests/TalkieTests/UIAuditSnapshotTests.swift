import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in audit renderer: hosts the real `MainView` (sidebar + detail) in an offscreen
/// titled window configured exactly like `MainWindowController`, for every tab and the
/// main Settings subpages, light and dark. Skipped unless TALKIE_UI_SNAPSHOT_DIR is set.
/// All stores resolve to `AppPaths.testSandboxRoot` (a throwaway temp dir), never real data.
@MainActor
final class UIAuditSnapshotTests: XCTestCase {
    private var log: [String] = []

    @MainActor private struct Stores {
        let settings = AppSettings()
        let dictionary = DictionaryStore()
        let permissions = PermissionsModel()
        let history: HistoryStore
        let stats = StatsStore()
        let appUsage = AppUsageStore()
        let activity = ActivityStore()
        let wordFreq = WordFrequencyStore()
        let jobTitle = JobTitleStore()
        let latency = LatencyStore()
        let pressure = SystemPressure()
        let scratchpad = ScratchpadStore()
        let profileImage = ProfileImageStore()
        let autoAdd = AutoAddPreviewLog()
        let projectIndex = ProjectIndexStore()
        let contextSummary = ContextSummaryStore()
        let meetingRecorder: MeetingRecorder
        let meetingStore: MeetingStore
        let contextGraph = ContextGraphStore()
        let macros = MacroStore()
        let profiles = AppProfileStore()
        let search = SearchEngine()
        let nicheVocab = NicheVocabStore()
        let commandRouter: CommandRouter
        let hud = HUDController()
        let router = SettingsRouter()
        let tmp: URL

        init() throws {
            tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("talkie-ui-audit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            // Meetings via the JSON index.
            let meetings = UISnapshotTests.fixtureMeetings()
            try JSONEncoder().encode(meetings).write(to: tmp.appendingPathComponent("meetings.json"))
            meetingStore = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
            meetingRecorder = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: meetingStore)
            // History through its JSON file.
            let now = Date().timeIntervalSince1970
            let samples: [(String, String)] = [
                ("Let's move the planning review to Thursday afternoon and invite the design team.", "Notes"),
                ("Remind me to send the revised budget spreadsheet before the end of the week.", "Mail"),
                ("The onboarding flow needs a clearer empty state when there are no projects yet.", "Notes"),
                ("Could you take a look at the pull request when you get a chance, thanks.", "Slack"),
                ("Draft a short summary of today's customer call and list the follow-up actions.", "Notes"),
                ("Add a section about keyboard shortcuts to the handbook.", "Pages"),
            ]
            let entries = samples.enumerated().map { i, s in
                DictationEntry(timestampUnix: now - Double(i) * 5400 - 600, text: s.0,
                               wordCount: s.0.split(separator: " ").count, durationSec: 9 + Double(i),
                               appName: s.1, appCategory: nil, bundleID: nil)
            }
            try JSONEncoder().encode(entries).write(to: tmp.appendingPathComponent("history.json"))
            history = HistoryStore(retentionDays: 0, maxCount: 0, directory: tmp)
            commandRouter = CommandRouter(macros: macros)
        }
    }

    private func seed(_ s: Stores) {
        s.settings.hasOnboarded = true
        s.settings.userName = "Alex"
        for t in ["Kestrel", "Northwind", "Ledgerly", "Orchid", "Quarterly roadmap"] { s.dictionary.addVocabularyTerm(t) }
        s.macros.add(trigger: "my signature", expansion: "Best regards,\nAlex")
        s.macros.add(trigger: "standup template", expansion: "Yesterday: \nToday: \nBlockers: ")
        for i in 0..<20 {
            _ = s.stats.record(words: 40 + i * 7, durationSec: 20 + Double(i))
            s.activity.record(words: 300 + i * 40, at: Date().addingTimeInterval(-Double(i) * 86_400))
        }
        s.stats.recordFixes(dictionary: 12, fillers: 48, aiWords: 9)
    }

    private func makeWindow(_ s: Stores, size: NSSize, appearance: NSAppearance)
        -> (NSWindow, NSHostingController<MainView>) {
        let root = MainView(
            settings: s.settings, dictionary: s.dictionary, permissions: s.permissions, history: s.history,
            stats: s.stats, appUsage: s.appUsage, activity: s.activity, wordFreq: s.wordFreq,
            jobTitle: s.jobTitle, latency: s.latency, systemPressure: s.pressure, scratchpad: s.scratchpad,
            profileImage: s.profileImage, autoAddPreviewLog: s.autoAdd, projectIndex: s.projectIndex,
            contextSummary: s.contextSummary, meetingRecorder: s.meetingRecorder, meetingStore: s.meetingStore,
            contextGraph: s.contextGraph, macros: s.macros, profiles: s.profiles, searchEngine: s.search,
            nicheVocab: s.nicheVocab, commandRouter: s.commandRouter, hud: s.hud, router: s.router,
            onRetryHotKey: { true })
        // Mirrors MainWindowController.init (SettingsView.swift:177-203).
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = Brand.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(name: nil) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x000000) : NSColor(hex: 0xFFFFFF)
        }
        let hc = NSHostingController(rootView: root)
        window.contentViewController = hc
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.appearance = appearance
        return (window, hc)
    }

    private func capture(_ s: Stores, name: String, dir: URL, tab: SettingsTab, page: SettingsPage?, measure: Bool) throws {
        let size = NSSize(width: 1100, height: 720)
        for (scheme, an) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: an)!
            s.router.selectedTab = tab
            s.router.pendingPage = page
            let root = MainView(
                settings: s.settings, dictionary: s.dictionary, permissions: s.permissions, history: s.history,
                stats: s.stats, appUsage: s.appUsage, activity: s.activity, wordFreq: s.wordFreq,
                jobTitle: s.jobTitle, latency: s.latency, systemPressure: s.pressure, scratchpad: s.scratchpad,
                profileImage: s.profileImage, autoAddPreviewLog: s.autoAdd, projectIndex: s.projectIndex,
                contextSummary: s.contextSummary, meetingRecorder: s.meetingRecorder, meetingStore: s.meetingStore,
                contextGraph: s.contextGraph, macros: s.macros, profiles: s.profiles, searchEngine: s.search,
                nicheVocab: s.nicheVocab, commandRouter: s.commandRouter, hud: s.hud, router: s.router,
                onRetryHotKey: { true })
            // Borderless host: NO titlebar/toolbar, so the real 52pt top inset (measure.txt) is absent in PNGs.
            let host = NSHostingView(rootView: root
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            for _ in 0..<12 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("\(name)-\(scheme).png"))
            window.orderOut(nil)
            window.close()
        }
        _ = measure
    }

    /// Real titled-window measurement (no image): toolbar / safe-area numbers.
    private func measureReal(_ s: Stores, tab: SettingsTab, label: String) {
        s.router.selectedTab = tab
        let (w, hc) = makeWindow(s, size: NSSize(width: 1100, height: 720), appearance: NSAppearance(named: .aqua)!)
        w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        w.orderBack(nil)
        for _ in 0..<6 { hc.view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        measureWindow(w, hc, label: label)
        w.orderOut(nil); w.close()
    }

    private func measureWindow(_ w: NSWindow, _ hc: NSHostingController<MainView>, label: String) {
        let cv = w.contentView!
        log.append("[\(label)] window.frame=\(w.frame.size) contentView.frame=\(cv.frame) contentLayoutRect=\(w.contentLayoutRect)")
        log.append("[\(label)] contentView.safeAreaInsets=\(cv.safeAreaInsets) hostingView.safeAreaInsets=\(hc.view.safeAreaInsets)")
        log.append("[\(label)] toolbar=\(String(describing: w.toolbar)) items=\(w.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []) style=\(w.toolbarStyle.rawValue) visible=\(w.toolbar?.isVisible ?? false)")
        log.append("[\(label)] titlebar height (frame - contentLayoutRect) = \(w.frame.height - w.contentLayoutRect.height)")
        if let frame = cv.superview {
            func walk(_ v: NSView, _ d: Int) {
                let n = String(describing: type(of: v))
                if d <= 3 || n.lowercased().contains("toolbar") || n.lowercased().contains("titlebar") {
                    log.append("[\(label)] \(String(repeating: "  ", count: d))\(n) frame=\(v.frame)")
                }
                if d < 4 { v.subviews.forEach { walk($0, d + 1) } }
            }
            walk(frame, 0)
        }
    }

    func testRenderAllPages() throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_UI_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_UI_SNAPSHOT_DIR")
        }
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try Stores()
        defer { try? FileManager.default.removeItem(at: s.tmp) }
        seed(s)
        s.meetingRecorder.markSummarizingForTesting(s.meetingStore.meetings[0].id)
        measureReal(s, tab: .dashboard, label: "dashboard")
        measureReal(s, tab: .meetings, label: "meetings")
        let tabs: [(SettingsTab, String)] = [(.dashboard, "dashboard"), (.memory, "memory"), (.meetings, "meetings"),
                                             (.dictionary, "dictionary"), (.commands, "commands"),
                                             (.vibeCoding, "vibecoding"), (.general, "settings-index")]
        for (tab, name) in tabs {
            try capture(s, name: name, dir: dir, tab: tab, page: nil, measure: false)
        }
        let pages: [(SettingsPage, String)] = [(.dictation, "settings-dictation"), (.cleanupStyle, "settings-cleanup"),
                                               (.languages, "settings-languages"), (.meetings, "settings-meetings"),
                                               (.notesBehavior, "settings-notes"), (.claude, "settings-agent"),
                                               (.privacy, "settings-privacy")]
        for (page, name) in pages {
            try capture(s, name: name, dir: dir, tab: .general, page: page, measure: false)
        }
        try log.joined(separator: "\n").write(to: dir.appendingPathComponent("measure.txt"), atomically: true, encoding: .utf8)
    }
}
