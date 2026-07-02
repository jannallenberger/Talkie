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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case folderPaths, folderPath, scannedAtUnix, files, symbols, docTerms
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folderPaths, forKey: .folderPaths)
        try c.encodeIfPresent(scannedAtUnix, forKey: .scannedAtUnix)
        try c.encode(files, forKey: .files)
        try c.encode(symbols, forKey: .symbols)
        try c.encode(docTerms, forKey: .docTerms)
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
        data.scannedAtUnix = Date().timeIntervalSince1970
        isScanning = false
        save()
        rebuildSnapshot()
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
                guard seen.insert(f.lowercased()).inserted else { continue }
                files.append(f)
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
        return Result(files: files, symbols: Array(symbolSet), docTerms: docTerms)
    }

    static func scan(root: URL) -> Result {
        var files: [String] = []
        var symbolSet = Set<String>()
        var docFiles: [URL] = []
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
            guard seen.insert(name.lowercased()).inserted else { continue }
            files.append(name)
            let base = url.deletingPathExtension().lastPathComponent
            if base.count >= 3 { symbolSet.insert(base) }
        }
        return Result(files: files, symbols: Array(symbolSet), docTerms: [], docFiles: docFiles)
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
