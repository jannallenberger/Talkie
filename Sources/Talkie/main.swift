import AppKit

NSLog("Talkie: launching (pid \(ProcessInfo.processInfo.processIdentifier))")

// Single-instance: if another Talkie is already running, hand off to it and exit.
// (Duplicate copies with the same bundle id otherwise confuse LaunchServices and
// you get "sometimes it doesn't open".)
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0 != NSRunningApplication.current }
    if let existing = others.first {
        NSLog("Talkie: another instance already running (pid \(existing.processIdentifier)); exiting")
        existing.activate()
        exit(0)
    }
}

// Talkie is a regular Dock app (with a menu-bar status item too).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
