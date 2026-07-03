import Foundation
import Darwin // proc_pidinfo / proc_listchildpids — local process introspection, no network

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
    ///
    /// **Title first, cwd second (A10).** We always try the window-title path candidates
    /// first (the false-negative-biased parse above). When those yield nothing AND we have
    /// the terminal's `processID`, we fall back to reading the working directory of the
    /// terminal's child shells via `proc_pidinfo` — this is what lets a bare Claude Code
    /// terminal (whose title is often just "claude — repo", no path) scope to the checkout
    /// it's actually `cd`'d into, including a parallel worktree. If the shells disagree
    /// (multiple tabs in different repos) and the title gave no signal, we return nil and
    /// the caller keeps the merged snapshot — never a guess. `processID` defaults to 0
    /// (no proc fallback), keeping the pure title-only call site (A9's offer) unchanged.
    static func resolveRoot(
        bundleID: String?,
        windowTitle: String?,
        processID: pid_t = 0,
        fileManager: FileManager = .default
    ) -> URL? {
        for candidate in pathCandidates(bundleID: bundleID, windowTitle: windowTitle) {
            if let root = gitRoot(forPath: candidate, fileManager: fileManager) {
                return root
            }
        }
        // Title had no resolvable path — try the terminal's shell cwd(s).
        if processID > 0, let root = cwdGitRoot(terminalPID: processID, fileManager: fileManager) {
            return root
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

    // MARK: - Terminal cwd fallback (A10)

    /// How deep we walk the terminal's process subtree looking for shells. A terminal
    /// emulator's frontmost tab is a login shell that is usually a direct child or one or
    /// two levels down (shell → the program it launched). Shallow on purpose — deep enough
    /// to reach the shell, shallow enough to stay cheap and not wander into unrelated
    /// grandchild trees.
    private static let maxProcDepth = 4
    /// Cap on descendants visited, so a terminal running a fan-out of subprocesses can't
    /// make this walk unbounded. Best-effort: we stop at the cap and reason over whatever
    /// cwds we gathered.
    private static let maxProcVisited = 64

    /// Read the working directory git root behind a terminal process, or nil. Enumerates
    /// the terminal PID's descendant shells (`proc_listchildpids`), reads each one's cwd
    /// (`proc_pidinfo` with `PROC_PIDVNODEPATHINFO`), resolves each cwd to a git root, and:
    ///   • returns that root if every resolvable shell agrees on ONE repo (the common
    ///     single-repo case, incl. a lone tab),
    ///   • returns nil if two shells resolve to DIFFERENT repos (ambiguous multi-tab — we
    ///     refuse to guess, per the never-a-wrong-scope gate).
    /// Pure-syscall + read-only; every call is best-effort and returns nil on any failure
    /// (a hardened terminal that denies `proc_pidinfo` simply degrades to title-only).
    static func cwdGitRoot(terminalPID: pid_t, fileManager fm: FileManager) -> URL? {
        guard terminalPID > 0 else { return nil }
        var distinctRoots: [String: URL] = [:]   // standardized path → root
        var visited = 0

        // BFS over the process subtree, bounded by depth and visit count.
        var frontier: [(pid: pid_t, depth: Int)] = [(terminalPID, 0)]
        var seenPIDs: Set<pid_t> = [terminalPID]
        while !frontier.isEmpty {
            let (pid, depth) = frontier.removeFirst()
            visited += 1
            if visited > maxProcVisited { break }

            // Read this process's cwd and try to resolve it to a repo root. We skip the
            // terminal app's OWN cwd (depth 0) — it's the app bundle's launch dir, not a
            // project — and only trust the shell descendants.
            if depth > 0, let cwd = workingDirectory(ofPID: pid),
               let root = gitRoot(forPath: cwd, fileManager: fm) {
                distinctRoots[root.standardizedFileURL.path] = root
                // Two different repos among the tabs → ambiguous, refuse to guess.
                if distinctRoots.count > 1 { return nil }
            }

            if depth < maxProcDepth {
                for child in childPIDs(ofPID: pid) where seenPIDs.insert(child).inserted {
                    frontier.append((child, depth + 1))
                }
            }
        }
        // Exactly one repo across all shells → confident. Zero → nil (no signal).
        return distinctRoots.count == 1 ? distinctRoots.values.first : nil
    }

    /// Direct child PIDs of `pid` via `proc_listchildpids`. Best-effort: returns [] on any
    /// error or a process with no children. Sized generously and retried once if the first
    /// probe fills the buffer (a shell with a burst of children).
    private static func childPIDs(ofPID pid: pid_t) -> [pid_t] {
        var capacity = 64
        for _ in 0..<2 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let bytes = proc_listchildpids(pid, &buffer, Int32(capacity * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / MemoryLayout<pid_t>.size
            if count < capacity {
                return buffer.prefix(count).filter { $0 > 0 }
            }
            capacity *= 2   // buffer was full — there may be more; grow and retry once.
        }
        return []
    }

    /// The current working directory of a process via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`,
    /// or nil. Reads only the `pvi_cdir` (current directory) vnode path — a single local
    /// syscall, no network, no subprocess. Fails closed (nil) when the call returns an
    /// unexpected size or the process is gone / not permitted.
    private static func workingDirectory(ofPID pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let ret = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        guard ret == size else { return nil }
        // vip_path is a fixed-size C char array (MAXPATHLEN) — read it as a C string.
        var path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { p -> String in
            p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
