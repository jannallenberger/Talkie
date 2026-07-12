import Foundation

// MARK: - Project index (auto-scan a folder you pick)

/// One scanned project root's index: the files/symbols/docs it holds, kept SEPARATE
/// from every other root (A10). This is what lets a spoken filename scope to the repo
/// the terminal is actually in — a worktree `Talkie-B` snaps to *its* casing and terms,
/// not to `Talkie-A`'s — instead of everyone merging into one bucket where the first
/// folder wins colliding basenames.
struct ProjectRootIndex: Codable {
    var files: [String] = []        // basenames, e.g. "ExerciseLibrary.tsx"
    var symbols: [String] = []      // bare identifiers, e.g. "ExerciseLibrary"
    /// Jargon mined from THIS root's docs (CLAUDE.md/README/docs) + git branch and
    /// commit-message words (A3). Feeds the post-hoc niche corrector so "cloud MD"
    /// snaps to `CLAUDE.md` when you dictate in this project. Deduped, capped.
    var docTerms: [String] = []
    /// Lowercased basename → its full on-disk path (A11), for THIS root only. Lets a
    /// window-title filename ("ExerciseLibrary.tsx — …") resolve to the real file whose
    /// identifiers we then mine for that session.
    var filePaths: [String: String] = [:]

    init() {}
    init(files: [String], symbols: [String], docTerms: [String], filePaths: [String: String]) {
        self.files = files
        self.symbols = symbols
        self.docTerms = docTerms
        self.filePaths = filePaths
    }

    /// Lowercased basename → path RELATIVE to `root` (G10), derived from the absolute
    /// `filePaths` this bucket already stores. In a terminal we want to insert the
    /// repo-relative path the shell + Claude Code actually consume (`Sources/Views/
    /// ExerciseLibrary.tsx`), not the bare basename. We DON'T persist a second map: the
    /// absolute paths are already here per-root, and the root is the bucket's own key,
    /// so the relative form is a cheap pure derivation (see `SpokenFileMatcher.relativePath`,
    /// which standardizes both sides so a `/private/var…` file path still strips against a
    /// `/var…` root key on macOS). A file that somehow isn't under `root` is dropped, so
    /// the caller falls back to the basename for it — never an absolute or wrong path.
    func relativeFilePaths(root: URL) -> [String: String] {
        var out: [String: String] = [:]
        for (key, absolute) in filePaths {
            if let rel = SpokenFileMatcher.relativePath(ofAbsolute: absolute, underRoot: root) {
                out[key] = rel
            }
        }
        return out
    }
}

