import Foundation
import AppKit

/// Swaps the running Talkie.app bundle for a freshly downloaded one and relaunches.
///
/// The heavy work (unzip, validate, de-quarantine) runs off the main actor; the
/// actual bundle swap is handed to a small detached shell script that waits for
/// this process to exit, replaces the bundle, and re-opens it — the same
/// quit→replace→open dance `scripts/run.sh` does, and the relaunch pattern the
/// Permissions pane already uses.
enum UpdateInstaller {
    /// Validates and stages the new app, spawns the swap script, then terminates
    /// this instance. Throws on any failure BEFORE the swap is committed; on
    /// success it does not return normally (the app quits).
    static func installAndRelaunch(zip: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try performInstall(zip: zip)
        }.value
        await MainActor.run { NSApp.terminate(nil) }
    }

    private static func performInstall(zip: URL) throws {
        let fm = FileManager.default
        let staging = UpdaterPaths.updatesDir().appendingPathComponent("staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // Unzip with ditto — it handles macOS archives and preserves the code
        // signature + resource forks (a plain unzip can corrupt the signature).
        let unzip = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        guard unzip.ok else { throw UpdaterError.installFailed("unzip failed: \(unzip.err)") }

        guard let newApp = findApp(in: staging) else {
            throw UpdaterError.badArtifact("no .app inside the downloaded archive")
        }

        // Validate it's really Talkie before we replace ourselves with it.
        let exe = newApp.appendingPathComponent("Contents/MacOS/Talkie")
        guard fm.isExecutableFile(atPath: exe.path) else {
            throw UpdaterError.badArtifact("missing Talkie executable")
        }
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleIdentifier"] as? String) == "com.coralate.talkie" else {
            throw UpdaterError.badArtifact("not Talkie (unexpected bundle identifier)")
        }

        // Strip quarantine so Gatekeeper doesn't block the swapped-in app on the
        // recipient's Mac (it trusts the publisher; the download is the trust hop).
        _ = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        try spawnSwap(newApp: newApp, dest: Bundle.main.bundleURL)
    }

    /// Prefer a top-level `*.app`; otherwise take the first one a level down.
    private static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        let direct = dir.appendingPathComponent("Talkie.app")
        if fm.fileExists(atPath: direct.path) { return direct }
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.pathExtension == "app" }
    }

    private static func spawnSwap(newApp: URL, dest: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let script = """
        #!/bin/sh
        # Wait for the old Talkie to exit, swap the bundle, re-register, relaunch.
        PID=\(pid)
        SRC=\(shQuote(newApp.path))
        DEST=\(shQuote(dest.path))
        LSREGISTER=\(shQuote(lsregister))
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2
          i=$((i + 1))
          [ "$i" -gt 150 ] && break
        done
        rm -rf "$DEST.tmp-update"
        /usr/bin/ditto "$SRC" "$DEST.tmp-update" || exit 1
        rm -rf "$DEST"
        mv "$DEST.tmp-update" "$DEST"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEST" 2>/dev/null
        sleep 0.3
        /usr/bin/open "$DEST"
        """
        let scriptURL = UpdaterPaths.updatesDir().appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path]
        try p.run()  // detached: we do NOT wait — it outlives this process
    }

    /// Single-quote a path for safe interpolation into the /bin/sh script.
    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
