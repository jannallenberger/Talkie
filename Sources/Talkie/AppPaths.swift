import Foundation

enum AppPaths {
    static let bundleIdentifier = "com.coralate.talkie"

    /// Non-nil only inside a test process: a throwaway per-process root that
    /// stands in for the user's home-level folders. Dozens of tests build stores
    /// with their default directory (`DictionaryStore()`, `AppProfileStore()`, …)
    /// and feed them corrupt-JSON fixtures; before this, every `swift test` run
    /// overwrote the REAL `~/Library/Application Support/Talkie` (wiping the
    /// dictionary, resetting per-app cleanup styles, quarantining the scratchpad).
    /// Detected by the XCTest runtime being loaded — the app never links it.
    static let testSandboxRoot: URL? = {
        guard NSClassFromString("XCTestCase") != nil
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    /// ~/Library/Application Support/Talkie — created on demand.
    static func supportDirectory() -> URL {
        let base = testSandboxRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Talkie", isDirectory: true)
        ensure(dir)
        return dir
    }

    /// ~/Talkie Meetings — a plain, user-accessible home folder (NOT TCC-protected
    /// like ~/Documents) so meeting transcripts are easy to point Claude at.
    static func meetingsDirectory() -> URL {
        let dir = (testSandboxRoot ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Talkie Meetings", isDirectory: true)
        ensure(dir)
        return dir
    }

    /// Scratch space for the per-lane 16 kHz recordings the speaker-diarization pass
    /// reads (Application Support, NOT the user-visible Meetings folder). Holds call
    /// audio only while a pass is pending: files are deleted after the pass, on discard
    /// and on failure, and anything a crash left behind is swept at the next launch.
    static func diarizationTempDirectory() -> URL {
        let dir = supportDirectory().appendingPathComponent("diarization-tmp", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        return dir
    }

    private static func ensure(_ dir: URL) {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
