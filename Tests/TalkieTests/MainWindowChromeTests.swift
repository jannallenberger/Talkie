import AppKit
import XCTest
@testable import Talkie

final class MainWindowChromeTests: XCTestCase {
    func testWindowedIsTheApprovedConfiguration() {
        let w = MainWindowChrome.settings(fullScreen: false)
        XCTAssertEqual(w.toolbarStyle, .unified)
        XCTAssertTrue(w.titlebarAppearsTransparent)
        XCTAssertEqual(w.sidebarTopInset, 0)
        XCTAssertEqual(w, MainWindowChrome.windowed)
    }

    func testFullScreenIsThinOpaqueTitlebarWithSidebarInset() {
        let f = MainWindowChrome.settings(fullScreen: true)
        XCTAssertEqual(f.toolbarStyle, .unifiedCompact)
        XCTAssertFalse(f.titlebarAppearsTransparent)
        XCTAssertEqual(f.sidebarTopInset, MainWindowChrome.compactTitlebarHeight)
        XCTAssertGreaterThan(f.sidebarTopInset, 0)
    }

    @MainActor
    func testEnterThenExitRestoresWindowedValuesExactly() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "chrome-test")
        let router = SettingsRouter()
        MainWindowChrome.windowed.apply(to: window, router: router)
        let before = (window.toolbarStyle, window.titlebarAppearsTransparent, router.sidebarTopInset)

        MainWindowChrome.settings(fullScreen: true).apply(to: window, router: router)
        XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(router.sidebarTopInset, MainWindowChrome.compactTitlebarHeight)
        XCTAssertNotNil(window.toolbar, "the toolbar is never removed")

        MainWindowChrome.settings(fullScreen: false).apply(to: window, router: router)
        XCTAssertEqual(window.toolbarStyle, before.0)
        XCTAssertEqual(window.titlebarAppearsTransparent, before.1)
        XCTAssertEqual(router.sidebarTopInset, before.2)
        XCTAssertNotNil(window.toolbar)
    }
}
