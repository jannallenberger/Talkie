import Foundation

/// Repo-aware jargon mining (A3). Pulls the domain words a project actually uses —
/// out of its `CLAUDE.md` / `README` / `docs/*.md`, its branch names, and its recent
/// commit messages — so the post-hoc `NicheCorrector` can rescue them when you
/// dictate into that project ("cloud MD" → `CLAUDE.md`, "talky bench" → `talkie-bench`).
/// The point is to beat a coding agent's native `/voice` locally, on your own vocabulary.
///
/// **Pure by construction.** Every entry point is a `static func` over data you pass
/// in (Markdown strings) or a filesystem root read with direct `Data(contentsOf:)` /
/// `String(contentsOf:)` calls. There is **no subprocess** — git data is parsed by
/// reading the plumbing files under `.git/` ourselves, never by shelling out to `git`
/// (the scan path must never spawn a process, per the A3 spec). And every read is
/// `try?`-guarded: a repo mid-rebase in a parallel session, a half-written ref, a
/// missing `.git` — none of it may crash the caller; a failed read just yields no terms.
///
/// This is deliberately conservative on *what* it extracts: code-span tokens,
/// CamelCase/snake_case identifiers, and Capitalized proper nouns (the same
/// `isInteresting` shape `PhraseMiner` uses for on-screen phrases). Prose words are
/// the false-positive risk, and the defense is layered — this extractor's identifier
/// shaping is the first gate, `NicheTermGuard.isSafeToInject` is the second, and the
/// niche corrector's own length floor + phonetic match is the third. The gate that
/// proves it works is the false-positive prose corpus re-run with real mined terms
/// loaded (see `RepoTermMinerTests`).
enum RepoTermMiner {

    // MARK: - Markdown

    /// Extract candidate jargon from one Markdown document's contents. Reads at most
    /// `maxBytes` worth of characters so a giant generated doc can't dominate a scan.
    ///
    /// Three shapes are admitted, in priority of trust:
    ///   1. **Code spans** — anything inside backticks (`` `CLAUDE.md` ``, `` `talkie-bench` ``).
    ///      Authors backtick exactly the literal terms they want spelled right, so these
    ///      are the highest-signal source and are admitted even when they'd otherwise
    ///      look like prose (a hyphenated slug, a lowercase filename).
    ///   2. **Identifier-shaped tokens** in the running text — CamelCase (`ProjectIndexStore`),
    ///      snake_case (`context_graph`), or filename-ish (`AppDelegate.swift`).
    ///   3. **Capitalized proper nouns** (`Kubernetes`, `Coralate`) that aren't common
    ///      sentence-starters.
    static func mineMarkdown(_ contents: String, maxBytes: Int = 64_000) -> [String] {
        let text = boundedPrefix(contents, maxBytes: maxBytes)
        guard !text.isEmpty else { return [] }

        var seen = Set<String>()
        var out: [String] = []
        func admit(_ token: String) { Self.admit(token, into: &out, seen: &seen) }

        // Scan the UTF-8 BYTES, not Characters/scalars. Markdown is overwhelmingly ASCII
        // prose whose tokens fail `isInteresting`; a per-token String allocation for each
        // of thousands of prose words is what blew the scan-time budget. So we walk the
        // byte view, mark each token's byte range, apply a cheap byte-level pre-filter
        // (`byteShapeIsInteresting`), and only materialize a `String` for the few tokens
        // that could actually be jargon. Non-ASCII tokens are rare in identifiers; we let
        // any token containing a non-ASCII byte through the pre-filter and let the precise
        // `String`-level check decide (correctness preserved, cost still bounded).
        //
        // Backtick state is tracked on the byte stream: a token that begins inside a
        // backtick span is trusted more (authors backtick the literal terms they want
        // spelled right), so a single dotted/hyphenated slug there is admitted whole.
        let bytes = Array(text.utf8)
        var i = 0
        let n = bytes.count
        var inSpan = false
        while i < n {
            let b = bytes[i]
            if b == 0x60 {           // backtick
                inSpan.toggle()
                i += 1
                continue
            }
            if isSeparatorByte(b) { i += 1; continue }
            // Token run [start, j).
            let start = i
            let tokenInSpan = inSpan
            var hasUpperAfterFirst = false
            var firstUpper = false
            var hasUnderscore = false
            var hasDot = false
            var hasNonASCII = false
            var idx = 0
            while i < n {
                let c = bytes[i]
                if c == 0x60 || isSeparatorByte(c) { break }
                if c >= 0x80 { hasNonASCII = true }
                else if c == 0x5F { hasUnderscore = true }                 // _
                else if c == 0x2E { hasDot = true }                        // .
                else if c >= 0x41 && c <= 0x5A { if idx == 0 { firstUpper = true } else { hasUpperAfterFirst = true } } // A-Z
                idx += 1
                i += 1
            }
            let len = i - start
            guard len >= 3, len <= 64 else { continue }
            // Byte-level pre-filter: only tokens that COULD be interesting/slug-like get
            // a String. (A code-span token still needs the slug check, which needs a
            // separator; so admit code-span tokens through the filter too.)
            let couldMatter = tokenInSpan || hasUpperAfterFirst || firstUpper
                || hasUnderscore || hasDot || hasNonASCII
            guard couldMatter else { continue }
            let token = String(decoding: bytes[start..<i], as: UTF8.self)
            // Backtick spans are author intent → admit slugs + the full interesting set
            // (incl. bare proper nouns). Running prose → only DISTINCTIVE identifier
            // shapes (filename-ish, CamelCase/internal-cap, snake_case), never a bare
            // Capitalized word: that's where doc noise lives ("Runtime", "Design",
            // "Prefer", every sentence-starter) and it's the dominant false-positive
            // source on real docs.
            if tokenInSpan {
                if isSlugLike(token) { admit(token); continue }
                if isInteresting(token, allowProperNoun: true) { admit(token) }
            } else if isInteresting(token, allowProperNoun: false) {
                admit(token)
            }
        }
        return out
    }

