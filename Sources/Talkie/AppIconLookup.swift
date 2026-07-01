import AppKit

/// Looks up an app's real icon by bundle identifier — works even when the app
/// isn't currently running, unlike a `NSWorkspace.runningApplications` scan
/// (which only finds apps live right now). Resolves the installed app's URL
/// via LaunchServices and reads its icon directly. Returns `nil` when the
/// bundle ID can't be resolved — a stale/uninstalled app, or (for callers
/// backed by `AppUsage`/`DictationEntry`) a value that was never a real
/// bundle ID to begin with, since older records key on the app's display
/// *name* when no bundle ID was captured at the time. Callers show a generic
/// SF Symbol in that case; this never fabricates a placeholder icon itself.
///
/// Cached per bundle ID — the underlying LaunchServices lookup isn't free,
/// and this gets called once per row in lists (Dashboard's "Where your words
/// go", Memory's dictation feed) that can have many rows.
@MainActor
enum AppIconLookup {
    private static var cache: [String: NSImage?] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = resolved
        return resolved
    }
}
