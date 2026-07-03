import Foundation

// MARK: - Project index (auto-scan a folder you pick)

/// Persisted snapshot of a scanned project: which folders, when, and the files
/// found across all of them. Spoken filenames are matched against this so
/// "exercise library dot tsx" snaps to the real `ExerciseLibrary.tsx`.
struct ProjectIndexData: Codable {
    var folderPaths: [String] = []  // the project roots, in the order picked
    var scannedAtUnix: Double?
    var files: [String] = []        // basenames, e.g. "ExerciseLibrary.tsx"
    var symbols: [String] = []      // bare identifiers, e.g. "ExerciseLibrary"
    /// Jargon mined from the project's docs (CLAUDE.md/README/docs) + git branch and
    /// commit-message words (A3). Feeds the post-hoc niche corrector so "cloud MD"
    /// snaps to `CLAUDE.md` when you dictate in this project. Deduped, capped.
    var docTerms: [String] = []
    /// Lowercased basename → its full on-disk path (A11). Lets a window-title filename
    /// ("ExerciseLibrary.tsx — …") resolve to the real file whose identifiers we then
    /// mine for that session. First folder wins a colliding basename, matching the
    /// `files` de-dup. Memory-bounded by the same `maxFiles` cap as `files`, so a
    /// stack of monorepos can't blow the map up. Persisted so title→file resolution
    /// works right after launch without waiting for a rescan.
    var filePaths: [String: String] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case folderPaths, folderPath, scannedAtUnix, files, symbols, docTerms, filePaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let paths = try c.decodeIfPresent([String].self, forKey: .folderPaths) {
            folderPaths = paths
        } else if let single = try c.decodeIfPresent(String.self, forKey: .folderPath),
                  !single.isEmpty {
            folderPaths = [single]  // migrate the old single-folder field
        }
        scannedAtUnix = try c.decodeIfPresent(Double.self, forKey: .scannedAtUnix)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        symbols = try c.decodeIfPresent([String].self, forKey: .symbols) ?? []
        docTerms = try c.decodeIfPresent([String].self, forKey: .docTerms) ?? []
        filePaths = try c.decodeIfPresent([String: String].self, forKey: .filePaths) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folderPaths, forKey: .folderPaths)
        try c.encodeIfPresent(scannedAtUnix, forKey: .scannedAtUnix)
        try c.encode(files, forKey: .files)
        try c.encode(symbols, forKey: .symbols)
        try c.encode(docTerms, forKey: .docTerms)
        try c.encode(filePaths, forKey: .filePaths)
    }
}

/// A single chosen project root, for display in the Vibe Coding pane.
struct ProjectFolder: Identifiable, Hashable {
    let path: String
    var id: String { path }
    /// The folder's own name, e.g. "Talkie".
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    /// The abbreviated parent location, e.g. "~/Developer".
    var location: String {
        let parent = (path as NSString).deletingLastPathComponent
        return (parent as NSString).abbreviatingWithTildeInPath
    }
}

/// An immutable, Sendable view of the index used off the main actor during
/// post-processing: the spoken→canonical map plus phrases to bias the recognizer.
struct ProjectIndexSnapshot: Sendable {
    var keyMap: [String: String]   // normalized spoken key → canonical filename
    var maxKeyTokens: Int
    var biasPhrases: [String]      // filenames + base words for contextual biasing
    /// Project jargon (from docs + git) safe to feed the post-hoc niche corrector:
    /// each term has cleared `NicheTermGuard.isSafeToInject` and the corrector's own
    /// 4-letter floor, so folding it into the corrector's term set can only rescue a
    /// close-sounding misrecognition, never force a rare spelling onto a common word.
    var correctorTerms: [String] = []

    static let empty = ProjectIndexSnapshot(keyMap: [:], maxKeyTokens: 0, biasPhrases: [], correctorTerms: [])
    /// `isEmpty` gates the spoken-filename matcher only, so it keys off `keyMap`
    /// exactly as before A3 — its meaning is unchanged. Corrector terms are a
    /// separate channel read directly (`correctorTerms`) at the endDictation union,
    /// so a docs-only project (terms but no matchable filenames) still contributes
    /// its jargon without perturbing the file-matching fast path.
    var isEmpty: Bool { keyMap.isEmpty }
}

@MainActor
final class ProjectIndexStore: ObservableObject {
    @Published private(set) var data = ProjectIndexData()
    @Published private(set) var isScanning = false
    /// Rebuilt whenever `data` changes; handed to the formatter each dictation.
    @Published private(set) var snapshot = ProjectIndexSnapshot.empty

