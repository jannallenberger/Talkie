import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// `talkieCalmWhileScrolling` turns hit testing off for a scroll view's content while
/// it moves. Scroll-wheel events are routed by hit testing too, so this checks the
/// part that matters: trackpad gesture events sent through the WINDOW (routed by hit
/// testing, as AppKit routes a real one) keep scrolling the page while the content is
/// calm, and a second gesture right after still scrolls.
///
/// Momentum is not asserted: AppKit does not apply synthesized momentum events in a
/// test process, with or without the calm modifier (checked both ways).
@MainActor
final class CalmScrollTests: XCTestCase {
    private struct Page: View {
        var body: some View {
            TalkieScrollPage {
                ForEach(0..<300, id: \.self) { i in
                    HStack {
                        Text(verbatim: "Row \(i)")
                        Spacer()
                        Button("Copy") {}.buttonStyle(.talkie(.quiet, size: .small))
                    }
                    .talkieRowCard(padding: 14)
                }
            }
        }
    }

    private func scrollView(in root: NSView) -> NSScrollView? {
        if let sv = root as? NSScrollView, (sv.documentView?.frame.height ?? 0) > sv.contentView.bounds.height { return sv }
        for sub in root.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    func testAGestureThroughTheWindowScrollsTheWholeWay() throws {
        _ = NSApplication.shared
        let size = NSSize(width: 700, height: 600)
        let host = NSHostingView(rootView: Page().frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // At the screen origin, a window-less event's location (screen coordinates)
        // is also its location in this window, so the window's hit test finds the page.
        window.setFrameOrigin(.zero)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        func pump(_ s: Double) {
            let end = Date().addingTimeInterval(s)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.008))
                host.layoutSubtreeIfNeeded()
            }
        }
        pump(0.5)
        let sv = try XCTUnwrap(scrollView(in: host))
        // Start mid-page, so the test holds whichever way a negative delta scrolls.
        let docHeight = sv.documentView?.frame.height ?? 0
        sv.contentView.scroll(to: NSPoint(x: 0, y: docHeight / 2))
        sv.reflectScrolledClipView(sv.contentView)
        pump(0.3)
        let inWindow = sv.convert(NSPoint(x: sv.bounds.midX, y: sv.bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: onScreen.x, y: screenHeight - onScreen.y)

        func send(_ dy: Int32, phase: Int64, momentum: Int64) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: dy, wheel2: 0, wheel3: 0) else { return }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            cg.location = cgPoint
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            guard let ev = NSEvent(cgEvent: cg) else { return }
            window.sendEvent(ev)
            pump(0.012)
        }
        func gesture() -> (start: CGFloat, midGesture: CGFloat, end: CGFloat) {
            let start = sv.contentView.bounds.origin.y
            send(0, phase: 1, momentum: 0)
            for _ in 0..<6 { send(-60, phase: 2, momentum: 0) }
            let mid = sv.contentView.bounds.origin.y
            send(0, phase: 4, momentum: 0)
            var v = 120.0
            send(-Int32(v), phase: 0, momentum: 1)
            while v > 3 { v *= 0.9; send(-Int32(v), phase: 0, momentum: 2) }
            send(0, phase: 0, momentum: 3)
            pump(0.3)
            return (start, mid, sv.contentView.bounds.origin.y)
        }

        let first = gesture()
        XCTAssertGreaterThan(abs(first.midGesture - first.start), 200,
                             "the gesture keeps scrolling after its first event made the content calm")
        let second = gesture()
        XCTAssertGreaterThan(abs(second.midGesture - second.start), 200, "a second gesture right after still scrolls")
    }
}
