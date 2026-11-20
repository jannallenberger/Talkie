import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in page-speed bench: copies a real Talkie support folder (read-only) into the
/// test sandbox, builds every store from it, hosts the real `MainView` offscreen and
/// times each page switch (graph update + layout + draw) cold and warm, plus the main
/// thread CPU spent in the half second after each switch (onAppear/task work and any
/// running animation). Skipped unless TALKIE_PERF_BENCH_SOURCE points at a support
/// folder. Writes the report to TALKIE_PERF_BENCH_OUT (or prints it).
///
/// Nothing is ever written to the source folder: stores resolve to
/// `AppPaths.testSandboxRoot`, and the copy goes source → sandbox only.
@MainActor
final class PagePerfBenchTests: XCTestCase {
    private var lines: [String] = []

    private func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }

    private func now() -> Double { CFAbsoluteTimeGetCurrent() * 1000 }

    private func copySource(_ src: URL) throws {
        let dst = AppPaths.supportDirectory()
        XCTAssertTrue(dst.path.contains("tk-tests-"), "bench must only ever write into the test sandbox")
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            if name.hasSuffix(".bak") || name.hasSuffix(".corrupt") || name.hasSuffix(".log")
                || name == "diarization-tmp" || name == "inbox" { continue }
            let from = src.appendingPathComponent(name), to = dst.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: from, to: to)
        }
    }

    private func timed<T>(_ label: String, _ make: () throws -> T) rethrows -> T {
        let t0 = now()
        let v = try make()
        lines.append(String(format: "store  %-22@ %7.1f ms", label as NSString, now() - t0))
        return v
    }

    func testPageSwitchTimings() throws {
        guard let srcPath = ProcessInfo.processInfo.environment["TALKIE_PERF_BENCH_SOURCE"], !srcPath.isEmpty else {
            throw XCTSkip("set TALKIE_PERF_BENCH_SOURCE")
        }
        _ = NSApplication.shared
        try copySource(URL(fileURLWithPath: srcPath, isDirectory: true))

        let settings = AppSettings()
        settings.hasOnboarded = true
        let dictionary = timed("DictionaryStore") { DictionaryStore() }
        let permissions = PermissionsModel()
        let history = timed("HistoryStore") { HistoryStore(retentionDays: 0) }
        let stats = timed("StatsStore") { StatsStore() }
        let appUsage = timed("AppUsageStore") { AppUsageStore() }
        let activity = timed("ActivityStore") { ActivityStore() }
        let wordFreq = timed("WordFrequencyStore") { WordFrequencyStore() }
        let jobTitle = JobTitleStore()
        let latency = timed("LatencyStore") { LatencyStore() }
        let pressure = SystemPressure()
        let scratchpad = timed("ScratchpadStore") { ScratchpadStore() }
        let profileImage = ProfileImageStore()
        let autoAdd = AutoAddPreviewLog()
        let projectIndex = timed("ProjectIndexStore") { ProjectIndexStore() }
        let contextSummary = ContextSummaryStore()
        let meetingStore = timed("MeetingStore") { MeetingStore() }
        let meetingRecorder = MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: meetingStore)
        let contextGraph = timed("ContextGraphStore") { ContextGraphStore() }
        let macros = MacroStore()
        let profiles = AppProfileStore()
        let search = timed("SearchEngine") { SearchEngine() }
        let nicheVocab = timed("NicheVocabStore") { NicheVocabStore() }
        let commandRouter = CommandRouter(macros: macros)
        let hud = HUDController()
        let router = SettingsRouter()
        lines.append("data   history=\(history.entries.count) meetings=\(meetingStore.meetings.count) "
                     + "segments=\(meetingStore.meetings.reduce(0) { $0 + ($1.segments?.count ?? 0) }) "
                     + "graphNodes=\(contextGraph.entities.count)")

        let root = MainView(
            settings: settings, dictionary: dictionary, permissions: permissions, history: history,
            stats: stats, appUsage: appUsage, activity: activity, wordFreq: wordFreq,
            jobTitle: jobTitle, latency: latency, systemPressure: pressure, scratchpad: scratchpad,
            profileImage: profileImage, autoAddPreviewLog: autoAdd, projectIndex: projectIndex,
            contextSummary: contextSummary, meetingRecorder: meetingRecorder, meetingStore: meetingStore,
            contextGraph: contextGraph, macros: macros, profiles: profiles, searchEngine: search,
            nicheVocab: nicheVocab, commandRouter: commandRouter, hud: hud, router: router,
            onRetryHotKey: { true })
        let size = NSSize(width: 1100, height: 720)
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }

        func settle(_ seconds: Double) -> Double {
            let c0 = threadCPU()
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            return threadCPU() - c0
        }

        let t0 = now()
        router.selectedTab = .dashboard
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        lines.append(String(format: "first  window + dashboard        %7.1f ms", now() - t0))
        _ = settle(1.0)

        // Profiling aid: TALKIE_PERF_BENCH_LOOP=<tab title> flips between Settings and
        // that page for 12 s so `sample` can attribute the switch cost.
        if let loop = ProcessInfo.processInfo.environment["TALKIE_PERF_BENCH_LOOP"],
           let target = SettingsTab.allCases.first(where: { $0.title == loop }) {
            if ProcessInfo.processInfo.environment["TALKIE_PERF_BENCH_IDLE"] != nil {
                // Land on the page fresh (from Settings), then sit there: the sampler
                // sees the page's whole after-appear transient.
                router.selectedTab = .general
                _ = settle(0.5)
                FileHandle.standardError.write(Data("PERF_LOOP_START pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
                _ = settle(1.0)
                router.selectedTab = target
                _ = settle(8)
                return
            }
            // stderr is unbuffered, so the line reaches a watcher while the loop runs.
            FileHandle.standardError.write(Data("PERF_LOOP_START pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
            let end = Date().addingTimeInterval(12)
            while Date() < end {
                for tab in [target, SettingsTab.general] {
                    router.selectedTab = tab
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    _ = settle(0.05)
                }
            }
            return
        }

        let tabs: [SettingsTab] = [.memory, .meetings, .dictionary, .commands, .vibeCoding, .general, .dashboard]
        for pass in ["cold", "warm"] {
            for tab in tabs {
                let s = now()
                router.selectedTab = tab
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let sync = now() - s
                let after = settle(0.6)
                lines.append(String(format: "%@ %-12@ switch %7.1f ms   +%6.1f ms CPU in next 600 ms",
                                    pass as NSString, tab.title as NSString, sync, after))
            }
        }
        // Idle: whatever page is showing, nothing changes — CPU here is pure churn.
        router.selectedTab = .meetings
        _ = settle(0.5)
        lines.append(String(format: "idle   meetings 2 s                %7.1f ms CPU", settle(2.0)))
        router.selectedTab = .dashboard
        _ = settle(0.5)
        lines.append(String(format: "idle   dashboard 2 s               %7.1f ms CPU", settle(2.0)))

        let report = lines.joined(separator: "\n")
        if let out = ProcessInfo.processInfo.environment["TALKIE_PERF_BENCH_OUT"], !out.isEmpty {
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        print("\n=== page perf bench ===\n\(report)\n")
    }
}

/// Opt-in: idle main-thread CPU of the Dashboard's animated backdrop on its own, in
/// dark mode (the only mode that animates). Skipped unless TALKIE_PERF_BENCH_PARTS is set.
@MainActor
final class BackdropPerfBenchTests: XCTestCase {
    private func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
    }

    private func idleCPU<V: View>(_ view: V, seconds: Double = 2) -> Double {
        let size = NSSize(width: 1100, height: 720)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        func spin(_ s: Double) {
            let end = Date().addingTimeInterval(s)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            }
        }
        spin(0.5)
        let c0 = threadCPU()
        spin(seconds)
        return threadCPU() - c0
    }

    func testBackdropIdleCPU() throws {
        guard ProcessInfo.processInfo.environment["TALKIE_PERF_BENCH_PARTS"] != nil else {
            throw XCTSkip("set TALKIE_PERF_BENCH_PARTS")
        }
        _ = NSApplication.shared
        if ProcessInfo.processInfo.environment["TALKIE_PERF_BENCH_SKELETON_LOOP"] != nil {
            FileHandle.standardError.write(Data("PERF_LOOP_START\n".utf8))
            _ = idleCPU(VStack(spacing: 10) { ForEach(0..<4, id: \.self) { _ in TalkieSkeletonCard() } }.padding(28),
                        seconds: 8)
            return
        }
        var out: [String] = []
        out.append(String(format: "empty canvas      2 s: %7.1f ms CPU", idleCPU(Theme.canvas)))
        out.append(String(format: "TalkieBackdrop    2 s: %7.1f ms CPU", idleCPU(TalkieBackdrop())))
        out.append(String(format: "skeleton group    2 s: %7.1f ms CPU", idleCPU(
            VStack(spacing: 10) { ForEach(0..<4, id: \.self) { _ in TalkieSkeletonCard() } }
                .padding(28))))
        let report = out.joined(separator: "\n")
        if let path = ProcessInfo.processInfo.environment["TALKIE_PERF_BENCH_OUT"], !path.isEmpty {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("\n=== backdrop bench ===\n\(report)\n")
    }
}