    /// Edge punctuation stripped from every candidate before admission. Includes
    /// `- _ .` so a hyphenation/truncation artifact ("Talkie-", "context_") or a CLI
    /// flag ("--cask", "-rniE") can't enter the term set — interior `- _ .` survive
    /// (that's what keeps "CLAUDE.md" / "talkie-bench" / "context_graph" one token).
    private static let junkEdgeChars = CharacterSet(charactersIn: "-_.#@,:;!?()[]{}\"'`*=<>/\\")

    /// Shared admission: trim edge junk, enforce the length window, drop a
    /// common-word-plus-extension filename ("run.sh", "test.js") that would make the
    /// corrector rewrite the bare common word, dedupe case-insensitively.
    private static func admit(_ token: String, into out: inout [String], seen: inout Set<String>) {
        let trimmed = token.trimmingCharacters(in: junkEdgeChars)
        guard trimmed.count >= 3, trimmed.count <= 48 else { return }
        if let dot = trimmed.firstIndex(of: "."), dot == trimmed.lastIndex(of: ".") {
            let base = String(trimmed[..<dot]).lowercased()
            if NicheTermGuard.default.commonWords.contains(base) || commonEnglishWords.contains(base) {
                return
            }
        }
        let key = trimmed.lowercased()
        if seen.insert(key).inserted { out.append(trimmed) }
    }

    /// A token-separator byte for the Markdown scan: ASCII whitespace or the punctuation
    /// that never belongs inside an identifier/slug. `.` `-` `_` are deliberately NOT
    /// separators (they're part of "CLAUDE.md", "talkie-bench", "context_graph").
    /// Non-ASCII bytes (≥0x80) are never separators — they stay inside the token.
    private static func isSeparatorByte(_ b: UInt8) -> Bool {
        switch b {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:   // tab, LF, VT, FF, CR, space
            return true
        case 0x21, 0x22, 0x23, 0x25, 0x26, 0x27, 0x28, 0x29,   // ! " # % & ' ( )
             0x2A, 0x2C, 0x2F, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,   // * , / : ; < = > ?
             0x5B, 0x5C, 0x5D, 0x7B, 0x7C, 0x7D:   // [ \ ] { | }
            return true
        default:
            return false
        }
    }

