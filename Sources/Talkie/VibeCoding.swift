import Foundation

// MARK: - Project index (auto-scan a folder you pick)

/// Persisted snapshot of a scanned project: which folder, when, and the files
/// found. Spoken filenames are matched against this so "exercise library dot
/// tsx" snaps to the real `ExerciseLibrary.tsx`.
struct ProjectIndexData: Codable {
    var folderPath: String?
    var scannedAtUnix: Double?
    var files: [String] = []      // basenames, e.g. "ExerciseLibrary.tsx"
    var symbols: [String] = []    // bare identifiers, e.g. "ExerciseLibrary"
}

/// An immutable, Sendable view of the index used off the main actor during
/// post-processing: the spoken→canonical map plus phrases to bias the recognizer.
struct ProjectIndexSnapshot: Sendable {
    var keyMap: [String: String]   // normalized spoken key → canonical filename
    var maxKeyTokens: Int
    var biasPhrases: [String]      // filenames + base words for contextual biasing

    static let empty = ProjectIndexSnapshot(keyMap: [:], maxKeyTokens: 0, biasPhrases: [])
    var isEmpty: Bool { keyMap.isEmpty }
}

@MainActor
final class ProjectIndexStore: ObservableObject {
    @Published private(set) var data = ProjectIndexData()
    @Published private(set) var isScanning = false
    /// Rebuilt whenever `data` changes; handed to the formatter each dictation.
    @Published private(set) var snapshot = ProjectIndexSnapshot.empty

    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("project_index.json")
        load()
        rebuildSnapshot()
    }

    var folderName: String? {
        guard let p = data.folderPath else { return nil }
        return URL(fileURLWithPath: p).lastPathComponent
    }
    var fileCount: Int { data.files.count }
    var lastScanned: Date? { data.scannedAtUnix.map { Date(timeIntervalSince1970: $0) } }

    func setFolder(_ url: URL) {
        data.folderPath = url.path
        save()
        Task { await rescan() }
    }

    func clear() {
        data = ProjectIndexData()
        save()
        rebuildSnapshot()
    }

    /// Walk the chosen folder off the main actor and refresh the file list.
    func rescan() async {
        guard let path = data.folderPath else { return }
        isScanning = true
        let result = await Task.detached(priority: .utility) {
            ProjectScanner.scan(root: URL(fileURLWithPath: path))
        }.value
        data.files = result.files
        data.symbols = result.symbols
        data.scannedAtUnix = Date().timeIntervalSince1970
        isScanning = false
        save()
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        snapshot = SpokenFileMatcher.buildSnapshot(files: data.files, symbols: data.symbols)
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

    struct Result { var files: [String]; var symbols: [String] }

    static func scan(root: URL) -> Result {
        var files: [String] = []
        var symbolSet = Set<String>()
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return Result(files: [], symbols: []) }

        var seen = Set<String>()
        for case let url as URL in walker {
            if files.count >= maxFiles { break }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if ignoredDirs.contains(name) { walker.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard codeExtensions.contains(ext) else { continue }
            guard seen.insert(name.lowercased()).inserted else { continue }
            files.append(name)
            let base = url.deletingPathExtension().lastPathComponent
            if base.count >= 3 { symbolSet.insert(base) }
        }
        return Result(files: files, symbols: Array(symbolSet))
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
    static func buildSnapshot(files: [String], symbols: [String]) -> ProjectIndexSnapshot {
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
            biasPhrases: Array(bias.prefix(250))
        )
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
