import Foundation

/// Turns "who you're dictating into" (a target app's bundle id + window title) into
/// a discoverable project root — a directory that actually exists and is a git
/// working copy. This is what lets the in-context Vibe Coding offer say a *real*
/// repo name ("Index 〈Talkie〉 filenames?") the first time you dictate into an
/// editor or terminal, instead of leaving the flagship dev feature invisible.
///
/// Two layers, both pure enough to unit-test:
///   1. `pathCandidates(bundleID:windowTitle:)` — parses path-like tokens out of a
///      window title (absolute `/…` paths and `~`-prefixed segments). No filesystem
///      access, so it's exhaustively testable on title fixtures.
///   2. `resolveRoot(bundleID:windowTitle:)` — expands `~`, confirms the path exists,
///      and walks up (≤ `maxWalkUp` levels) to the nearest directory that contains a
///      `.git` entry (dir OR file, so worktrees resolve). Returns the git root, or nil.
///
/// **Design bias: prefer a false negative over a false positive.** A wrong-repo offer
/// ("Index 〈SomeoneElsesRepo〉?") burns the user's trust in the feature forever, so
/// every rule here is conservative: we only ever propose a root we could resolve from
/// an *explicit path* the title actually contained. Editor titles that show only a
/// bare repo name with no path ("Foo.swift — MyRepo") are deliberately NOT guessed at
/// — there's no reliable way to turn a bare name into a real directory, so we yield
/// nil and stay silent rather than risk pointing at the wrong folder.
///
/// Entirely local, read-only, no new permission: the window title is already read by
/// `ContextCapture` (behind the existing `contextAwareness` setting); this only parses
/// the string it already has.
enum ProjectRootDetector {
    /// How far up from a resolved path we'll climb looking for a `.git`. Deep enough
    /// to reach a repo root from a nested file, shallow enough that a stray path in a
    /// title can't march up to `$HOME`'s own `.git` (if any) from six levels down.
    static let maxWalkUp = 6

    // MARK: - Public API

    /// The best project root discoverable from this target, or nil. Pure parsing
    /// feeds real-filesystem resolution; `fileManager` is injectable so tests can
    /// resolve against a fixture tree (defaults to `.default` in the app).
    static func resolveRoot(
        bundleID: String?,
        windowTitle: String?,
        fileManager: FileManager = .default
    ) -> URL? {
        for candidate in pathCandidates(bundleID: bundleID, windowTitle: windowTitle) {
            if let root = gitRoot(forPath: candidate, fileManager: fileManager) {
                return root
            }
        }
        return nil
    }

    /// Path-like tokens extracted from a window title, most-specific first. PURE —
    /// no filesystem access. Recognizes:
    ///   • absolute POSIX paths      `/Users/jann/Talkie/Sources/App.swift`
    ///   • home-relative paths       `~/Developer/Talkie` or `~/Developer/Talkie/x.ts`
    /// Anything else (bare repo names, "Untitled", chat/browser titles) yields no
    /// candidate — that's the false-negative bias, on purpose.
    static func pathCandidates(bundleID: String?, windowTitle: String?) -> [String] {
        guard let title = windowTitle, !title.isEmpty else { return [] }

        var out: [String] = []
        var seen = Set<String>()
        func push(_ path: String) {
            let trimmed = trimTrailingPunctuation(path)
            // A single "/" or "~" is not a project path; require real depth.
            guard trimmed.count >= 3, trimmed.contains("/") else { return }
            if seen.insert(trimmed).inserted { out.append(trimmed) }
        }

        // Editors/terminals overwhelmingly separate the file/label from the path with
        // an em dash, en dash, or a padded hyphen ("App.swift — ~/dev/Talkie"). Split
        // on those first so a path sitting in a title segment is isolated cleanly, then
        // also scan the raw title so a title that *is* just a path still matches.
        var segments = title.components(separatedBy: CharacterSet(charactersIn: "—–"))
        segments.append(title)

        for segment in segments {
            for token in tokenize(segment) {
                if token.hasPrefix("/") {
                    push(token)
                } else if token == "~" || token.hasPrefix("~/") {
                    push(token)
                }
            }
        }
        return out
    }

    // MARK: - Parsing helpers (pure)

    /// Split a title segment into whitespace-delimited tokens, but keep a path with
    /// spaces in it intact when the whole segment is clearly one path. We first try
    /// the whole trimmed segment (covers "~/My Code/App" and "/Users/jann/Repo"), then
    /// fall back to whitespace tokens (covers "edited /Users/jann/Repo/x.swift").
    private static func tokenize(_ segment: String) -> [String] {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var tokens: [String] = []
        // Whole-segment-as-path first (only if it starts like a path), so spaces in a
        // directory name survive.
        if trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") {
            tokens.append(trimmed)
        }
        // Then individual tokens, so a path embedded mid-sentence is still found.
        for raw in trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            tokens.append(String(raw))
        }
        return tokens
    }

    /// Strip trailing sentence/UI punctuation an app may have appended to a title
    /// ("… — Edited", a trailing ":" or ")"), without touching path separators.
    private static func trimTrailingPunctuation(_ s: String) -> String {
        var out = Substring(s)
        while let last = out.last, ".,;:!?)]}\"'`".contains(last) {
            out = out.dropLast()
        }
        return String(out)
    }

    // MARK: - Filesystem resolution

    /// Expand a candidate path and, if it (or an ancestor within `maxWalkUp`) is a git
    /// working copy, return that repo root. Directories and files both resolve — a file
    /// path just starts the walk from its parent directory.
    private static func gitRoot(forPath rawPath: String, fileManager fm: FileManager) -> URL? {
        let expanded = expandTilde(rawPath)
        guard !expanded.isEmpty else { return nil }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDir) else { return nil }

        // Start the walk at the path itself if it's a directory, else at its parent.
        var dir = URL(fileURLWithPath: expanded, isDirectory: isDir.boolValue)
        if !isDir.boolValue { dir = dir.deletingLastPathComponent() }
        dir = dir.standardizedFileURL

        var levels = 0
        while levels <= maxWalkUp {
            if containsGit(dir, fileManager: fm) { return dir }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            // Stop at the filesystem root (parent == self) so we can't loop forever.
            if parent.path == dir.path { break }
            dir = parent
            levels += 1
        }
        return nil
    }

    /// True when `dir` holds a `.git` — a normal repo (`.git` directory) OR a git
    /// worktree / submodule (`.git` is a *file* pointing at the real gitdir). Both
    /// mean "this is a working copy worth indexing," so we accept either.
    private static func containsGit(_ dir: URL, fileManager fm: FileManager) -> Bool {
        let dotGit = dir.appendingPathComponent(".git").path
        return fm.fileExists(atPath: dotGit)
    }

    /// Expand a leading `~` / `~/` to the current user's home directory. Only a
    /// leading tilde is special (that's the sole form window titles use); a tilde
    /// anywhere else is left as-is.
    static func expandTilde(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + String(path.dropFirst(1))
        }
        return path
    }
}