    private let fileURL: URL
    /// Bumped on every change to the desired folder set. A scan that finishes
    /// after a newer change (or a `clear`) sees a mismatch and discards its stale
    /// result, so an in-flight scan can never clobber a later edit.
    private var scanGeneration = 0
    /// The in-flight off-main walk. Retained so a new rescan/clear can CANCEL the
    /// prior one — the generation token alone only discards a stale *result*; the
    /// walk would otherwise keep churning the disk on a huge project dir. The
    /// detached work polls `Task.isCancelled` and breaks out promptly.
    private var scanTask: Task<ProjectScanner.Result, Never>?

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("project_index.json")
        load()
        rebuildSnapshot()
    }

    /// The chosen project roots, in the order they were added.
    var folders: [ProjectFolder] { data.folderPaths.map { ProjectFolder(path: $0) } }
    var hasFolders: Bool { !data.folderPaths.isEmpty }
    var fileCount: Int { data.files.count }
    var lastScanned: Date? { data.scannedAtUnix.map { Date(timeIntervalSince1970: $0) } }

    /// Add a project root (ignoring duplicates), then rescan everything.
    func addFolder(_ url: URL) { addFolders([url]) }

    /// Add several project roots at once (ignoring duplicates) and rescan a
    /// single time, so picking five folders doesn't kick off five scans.
    func addFolders(_ urls: [URL]) {
        var added = false
        for url in urls where !data.folderPaths.contains(url.path) {
            data.folderPaths.append(url.path)
            added = true
        }
        guard added else { return }
        save()
        Task { await rescan() }
    }

    /// Drop a project root and rescan so its files leave the index.
    func removeFolder(_ path: String) {
        guard data.folderPaths.contains(path) else { return }
        data.folderPaths.removeAll { $0 == path }
        save()
        Task { await rescan() }
    }

    func clear() {
        data = ProjectIndexData()
        scanGeneration += 1   // supersede any in-flight scan so it can't refill
        scanTask?.cancel()    // and stop the walk now — don't let it churn the disk
        scanTask = nil
        isScanning = false
        save()
        rebuildSnapshot()
    }

    /// Walk every chosen folder off the main actor and rebuild the merged file
    /// list. With no folders left, the index empties. A generation token makes
    /// overlapping scans safe: only the latest one may write its result.
    func rescan() async {
        scanGeneration += 1
        let generation = scanGeneration
        // Cancel any walk still running for a previous folder set before kicking
        // off the new one, so two rescans in quick succession don't both grind the
        // disk. (Retaining + cancelling the Task is what makes `Task.isCancelled`
        // fire inside the detached walk.)
        scanTask?.cancel()
        let paths = data.folderPaths
        guard !paths.isEmpty else {
            scanTask = nil
            data.files = []
            data.symbols = []
            data.docTerms = []
            data.filePaths = [:]
            data.scannedAtUnix = nil
            isScanning = false
            save()
            rebuildSnapshot()
            return
        }
        isScanning = true
        let task = Task.detached(priority: .utility) {
            ProjectScanner.scanAll(roots: paths.map { URL(fileURLWithPath: $0) })
        }
        scanTask = task
        let result = await task.value
        // A newer change/scan superseded us — drop this stale result untouched and
        // let the newest scan settle `isScanning`.
        guard generation == scanGeneration else { return }
        scanTask = nil
        data.files = result.files
        data.symbols = result.symbols
        data.docTerms = result.docTerms
        data.filePaths = result.filePaths
        data.scannedAtUnix = Date().timeIntervalSince1970
        isScanning = false
        save()
        rebuildSnapshot()
    }

    /// Resolve a window-title filename to the real on-disk path of an indexed file, or
    /// nil (A11). Read on the main actor at `beginDictation`, then handed as a plain
    /// `String` into the off-main miner. Returns nil for a title with no filename token
    /// or a filename we didn't index — the caller then simply skips active-file mining.
    func resolveIndexedFilePath(forWindowTitle title: String?) -> String? {
        FileIdentifierMiner.resolvePath(fromWindowTitle: title, filePaths: data.filePaths)
    }

    private func rebuildSnapshot() {
        snapshot = SpokenFileMatcher.buildSnapshot(files: data.files, symbols: data.symbols,
                                                   docTerms: data.docTerms)
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(ProjectIndexData.self, from: raw) else { return }
        data = decoded
    }

    private func save() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? raw.write(to: fileURL, options: .atomic)
    }
}

