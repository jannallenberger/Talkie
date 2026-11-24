import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// The pill grows downward inside a fixed, top-anchored panel. Whatever the panel
/// does not hold is cut off flat by the window edge, so the tallest pill (format
/// line + a full live tail, in Increase Contrast) and its shadow must fit.
@MainActor
final class PillPanelFitTests: XCTestCase {
    private static let longText = "Yes, please. We also need to make a couple of changes that I will list now. "
        + "First of all, we need to make sure that the Commands option when pressing the control key "
        + "is enabled by pressing the key once and disabled by pressing it again, because currently "
        + "there is something like a long press going on that I do not seem to understand."

    /// Lays the real `HUDView` out in a panel-sized host and returns the pill's frame
    /// (top-left coordinates), as the pass-through hosting view sees it.
    private func pillFrame(highContrast: Bool, events: [PillFormatState.Event],
                           text: String, volatile: String) -> CGRect {
        let model = HUDModel()
        model.highContrast = highContrast
        model.phase = .listening
        model.levels = (0..<HUDModel.barCount).map { i in CGFloat(0.25 + 0.6 * abs(sin(Double(i) * 0.7))) }
        model.text = text
        model.volatileText = volatile
        for e in events { model.formatState.handle(e) }
        let box = PillFrameBox()
        let host = NSHostingView(rootView: HUDView(model: model, pillFrame: box))
        host.frame = NSRect(origin: .zero, size: HUDController.panelSize)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return box.rect
    }

    private func assertFits(_ rect: CGRect, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(rect.isNull, "\(label): the pill never laid out", file: file, line: line)
        let panel = HUDController.panelSize
        let needed = rect.maxY + HUDController.pillShadowReach
        XCTAssertLessThanOrEqual(needed, panel.height,
                                 "\(label): pill bottom \(rect.maxY) + shadow needs \(needed) pt, panel is \(panel.height)",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(rect.width + 2 * HUDController.pillShadowReach, panel.width + 0.5,
                                 "\(label): pill and shadow wider than the panel", file: file, line: line)
    }

    /// The tallest state the pill has: a format active (its status line under the
    /// waveform) and more live text than the tail holds, in normal and high contrast.
    func testTallestPillFitsThePanel() {
        let active: [PillFormatState.Event] = [.resolved(.format("Bullet list")), .flashExpired]
        for hc in [false, true] {
            let rect = pillFrame(highContrast: hc, events: active, text: Self.longText, volatile: "The newest words are here")
            assertFits(rect, "format + full tail, highContrast=\(hc)")
        }
    }

    /// The bullet list the format key produces: chip plus four list lines (the case
    /// that showed the bottom of the pill cut off in the app).
    func testFormatListPillFitsThePanel() {
        let active: [PillFormatState.Event] = [.resolved(.format("Bullet list")), .flashExpired]
        let rect = pillFrame(highContrast: false, events: active, text: "I need\n- Milk\n- Eggs", volatile: "\n- Fresh bread")
        assertFits(rect, "format list, four lines")
    }

    /// Listening for a command (status line + blue words) with a full tail.
    func testListeningForFormatPillFitsThePanel() {
        let rect = pillFrame(highContrast: true, events: [.keyDown], text: Self.longText, volatile: "bullet list")
        assertFits(rect, "listening for a format + full tail")
    }

    /// Opt-in REAL-window shot of the pill's panel in its tallest everyday state (a
    /// bullet list with the format line), so the bottom edge can be checked by eye.
    /// TALKIE_REAL_SHOT_DIR=<dir> swift test --filter PillPanelFitTests/testRealTallPillShot
    func testRealTallPillShot() throws {
        guard let path = ProcessInfo.processInfo.environment["TALKIE_REAL_SHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("set TALKIE_REAL_SHOT_DIR")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hud = HUDController()
        hud.showArming()
        hud.setFormatKeyName("⌃")
        hud.showListening()
        hud.formatEvent(.resolved(.format("Bullet list")))
        hud.updateTranscribing(finalized: "I need\n- Milk\n- Eggs", volatile: "\n- Fresh bread")
        let start = Date()
        while Date().timeIntervalSince(start) < 2.0 {   // past the 1.4 s confirm flash
            hud.updateLevel(Float.random(in: 0.2...0.8))
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 30))
        }
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is NSPanel && $0.isVisible && $0.frame.width == HUDController.panelSize.width })
        let out = dir.appendingPathComponent("pill-tall-\(Int(HUDController.panelSize.height)).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(panel.windowNumber), out.path]
        try task.run()
        task.waitUntilExit()
        hud.hide(after: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(task.terminationStatus, 0)
    }
}
