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

/// The one-time consent gate for the dev-tools updater's *first* network touch.
///
/// The whole app promises nothing leaves your Mac; a dev build's updater is the
/// one module that talks to GitHub. So before its first-ever contact — the
/// launch-time check ~3s after opening, or any `gh auth status` probe — the build
/// asks once, in the App-updates card, whether it may. This type is that gate:
/// a UserDefaults-backed tri-state plus a *pure* decision function so the policy
/// is unit-testable without touching defaults.
///
/// Fail-closed by construction: the tri-state's zero-value is `.unasked` and the
/// key is absent for every existing collaborator, so a build that previously had
/// auto-check ON is nonetheless treated as never-asked and stays silent until the
/// collaborator says yes. Consent is a one-time gate; the ongoing on/off control
/// stays the existing `autoCheckOnLaunch` toggle (no second switch).
public enum UpdaterConsent {
    /// Whether the collaborator has answered the "may this dev build check GitHub?"
    /// question yet, and how. `unasked` is the fail-closed default (absent key).
    public enum State: String, Sendable, Equatable {
        case unasked
        case granted
        case declined
    }

    /// The UserDefaults key holding the raw `State`. Absent → `.unasked`.
    static let key = "TalkieUpdaterConsent"

    /// The pure policy: an automatic launch-time check may fire ONLY when the
    /// collaborator has explicitly granted consent AND left auto-check on. No
    /// UserDefaults here so the truth table is testable in isolation.
    public static func mayAutoCheck(consent: State, autoCheckOn: Bool) -> Bool {
        consent == .granted && autoCheckOn
    }

    /// The current consent state read from `UserDefaults.standard`. An absent or
    /// unrecognized value reads as `.unasked` (fail-closed).
    public static var current: State {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let state = State(rawValue: raw) else { return .unasked }
        return state
    }

    /// Persist a new consent state.
    public static func set(_ state: State) {
        UserDefaults.standard.set(state.rawValue, forKey: key)
    }
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
