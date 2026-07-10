import Foundation
import AppKit
import CryptoKit

/// Swaps the running Talkie.app bundle for a freshly downloaded one and relaunches.
///
/// The heavy work (verify, unzip, validate, de-quarantine) runs off the main
/// actor; the actual bundle swap is handed to a small detached shell script that
/// waits for this process to exit, replaces the bundle, and re-opens it — the same
/// quit→replace→open dance `scripts/run.sh` does, and the relaunch pattern the
/// Permissions pane already uses.
enum UpdateInstaller {
    /// Validates and stages the new app, spawns the swap script, then terminates
    /// this instance. Throws on any failure BEFORE the swap is committed; on
    /// success it does not return normally (the app quits).
    ///
    /// `expectedSize` (the GitHub asset's byte size, always populated) and
    /// `expectedSHA256` (the publisher-supplied zip digest, nil for older
    /// releases) gate the install BEFORE we ever de-quarantine and run the new
    /// code — defense-in-depth against a swapped or truncated download.
    static func installAndRelaunch(
        zip: URL,
        expectedSize: Int,
        expectedSHA256: String?
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try performInstall(zip: zip, expectedSize: expectedSize, expectedSHA256: expectedSHA256)
        }.value
        await MainActor.run { NSApp.terminate(nil) }
    }

    /// Verifies the downloaded zip's size and (when published) SHA-256 against the
    /// release metadata. Pure and synchronous so it is unit-testable in isolation.
    ///
    /// - Size is enforced ALWAYS (fail-closed): the asset size is free from the
    ///   GitHub API, so a mismatch means the bytes on disk are not the bytes the
    ///   release advertised — refuse.
    /// - SHA-256 is enforced fail-closed ONLY when `expectedSHA256` is present.
    ///   GitHub exposes no per-asset digest, so the publisher must opt in by
    ///   publishing one; releases predating that keep installing on the size gate
    ///   alone rather than bricking (see "Decision for Jann" in the PR).
    static func verifyArtifact(
        zipData: Data,
        expectedSize: Int,
        expectedSHA256: String?
    ) -> Result<Void, UpdaterError> {
        guard zipData.count == expectedSize else {
            return .failure(.badArtifact(
                "size mismatch (got \(zipData.count) bytes, expected \(expectedSize))"
            ))
        }
        if let expected = expectedSHA256?.lowercased() {
            let actual = SHA256.hash(data: zipData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actual == expected else {
                return .failure(.badArtifact("SHA-256 mismatch"))
            }
        }
        return .success(())
    }

    private static func performInstall(
        zip: URL,
        expectedSize: Int,
        expectedSHA256: String?
    ) throws {
        let fm = FileManager.default

        // Verify the downloaded bytes BEFORE unzipping, de-quarantining, or running
        // any of the new code. This is the trust gate the in-app updater hangs on.
        let zipData = try Data(contentsOf: zip, options: .mappedIfSafe)
        switch verifyArtifact(zipData: zipData, expectedSize: expectedSize, expectedSHA256: expectedSHA256) {
        case .success:
            break
        case .failure(let error):
            throw error
        }

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

        // Only NOW, after the artifact passed verification, strip quarantine so
        // Gatekeeper doesn't block the swapped-in app on the recipient's Mac (it
        // trusts the publisher; the verified download is the trust hop).
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
        let updatesDir = UpdaterPaths.updatesDir().path
        let script = """
        #!/bin/sh
        # Wait for the old Talkie to exit, swap the bundle, re-register, relaunch.
        PID=\(pid)
        SRC=\(shQuote(newApp.path))
        DEST=\(shQuote(dest.path))
        LSREGISTER=\(shQuote(lsregister))
        UPDATES_DIR=\(shQuote(updatesDir))
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2
          i=$((i + 1))
          if [ "$i" -gt 150 ]; then
            # The old process never exited after ~30s. Abort instead of falling
            # through to rm -rf: that would delete the running app out from under
            # itself. Leave the staged copy in place so a retry (or the next
            # relaunch) can pick it up.
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) update aborted: PID $PID still running after 30s, staged app left at $SRC" >> "$UPDATES_DIR/swap-timeout.log" 2>/dev/null
            exit 1
          fi
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
