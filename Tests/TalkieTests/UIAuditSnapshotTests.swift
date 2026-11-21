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
        // Real-window shots only: a lived-in dashboard (apps, speed, scratchpad).
        guard ProcessInfo.processInfo.environment["TALKIE_REAL_SHOT_DIR"] != nil else { return }
        let apps: [(String, String, AppCategory, Int)] = [
            ("com.apple.Notes", "Notes", .notes, 5200), ("com.apple.mail", "Mail", .mail, 3100),
            ("com.tinyspeck.slackmacgap", "Slack", .chat, 2300), ("com.apple.dt.Xcode", "Xcode", .coding, 1400),
            ("com.apple.Safari", "Safari", .browser, 800), ("com.apple.Terminal", "Terminal", .terminal, 300),
        ]
        for a in apps { s.appUsage.record(target: TargetApp(bundleID: a.0, name: a.1, category: a.2), words: a.3) }
        for i in 0..<12 {
            s.latency.record(totalMs: 380 + Double(i * 9), finalizeMs: 120, reTxMs: 0, cleanupMs: 200, insertMs: 40,
                             chars: 180, streamed: false, optimistic: false, coldStart: false, mode: "paste", outcome: "inserted")
        }
        if s.scratchpad.lines.isEmpty {
            for line in ["- Send the revised budget to Dana", "- Book the room for Thursday", "Idea: a weekly digest of decisions",
                         "- Reply to the hiring thread"] { s.scratchpad.addLine(line) }
        }
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
        // Mirrors MainWindowController.init (SettingsView.swift); MainView itself hides the toolbar.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = Brand.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
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
                if n.contains("Split") || n.contains("Hosting") {
                    log.append("[\(label)] split/host d\(d) \(n) frame=\(v.frame)")
                }
                if d < 9 { v.subviews.forEach { walk($0, d + 1) } }
            }
            walk(frame, 0)
        }
    }

    /// Opt-in REAL-window shots (Liquid Glass and materials only composite in a window
    /// the window server draws; `cacheDisplay` shows them flat). Puts the real titled
    /// window behind everything on screen and grabs it with `screencapture -l`.
    /// TALKIE_REAL_SHOT_DIR=<dir> [TALKIE_REAL_SHOT_TABS=dashboard,meetings,…]
    /// [TALKIE_REAL_SHOT_SCHEMES=light,dark] [TALKIE_LOOK=backdrop:glass:accent:intensity:angle]
    func testRealWindowShots() throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_REAL_SHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_REAL_SHOT_DIR")
        }
        let env = ProcessInfo.processInfo.environment
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try Stores()
        defer { try? FileManager.default.removeItem(at: s.tmp) }
        seed(s)
        if let look = env["TALKIE_LOOK"]?.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
            AppearanceStore.shared.update { l in
                if look.count > 0, let v = TalkieBackdropStyle(rawValue: look[0]) { l.backdrop = v }
                if look.count > 1, let v = TalkieGlassStyle(rawValue: look[1]) { l.glass = v }
                if look.count > 2, let v = TalkieAccent(rawValue: look[2]) { l.accent = v }
                if look.count > 3, let v = Double(look[3]) { l.intensity = v }
                if look.count > 4, let v = Double(look[4]) { l.angle = v }
            }
        }
        let all: [(String, SettingsTab, SettingsPage?)] = [
            ("dashboard", .dashboard, nil), ("memory", .memory, nil), ("meetings", .meetings, nil),
            ("dictionary", .dictionary, nil), ("commands", .commands, nil), ("vibecoding", .vibeCoding, nil),
            ("settings-index", .general, nil), ("settings-dictation", .general, .dictation),
            ("settings-cleanup", .general, .cleanupStyle), ("settings-languages", .general, .languages),
            ("settings-meetings", .general, .meetings), ("settings-notes", .general, .notesBehavior),
            ("settings-privacy", .general, .privacy), ("settings-appearance", .general, .appearance),
            ("onboarding", .dashboard, nil),
        ]
        if let photo = env["TALKIE_REAL_SHOT_PHOTO"] { _ = s.profileImage.setImage(fromFile: URL(fileURLWithPath: photo)) }
        defer { s.profileImage.clear() }
        let wanted = env["TALKIE_REAL_SHOT_TABS"].map { Set($0.split(separator: ",").map(String.init)) }
        let schemes = (env["TALKIE_REAL_SHOT_SCHEMES"] ?? "light,dark").split(separator: ",").map(String.init)
        let scroll = env["TALKIE_REAL_SHOT_SCROLL"].flatMap(Double.init) ?? 0
        for (name, tab, page) in all where wanted?.contains(name) ?? true {
            for scheme in schemes {
                s.settings.hasOnboarded = name != "onboarding"
                defer { s.settings.hasOnboarded = true }
                s.router.selectedTab = tab
                s.router.pendingPage = page
                let appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)!
                let (window, hc) = makeWindow(s, size: NSSize(width: 1100, height: 720), appearance: appearance)
                window.setFrameOrigin(NSPoint(x: 40, y: 40))
                window.orderBack(nil)
                for _ in 0..<10 { hc.view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
                if scroll > 0 { Self.scrollFirstScrollView(in: hc.view, by: scroll) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let out = dir.appendingPathComponent("\(name)-\(scheme).png")
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", String(window.windowNumber), out.path]
                try task.run()
                task.waitUntilExit()
                log.append("[\(name)-\(scheme)] screencapture exit=\(task.terminationStatus)")
                window.orderOut(nil); window.close()
            }
        }
        try log.joined(separator: "\n").write(to: dir.appendingPathComponent("shots.txt"), atomically: true, encoding: .utf8)
    }

    /// Scrolls the tallest scroll view under `root` down by `points` (for the edge fades).
    private static func scrollFirstScrollView(in root: NSView, by points: Double) {
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let sv = v as? NSScrollView, sv.frame.height > (best?.frame.height ?? 0),
               (sv.documentView?.frame.height ?? 0) > sv.frame.height { best = sv }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let sv = best else { return }
        sv.contentView.scroll(to: NSPoint(x: 0, y: points))
        sv.reflectScrolledClipView(sv.contentView)
    }

    /// Opt-in REAL-window shot of the small meeting-notes window, mid-recording and idle.
    func testRealNotesWindowShots() throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_REAL_SHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_REAL_SHOT_DIR")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try Stores()
        defer { try? FileManager.default.removeItem(at: s.tmp) }
        seed(s)
        let subtopic = MeetingSubtopicModel()
        let tab = ProcessInfo.processInfo.environment["TALKIE_NOTES_TAB"] ?? "soFar"
        UserDefaults.standard.set(tab, forKey: "meetingNotesWindowContextTab")
        for state in ["idle", "recording"] {
            if state == "recording" {
                s.meetingRecorder.stageRecordingForTesting(
                    elapsed: 14 * 60 + 7, farEnd: true,
                    notes: "Pricing page goes live on the 3rd\n[09:12] Ask Dana about the migration window\nBudget: keep the pilot under 40k")
                subtopic.current = "Launch timeline"
                subtopic.currentGloss = "Agreeing the launch date and who signs off the pricing page"
                s.meetingRecorder.liveSummary.reset(.listening)
                s.meetingRecorder.liveSummary.update(LiveSummarySnapshot(
                    topics: ["Launch timeline for the pricing page", "Pilot budget and scope"],
                    decisions: ["Pricing page goes live on the 3rd"],
                    actions: ["Dana: confirm the migration window", "Alex: send the pilot budget by Friday"], chunks: 3))
                s.meetingRecorder.liveTail.stageForTesting([
                    .init(elapsed: 801, speaker: .them, text: "So if the pricing page is ready, I would rather not wait for the next sprint."),
                    .init(elapsed: 809, speaker: .me, text: "Agreed. We can go live on the third if legal signs off this week."),
                    .init(elapsed: 822, speaker: .them, text: "I will check the migration window with Dana and come back to you tomorrow."),
                    .init(elapsed: 835, speaker: .me, text: "Good. And the pilot stays under forty thousand, that was the condition."),
                ])
            }
            for scheme in ["light", "dark"] {
                let controller = MeetingNotesWindowController(recorder: s.meetingRecorder, subtopic: subtopic,
                                                              settings: s.settings, onOpenMeetings: {})
                controller.show(automatic: true)
                controller.setAppearanceForTesting(NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)!)
                RunLoop.main.run(until: Date().addingTimeInterval(1.6))
                let out = dir.appendingPathComponent("notes-\(state)-\(tab)-\(scheme).png")
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", String(controller.windowNumberForTesting ?? 0), out.path]
                try task.run()
                task.waitUntilExit()
                controller.close()
            }
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
        if ProcessInfo.processInfo.environment["TALKIE_UI_MEASURE_ONLY"] != nil {
            try log.joined(separator: "\n").write(to: dir.appendingPathComponent("measure.txt"), atomically: true, encoding: .utf8)
            return
        }
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
