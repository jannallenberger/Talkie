import AppKit
import SwiftUI
import XCTest
@testable import Talkie

/// Opt-in REAL-window shots of every onboarding step (the glass card and the
/// backdrop only composite in a window the window server draws).
/// TALKIE_REAL_SHOT_DIR=<dir> [TALKIE_REAL_SHOT_SCHEMES=light,dark] [TALKIE_ONBOARDING_STEPS=0,2,3]
@MainActor
final class OnboardingRealShotTests: XCTestCase {
    func testRealOnboardingShots() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TALKIE_REAL_SHOT_DIR"], !path.isEmpty else { throw XCTSkip("set TALKIE_REAL_SHOT_DIR") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = AppSettings()
        settings.hasOnboarded = false
        defer { settings.hasOnboarded = true }
        let permissions = PermissionsModel()
        // The shipped look (the test process keeps whatever an earlier run set).
        let savedLook = AppearanceStore.shared.look
        AppearanceStore.shared.reset()
        defer { AppearanceStore.shared.update { $0 = savedLook } }
        let steps = env["TALKIE_ONBOARDING_STEPS"].map { $0.split(separator: ",").compactMap { Int($0) } }
            ?? Array(0...OnboardingView.readyStepIndex)
        let schemes = (env["TALKIE_REAL_SHOT_SCHEMES"] ?? "light,dark").split(separator: ",").map(String.init)
        for step in steps {
            for scheme in schemes {
                let size = NSSize(width: 980, height: 760)
                let root = OnboardingView(settings: settings, permissions: permissions, onRetryHotKey: { true },
                                          initialStep: step)
                    .frame(width: size.width, height: size.height)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.backgroundColor = NSColor(name: nil) { a in
                    a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x000000) : NSColor(hex: 0xFFFFFF)
                }
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: root)
                window.setContentSize(size)
                window.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
                window.setFrameOrigin(NSPoint(x: 40, y: 40))
                window.orderBack(nil)
                for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
                let out = dir.appendingPathComponent(String(format: "onboarding-%02d-%@.png", step, scheme))
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", String(window.windowNumber), out.path]
                try task.run()
                task.waitUntilExit()
                window.orderOut(nil); window.close()
            }
        }
    }
}
