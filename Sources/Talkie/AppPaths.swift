import Foundation

enum AppPaths {
    static let bundleIdentifier = "com.coralate.talkie"

    /// ~/Library/Application Support/Talkie — created on demand.
    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Talkie", isDirectory: true)
        ensure(dir)
        return dir
    }

    /// ~/Talkie Meetings — a plain, user-accessible home folder (NOT TCC-protected
    /// like ~/Documents) so meeting transcripts are easy to point Claude at.
    static func meetingsDirectory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Talkie Meetings", isDirectory: true)
        ensure(dir)
        return dir
    }

    private static func ensure(_ dir: URL) {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
