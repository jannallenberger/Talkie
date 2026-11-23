import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in stress test for the "fast scroll freezes the window" bug: copies a real
/// Talkie support folder (read-only) into the test sandbox, hosts the real `MainView`
/// in an on-screen window, and flings the biggest scroll view of the long pages
/// (Memory feed, a long meeting's transcript, the meeting list, Dictionary) as a
/// trackpad flick would: big jumps, reversals, top/bottom slams, with only a frame's
/// worth of run loop between them.
///
/// A watchdog thread samples the process and exits if the main thread stops ticking,
/// so a livelock shows up as a failed run with a `sample` report, not a stuck test.
///
/// TALKIE_SCROLL_STRESS_SOURCE=<support folder> [TALKIE_SCROLL_STRESS_OUT=<dir>]
/// [TALKIE_SCROLL_STRESS_PAGES=memory,meeting,meetinglist,dictionary] [TALKIE_SCROLL_STRESS_STEPS=400]
@MainActor
final class ScrollStressTests: XCTestCase {
    /// The main thread's last tick (ms since reference date), read by the watchdog.
    nonisolated(unsafe) private static var heartbeat: Double = 0
    nonisolated(unsafe) private static var phase = "setup"

    private func now() -> Double { CFAbsoluteTimeGetCurrent() * 1000 }