    // MARK: - Git (plumbing files only — never a subprocess)

    /// Terms mined from a repo's git metadata: branch names (current + all local
    /// heads) and words from recent commit-message subjects. `root` is the project
    /// working directory (the folder the user picked); this resolves its `.git`,
    /// including the worktree case where `.git` is a FILE containing `gitdir: …`.
    ///
    /// All reads are `try?` — a repo being actively rebased, a packed-but-not-loose
    /// ref, a truncated reflog, or no git at all each degrade to "fewer terms", never
    /// a throw. Returns [] for a non-repo.
    static func mineGit(root: URL, maxCommitLines: Int = 200) -> [String] {
        guard let gitDir = resolveGitDir(for: root) else { return [] }

        var seen = Set<String>()
        var out: [String] = []
        func admit(_ token: String) { Self.admit(token, into: &out, seen: &seen) }

        // --- Branch names ---
        for branch in branchNames(gitDir: gitDir) {
            // Admit the whole branch slug ("feat/meeting-far-audio" → "meeting-far-audio")
            // AND its component words. Branch names are almost always the codename you'd
            // want to dictate ("agitated-merkle", "quicksilver"), so the slug is
            // high-signal — and unlike prose, each component word is a DELIBERATE label,
            // so we admit even lowercase words here (via `isBranchWord`) that the stricter
            // prose bar (`isInteresting`) would drop.
            let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
            if isSlugLike(leaf) { admit(leaf) }
            for piece in leaf.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            where isBranchWord(piece) { admit(piece) }
        }

        // --- Recent commit-message subjects (from the reflog + a few loose commits) ---
        for line in recentCommitText(gitDir: gitDir, maxLines: maxCommitLines) {
            for raw in line.split(whereSeparator: { $0.isWhitespace || "•|—–/\\()[]{}<>\"'`,:;!?".contains($0) }) {
                let token = String(raw)
                if isInteresting(token) { admit(token) }
            }
        }
        return out
    }

    // MARK: - Git plumbing helpers

