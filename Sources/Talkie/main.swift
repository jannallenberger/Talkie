import AppKit

NSLog("Talkie: launching (pid \(ProcessInfo.processInfo.processIdentifier))")

// CLI seam (feature I6): `Talkie doctor` prints the privacy self-check as a
// pasteable markdown receipt and exits, launching no UI. This MUST run BEFORE the
// single-instance handoff below — otherwise, when another Talkie is already
// running, the handoff would activate that instance and exit(0) here, and the
// doctor invocation would silently focus the app instead of printing.
//
// `includeTCC: false`: permission answers from a terminal-spawned process are
// attributed by macOS to the terminal, not to Talkie, so the report omits live
// TCC state on the CLI and points at the in-app pane instead (the in-app "Copy
// diagnostic report" button passes `includeTCC: true`).
if CommandLine.arguments.dropFirst().first == "doctor" {
    print(DoctorReport.generate(includeTCC: false))
    exit(0)
}

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
