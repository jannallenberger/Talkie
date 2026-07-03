import XCTest
@testable import Talkie

/// Tests for the Vibe-Coding in-context offer's project-root detector (A9).
///
/// Two halves, mirroring the detector's two layers:
///   • `pathCandidates` — the PURE title-parsing matrix over real editor/terminal
///     window-title shapes. This is the testable core the package hangs on, so it's
///     exhaustive: VS Code / Cursor / Xcode / Terminal / iTerm / Ghostty title
///     shapes, worktrees, and titles that must yield *nothing* (the false-negative
///     bias — a wrong-repo offer is unacceptable).
///   • `resolveRoot` — resolution against a real temp fixture tree, proving the
///     git-root walk (incl. the worktree `.git`-*file* case), the ≤6-level cap, and
///     that non-existent / non-git paths resolve to nil.
final class ProjectRootDetectorTests: XCTestCase {
    private typealias Detector = ProjectRootDetector

    private func candidates(_ bundleID: String?, _ title: String?) -> [String] {
        Detector.pathCandidates(bundleID: bundleID, windowTitle: title)
    }

    // MARK: - Pure title parsing: paths that SHOULD be extracted

    func testAbsolutePathInXcodeTitle() {
        // Xcode: "App.swift — Talkie" often has no path, but the AX title on the
        // document window can carry the represented file's full path.
        let c = candidates("com.apple.dt.Xcode",
                           "/Users/jann/Developer/Talkie/Sources/Talkie/App.swift")
        XCTAssertEqual(c.first, "/Users/jann/Developer/Talkie/Sources/Talkie/App.swift",
                       "an absolute file path in the title is the top candidate")
    }

    func testVSCodeTitleWithEmDashAndTildePath() {
        // VS Code / Cursor commonly render "file — folder — workspace" with the
        // folder as a tilde path when 'window.title' includes the dirname.
        let c = candidates("com.microsoft.VSCode",
                           "AppDelegate.swift — ~/Developer/Talkie")
        XCTAssertTrue(c.contains("~/Developer/Talkie"),
                      "the tilde folder segment after the em dash must be a candidate")
    }

    func testCursorTitleWithAbsoluteFolderSegment() {
        let c = candidates("com.todesktop.230313mzl4w4u92", // Cursor's bundle id
                           "main.ts — /Users/jann/code/webapp")
        XCTAssertTrue(c.contains("/Users/jann/code/webapp"),
                      "an absolute folder segment after the em dash resolves as a candidate")
    }

    func testTerminalCwdTitleTildeOnly() {
        // Terminal.app / zsh usually title the window with the cwd, often tilde-abbrev.
        let c = candidates("com.apple.Terminal", "~/Developer/Talkie")
        XCTAssertEqual(c.first, "~/Developer/Talkie",
                       "a bare tilde cwd title is the candidate")
    }

    func testITermTitleWithUserHostPrefix() {
        // iTerm2: "user@host: ~/dev/Talkie" — the path token is isolated from the prefix.
        let c = candidates("com.googlecode.iterm2", "jann@mbp: ~/dev/Talkie")
        XCTAssertTrue(c.contains("~/dev/Talkie"),
                      "the cwd token is extracted even with a user@host: prefix")
    }

    func testGhosttyTitleAbsoluteCwd() {
        let c = candidates("com.mitchellh.ghostty", "/Users/jann/Developer/Talkie")
        XCTAssertEqual(c.first, "/Users/jann/Developer/Talkie",
                       "Ghostty's absolute cwd title resolves as the candidate")
    }

    func testPathWithSpacesInDirectoryNameSurvives() {
        // A whole-segment path keeps interior spaces ("~/My Code/Talkie").
        let c = candidates("com.apple.Terminal", "~/My Code/Talkie")
        XCTAssertTrue(c.contains("~/My Code/Talkie"),
                      "a path whose directory name has a space is kept intact")
    }

    func testEmbeddedPathMidSentenceIsFound() {
        // Some editors annotate ("Edited /Users/jann/Talkie/x.swift").
        let c = candidates("com.microsoft.VSCode", "Edited /Users/jann/Talkie/x.swift")
        XCTAssertTrue(c.contains("/Users/jann/Talkie/x.swift"),
                      "a path embedded mid-sentence is still extracted as a token")
    }

    func testTrailingPunctuationStripped() {
        let c = candidates("com.apple.Terminal", "~/Developer/Talkie)")
        XCTAssertTrue(c.contains("~/Developer/Talkie"),
                      "trailing punctuation is trimmed off a path candidate")
    }

    func testMultipleCandidatesDedupedAndOrdered() {
        // File path first (more specific), then the folder segment.
        let c = candidates("com.microsoft.VSCode",
                           "/Users/jann/Talkie/a.swift — /Users/jann/Talkie")
        XCTAssertEqual(c.first, "/Users/jann/Talkie/a.swift",
                       "the more-specific file path is ordered first")
        XCTAssertTrue(c.contains("/Users/jann/Talkie"), "the folder segment is also present")
        XCTAssertEqual(Set(c).count, c.count, "candidates are de-duplicated")
    }

    // MARK: - Pure title parsing: titles that must yield NOTHING (false-negative bias)

    func testBareRepoNameYieldsNoCandidate() {
        // The classic editor title with NO path — must NOT be guessed at.
        XCTAssertTrue(candidates("com.microsoft.VSCode", "AppDelegate.swift — Talkie").isEmpty,
                      "a bare repo name (no path) must produce no candidate — never guess a folder")
    }