/// Pure filesystem walk. Skips the usual heavy/irrelevant directories and caps
/// the result so a giant monorepo can't blow up memory.
enum ProjectScanner {
    static let ignoredDirs: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "out", ".next",
        "vendor", "Pods", ".venv", "venv", "__pycache__", ".cache", "target",
        "DerivedData", ".gradle", ".idea", "coverage", ".turbo", ".vercel",
    ]
    static let codeExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs",
        "java", "kt", "c", "h", "cpp", "hpp", "cc", "m", "mm", "cs", "php",
        "vue", "svelte", "css", "scss", "html", "json", "yaml", "yml", "toml",
        "md", "sql", "sh", "graphql", "proto", "dart", "ex", "exs", "scala",
    ]
    static let maxFiles = 6000
    /// Hard ceiling on directory entries *visited* per scan. `maxFiles` caps the
    /// kept code files, but a folder packed with assets/binaries (or a pathological
    /// tree under an un-ignored dir) yields few matches while still walking forever.
    /// This bounds the enumeration itself so a rescan over a giant project dir can't
    /// run unbounded. The walk is breadth-stable across runs, so results stay
    /// deterministic up to the cap.
    static let maxEntries = 200_000

    struct Result {
        var files: [String]
        var symbols: [String]
        /// Deduped jargon mined from each root's docs + git (A3). Empty unless the
        /// walk found doc files / a `.git` to read. Capped by `maxDocTerms`.
        var docTerms: [String] = []
        /// Doc-file URLs the walk flagged for mining (CLAUDE.md / README* / docs/*.md).
        /// Transient scan-time output consumed by `scanAll`; never persisted.
        var docFiles: [URL] = []
        /// Lowercased basename → full path for every kept code file (A11). Built during
        /// the same walk that fills `files`, so it costs no extra traversal. Used to
        /// resolve a window-title filename to the real file for active-file identifier
        /// mining. First occurrence wins (mirrors the `seen` de-dup on `files`).
        var filePaths: [String: String] = [:]
    }

    /// Doc files worth mining for jargon: the project's `CLAUDE.md`, any `README*`,
    /// and Markdown that is a DIRECT child of a `docs/` directory. Matched by name/path
    /// during the existing walk so we never do a second pass over the tree.
    static let maxDocTerms = 200
    /// A hard ceiling on doc files we open per scan. Kept small on purpose: the
    /// highest-signal jargon lives in CLAUDE.md, the README, and top-level docs — not
    /// in a deep `docs/plans/**` tree — and reading fewer files keeps the mine's cost a
    /// small fraction of the file walk (the "<20% scan-time growth" budget). A repo with
    /// dozens of docs still only pays for the first `maxDocFiles`.
    static let maxDocFiles = 6
    /// Per-doc read bound (bytes). Jargon (backticked terms, the intro, identifiers)
    /// clusters in the first few KB of a README/CLAUDE.md, so a small partial read
    /// captures it while keeping parse cost a small fraction of the file walk.
    static let maxDocBytes = 4_000

    /// Scan several roots and merge them into one index, de-duping filenames
    /// across folders (first folder wins a colliding basename) and capping the
    /// total so a stack of monorepos can't blow up memory. Also mines each root's
    /// docs + git metadata into `docTerms` (A3) — the doc-file URLs and the git root
    /// are collected DURING the file walk (no second traversal).
    static func scanAll(roots: [URL]) -> Result {
        var files: [String] = []
        var symbolSet = Set<String>()
        var seen = Set<String>()
        var docSeen = Set<String>()
        var docTerms: [String] = []
        var filePaths: [String: String] = [:]
        func admitTerms(_ terms: [String]) {
            for t in terms where docTerms.count < maxDocTerms {
                if docSeen.insert(t.lowercased()).inserted { docTerms.append(t) }
            }
        }
        for root in roots {
            if files.count >= maxFiles { break }
            if Task.isCancelled { break }
            let r = scan(root: root)
            for f in r.files {
                if files.count >= maxFiles { break }
                let key = f.lowercased()
                guard seen.insert(key).inserted else { continue }
                files.append(f)
                // A11: carry this file's path across, first-folder-wins — keyed on the
                // same lowercased basename the de-dup uses, so the map matches `files`.
                if let path = r.filePaths[key] { filePaths[key] = path }
            }
            symbolSet.formUnion(r.symbols)

            // A3: mine this root's git metadata (branches + recent commits) and the
            // doc files the walk flagged. All reads are try?-guarded inside the miner.
            if Task.isCancelled { break }
            admitTerms(RepoTermMiner.mineGit(root: root))
            for docURL in r.docFiles.prefix(maxDocFiles) {
                if Task.isCancelled { break }
                if docTerms.count >= maxDocTerms { break }
                // Read only the first `maxDocBytes` so a giant doc can't dominate the
                // scan. try? — an unreadable/vanished doc (parallel edit) is skipped.
                guard let contents = readPrefix(of: docURL, maxBytes: maxDocBytes) else { continue }
                admitTerms(RepoTermMiner.mineMarkdown(contents, maxBytes: maxDocBytes))
            }
        }
        return Result(files: files, symbols: Array(symbolSet), docTerms: docTerms,
                      filePaths: filePaths)
    }

    static func scan(root: URL) -> Result {
        var files: [String] = []
        var symbolSet = Set<String>()
        var docFiles: [URL] = []
        var filePaths: [String: String] = [:]
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return Result(files: [], symbols: []) }

        var seen = Set<String>()
        var visited = 0
        for case let url as URL in walker {
            if files.count >= maxFiles { break }
            // Bound the walk itself, not just the kept files, and bail out fast when
            // a newer rescan/clear has superseded us.
            visited += 1
            if visited > maxEntries { break }
            if Task.isCancelled { break }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if ignoredDirs.contains(name) { walker.skipDescendants() }
                continue
            }
            // A3: flag docs to mine for jargon (CLAUDE.md / README* / docs/*.md).
            // Capped so a docs-heavy repo can't collect thousands of URLs. This is
            // additive to — not a replacement for — keeping .md files in `files`.
            if docFiles.count < maxDocFiles, isDocFile(url) { docFiles.append(url) }
            let ext = url.pathExtension.lowercased()
            guard codeExtensions.contains(ext) else { continue }
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            files.append(name)
            // A11: remember where this basename lives so a window-title filename can be
            // resolved back to the real file for identifier mining. The `seen` guard
            // above already makes first-occurrence win, so no collision handling needed.
            filePaths[key] = url.path
            let base = url.deletingPathExtension().lastPathComponent
            if base.count >= 3 { symbolSet.insert(base) }
        }
        return Result(files: files, symbols: Array(symbolSet), docTerms: [],
                      docFiles: docFiles, filePaths: filePaths)
    }

    /// Whether a file is worth mining for project jargon (A3): the project's
    /// `CLAUDE.md`, any `README*`, or a Markdown file that is a DIRECT child of a
    /// `docs/` directory. Matched by name/path only — no read here; the miner reads
    /// (bounded) later. The direct-child rule keeps a big `docs/plans/**` tree of
    /// planning prose out of the jargon mine (that's design writing, not vocabulary),
    /// which is both higher-signal and cheaper.
    static func isDocFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        let isMarkdown = ext == "md" || ext == "markdown"
        if name == "claude.md" { return true }
        if name.hasPrefix("readme") { return true }
        if isMarkdown {
            // Only when the immediate parent directory is named "docs".
            if url.deletingLastPathComponent().lastPathComponent.lowercased() == "docs" { return true }
        }
        return false
    }

    /// Read at most `maxBytes` bytes of a file without pulling the whole thing into
    /// memory (a doc could be arbitrarily large). Uses a `FileHandle`; `try?` so an
    /// unreadable or vanished file yields nil rather than throwing. When the file is
    /// longer than `maxBytes` the read is trimmed back to the last ASCII whitespace, so
    /// the final token is a complete word — never a mid-word cut ("GitHub"→"GitHu")
    /// that would pollute the mined term set. Decoded leniently as UTF-8.
    static func readPrefix(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = (try? handle.read(upToCount: maxBytes)) ?? nil else { return nil }
        var bytes = [UInt8](data)
        // Only trim when we likely hit the cap mid-file (a full read == maxBytes bytes).
        if bytes.count >= maxBytes {
            var cut = bytes.count
            while cut > 0 {
                let b = bytes[cut - 1]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C { break }
                cut -= 1
            }
            if cut > 0 { bytes.removeLast(bytes.count - cut) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Spoken filename matching

/// Builds the spoken→canonical map and applies it to a transcript. The heart of
/// the "say a filename, get the real file" feature.
enum SpokenFileMatcher {
    /// Spelled-out single letters the recognizer emits for extensions ("t s x").
    private static let letterWords: [String: String] = [
        "a": "a", "b": "b", "c": "c", "d": "d", "e": "e", "f": "f", "g": "g",
        "h": "h", "i": "i", "j": "j", "k": "k", "l": "l", "m": "m", "n": "n",
        "o": "o", "p": "p", "q": "q", "r": "r", "s": "s", "t": "t", "u": "u",
        "v": "v", "w": "w", "x": "x", "y": "y", "z": "z",
    ]

    /// Build the off-main snapshot once, when the index changes.
    static func buildSnapshot(files: [String], symbols: [String],
                             docTerms: [String] = []) -> ProjectIndexSnapshot {
        var keyMap: [String: String] = [:]
        var maxTokens = 0
        var bias = Set<String>()

        for file in files {
            for key in spokenKeys(for: file) {
                let tokenCount = key.split(separator: " ").count
                guard tokenCount > 0 else { continue }
                // First file scanned wins a colliding spoken key (collisions are rare).
                if keyMap[key] == nil { keyMap[key] = file }
                maxTokens = max(maxTokens, tokenCount)
            }
            bias.insert(file)
            // The "spaced" human reading also helps the recognizer.
            let spaced = splitWords(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)
                .joined(separator: " ")
            if !spaced.isEmpty { bias.insert(spaced) }
        }
        for symbol in symbols { bias.insert(symbol) }

        return ProjectIndexSnapshot(
            keyMap: keyMap,
            maxKeyTokens: maxTokens,
            biasPhrases: Array(bias.prefix(250)),
            correctorTerms: correctorTerms(from: docTerms)
        )
    }

    /// The repo-mined terms that are safe to hand the post-hoc `NicheCorrector` (A3).
    /// THREE gates, because repo terms are auto-harvested with zero human confirmation
    /// and so carry the highest false-positive risk:
    ///   1. a 4-letter LETTER floor, mirroring `NicheCorrector.buildTargets` (which
    ///      drops sub-4-letter cores anyway) — so "CLAUDE.md" (7 letters) passes and a
    ///      short slug like "a-b" does not;
    ///   2. `NicheTermGuard.isSafeToInject` — rejects a term that IS, or is edit-
    ///      distance-1 from, a common word;
    ///   3. `RepoTermMiner.isPhoneticallyCommon` — rejects a term whose *phonetic
    ///      skeleton* is within edit-distance-1 of a common English word's, so a mined
    ///      term can't rewrite ordinary prose in the corrector ("mining"↔"morning",
    ///      "Talkie"↔"talked", "Coralate"↔"correlate"). This third gate is what makes
    ///      the false-positive-corpus re-run pass with real repo terms loaded.
    /// Deduped case-insensitively, capped so one project's docs can't flood the
    /// corrector's global budget.
    static func correctorTerms(from docTerms: [String], limit: Int = 200,
                              termGuard: NicheTermGuard = .default) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in docTerms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let letterCount = term.filter { $0.isLetter }.count
            guard letterCount >= 4 else { continue }
            guard termGuard.isSafeToInject(term) else { continue }
            guard !RepoTermMiner.isPhoneticallyCommon(term) else { continue }
            let key = term.lowercased()
            if seen.insert(key).inserted {
                out.append(term)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Apply the snapshot to a transcript. Returns the rewritten text and the
    /// number of filenames substituted.
    static func format(_ text: String, snapshot: ProjectIndexSnapshot) -> (String, Int) {
        guard !snapshot.isEmpty, !text.isEmpty else { return (text, 0) }

        // Tokenize, splitting "library.tsx" → library · dot · tsx so a literal
        // period the recognizer inserted still matches a spoken "dot" key.
        var tokens: [(original: String, norm: String)] = []
        for raw in text.split(separator: " ", omittingEmptySubsequences: true) {
            let original = String(raw)
            let punct = CharacterSet(charactersIn: ",;:!?\"'()")
            let cleaned = original.trimmingCharacters(in: punct)
            if cleaned.contains("."), !cleaned.hasPrefix("."), !cleaned.hasSuffix(".") {
                // Preserve the leading punctuation the trim discarded, so a
                // non-match round-trips the original text unchanged.
                let lead = String(original.prefix(while: { ",;:!?\"'()".contains($0) }))
                let parts = cleaned.split(separator: ".", omittingEmptySubsequences: true)
                for (i, part) in parts.enumerated() {
                    if i > 0 { tokens.append(("dot", "dot")) }
                    let originalPart = (i == 0 ? lead : "") + String(part)
                    tokens.append((originalPart, normalizeToken(String(part))))
                }
                // Re-attach any trailing punctuation to the last sub-token.
                if let trailing = original.last, ",;:!?\"')".contains(trailing), var last = tokens.last {
                    last.original += String(trailing)
                    tokens[tokens.count - 1] = last
                }
            } else {
                tokens.append((original, normalizeToken(original)))
            }
        }

        var out: [String] = []
        var i = 0
        var replacements = 0
        let maxN = max(1, snapshot.maxKeyTokens)

        while i < tokens.count {
            var matched = false
            // Greedy: try the longest window first.
            for n in stride(from: min(maxN, tokens.count - i), through: 1, by: -1) {
                let window = tokens[i..<(i + n)]
                // An interior punctuation token (empty norm) must BLOCK a match —
                // not be silently skipped — so it isn't swallowed and words on
                // either side of it can't masquerade as adjacent.
                if window.contains(where: { $0.norm.isEmpty }) { continue }
                let windowNorm = window.map(\.norm).joined(separator: " ")
                guard !windowNorm.isEmpty, let canonical = snapshot.keyMap[windowNorm] else { continue }
                // Carry trailing punctuation from the last original token.
                let trailing = tokens[i + n - 1].original.filter { ",;:!?\"')".contains($0) }
                out.append(canonical + trailing)
                replacements += 1
                i += n
                matched = true
                break
            }
            if !matched {
                out.append(tokens[i].original)
                i += 1
            }
        }
        return (out.joined(separator: " "), replacements)
    }

    // MARK: Spoken-key generation

    /// All the ways a person might dictate `file`, normalized to lowercase
    /// space-joined token strings.
    private static func spokenKeys(for file: String) -> [String] {
        let url = URL(fileURLWithPath: file)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        let baseWords = splitWords(base).map { $0.lowercased() }
        guard !baseWords.isEmpty else { return [] }

        // Base spoken forms: "exercise library" and the contiguous "exerciselibrary".
        var baseForms: Set<String> = [baseWords.joined(separator: " ")]
        baseForms.insert(baseWords.joined())

        guard !ext.isEmpty else { return Array(baseForms) }

        // Extension spoken forms: "tsx", "t s x", and "dot …" variants.
        let extWord = ext
        let extSpelled = ext.map { String($0) }.joined(separator: " ")
        var extForms: Set<String> = [extWord, extSpelled, "dot \(extWord)", "dot \(extSpelled)"]
        // Common shorthands.
        if ext == "tsx" || ext == "jsx" { extForms.insert("dot \(ext)") }

        var keys = Set<String>()
        for b in baseForms {
            for e in extForms {
                keys.insert("\(b) \(e)")
            }
            // Also allow just the base name (no extension) for short, unique names.
            if baseWords.count >= 2 { keys.insert(b) }
        }
        return Array(keys)
    }

    /// Split a filename base into words across camelCase, snake_case, kebab, and
    /// digit boundaries: "ExerciseLibrary2" → ["Exercise","Library","2"].
    static func splitWords(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for ch in s {
            if ch == "_" || ch == "-" || ch == " " || ch == "." {
                if !current.isEmpty { words.append(current); current = "" }
                previous = ch
                continue
            }
            if let prev = previous {
                let boundary = (ch.isUppercase && (prev.isLowercase || prev.isNumber))
                    || (ch.isNumber && prev.isLetter)
                    || (ch.isLetter && prev.isNumber)
                if boundary && !current.isEmpty { words.append(current); current = "" }
            }
            current.append(ch)
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { !$0.isEmpty }
    }

    private static func normalizeToken(_ token: String) -> String {
        let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'()[]{}"))
        return stripped.lowercased()
    }
}

// MARK: - Active-file identifier mining (A11)

/// When you dictate into VS Code / Cursor / Xcode, the file you're *looking at* is the
/// one whose symbols you're most likely to speak — "exercise filter" for `exerciseFilter`,
/// a helper's name, a prop. `FileIdentifierMiner` reads that one file (bounded), pulls
/// its declared-looking identifiers, and hands the guard-safe ones to the post-hoc
/// `NicheCorrector` for the duration of that session, so a close-miss snaps to the
/// real symbol. This is the editor-focused complement to A3's repo-wide doc/git mine:
/// A3 gives you the project's vocabulary, A11 sharpens it to the file on screen.
///
/// **Pure + privacy-scoped.** `mine(path:)` is a `static func` over a path the caller
/// resolved from the user's *own* project index (`ProjectIndexStore.data.filePaths`) —
/// i.e. a file inside a folder the user explicitly picked for Vibe Coding. We never
/// discover or read a file from anywhere else: the only entry into a read is a basename
/// that was already indexed from a consented root. Every read is `try?`-guarded and
/// byte-bounded, so a vanished/huge/binary file degrades to "no terms," never a crash
/// or a latency spike.
///
/// **Honest rescue window.** The corrector joins at most TWO adjacent spoken words (plus
/// one ≤3-letter connector). An identifier that a speaker renders as three-plus words
/// (`useExerciseFilter` → "use exercise filter") is therefore beyond rescue, so we drop
/// it here rather than crowd the corrector's 300-term budget with terms it can never
/// fire on. Only identifiers whose spoken reading is ≤ 2 words survive.
enum FileIdentifierMiner {
    /// Hard cap on bytes read from the focused file. Identifiers are dense near the top
    /// (imports, the main declaration, its props/fields), and 128 KB comfortably covers
    /// any hand-written source file while bounding a machine-generated monster. Reading
    /// a prefix — not the whole file — is what keeps mining cheap enough to run inside
    /// the arming window without delaying it.
    static let maxBytes = 128 * 1024
    /// Cap on identifiers handed to the corrector from one file. Ranked by in-file
    /// frequency first, so the symbols you actually work with (declared and referenced
    /// repeatedly) win the budget over a one-off import. Small on purpose: the file on
    /// screen contributes a *focused* boost, and it must share the global 300-term
    /// corrector cap with the dictionary, graduated, and repo terms.
    static let maxTerms = 80
    /// Minimum identifier length (characters). Mirrors the corrector's own 4-letter core
    /// floor — shorter tokens carry too little signal and too much collision risk.
    static let minIdentifierLength = 4

    /// Mine the guard-safe, rescue-window-eligible identifiers of one source file.
    /// `path` MUST be a file the caller resolved from the user's project index (see the
    /// type comment) — this function does no discovery of its own. Returns [] on any
    /// read failure, an empty/binary file, or a file with no eligible identifiers.
    static func mine(path: String,
                     termGuard: NicheTermGuard = .default,
                     fileManager: FileManager = .default) -> [String] {
        guard let contents = readPrefix(path: path, maxBytes: maxBytes, fileManager: fileManager),
              !contents.isEmpty else { return [] }
        return identifiers(in: contents, termGuard: termGuard)
    }

    /// The pure extraction over already-read text (split out so tests don't need a file).
    /// Walks the text, collects identifier-shaped tokens (CamelCase / PascalCase /
    /// snake_case / camelCase, len ≥ `minIdentifierLength`), counts each one's in-file
    /// frequency, then keeps the terms that (a) split into ≤ 2 spoken words and (b) clear
    /// the three safety gates — ranked by frequency, capped at `maxTerms`.
    static func identifiers(in text: String, termGuard: NicheTermGuard = .default) -> [String] {
        // Count frequency across the file, remembering each identifier's first-seen index.
        // Keyed on the exact identifier spelling so the canonical casing we insert is the
        // one the file actually uses. The stored index is the stable tie-break, so ranking
        // needs no O(n) `firstIndex` lookups.
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var nextIndex = 0
        for token in identifierTokens(in: text) {
            if counts[token] == nil { firstSeen[token] = nextIndex; nextIndex += 1 }
            counts[token, default: 0] += 1
        }
        guard !counts.isEmpty else { return [] }

        // Rank: frequency desc, then first-seen asc (stable, deterministic — no reliance
        // on dictionary iteration order).
        let ranked = counts.keys.sorted { a, b in
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            if ca != cb { return ca > cb }
            return (firstSeen[a] ?? 0) < (firstSeen[b] ?? 0)
        }

        var out: [String] = []
        var seen = Set<String>()
        for token in ranked {
            guard isRescuable(token) else { continue }
            guard passesSafetyGates(token, termGuard: termGuard) else { continue }
            let key = token.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(token)
            if out.count >= maxTerms { break }
        }
        return out
    }

    // MARK: Extraction

    /// Every identifier-shaped run in the text. An identifier run is a maximal run of
    /// ASCII letters, digits, and underscores that begins with a letter or underscore —
    /// the lexical shape of an identifier in every language we index. Digit-led runs
    /// (`0x1F`, `42px`) and pure-punctuation are skipped. We DON'T try to parse the
    /// language; frequency ranking + the safety gates do the discriminating.
    private static func identifierTokens(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { out.append(current); current = "" }
        }
        for ch in text {
            if ch == "_" || ch.isLetter || ch.isNumber {
                // Start a token only on a letter/underscore; a digit can only extend one.
                if current.isEmpty {
                    if ch.isLetter || ch == "_" { current.append(ch) }
                    // else: leading digit — ignore, don't start a token
                } else {
                    current.append(ch)
                }
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// Whether a raw identifier is worth mining at all: long enough, and made of the
    /// distinctive shapes an identifier takes (CamelCase/PascalCase, an internal capital,
    /// or snake_case). A bare all-lowercase word ("filter", "count") is deliberately
    /// EXCLUDED — on its own it's indistinguishable from prose and is exactly the false-
    /// positive risk the corrector must avoid; such a word only becomes a term when it's
    /// PART of a multi-word identifier the speaker renders as ≤2 words (handled by
    /// `isRescuable`). All-caps constants ("MAX_LEN") are handled by the snake_case /
    /// internal-capital paths where they carry a `_`, and dropped otherwise (an all-caps
    /// acronym is rarely the jargon a user dictates and often collides with a word).
    private static func isDistinctivelyShaped(_ token: String) -> Bool {
        guard token.count >= minIdentifierLength else { return false }
        // snake_case (has an underscore and a letter).
        if token.contains("_") && token.contains(where: \.isLetter) { return true }
        // An internal capital: camelCase (useState) or PascalCase (ExerciseLibrary).
        if token.dropFirst().contains(where: { $0.isUppercase }) { return true }
        return false
    }

    /// Whether this identifier is inside the corrector's honest rescue window: its spoken
    /// reading is at most TWO words. `SpokenFileMatcher.splitWords` gives the word split
    /// the same way the rest of Vibe Coding reasons about spoken filenames, so "useState"
    /// → ["use","State"] (2, rescuable) but "useExerciseFilter" → 3 words (dropped). A
    /// single-word identifier ("Kubernetes") is also fine — the corrector rescues it as
    /// one token. We additionally require the identifier be distinctively shaped, so a
    /// two-word split of a lowercase prose bigram can't sneak in.
    static func isRescuable(_ token: String) -> Bool {
        guard isDistinctivelyShaped(token) else { return false }
        let words = SpokenFileMatcher.splitWords(token).filter { $0.contains(where: \.isLetter) }
        guard !words.isEmpty else { return false }
        return words.count <= 2
    }

    /// The safety gates, extending A3's `correctorTerms` discipline — because an
    /// auto-mined in-file identifier gets the same zero-human-confirmation treatment a
    /// repo term does, so it must clear the same bar that makes the false-positive corpus
    /// stay clean:
    ///   1. a ≥4-LETTER floor (letters only), matching `NicheCorrector.buildTargets`;
    ///   2. `NicheTermGuard.isSafeToInject` — reject a term that IS, or is edit-distance-1
    ///      from, a common word;
    ///   3. `RepoTermMiner.isPhoneticallyCommon` — reject a term whose phonetic skeleton
    ///      sits within edit-distance-1 of a common English word's, so no mined identifier
    ///      can rewrite ordinary prose in the corrector.
    ///   4. **The leading-common-word gate (A11-specific).** A two-word identifier whose
    ///      FIRST spoken word is an ordinary English word ("benchSeat" → bench…, "dataModel"
    ///      → data…, "useState" → use…) passes 1–3 — as a whole token it's neither a common
    ///      word nor phonetically near one — yet it is uniquely dangerous HERE. The
    ///      corrector rescues a spoken symbol by fusing the FIRST matched word with the
    ///      next; when that first word is common, ordinary prose that merely contains it
    ///      ("The old *bench sat* under the tree") can be fused into the identifier, because
    ///      the second prose word need only sound close to the identifier's second half.
    ///      A DISTINCTIVE leading word ("exercise", "context", "workout", "zephyr") anchors
    ///      the match to genuine intent — it almost never appears in plain prose — so
    ///      "exerciseFilter"/"contextGraph"/"workoutPlan" are kept while the prose-triggerable
    ///      ones are dropped. This mirrors the corrector's own bigram join, which is anchored
    ///      on the first word, and it is the gate the false-positive corpus with real in-file
    ///      identifiers proves. (Single-word identifiers are unaffected — no leading half to
    ///      fuse from.)
    private static func passesSafetyGates(_ token: String, termGuard: NicheTermGuard) -> Bool {
        let letters = token.filter { $0.isLetter }.count
        guard letters >= minIdentifierLength else { return false }
        guard termGuard.isSafeToInject(token) else { return false }
        guard !RepoTermMiner.isPhoneticallyCommon(token) else { return false }
        guard !leadsWithCommonWord(token, termGuard: termGuard) else { return false }
        return true
    }

    /// True when a two-word identifier's FIRST spoken word is ordinary English — the
    /// leading-common-word case (gate 4 above). Only fires on a 2-word split; a one-word
    /// identifier has no leading half to fuse a prose neighbour onto, and a ≥3-word
    /// identifier is already outside the rescue window.
    private static func leadsWithCommonWord(_ token: String, termGuard: NicheTermGuard) -> Bool {
        let words = SpokenFileMatcher.splitWords(token)
            .map { $0.lowercased().filter { c in c.isLetter } }
            .filter { !$0.isEmpty }
        guard words.count == 2, let first = words.first else { return false }
        return isCommonWord(first, termGuard: termGuard)
    }

    /// Whether a single lowercase word is ordinary English: present in either shipped
    /// common-word set (`NicheTermGuard`'s function-word basis or `RepoTermMiner`'s
    /// everyday-vocabulary list), or within edit-distance-1 of a `NicheTermGuard` common
    /// word (the same acoustic-neighbour test the guard itself uses, so a lightly-inflected
    /// "benches" is still caught). Words < 3 letters are treated as common — too short to
    /// be distinctive jargon and a poor anchor.
    private static func isCommonWord(_ word: String, termGuard: NicheTermGuard) -> Bool {
        guard word.count >= 3 else { return true }
        if termGuard.commonWords.contains(word) { return true }
        if RepoTermMiner.commonEnglishWords.contains(word) { return true }
        for common in termGuard.commonWords where abs(common.count - word.count) <= 1 {
            if NicheTermGuard.isWithinEditDistance1(word, common) { return true }
        }
        return false
    }

    // MARK: Window-title → indexed-file resolution

    /// Resolve a window-title filename to the full path of an indexed file, or nil.
    /// PURE (the `filePaths` map is passed in). Pulls candidate filename tokens out of the
    /// title — a token that looks like `Name.ext` — and returns the first one present in
    /// the index (lowercased-basename keyed, matching how the scanner stored it). Editors
    /// put the open file's name in the title ("ExerciseLibrary.tsx — myapp", "index.ts",
    /// "App.swift — Edited"), so this is a cheap, reliable hook. A title with no filename
    /// token, or a filename we didn't index, yields nil — the caller then just skips
    /// active-file mining (silent degrade to A3 behavior).
    static func resolvePath(fromWindowTitle title: String?, filePaths: [String: String]) -> String? {
        guard let title, !title.isEmpty, !filePaths.isEmpty else { return nil }
        for candidate in filenameCandidates(in: title) {
            if let path = filePaths[candidate.lowercased()] { return path }
        }
        return nil
    }

    /// Filename-shaped tokens in a window title, in order. A candidate is a token of the
    /// form `base.ext` where `ext` is 1–5 letters and `base` is a non-empty run of
    /// identifier characters — i.e. what a source filename looks like. Splits the title on
    /// whitespace and the separators editors use (dashes, bullets, pipes, path slashes),
    /// so both "ExerciseLibrary.tsx — repo" and "~/dev/repo/ExerciseLibrary.tsx" surface
    /// the bare "ExerciseLibrary.tsx".
    static func filenameCandidates(in title: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let tokens = title.split { ch in
            ch.isWhitespace || "•|—–/\\()[]{}<>\"'`,:;!?".contains(ch)
        }
        for raw in tokens {
            // A token may still carry a leading path-ish prefix if there were no slashes
            // to split on; take the last path component defensively.
            let token = String(raw)
            let bare = token.split(separator: "/").last.map(String.init) ?? token
            guard looksLikeFilename(bare) else { continue }
            if seen.insert(bare.lowercased()).inserted { out.append(bare) }
        }
        return out
    }

    /// True if `token` has the shape `base.ext` with a 1–5 letter extension and a base of
    /// identifier characters (letters, digits, `_`, `-`, `.`). Deliberately loose on the
    /// base (config files like `vite.config.ts` have interior dots) but strict on the
    /// extension so a sentence-ending word ("done.") or a version ("1.2") isn't mistaken
    /// for a file.
    private static func looksLikeFilename(_ token: String) -> Bool {
        guard let dot = token.lastIndex(of: "."), dot != token.startIndex else { return false }
        let ext = token[token.index(after: dot)...]
        guard (1...5).contains(ext.count), ext.allSatisfy(\.isLetter) else { return false }
        let base = token[..<dot]
        guard !base.isEmpty else { return false }
        return base.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    // MARK: Bounded file read

    /// Read at most `maxBytes` of a file without pulling the whole thing into memory.
    /// `try?` throughout: an unreadable/vanished file yields nil (the caller degrades
    /// silently). Decoded leniently as UTF-8. We don't trim to a token boundary the way
    /// the doc miner does — a partial final identifier is harmless here (it's just one
    /// candidate among the file's many, and frequency ranking sidelines a one-off).
    private static func readPrefix(path: String, maxBytes: Int, fileManager: FileManager) -> String? {
        let url = URL(fileURLWithPath: path)
        // Confirm it's a regular file before opening — never follow a directory/device.
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = (try? handle.read(upToCount: maxBytes)) ?? nil, !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Per-(path, mtime) cache of a file's mined identifiers, so re-focusing the same
/// unchanged file across sessions doesn't re-read + re-parse it. An `actor` because
/// dictation sessions can overlap the tail of a previous one; the cache is tiny
/// (a handful of recently-focused files) and bounded so it can't grow without limit.
/// Invalidation is by modification time: a saved edit changes the mtime, so the next
/// mine re-reads. Off-main by construction (it's an actor) — callers `await` it from
/// the detached mining Task, never on the main actor's hot path.
actor FileIdentifierCache {
    static let shared = FileIdentifierCache()

    private struct Entry { let mtime: Date?; let terms: [String] }
    private var entries: [String: Entry] = [:]
    private var lru: [String] = []   // most-recent last
    /// Small: only the last few focused files matter. Bounds memory to a trivial amount.
    private let capacity = 16

    /// Mined identifiers for `path`, from cache when the file's mtime is unchanged, else
    /// freshly mined and cached. `path` must already be an index-resolved file (see
    /// `FileIdentifierMiner`). Returns [] on any read failure.
    func terms(forPath path: String, fileManager: FileManager = .default) -> [String] {
        let mtime = Self.modificationDate(ofPath: path, fileManager: fileManager)
        if let hit = entries[path], hit.mtime == mtime {
            touch(path)
            return hit.terms
        }
        let mined = FileIdentifierMiner.mine(path: path, fileManager: fileManager)
        entries[path] = Entry(mtime: mtime, terms: mined)
        touch(path)
        evictIfNeeded()
        return mined
    }

    private func touch(_ path: String) {
        lru.removeAll { $0 == path }
        lru.append(path)
    }

    private func evictIfNeeded() {
        while lru.count > capacity, let oldest = lru.first {
            lru.removeFirst()
            entries[oldest] = nil
        }
    }

    private static func modificationDate(ofPath path: String, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
