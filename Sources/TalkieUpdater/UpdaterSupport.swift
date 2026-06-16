import Foundation

/// `TalkieUpdater` is a SEPARATE, networked module — the in-app "update from
/// GitHub" feature. Like `TalkieBridge`, it is compiled into the app ONLY in the
/// dev-tools flavor (`TALKIE_DEV_TOOLS`), and the always-local app core never
/// imports it. That separation is what keeps the zero-network promise structural:
/// the public build links neither networked module, so `check-no-network.sh`
/// (which scans only `Sources/Talkie` + `Sources/TalkieMCP`) stays honest.
///
/// This file holds the small, dependency-free plumbing the rest of the module
/// shares: a blocking shell runner, a `gh` CLI locator, and the on-disk staging
/// directory.

/// The dev-update channel's coordinates. The updater pulls prereleases tagged
/// `dev-<build>` (where `<build>` is the publisher's commit count) from this
/// PRIVATE repo, so fetching requires auth (gh CLI or a stored token).
enum UpdaterRepo {
    static let owner = "jannallenberger"
    static let name = "Talkie"
    static var slug: String { "\(owner)/\(name)" }
}

/// A tiny blocking process runner used for `gh`, `ditto`, and `xattr`. Always
/// call it OFF the main actor (it waits on the child) — the updater wraps these
/// in `Task.detached`.
enum Shell {
    struct Result: Sendable {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
    }

    static func run(_ launchPath: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }
        // Drain before waiting so a large payload can't deadlock on a full pipe.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(
            status: p.terminationStatus,
            out: String(decoding: outData, as: UTF8.self),
            err: String(decoding: errData, as: UTF8.self)
        )
    }
}

/// Locates and queries the GitHub CLI. GUI apps launched from Finder inherit a
/// minimal PATH, so we look in the usual Homebrew locations and, failing that,
/// ask a login shell to resolve `gh` (which sources the user's profile PATH).
enum GH {
    private static let candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]

    static func path() -> String? {
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let r = Shell.run("/bin/zsh", ["-lc", "command -v gh"])
        let found = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.ok, !found.isEmpty, FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
    }

    /// True when `gh` is installed AND logged in (so it can read the private repo).
    static func isAuthenticated() -> Bool {
        guard let gh = path() else { return false }
        return Shell.run(gh, ["auth", "status"]).ok
    }
}

/// The updater's scratch space: `~/Library/Application Support/Talkie/Updates`.
/// Mirrors `AppPaths.supportDirectory()` in the app core (which this module
/// cannot import).
enum UpdaterPaths {
    static func updatesDir() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Talkie/Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