    func testChatTitleYieldsNothing() {
        XCTAssertTrue(candidates("com.tinyspeck.slackmacgap", "general — Acme").isEmpty,
                      "a Slack channel title must not be mistaken for a path")
    }

    func testBrowserTitleYieldsNothing() {
        XCTAssertTrue(candidates("com.apple.Safari",
                                 "GitHub - jann/Talkie: on-device dictation").isEmpty,
                      "a browser tab title with slashes in the page text is not a filesystem path")
    }

    func testNilAndEmptyTitleYieldNothing() {
        XCTAssertTrue(candidates("com.apple.Terminal", nil).isEmpty, "nil title → no candidate")
        XCTAssertTrue(candidates("com.apple.Terminal", "").isEmpty, "empty title → no candidate")
        XCTAssertTrue(candidates(nil, nil).isEmpty, "nil bundle + nil title → no candidate")
    }

    func testLoneSlashOrTildeIsNotAPath() {
        XCTAssertTrue(candidates("com.apple.Terminal", "/").isEmpty, "a lone / is not a project path")
        XCTAssertTrue(candidates("com.apple.Terminal", "~").isEmpty, "a lone ~ is not a project path")
    }

    func testUntitledTitleYieldsNothing() {
        XCTAssertTrue(candidates("com.microsoft.VSCode", "Untitled-1").isEmpty,
                      "an unsaved 'Untitled' buffer has no path")
    }

    // MARK: - expandTilde (pure)

    func testExpandTilde() {
        XCTAssertEqual(Detector.expandTilde("~"), NSHomeDirectory())
        XCTAssertEqual(Detector.expandTilde("~/dev/Talkie"), NSHomeDirectory() + "/dev/Talkie")
        XCTAssertEqual(Detector.expandTilde("/abs/path"), "/abs/path",
                       "a non-tilde path is returned unchanged")
        XCTAssertEqual(Detector.expandTilde("nested/~/x"), "nested/~/x",
                       "only a LEADING tilde is expanded")
    }

    // MARK: - Resolution against a real fixture tree

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rootdetector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func mkdir(_ rel: String) throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ rel: String, _ contents: String = "") throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testResolvesRepoRootFromNestedFilePath() throws {
        let repo = try mkdir("Talkie")
        _ = try mkdir("Talkie/.git")                       // normal repo
        let file = try write("Talkie/Sources/App.swift", "// x")

        let root = Detector.resolveRoot(bundleID: "com.microsoft.VSCode",
                                        windowTitle: "App.swift — \(file.path)")
        XCTAssertEqual(root?.standardizedFileURL.path, repo.standardizedFileURL.path,
                       "the walk climbs from the nested file to the .git repo root")
    }

    func testResolvesRepoRootFromDirectoryTitle() throws {
        let repo = try mkdir("webapp")
        _ = try mkdir("webapp/.git")
        let root = Detector.resolveRoot(bundleID: "com.apple.Terminal", windowTitle: repo.path)
        XCTAssertEqual(root?.standardizedFileURL.path, repo.standardizedFileURL.path,
                       "a directory title that IS the repo root resolves directly")
    }

    func testWorktreeGitFileResolves() throws {
        // A git worktree has a `.git` *file* (not a directory) pointing at the gitdir.
        let wt = try mkdir("Talkie-worktree")
        _ = try write("Talkie-worktree/.git", "gitdir: /somewhere/.git/worktrees/wt\n")
        let file = try write("Talkie-worktree/Sources/App.swift")

        let root = Detector.resolveRoot(bundleID: "com.microsoft.VSCode",
                                        windowTitle: file.path)
        XCTAssertEqual(root?.standardizedFileURL.path, wt.standardizedFileURL.path,
                       "a `.git` FILE (worktree/submodule) counts as a repo root, not just a dir")
    }

    func testNonExistentPathResolvesToNil() {
        let root = Detector.resolveRoot(
            bundleID: "com.microsoft.VSCode",
            windowTitle: "App.swift — \(tmp.path)/does/not/exist/App.swift")
        XCTAssertNil(root, "a path that doesn't exist on disk must never yield a root")
    }

    func testExistingNonGitDirectoryResolvesToNil() throws {
        // Exists, but no `.git` anywhere up the (short) chain → no offer.
        let file = try write("just-a-folder/notes.txt")
        let root = Detector.resolveRoot(bundleID: "com.apple.Terminal", windowTitle: file.path)
        XCTAssertNil(root, "an existing directory that isn't a git working copy yields nil")
    }

    func testGitBeyondWalkLimitIsNotFound() throws {
        // Put `.git` at the top, then bury a file far deeper than maxWalkUp (6).
        _ = try mkdir("deeprepo/.git")
        // 8 nested levels below the repo root — beyond the 6-level cap.
        let deep = "deeprepo/a/b/c/d/e/f/g/h/leaf.swift"
        let file = try write(deep)
        let root = Detector.resolveRoot(bundleID: "com.microsoft.VSCode", windowTitle: file.path)
        XCTAssertNil(root, "the upward walk stops at maxWalkUp, so a too-deep file finds no root")
    }

    func testBareRepoNameTitleResolvesToNilEvenIfSuchFolderExists() throws {
        // Even if a "Talkie" repo exists somewhere, a title with only the bare name
        // (no path) must resolve to nil — we never fabricate a path from a name.
        _ = try mkdir("Talkie/.git")
        let root = Detector.resolveRoot(bundleID: "com.microsoft.VSCode",
                                        windowTitle: "App.swift — Talkie")
        XCTAssertNil(root, "a bare-name title never resolves, even when a matching repo exists")
    }
}