    private func copySource(_ src: URL) throws {
        let dst = AppPaths.supportDirectory()
        XCTAssertTrue(dst.path.contains("tk-tests-"), "stress test must only ever write into the test sandbox")
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            if name.hasSuffix(".bak") || name.hasSuffix(".corrupt") || name.hasSuffix(".log")
                || name == "diarization-tmp" || name == "inbox" { continue }
            let from = src.appendingPathComponent(name), to = dst.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: from, to: to)
        }
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Samples the process and exits when the main thread has not ticked for `limit` s.
    private static func startWatchdog(outDir: URL, limit: Double = 10) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let last = heartbeat
                guard last > 0 else { continue }
                let stalled = CFAbsoluteTimeGetCurrent() * 1000 - last
                if stalled > limit * 1000 {
                    let out = outDir.appendingPathComponent("hang-sample.txt").path
                    FileHandle.standardError.write(Data("SCROLL_STRESS_HANG phase=\(phase) stalled=\(Int(stalled)) ms — sampling to \(out)\n".utf8))
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    p.arguments = [String(pid), "4", "-file", out]
                    try? p.run()
                    p.waitUntilExit()
                    exit(3)
                }
            }
        }
        thread.start()
    }

    private static func biggestScrollView(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var bestScore: CGFloat = 0
        func walk(_ v: NSView) {
            if let sv = v as? NSScrollView, let doc = sv.documentView {
                let overflow = doc.frame.height - sv.contentView.bounds.height
                if overflow > 0, sv.frame.width * max(overflow, 1) > bestScore {
                    best = sv; bestScore = sv.frame.width * max(overflow, 1)
                }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    func testFastScrollDoesNotFreeze() throws {
        let env = ProcessInfo.processInfo.environment
        guard let srcPath = env["TALKIE_SCROLL_STRESS_SOURCE"], !srcPath.isEmpty else {
            throw XCTSkip("set TALKIE_SCROLL_STRESS_SOURCE")
        }
        let outDir = URL(fileURLWithPath: env["TALKIE_SCROLL_STRESS_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try copySource(URL(fileURLWithPath: srcPath, isDirectory: true))

        if let g = env["TALKIE_SCROLL_STRESS_GLASS"].flatMap(TalkieGlassStyle.init) {
            AppearanceStore.shared.update { $0.glass = g }
        }
        let settings = AppSettings()
        settings.hasOnboarded = true
        let history = HistoryStore(retentionDays: 0)
        let meetingStore = MeetingStore()
        let router = SettingsRouter()
        let root = MainView(
            settings: settings, dictionary: DictionaryStore(), permissions: PermissionsModel(), history: history,
            stats: StatsStore(), appUsage: AppUsageStore(), activity: ActivityStore(), wordFreq: WordFrequencyStore(),
            jobTitle: JobTitleStore(), latency: LatencyStore(), systemPressure: SystemPressure(),
            scratchpad: ScratchpadStore(), profileImage: ProfileImageStore(), autoAddPreviewLog: AutoAddPreviewLog(),
            projectIndex: ProjectIndexStore(), contextSummary: ContextSummaryStore(),
            meetingRecorder: MeetingRecorder(engine: TranscriptionEngine(localeIdentifier: "en-US"), store: meetingStore),
            meetingStore: meetingStore, contextGraph: ContextGraphStore(), macros: MacroStore(),
            profiles: AppProfileStore(), searchEngine: SearchEngine(), nicheVocab: NicheVocabStore(),
            commandRouter: CommandRouter(macros: MacroStore()), hud: HUDController(), router: router,
            onRetryHotKey: { true })

        let size = NSSize(width: 1100, height: 720)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }

        Self.heartbeat = now()
        Self.startWatchdog(outDir: outDir)
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                Self.heartbeat = now()
                autoreleasepool {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.004))
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                }
            } while Date() < end
            Self.heartbeat = now()
        }

        var report: [String] = [
            "data history=\(history.entries.count) meetings=\(meetingStore.meetings.count) "
            + "longest=\(meetingStore.meetings.map { $0.segments?.count ?? 0 }.max() ?? 0) segments"]
        let wanted = Set((env["TALKIE_SCROLL_STRESS_PAGES"] ?? "memory,meeting,meetinglist,dictionary")
            .split(separator: ",").map(String.init))
        let steps = Int(env["TALKIE_SCROLL_STRESS_STEPS"] ?? "") ?? 400
        var worstOverall = 0.0

        // The Meetings page opens on the newest meeting.
        let newest = meetingStore.meetings.max { $0.date < $1.date }
        report.append("newest meeting: \(newest?.segments?.count ?? 0) segments, \(newest?.transcript.count ?? 0) chars")
        let pages: [(String, SettingsTab, () -> Void)] = [
            ("memory", .memory, {}),
            ("meeting", .meetings, {}),
            ("meetinglist", .meetings, {}),
            ("dictionary", .dictionary, {}),
        ]
        for (name, tab, prepare) in pages where wanted.contains(name) {
            Self.phase = "\(name): open"
            prepare()
            router.selectedTab = .general
            pump(0.4)
            router.selectedTab = tab
            pump(1.5)
            // The meeting detail is the right-hand (wider) pane; the list is the narrow one.
            var target: NSScrollView?
            if name == "meetinglist" {
                var narrow: NSScrollView?
                func walk(_ v: NSView) {
                    if let sv = v as? NSScrollView, (sv.documentView?.frame.height ?? 0) > sv.contentView.bounds.height,
                       sv.frame.width < 400 { narrow = sv }
                    v.subviews.forEach(walk)
                }
                walk(host)
                target = narrow
            } else {
                target = Self.biggestScrollView(in: host)
            }
            guard let sv = target, let doc = sv.documentView else {
                report.append("\(name): no scroll view with overflow — skipped")
                continue
            }
            let mem0 = Self.footprintMB()
            var worst = 0.0, total = 0.0
            var rng = SystemRandomNumberGenerator()
            if env["TALKIE_SCROLL_STRESS_MODE"] == "events" {
                // Real scroll-wheel events, shaped like trackpad flicks: a gesture
                // (began → changed… → ended) and then its momentum tail, one event per
                // 120 Hz frame — with the pointer parked over the list, so every row
                // sliding under it gets a hover update, as it does in real use.
                let mid = sv.convert(NSPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: nil)
                if let move = NSEvent.mouseEvent(with: .mouseMoved, location: mid, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 0, pressure: 0) {
                    window.sendEvent(move)
                }
                func send(_ dy: Int32, phase: Int64, momentum: Int64) -> Double {
                    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                           wheel1: dy, wheel2: 0, wheel3: 0) else { return 0 }
                    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                    guard let ev = NSEvent(cgEvent: cg) else { return 0 }
                    let t0 = now()
                    autoreleasepool {
                        sv.scrollWheel(with: ev)
                        Self.heartbeat = now()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.008))
                        host.layoutSubtreeIfNeeded()
                        host.displayIfNeeded()
                    }
                    Self.heartbeat = now()
                    return now() - t0
                }
                for step in 0..<steps {
                    Self.phase = "\(name): flick \(step)"
                    let dir: Int32 = (step / 3) % 2 == 0 ? -1 : 1   // three flicks down, three up
                    let speed = Int32.random(in: 60...220, using: &rng)
                    var dts: [Double] = []
                    dts.append(send(0, phase: 1, momentum: 0))
                    for _ in 0..<5 { dts.append(send(dir * speed, phase: 2, momentum: 0)) }
                    dts.append(send(0, phase: 4, momentum: 0))
                    var v = Double(speed) * 2.2
                    dts.append(send(dir * Int32(v), phase: 0, momentum: 1))
                    while v > 2 {
                        v *= 0.92
                        dts.append(send(dir * Int32(v), phase: 0, momentum: 2))
                    }
                    dts.append(send(0, phase: 0, momentum: 3))
                    worst = max(worst, dts.max() ?? 0); total += dts.reduce(0, +)
                }
                pump(1.0)
                let mem1 = Self.footprintMB()
                worstOverall = max(worstOverall, worst)
                report.append(String(format: "%@: %d event flicks, doc %.0f pt, avg %.1f ms/flick, worst frame %.1f ms, footprint %.0f → %.0f MB",
                                     name as NSString, steps, doc.frame.height, total / Double(steps), worst, mem0, mem1))
                continue
            }
            for step in 0..<steps {
                Self.phase = "\(name): step \(step)"
                let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
                let y: CGFloat
                switch step % 8 {
                case 0: y = 0
                case 1: y = maxY
                case 2, 3: y = CGFloat.random(in: 0...max(1, maxY), using: &rng)
                default:
                    // Flick: a large delta from where it is, either way.
                    let delta = CGFloat.random(in: 900...4_000, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                    y = min(maxY, max(0, sv.contentView.bounds.origin.y + delta))
                }
                let t0 = now()
                // One pool per step, as the app's run loop drains one per event —
                // without it the footprint counts every frame's autoreleased objects.
                autoreleasepool {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                    sv.reflectScrolledClipView(sv.contentView)
                    Self.heartbeat = now()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.008))
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                }
                let dt = now() - t0
                Self.heartbeat = now()
                worst = max(worst, dt); total += dt
            }
            pump(1.0)
            let mem1 = Self.footprintMB()
            worstOverall = max(worstOverall, worst)
            report.append(String(format: "%@: %d flicks, doc %.0f pt, avg %.1f ms, worst %.1f ms, footprint %.0f → %.0f MB",
                                 name as NSString, steps, doc.frame.height, total / Double(steps), worst, mem0, mem1))
        }
        Self.heartbeat = 0
        let text = report.joined(separator: "\n")
        try text.write(to: outDir.appendingPathComponent("scroll-stress.txt"), atomically: true, encoding: .utf8)
        print("\n=== scroll stress ===\n\(text)\n")
        XCTAssertLessThan(worstOverall, 2_000, "one scroll step blocked the main thread for over 2 s")
    }
}