/// Persisted snapshot of a scanned project: which folders, when, and the files
/// found in each of them. Spoken filenames are matched against this so
/// "exercise library dot tsx" snaps to the real `ExerciseLibrary.tsx`.
///
/// **Per-root (A10).** The index is now keyed BY root (`roots[path]`), so dictating in
/// one checkout scopes to that checkout's files/terms rather than a global merge. The
/// merged view (first-folder-wins across `folderPaths` order) is still derived on demand
/// as the FALLBACK snapshot for when we can't tell which root you're in.
///
/// **Back-compat / migration.** Older builds wrote FLAT top-level `files`/`symbols`/
/// `docTerms`/`filePaths` merged across all folders (there was no per-root split). We
/// still decode those tolerantly into `legacyMerged`; the merged accessors fold it in so
/// an old `project_index.json` keeps working (filename snapping, the merged fallback)
/// with zero loss until the next rescan repopulates the per-root `roots` map — at which
/// point `legacyMerged` is cleared. Decode round-trips old files by design (see the
/// migration test); we never throw on a legacy file.
struct ProjectIndexData: Codable {
    var folderPaths: [String] = []  // the project roots, in the order picked
    var scannedAtUnix: Double?
    /// Per-root buckets, keyed by absolute root path. Written by `rescan`. A root in
    /// `folderPaths` with no entry here simply hasn't been scanned yet (or was scanned
    /// by an older build — see `legacyMerged`).
    var roots: [String: ProjectRootIndex] = [:]
    /// The pre-A10 merged arrays, decoded from an older on-disk file. Non-empty ONLY
    /// right after upgrading from a flat `project_index.json`; a rescan clears it once
    /// the per-root buckets are filled. Folded into the merged accessors so the global
    /// fallback still works before that first rescan.
    var legacyMerged = ProjectRootIndex()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case folderPaths, folderPath, scannedAtUnix, roots
        // Legacy flat fields (pre-A10) — decoded, never re-encoded.
        case files, symbols, docTerms, filePaths
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
        roots = try c.decodeIfPresent([String: ProjectRootIndex].self, forKey: .roots) ?? [:]
        // Migration: fold any legacy top-level merged arrays into `legacyMerged`, so an
        // old flat file round-trips without loss until the next rescan. If the new `roots`
        // map is already present we still keep the legacy arrays (harmless — the merged
        // accessors de-dup), but in practice a file has one shape or the other.
        legacyMerged = ProjectRootIndex(
            files: try c.decodeIfPresent([String].self, forKey: .files) ?? [],
            symbols: try c.decodeIfPresent([String].self, forKey: .symbols) ?? [],
            docTerms: try c.decodeIfPresent([String].self, forKey: .docTerms) ?? [],
            filePaths: try c.decodeIfPresent([String: String].self, forKey: .filePaths) ?? [:]
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folderPaths, forKey: .folderPaths)
        try c.encodeIfPresent(scannedAtUnix, forKey: .scannedAtUnix)
        try c.encode(roots, forKey: .roots)
        // We deliberately DON'T re-encode the legacy flat fields: once we've loaded and
        // (eventually) rescanned, the per-root `roots` map is authoritative. Persisting a
        // legacy file that still carries un-rescanned data preserves it via `legacyMerged`
        // only in memory; the moment a rescan runs, the file is rewritten in the new shape.
        // To avoid *losing* legacy data if the app quits before any rescan, we round-trip
        // it back out under the legacy keys when (and only when) `roots` is still empty.
        if roots.isEmpty, !legacyMerged.files.isEmpty || !legacyMerged.docTerms.isEmpty {
            try c.encode(legacyMerged.files, forKey: .files)
            try c.encode(legacyMerged.symbols, forKey: .symbols)
            try c.encode(legacyMerged.docTerms, forKey: .docTerms)
            try c.encode(legacyMerged.filePaths, forKey: .filePaths)
        }
    }

    // MARK: - Merged (fallback) accessors

    /// The roots that actually have an index, in `folderPaths` order (so "first folder
    /// wins" a colliding basename stays deterministic and matches pre-A10 behavior).
    /// Includes the legacy merged bucket LAST, under a sentinel path, so its files are a
    /// lower-priority fallback than any freshly-scanned root.
    private var orderedBuckets: [ProjectRootIndex] {
        var out: [ProjectRootIndex] = []
        for path in folderPaths {
            if let bucket = roots[path] { out.append(bucket) }
        }
        // Any scanned root not in folderPaths (shouldn't happen, but be safe).
        for (path, bucket) in roots where !folderPaths.contains(path) { out.append(bucket) }
        if !legacyMerged.files.isEmpty || !legacyMerged.docTerms.isEmpty || !legacyMerged.filePaths.isEmpty {
            out.append(legacyMerged)
        }
        return out
    }

    /// First-folder-wins de-duped basenames across every bucket — the merged file list
    /// that feeds the GLOBAL fallback snapshot (used when we can't resolve which root
    /// you're in) and the Settings file count.
    var mergedFiles: [String] {
        var files: [String] = []
        var seen = Set<String>()
        for bucket in orderedBuckets {
            for f in bucket.files where seen.insert(f.lowercased()).inserted { files.append(f) }
        }
        return files
    }

    var mergedSymbols: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for bucket in orderedBuckets {
            for s in bucket.symbols where seen.insert(s.lowercased()).inserted { out.append(s) }
        }
        return out
    }

    var mergedDocTerms: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for bucket in orderedBuckets {
            for t in bucket.docTerms where seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }

    /// First-folder-wins merged basename→path map — the FALLBACK for title→file
    /// resolution when the active root is unknown. Per-root maps are preferred by the
    /// caller; this only backstops the ambiguous case.
    var mergedFilePaths: [String: String] {
        var out: [String: String] = [:]
        for bucket in orderedBuckets {
            for (k, v) in bucket.filePaths where out[k] == nil { out[k] = v }
        }
        return out
    }

    /// First-folder-wins merged basename → ROOT-RELATIVE path (G10) — feeds the merged
    /// fallback snapshot's `pathMap` so a terminal still gets repo-relative paths even
    /// when we couldn't resolve which checkout you're in (the scoped `snapshot(for:)`
    /// path is preferred). Unlike `mergedFilePaths`, this must strip each file against ITS
    /// OWN root, so we walk the per-root buckets (in `folderPaths` order — first folder
    /// wins a colliding basename, same rule as everywhere else) and derive each root's
    /// relative map. The legacy merged bucket is deliberately EXCLUDED here: its absolute
    /// paths carry no per-root structure to strip against, so a pre-A10 file simply
    /// contributes no relative paths until the one-shot migration rescan repopulates the
    /// per-root map — the caller then falls back to the bare basename, never a wrong path.
    var mergedRelativeFilePaths: [String: String] {
        var out: [String: String] = [:]
        func admit(root: String, bucket: ProjectRootIndex) {
            let rel = bucket.relativeFilePaths(root: URL(fileURLWithPath: root))
            for (k, v) in rel where out[k] == nil { out[k] = v }
        }
        for path in folderPaths {
            if let bucket = roots[path] { admit(root: path, bucket: bucket) }
        }
        for (path, bucket) in roots where !folderPaths.contains(path) { admit(root: path, bucket: bucket) }
        return out
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
    /// Canonical basename → repo-relative path (G10). Keyed by the SAME canonical
    /// filename `keyMap`'s values hold, so at a match the formatter can swap the bare
    /// basename for `Sources/Views/ExerciseLibrary.tsx` when `preferPaths` is on (a
    /// terminal). Empty for a basename we couldn't place under its root (or a legacy
    /// pre-A10 index before its migration rescan), in which case the formatter keeps the
    /// basename — so paths are strictly an ENRICHMENT, never a way to emit a wrong string.
    /// Derived, never fed to the recognizer as a bias phrase (`biasPhrases` is unchanged).
    var pathMap: [String: String] = [:]

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
    private var scanTask: Task<[String: ProjectRootIndex], Never>?

    // MARK: Auto (index-on-first-sight) roots — A10

    /// Paths of roots auto-indexed on first sight (a detected terminal cwd we scanned but
    /// the user never pinned). Kept SEPARATE from `folderPaths` so they're session-visible
    /// but never persisted — `save()` writes only pinned roots. LRU-ordered (most-recent
    /// last) and capped at `autoRootCap`, so visiting many checkouts across a session can't
    /// grow the in-memory index without bound.
    private var autoRootOrder: [String] = []
    /// Auto-root ceiling. ~8 recently-visited checkouts is plenty for the parallel-worktree
    /// workflow; older ones are evicted (their bucket dropped) as new ones arrive.
    private let autoRootCap = 8
    /// Paths with an auto-scan currently in flight, so a rapid re-focus doesn't kick off a
    /// second walk of the same root.
    private var autoScanInFlight: Set<String> = []

    /// The app injects nothing (defaults to the shared support-dir file); tests pass a
    /// temp `fileURL` so a scan never touches — or clobbers — the real project_index.json.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppPaths.supportDirectory().appendingPathComponent("project_index.json")
        load()
        rebuildSnapshot()
        // G10 migration: a legacy pre-A10 `project_index.json` stored a flat merged
        // `filePaths` with NO per-root structure, so we can't derive repo-relative paths
        // from it — `mergedRelativeFilePaths` skips the legacy blob by design. If we loaded
        // such a file (folders pinned, but the per-root `roots` map is empty), kick off ONE
        // rescan to repopulate the per-root buckets; once it lands, `rebuildSnapshot` picks
        // up the relative paths and `legacyMerged` is cleared (see `rescan`). Until then the
        // snapshot we just built still snaps basenames from the legacy blob — paths are the
        // only thing missing, never matching itself, so nothing regresses mid-migration.
        // This reuses A10's existing `rescan` (no second migration path); a new-shape file
        // already has per-root buckets and needs no rescan (relative paths derive on load).
        if data.roots.isEmpty, !data.folderPaths.isEmpty {
            Task { await rescan() }
        }
    }

    /// The chosen project roots, in the order they were added.
    var folders: [ProjectFolder] { data.folderPaths.map { ProjectFolder(path: $0) } }
    var hasFolders: Bool { !data.folderPaths.isEmpty }
    var fileCount: Int { data.mergedFiles.count }
    var lastScanned: Date? { data.scannedAtUnix.map { Date(timeIntervalSince1970: $0) } }

    /// Add a project root (ignoring duplicates), then rescan everything.
    func addFolder(_ url: URL) { addFolders([url]) }

    /// Add several project roots at once (ignoring duplicates) and rescan a
    /// single time, so picking five folders doesn't kick off five scans. Paths are
    /// standardized so a pinned root's key matches the scanner's bucket key (and so
    /// promoting a previously auto-indexed root de-dups correctly).
    func addFolders(_ urls: [URL]) {
        var added = false
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !data.folderPaths.contains(path) else { continue }
            data.folderPaths.append(path)
            added = true
            // Promoting an auto root to pinned: it's no longer an evictable auto root; the
            // upcoming rescan re-indexes it authoritatively (and will persist it).
            autoRootOrder.removeAll { $0 == path }
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
        // Clear wipes everything, auto roots included; drop their bookkeeping too so a
        // stale LRU entry can't resurrect an evicted bucket.
        autoRootOrder = []
        autoScanInFlight = []
        isScanning = false
        save()
        rebuildSnapshot()
    }

    /// Walk every chosen folder off the main actor, PER ROOT, and rebuild the index.
    /// With no folders left, the index empties. A generation token makes overlapping
    /// scans safe: only the latest one may write its result. Each root's files/terms
    /// land in its OWN bucket (A10) so `snapshot(for:)` can scope to a single checkout;
    /// the merged fallback snapshot is rebuilt from all of them.
    func rescan() async {
        scanGeneration += 1
        let generation = scanGeneration
        // Cancel any walk still running for a previous folder set before kicking
        // off the new one, so two rescans in quick succession don't both grind the
        // disk. (Retaining + cancelling the Task is what makes `Task.isCancelled`
        // fire inside the detached walk.)
        scanTask?.cancel()
        let paths = data.folderPaths
        // Auto (first-sight) roots survive a pinned rescan — a worktree you were just
        // dictating into shouldn't vanish because you pinned an unrelated folder. We
        // carry their buckets across and re-attach them after the pinned scan lands.
        let carriedAuto = autoRootBuckets()
        guard !paths.isEmpty else {
            scanTask = nil
            data.roots = carriedAuto
            data.legacyMerged = ProjectRootIndex()
            data.scannedAtUnix = nil
            isScanning = false
            save()
            rebuildSnapshot()
            return
        }
        isScanning = true
        let task = Task.detached(priority: .utility) {
            ProjectScanner.scanPerRoot(roots: paths.map { URL(fileURLWithPath: $0) })
        }
        scanTask = task
        let result = await task.value
        // A newer change/scan superseded us — drop this stale result untouched and
        // let the newest scan settle `isScanning`.
        guard generation == scanGeneration else { return }
        scanTask = nil
        // Pinned scan results are authoritative for pinned roots; re-attach the carried
        // auto roots UNLESS the same path was just pinned (then the pinned result wins).
        var merged = result
        for (path, bucket) in carriedAuto where merged[path] == nil { merged[path] = bucket }
        data.roots = merged
        // Keep the LRU list consistent with what's actually present as an auto root (a
        // path just promoted to pinned is no longer an auto root).
        autoRootOrder = autoRootOrder.filter { data.roots[$0] != nil && !data.folderPaths.contains($0) }
        // The per-root buckets are now authoritative; drop the migrated legacy blob so it
        // can't shadow a freshly-scanned root or get re-persisted.
        data.legacyMerged = ProjectRootIndex()
        data.scannedAtUnix = Date().timeIntervalSince1970
        isScanning = false
        save()
        rebuildSnapshot()
    }

    /// The buckets of the current auto (first-sight) roots, keyed by path — the ones NOT
    /// pinned. Used to carry auto roots across a pinned rescan (which rebuilds `data.roots`).
    private func autoRootBuckets() -> [String: ProjectRootIndex] {
        var out: [String: ProjectRootIndex] = [:]
        for path in autoRootOrder where !data.folderPaths.contains(path) {
            if let bucket = data.roots[path] { out[path] = bucket }
        }
        return out
    }

    /// Resolve a window-title filename to the real on-disk path of an indexed file, or
    /// nil (A11). Read on the main actor at `beginDictation`, then handed as a plain
    /// `String` into the off-main miner. Prefers the ACTIVE root's own basename map when
    /// one is given (A10 — so a title filename resolves to the file in *this* checkout),
    /// falling back to the merged map when the root is unknown/unscoped. Returns nil for a
    /// title with no filename token or a filename we didn't index — the caller then simply
    /// skips active-file mining.
    func resolveIndexedFilePath(forWindowTitle title: String?, root: URL? = nil) -> String? {
        if let root, let bucket = data.roots[root.standardizedFileURL.path] {
            if let hit = FileIdentifierMiner.resolvePath(fromWindowTitle: title, filePaths: bucket.filePaths) {
                return hit
            }
        }
        return FileIdentifierMiner.resolvePath(fromWindowTitle: title, filePaths: data.mergedFilePaths)
    }

    /// The scoped snapshot for a single resolved root (A10), or nil if that root has no
    /// index yet. `beginDictation` uses this to scope filename snapping + repo terms to
    /// the checkout the terminal is actually in; when it returns nil (unknown/ambiguous
    /// root, or a brand-new root still scanning) the caller falls back to the merged
    /// global `snapshot` — never a wrong-repo scope.
    func snapshot(for root: URL) -> ProjectIndexSnapshot? {
        guard let bucket = data.roots[root.standardizedFileURL.path] else { return nil }
        // G10: derive this root's basename→relative-path map so a terminal target can
        // insert the repo-relative path. Scoped to THIS checkout, so the relative paths are
        // unambiguous (no cross-root first-wins needed here).
        return SpokenFileMatcher.buildSnapshot(files: bucket.files, symbols: bucket.symbols,
                                               docTerms: bucket.docTerms,
                                               filePaths: bucket.relativeFilePaths(root: root))
    }

    /// Index a detected-but-unpinned root in the background (A10 index-on-first-sight), so a
    /// worktree Jann just spun up is scoped within a dictation or two WITHOUT him having to
    /// add a folder chip. The root's bucket lands in `data.roots` but the path is tracked
    /// as an AUTO root (LRU-capped, never written to `project_index.json`) — so the index
    /// doesn't accumulate every directory ever visited. A no-op when the root is already
    /// indexed (pinned or auto), or a scan for it is already in flight. Utility QoS, single
    /// root, so it never contends with a running build (the parallel-session use case).
    func indexRootOnFirstSight(_ root: URL) {
        let path = root.standardizedFileURL.path
        guard data.roots[path] == nil else {           // already have an index for it
            if autoRootOrder.contains(path) { touchAutoRoot(path) }  // keep it warm in the LRU
            return
        }
        guard autoScanInFlight.insert(path).inserted else { return }  // scan already running
        // Snapshot the generation so a pinned rescan/clear that lands AFTER this walk
        // (bumping the generation) causes us to drop our stale result. We deliberately do
        // NOT cancel `scanTask` — that Task is the user's authoritative pinned rescan; a
        // best-effort first-sight scan must never abort it. Both run at utility QoS.
        let generation = scanGeneration
        Task { [weak self] in
            let bucket = await Task.detached(priority: .utility) {
                ProjectScanner.indexOne(root: root)
            }.value
            guard let self else { return }
            self.autoScanInFlight.remove(path)
            // A pin/clear/rescan (which bumps the generation) happened while we walked —
            // drop this result so we never clobber authoritative state.
            guard generation == self.scanGeneration else { return }
            guard self.data.roots[path] == nil, !self.data.folderPaths.contains(path) else { return }
            self.data.roots[path] = bucket
            self.touchAutoRoot(path)
            self.evictAutoRootsIfNeeded()
            // Auto roots are NOT persisted — `save()` strips them — so no disk write here.
            self.rebuildSnapshot()
        }
    }

    /// Mark an auto root most-recently-used (LRU: most-recent last).
    private func touchAutoRoot(_ path: String) {
        autoRootOrder.removeAll { $0 == path }
        autoRootOrder.append(path)
    }

    /// Evict the oldest auto roots (and drop their in-memory buckets) once we exceed the
    /// cap, so the auto-index footprint stays bounded across a long parallel-session day.
    private func evictAutoRootsIfNeeded() {
        while autoRootOrder.count > autoRootCap, let oldest = autoRootOrder.first {
            autoRootOrder.removeFirst()
            // Only drop it if it's still an auto root (a pin would have removed it from the
            // order list already).
            if !data.folderPaths.contains(oldest) { data.roots[oldest] = nil }
        }
    }

    private func rebuildSnapshot() {
        // G10: the merged fallback snapshot also carries repo-relative paths (first-folder-
        // wins across roots, each file stripped against its own root), so a terminal still
        // gets paths when we couldn't resolve which checkout you're in.
        snapshot = SpokenFileMatcher.buildSnapshot(files: data.mergedFiles, symbols: data.mergedSymbols,
                                                   docTerms: data.mergedDocTerms,
                                                   filePaths: data.mergedRelativeFilePaths)
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(ProjectIndexData.self, from: raw) else { return }
        data = decoded
    }

    private func save() {
        // Persist ONLY pinned roots — the ones the user picked (in `folderPaths`). Auto
        // roots (index-on-first-sight) are deliberately kept out of the file so
        // project_index.json doesn't accumulate every directory ever visited across a
        // parallel-session day; they live in memory for this run only. We snapshot `data`,
        // drop any bucket whose path isn't pinned, and encode that.
        var persisted = data
        persisted.roots = data.roots.filter { data.folderPaths.contains($0.key) }
        guard let raw = try? JSONEncoder().encode(persisted) else { return }
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

    /// Scan several roots into SEPARATE per-root buckets (A10). Same per-root walk + git/
    /// doc mining `scanAll` does, but each root's files/symbols/docTerms/filePaths stay in
    /// their own `ProjectRootIndex` — no cross-root merge, so two checkouts with the same
    /// basenames don't collide. Keyed by the root's standardized path (the same key
    /// `data.roots` and `snapshot(for:)` use). Honors cancellation between roots. Each root
    /// is independently capped by the same `maxFiles`/`maxDocTerms` limits as the merge.
    static func scanPerRoot(roots: [URL]) -> [String: ProjectRootIndex] {
        var out: [String: ProjectRootIndex] = [:]
        for root in roots {
            if Task.isCancelled { break }
            let bucket = indexOne(root: root)
            out[root.standardizedFileURL.path] = bucket
        }
        return out
    }

    /// Build one root's bucket: the file walk plus this root's git + doc jargon mine.
    /// Factored out of `scanAll`'s per-root loop body so `scanPerRoot` and the merged
    /// `scanAll` share exactly one mining path.
    static func indexOne(root: URL) -> ProjectRootIndex {
        let r = scan(root: root)
        var docTerms: [String] = []
        var docSeen = Set<String>()
        func admitTerms(_ terms: [String]) {
            for t in terms where docTerms.count < maxDocTerms {
                if docSeen.insert(t.lowercased()).inserted { docTerms.append(t) }
            }
        }
        if !Task.isCancelled {
            admitTerms(RepoTermMiner.mineGit(root: root))
            for docURL in r.docFiles.prefix(maxDocFiles) {
                if Task.isCancelled { break }
                if docTerms.count >= maxDocTerms { break }
                guard let contents = readPrefix(of: docURL, maxBytes: maxDocBytes) else { continue }
                admitTerms(RepoTermMiner.mineMarkdown(contents, maxBytes: maxDocBytes))
            }
        }
        return ProjectRootIndex(files: r.files, symbols: r.symbols,
                                docTerms: docTerms, filePaths: r.filePaths)
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
    ///
    /// `filePaths` (G10) is an OPTIONAL lowercased-basename → repo-relative-path map. When
    /// present, each matchable file's canonical basename is paired with its relative path
    /// in `pathMap`, so a terminal target can insert `Sources/Views/ExerciseLibrary.tsx`
    /// instead of the bare name. It never affects `keyMap`, `biasPhrases`, or matching —
    /// paths are purely a downstream emit choice — so callers that don't have (or don't
    /// want) paths simply omit it and behavior is exactly as before.
    static func buildSnapshot(files: [String], symbols: [String],
                             docTerms: [String] = [],
                             filePaths: [String: String] = [:]) -> ProjectIndexSnapshot {
        var keyMap: [String: String] = [:]
        var maxTokens = 0
        var bias = Set<String>()
        var pathMap: [String: String] = [:]

        for file in files {
            for key in spokenKeys(for: file) {
                let tokenCount = key.split(separator: " ").count
                guard tokenCount > 0 else { continue }
                // First file scanned wins a colliding spoken key (collisions are rare).
                if keyMap[key] == nil { keyMap[key] = file }
                maxTokens = max(maxTokens, tokenCount)
            }
            bias.insert(file)
            // G10: pair this file's canonical basename with its repo-relative path (keyed
            // on the lowercased basename the scanner stored). Missing ⇒ no pathMap entry,
            // so the formatter keeps the basename for it.
            if let rel = filePaths[file.lowercased()] { pathMap[file] = rel }
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
            correctorTerms: correctorTerms(from: docTerms),
            pathMap: pathMap
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
    ///      "Talkie"↔"talked", "GitHub"↔"get hub"). This third gate is what makes
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
    ///
    /// `preferPaths` (G10) makes a match emit the file's REPO-RELATIVE path
    /// (`Sources/Views/ExerciseLibrary.tsx`) instead of the bare basename — what a shell
    /// and Claude Code actually want. Callers pass `true` only for a terminal target; an
    /// editor keeps getting the basename (`false`, the default). The emitted string still
    /// carries any trailing punctuation, and a file with no path entry falls back to the
    /// basename, so a non-match round-trips byte-identically under `preferPaths` too.
    static func format(_ text: String, snapshot: ProjectIndexSnapshot,
                       preferPaths: Bool = false) -> (String, Int) {
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
                // G10: in a terminal, emit the repo-relative path when we have one for this
                // basename; otherwise (editor, or a basename with no path) keep the basename.
                // Trailing punctuation carries either way.
                let emitted = preferPaths ? (snapshot.pathMap[canonical] ?? canonical) : canonical
                out.append(emitted + trailing)
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

    /// The path of `absolute` RELATIVE to `root` (G10), or nil when `absolute` isn't under
    /// `root`. PURE + POSIX (`/`-separated) — the relative path is what we insert into a
    /// terminal, and shells/Claude Code use forward slashes.
    ///
    /// We standardize BOTH sides before comparing because the two come from different
    /// sources and can disagree on the `/private` prefix on macOS: the scanner stores the
    /// enumerator's `url.path` (which resolves a temp dir to `/private/var/…`) while a root
    /// key is `standardizedFileURL.path` (`/var/…`). Standardizing both collapses that so
    /// the prefix strip succeeds; on ordinary (non-temp) paths standardizing is a no-op and
    /// this is exact. We require a `/` boundary after the root so `/a/b` never matches a
    /// sibling `/a/bc`, and return nil (not the absolute path) for anything outside the
    /// root — the caller then keeps the basename rather than leaking an absolute path.
    static func relativePath(ofAbsolute absolute: String, underRoot root: URL) -> String? {
        guard !absolute.isEmpty else { return nil }
        let fileStd = URL(fileURLWithPath: absolute).standardizedFileURL.path
        let rootStd = root.standardizedFileURL.path
        guard !rootStd.isEmpty else { return nil }
        // Root itself is not a file under root; require a strict descendant.
        let prefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"
        guard fileStd.hasPrefix(prefix) else { return nil }
        let rel = String(fileStd.dropFirst(prefix.count))
        return rel.isEmpty ? nil : rel
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