    /// Resolve the real git directory for a working root. Handles the ordinary
    /// `<root>/.git` directory AND the worktree/submodule case where `<root>/.git`
    /// is a plain file whose contents are `gitdir: /abs/or/rel/path`.
    static func resolveGitDir(for root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        // It's a file: parse "gitdir: …". Relative paths resolve against `root`.
        guard let raw = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("gitdir:") else { continue }
            let path = s.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            return url
        }
        return nil
    }

    /// Local branch names: every entry under `refs/heads/**` (loose refs) unioned
    /// with the branch side of `packed-refs`, plus the symbolic target of `HEAD`.
    private static func branchNames(gitDir: URL) -> [String] {
        var names = Set<String>()

        // HEAD → "ref: refs/heads/<branch>" for the currently checked-out branch.
        if let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) {
            let s = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = s.range(of: "refs/heads/") {
                names.insert(String(s[range.upperBound...]))
            }
        }

        // Loose refs: recurse refs/heads/ (branch names can contain '/').
        let headsDir = gitDir.appendingPathComponent("refs/heads", isDirectory: true)
        if let walker = FileManager.default.enumerator(
            at: headsDir, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) {
            let base = headsDir.standardizedFileURL.path
            var visited = 0
            for case let url as URL in walker {
                visited += 1
                if visited > 5_000 { break }   // a pathological refs tree can't run us forever
                let isReg = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                guard isReg else { continue }
                let full = url.standardizedFileURL.path
                if full.hasPrefix(base + "/") {
                    names.insert(String(full.dropFirst(base.count + 1)))
                }
            }
        }

        // Packed refs: lines like "<sha> refs/heads/<branch>".
        if let packed = try? String(contentsOf: gitDir.appendingPathComponent("packed-refs"), encoding: .utf8) {
            for line in packed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                guard let range = line.range(of: " refs/heads/") else { continue }
                names.insert(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }

        return Array(names)
    }

    /// Recent commit-message text. The reflog (`logs/HEAD`) is the cheap source that
    /// needs no object parsing: each line ends with `\t<message>` (e.g.
    /// "… commit: fix(meetings): map-reduce summarization"). We read the last
    /// `maxLines` lines and take the text after the first tab. No object database
    /// reads, no subprocess.
    private static func recentCommitText(gitDir: URL, maxLines: Int) -> [String] {
        guard let log = try? String(contentsOf: gitDir.appendingPathComponent("logs/HEAD"), encoding: .utf8) else {
            return []
        }
        let lines = log.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        let tail = lines.suffix(maxLines)
        var out: [String] = []
        for line in tail {
            // Reflog format: "<old> <new> <name> <email> <time> <tz>\t<subject>".
            // Take everything after the first tab; also strip a leading
            // "<verb>: " (commit:, commit (amend):, rebase (pick):) so the verb
            // itself isn't mined as a term.
            guard let tab = line.firstIndex(of: "\t") else { continue }
            var msg = String(line[line.index(after: tab)...])
            if let colon = msg.firstIndex(of: ":"), msg.distance(from: msg.startIndex, to: colon) < 24 {
                // Only strip a short leading label ("commit:", "merge:"), never a
                // conventional-commit scope colon deep in the subject.
                let label = msg[..<colon].lowercased()
                if label.contains("commit") || label.hasPrefix("merge") || label.hasPrefix("rebase")
                    || label.hasPrefix("pull") || label.hasPrefix("checkout") || label.hasPrefix("reset")
                    || label.hasPrefix("clone") || label.hasPrefix("branch") {
                    msg = String(msg[msg.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if !msg.isEmpty { out.append(msg) }
        }
        return out
    }

    // MARK: - Shared token heuristics

    /// A single "slug" the author clearly intends as a literal identifier: a
    /// hyphen/dot/underscore-joined token with no spaces (e.g. "talkie-bench",
    /// "CLAUDE.md", "context_graph"). Admitted whole even though prose-shaped, because
    /// backtick spans and branch leaves are explicit author intent.
    private static func isSlugLike(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ".#@,:;!?()[]{}\"'`"))
        guard t.count >= 3, t.count <= 48 else { return false }
        guard t.contains("-") || t.contains("_") || t.contains(".") else { return false }
        // Must be made of identifier characters only (letters, digits, - _ .) — no
        // sentence punctuation, no spaces.
        guard t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            return false
        }
        // Needs at least one letter (reject "1.2.3", "---").
        guard t.contains(where: { $0.isLetter }) else { return false }
        // Reject a slug whose components are git noise: a hash-like segment
        // ("worktree-agent-adbbd971877a1f66c") or all-structural words. A slug is only
        // useful if at least one component is a real word and none is a long hex hash.
        let parts = t.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).map(String.init)
        if parts.contains(where: isHashLike) { return false }
        return parts.contains { part in
            let low = part.lowercased()
            return part.filter(\.isLetter).count >= 3 && !gitStructuralWords.contains(low)
        }
    }

    /// A component word of a branch name worth keeping: ≥4 letters, alphanumeric, not a
    /// common stopword, not git structure, not a hash fragment. Looser than
    /// `isInteresting` because branch words are chosen on purpose (a codename, a feature
    /// slug) — "meeting", "audio", "quicksilver" are all worth rescuing even though
    /// lowercase prose of the same shape would be skipped. (The `NicheTermGuard` +
    /// corrector floor + phonetic guard downstream still reject risky terms.)
    private static func isBranchWord(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".#@,:;!?()[]{}\"'`"))
        let letters = t.filter { $0.isLetter }.count
        guard letters >= 4, t.count <= 48 else { return false }
        guard t.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let low = t.lowercased()
        guard !stopwords.contains(low), !gitStructuralWords.contains(low) else { return false }
        return !isHashLike(t)
    }

    /// A hex-hash-ish token: mostly hex digits, length ≥ 7 (short git SHA and up). Git
    /// branch/worktree names routinely embed these ("agent-adbbd971877a1f66c"); they are
    /// never vocabulary and must not be mined.
    private static func isHashLike(_ token: String) -> Bool {
        let t = token.lowercased()
        guard t.count >= 7 else { return false }
        let hex = t.filter { $0.isHexDigit }.count
        // ≥80% hex digits ⇒ a hash, not a word.
        return Double(hex) / Double(t.count) >= 0.8
    }

    /// Git-structural words that appear in branch names / commit prefixes but are never
    /// project vocabulary. Filtered out of both slug and branch-word admission.
    private static let gitStructuralWords: Set<String> = [
        "feat", "feature", "fix", "bugfix", "hotfix", "chore", "refactor", "perf",
        "docs", "doc", "test", "tests", "style", "build", "ci", "revert", "release",
        "main", "master", "develop", "dev", "trunk", "head", "origin", "upstream",
        "branch", "merge", "rebase", "worktree", "agent", "wip", "temp", "tmp",
        "claude", "codex", "bot", "auto", "draft", "staging", "prod", "production",
    ]

    /// The "worth biasing toward" shape, close to `PhraseMiner.isInteresting`:
    /// filename-ish, CamelCase / internal-capital, or snake_case. A bare Capitalized
    /// proper noun (Kubernetes, Coralate) is admitted ONLY when `allowProperNoun` is
    /// true — i.e. from a backtick code span (author intent), never from running prose,
    /// because prose is full of Capitalized sentence-starters ("Runtime", "Design",
    /// "Prefer") that are the dominant false-positive source on real docs.
    static func isInteresting(_ raw: String, allowProperNoun: Bool = false) -> Bool {
        let token = raw.trimmingCharacters(in: junkEdgeChars)
        guard token.count >= 3, token.count <= 48 else { return false }

        // Reject git-noise up front: a hex hash ("adbbd971877a1f66c") or a hex colour
        // code ("FFFFFF", "1B1B1E") — both are all-hex and never vocabulary. (Colour
        // codes are the main junk in a design-heavy README.)
        if isHexNoise(token) { return false }
        // Reject an ALL-CAPS acronym-ish token ("HEAD", "TODO", "JSON", "HTTP") — the
        // internal-capital rule below would otherwise admit it, and these are rarely the
        // jargon a user needs rescued (and often collide with common words).
        if token.count >= 3, token.allSatisfy({ $0.isUppercase || $0.isNumber }),
           token.contains(where: \.isLetter) {
            return false
        }

        // Filename-ish: a dot with a short alpha extension (AppDelegate.swift, CLAUDE.md).
        if let dot = token.lastIndex(of: "."), dot != token.startIndex {
            let ext = token[token.index(after: dot)...]
            if (1...5).contains(ext.count) && ext.allSatisfy(\.isLetter) { return true }
        }
        // CamelCase or an internal capital (ExerciseLibrary, useState, NicheCorrector).
        if token.dropFirst().contains(where: { $0.isUppercase }) { return true }
        // snake_case identifier.
        if token.contains("_") && token.contains(where: \.isLetter) { return true }
        // A Capitalized proper-noun word (Coralate, Kubernetes) — spans only.
        if allowProperNoun, let first = token.first, first.isUppercase,
           token.dropFirst().allSatisfy({ $0.isLowercase || $0.isNumber }),
           token.count >= 4, !stopwords.contains(token.lowercased()) {
            return true
        }
        return false
    }

    /// A hex hash or hex colour code: all characters are hex digits (optionally a `#`
    /// prefix already trimmed) and it's long enough to be a hash/colour, not a word
    /// like "cafe" or "face". 6 = colour, 7+ = short SHA and up.
    private static func isHexNoise(_ token: String) -> Bool {
        guard token.count >= 6 else { return false }
        return token.allSatisfy { $0.isHexDigit }
    }

    /// Bound a document to (about) the first `maxBytes` UTF-8 bytes, cut back to the
    /// last ASCII whitespace so the final token is never a truncated partial word
    /// ("GitHub" cut to "GitHu", "talkie-bench" cut to "talkie-"). Without this, an
    /// arbitrary byte cut mid-word pollutes the term set with garbage. Cheap guard
    /// against a huge doc; if there's no whitespace in range (one giant token) we fall
    /// back to the hard byte cut.
    private static func boundedPrefix(_ s: String, maxBytes: Int) -> String {
        let utf8 = s.utf8
        if utf8.count <= maxBytes { return s }
        var bytes = Array(utf8.prefix(maxBytes))
        // Walk back to the last ASCII whitespace so we end on a token boundary.
        var cut = bytes.count
        while cut > 0 {
            let b = bytes[cut - 1]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C { break }
            cut -= 1
        }
        if cut > 0 { bytes.removeLast(bytes.count - cut) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Phonetic false-positive guard (the deliverable's real defense)

    /// True if `term` sounds too much like an ordinary English word to be safe as
    /// auto-mined jargon — i.e. its phonetic skeleton is within edit-distance-1 of a
    /// common word's skeleton. This is what stops a repo-mined term from rewriting
    /// clean prose in the corrector: `mining`↔`morning`, `Talkie`↔`talked`,
    /// `Coralate`↔`correlate` all collide here and are dropped, while the terms that
    /// actually matter (`CLAUDE.md`, `talkie-bench`, `Kubernetes`, `ContextGraph`,
    /// `NicheCorrector`) sit nowhere near a common word and pass.
    ///
    /// Mirrors `NichePhonetics` (the corrector's own matcher) applied DEFENSIVELY at
    /// term-admission time — because a repo term is auto-harvested with zero human
    /// confirmation, it must clear a stricter bar than a term the user typed. Terms
    /// with a distinctive multi-part shape (a dot or hyphen, e.g. `CLAUDE.md`,
    /// `talkie-bench`) are exempt: they can't be confused for a single spoken word.
    static func isPhoneticallyCommon(_ term: String) -> Bool {
        let core = term.lowercased().filter { $0.isLetter }
        guard core.count >= 4 else { return false }
        // A compound (dotted/hyphenated) term is spoken as multiple pieces and rescued
        // via the corrector's split path, never as a single common word — exempt it.
        if term.contains(".") || term.contains("-") || term.contains("_") { return false }
        let skel = NichePhonetics.skeleton(core)
        guard !skel.isEmpty else { return false }
        for common in commonEnglishWords {
            if core == common { return true }
            let cSkel = commonSkeletons[common] ?? NichePhonetics.skeleton(common)
            if abs(cSkel.count - skel.count) > 1 { continue }
            if NichePhonetics.editDistance(skel, cSkel) <= 1 { return true }
        }
        return false
    }

    /// Precomputed skeletons for the common-word list, so the per-term guard doesn't
    /// recompute them on every call.
    private static let commonSkeletons: [String: String] =
        Dictionary(uniqueKeysWithValues: commonEnglishWords.map { ($0, NichePhonetics.skeleton($0)) })

    /// Capitalized sentence-starters and generic doc words we never want as terms —
    /// superset of PhraseMiner's list plus the ones that recur in READMEs.
    private static let stopwords: Set<String> = [
        "the", "this", "that", "these", "those", "there", "then", "they", "them",
        "what", "when", "where", "which", "while", "with", "your", "you", "and",
        "but", "for", "from", "have", "here", "into", "more", "most", "name",
        "untitled", "new", "open", "save", "edit", "file", "menu", "window",
        "settings", "usage", "install", "installation", "example", "examples",
        "note", "notes", "todo", "readme", "license", "overview", "features",
        "getting", "started", "requirements", "contributing", "changelog",
        "about", "using", "make", "made", "also", "once", "only", "some", "such",
        "than", "very", "will", "would", "could", "should", "each", "both",
        "deploy", "config", "build", "test", "tests", "update", "merge", "fix",
        "run", "runs", "uses", "used", "add", "adds", "wire", "wires",
    ]

    /// A compact high-frequency English word list — the basis of the phonetic
    /// false-positive guard. Deliberately embedded in-code (no asset, no dependency —
    /// same choice `NicheTermGuard.builtinCommonWords` makes) and biased toward the
    /// everyday nouns/verbs/gerunds that actually appear in dictated prose, since those
    /// are what a mined term must not be confused with. Not exhaustive by design; the
    /// downstream `NicheTermGuard` + the corrector's own gates are the further layers.
    static let commonEnglishWords: Set<String> = [
        // pronouns / function words that survive the letter-only skeleton
        "about", "above", "after", "again", "against", "along", "among", "around",
        "because", "before", "behind", "below", "between", "beyond", "during",
        "under", "until", "within", "without", "would", "should", "could",
        // everyday verbs + their common inflections (gerunds are the biggest risk)
        "walk", "walked", "walking", "talk", "talked", "talking", "call", "called",
        "calling", "look", "looked", "looking", "work", "worked", "working",
        "play", "played", "playing", "watch", "watched", "watching", "learn",
        "learned", "learning", "morning", "evening", "meeting", "reading",
        "writing", "running", "making", "taking", "giving", "living", "coming",
        "going", "asking", "trying", "turning", "moving", "closing", "opening",
        "waiting", "keeping", "sitting", "standing", "growing", "burning",
        "gathered", "gathering", "sang", "sung", "poured", "pouring", "correlate",
        "kitchen", "garden", "window", "market", "candle", "parcel", "postman",
        "pastry", "pastries", "loaves", "flour", "flower", "flowers", "vegetable",
        "vegetables", "cheese", "saturday", "sunday", "monday", "tuesday",
        "wednesday", "thursday", "friday", "winter", "summer", "spring", "autumn",
        "feeder", "birds", "windowsill", "bakery", "baker", "square", "people",
        "dusted", "drip", "still", "over", "rush", "cold", "warm", "warmed",
        "table", "light", "night", "early", "hours", "step", "dew", "cat",
        "children", "parents", "family", "school", "teacher", "student", "office",
        "river", "mountain", "forest", "ocean", "valley", "bridge", "harbor",
        "street", "corner", "house", "cabin", "library", "movie", "story",
        "stories", "letter", "brother", "sister", "mother", "father", "coffee",
        "water", "bread", "milk", "coast", "trip", "train", "plane", "clock",
        "photo", "photos", "recipe", "recipes", "fabric", "sewing", "pizza",
        "salad", "order", "system", "record", "survey", "chart", "model",
        "circle", "circles", "weekend", "weekday", "afternoon", "yesterday",
        "tomorrow", "tonight", "today", "always", "never", "often", "usually",
        "really", "almost", "nearly", "quickly", "slowly", "softly", "barely",
        "money", "number", "people", "person", "thing", "place", "point",
        "world", "state", "field", "graph", "store", "token", "index", "query",
        "value", "level", "layer", "group", "stack", "queue", "block", "class",
        "frame", "shape", "style", "topic", "track", "train", "video", "voice",
        "clouds", "cloud", "cluster", "deployed", "everyone", "connection",
        "documentary", "wildflowers", "lemonade", "umbrella", "grandfather",
        "holidays", "midnight", "driveway", "counter", "faucet", "dishes",
        "ducks", "pond", "bench", "grass", "roses", "trees", "young", "tall",
        "fresh", "sweet", "heavy", "quiet", "bright", "gray", "blue", "green",
    ]
}
