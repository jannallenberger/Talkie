import Foundation

// Watched-inbox folder (D6): pick ONE folder; any audio/video file that lands in it is
// auto-transcribed into a meeting note (through the existing drop-to-transcribe import,
// D1/D5) and then moved into a `Transcribed/` subfolder. The whole point is that a Voice
// Memo AirDropped from your phone, or an iCloud recording that syncs down, becomes a note
// without you touching Talkie — and, just as importantly, **without Talkie ever opening a
// connection**. Everything here is local kernel/daemon file I/O:
//
//   • `DispatchSource.makeFileSystemObjectSource` watches a directory vnode for writes.
//     It is a purely local kernel event source (the same mechanism `DictionaryInbox`
//     already uses for the MCP inbox) — it reports filesystem changes, it does not reach
//     the network.
//   • `FileManager.startDownloadingUbiquitousItem` asks the **local** iCloud daemon
//     (`bird`/`cloudd`) to materialize a file that syncs down on its own; Talkie only ever
//     *reads* the resulting local bytes. It never uploads and never fetches anything itself.
//     (See docs/PRIVACY.md — the on-device core carries no network code or entitlement;
//     `scripts/check-no-network.sh` enforces it, and this file passes it.)
//
// Privacy trap (deliberate, load-bearing): this feature is OFF until the user picks a
// folder by hand. The watcher is NEVER seeded with a default path — no folder means the
// feature does nothing — so auto-transcribing a directory is always an explicit, visible
// choice, and the settings row says in plain words exactly what will happen to files that
// land there.

// MARK: - Persistence

/// The single watched folder, stored as a plain absolute path — the same shape and house
/// style as `ExportPreferences`: a tiny `@MainActor ObservableObject` with a shared
/// instance, an atomic JSON write to Application Support, and a failure-tolerant decode
/// that starts at the zero-config default. The default is **empty** (no folder), which is
/// the feature's off state; the app is not sandboxed, so a plain path (no security-scoped
/// bookmark) is correct here, exactly as `ExportPreferences.folderPath` does it.
@MainActor
final class InboxWatchPreferences: ObservableObject {
    /// One shared instance so the settings row and the AppDelegate-constructed watcher
    /// read/write the same choice.
    static let shared = InboxWatchPreferences()

    /// The watched folder's absolute path, or "" when the feature is off (no folder
    /// chosen). Writing "" turns watching off; writing a path turns it on. Never seeded.
    @Published var folderPath: String { didSet { save() } }

    private let fileURL: URL

    private init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("inbox_watch.json")
        folderPath = ""   // zero-config default: OFF, no seeded path — the privacy trap.
        load()
    }

    /// Whether the chosen folder currently exists and is a writable directory (so the
    /// settings row can warn, and the watcher can decline to arm on a bad path). Empty
    /// path → not watching, so not "accessible".
    var folderIsAccessible: Bool {
        guard !folderPath.isEmpty else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return FileManager.default.isWritableFile(atPath: folderPath)
    }

    /// The chosen folder as a URL, or nil when the feature is off.
    var folderURL: URL? {
        folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath)
    }

    // MARK: Persistence

    private struct Snapshot: Codable { var folderPath: String }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        folderPath = s.folderPath
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Snapshot(folderPath: folderPath)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Quiescence gate

/// Decides when a file has **stopped changing** and is safe to import. A large file dropped
/// or AirDropped in appears immediately but keeps growing while the bytes copy; transcribing
/// it early would read a truncated prefix. The gate is a pure state machine (no I/O, no
/// clock of its own) so it is unit-testable: feed it `(url, size, now)` samples and it tells
/// you the moment a file's size has held steady across `settleInterval`.
///
/// A file qualifies on the FIRST sample whose size equals the previously-recorded size AND
/// whose timestamp is at least `settleInterval` after that recorded size was first seen. It
/// qualifies exactly once; later samples of the same steady file return false so the watcher
/// enqueues it a single time. Any size change resets the clock.
final class QuiescenceGate {
    /// How long a file's size must hold steady before it's trusted as fully written.
    let settleInterval: TimeInterval

    private struct Sample { var size: Int64; var since: Date; var qualified: Bool }
    private var samples: [String: Sample] = [:]

    init(settleInterval: TimeInterval = 2) {
        self.settleInterval = settleInterval
    }

    /// Record an observation of `url` at `size` / `now`; return true exactly once, at the
    /// moment the file first qualifies (size unchanged for >= `settleInterval`).
    @discardableResult
    func observe(_ url: URL, size: Int64, now: Date = Date()) -> Bool {
        let key = url.standardizedFileURL.path
        guard let prev = samples[key] else {
            // First sighting: record the size and the time we first saw it. Never settles
            // on the first look — we have no earlier size to compare against.
            samples[key] = Sample(size: size, since: now, qualified: false)
            return false
        }
        if prev.size != size {
            // Still changing — reset the clock to this new size.
            samples[key] = Sample(size: size, since: now, qualified: false)
            return false
        }
        // Size unchanged since `prev.since`. Qualify once it has held long enough.
        if !prev.qualified, now.timeIntervalSince(prev.since) >= settleInterval {
            samples[key] = Sample(size: size, since: prev.since, qualified: true)
            return true
        }
        return false
    }

    /// Drop all state for `url` — called when a file is done (moved to Transcribed/) or has
    /// vanished, so a later file that reuses the same name starts a fresh settle cycle.
    func forget(_ url: URL) {
        samples[url.standardizedFileURL.path] = nil
    }

    /// Drop state for any tracked path not in `keep` — housekeeping so the map doesn't grow
    /// unbounded as files come and go.
    func retain(only keep: Set<String>) {
        for key in samples.keys where !keep.contains(key) { samples[key] = nil }
    }
}

// MARK: - Watcher

/// Watches one user-chosen folder and turns each settled audio/video file that lands there
/// into a meeting, then moves the original into `<folder>/Transcribed/`. `@MainActor`
/// because it drives the `@MainActor FileImportCoordinator` and reads the `@MainActor
/// MeetingStore`; the directory watch uses the same local `DispatchSource` vnode source as
/// `DictionaryInbox`, whose handler hops back to the main actor before touching state.
///
/// Lifecycle: `updateFolder(_:)` (called at startup and whenever the setting changes) arms
/// or disarms the watch. While armed, an initial scan plus every vnode `.write` event runs
/// `scan()`, which: (1) reconciles already-imported files by moving them to Transcribed/
/// (the durable done-marker — restart-safe, no processed-list DB), (2) requests iCloud
/// materialization for any dataless placeholder, (3) runs the quiescence gate, and
/// (4) enqueues newly-settled files on the import coordinator.
@MainActor
final class InboxWatcher {
    private let coordinator: FileImportCoordinator
    private let meetingStore: MeetingStore

    /// The folder currently being watched (nil = feature off). Set via `updateFolder`.
    private var folder: URL?
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    /// The quiescence gate — a file must hold its size steady before we import it.
    private let gate = QuiescenceGate()

    /// Files enqueued this session and not yet reconciled (moved to Transcribed/). Prevents
    /// a double-enqueue in the window between "enqueued" and "its meeting exists + moved".
    private var inFlight: Set<String> = []
    /// Files whose import failed this session — left in place (not moved) and NOT retried
    /// until the next launch, so a permanently-bad file can't cause a retry storm. Cleared
    /// only by a fresh process start.
    private var failed: Set<String> = []

    /// Coalesces the "poll again shortly" re-scan (used to let a still-copying file settle)
    /// into a single scheduled pass so overlapping vnode events don't fan out.
    private var rescanScheduled = false

    /// The subfolder name that doubles as the done-marker. A file living here has already
    /// been transcribed; the watch never descends into it. `nonisolated` so the pure
    /// static helpers (and tests) can read it off the main actor.
    nonisolated static let transcribedSubfolder = "Transcribed"

    init(coordinator: FileImportCoordinator, meetingStore: MeetingStore) {
        self.coordinator = coordinator
        self.meetingStore = meetingStore
    }

    deinit {
        // Cancelling the source closes the fd (see `arm`); if it never armed, close any
        // dangling fd directly. `deinit` can't hop actors, so touch only these locals.
        source?.cancel()
        if source == nil, dirFD >= 0 { close(dirFD) }
    }

    // MARK: Lifecycle

    /// Point the watcher at `url` (or nil to turn it off). Re-arms the vnode watch on the
    /// new directory and does an immediate scan. Idempotent: calling it with the folder
    /// already being watched is a no-op. This is the ONLY way the watcher gets a path — it
    /// is never seeded with a default, so no folder means the feature is inert.
    func updateFolder(_ url: URL?) {
        let newPath = url?.standardizedFileURL.path
        if newPath == folder?.standardizedFileURL.path { return }   // unchanged
        disarm()
        folder = url
        guard let url else { return }   // turned off — nothing else to do.
        arm(on: url)
        scan()
    }

    /// Convenience: read the folder from the shared preference and (re)arm accordingly.
    func syncFromPreferences(_ prefs: InboxWatchPreferences = .shared) {
        updateFolder(prefs.folderURL)
    }

    private func disarm() {
        source?.cancel()   // cancel handler closes the fd
        source = nil
        dirFD = -1
        gate.retain(only: [])
        inFlight.removeAll()
        // `failed` is intentionally NOT cleared here — a bad file stays quarantined for the
        // rest of the process even across a folder toggle; a real relaunch is the reset.
    }

    /// Open the directory and watch its vnode for writes/renames/deletes. An atomic add
    /// (AirDrop, a copy, an iCloud materialization) lands as a rename into the directory,
    /// which fires `.write` on the directory vnode. We create the `Transcribed/` marker
    /// folder up front so the very first successful import has somewhere to move to.
    private func arm(on url: URL) {
        ensureTranscribedFolder(in: url)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            talkieDebugLog("InboxWatcher: couldn't open folder for watching (\(url.path))")
            return
        }
        dirFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            // Already on .main; assume main-actor isolation to touch our state.
            MainActor.assumeIsolated { self?.scan() }
        }
        src.setCancelHandler { [fd] in close(fd) }
        source = src
        src.resume()
    }

    private func ensureTranscribedFolder(in folder: URL) {
        let dir = folder.appendingPathComponent(Self.transcribedSubfolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Scan

    /// The heart of the watcher. On every event (and once at startup) it:
    ///   1. Enumerates the top-level supported media (never into `Transcribed/`).
    ///   2. Reconciles files whose import already produced a meeting by moving the original
    ///      into `Transcribed/` — the move IS the done-marker, so this is what makes the
    ///      whole thing restart-safe and idempotent (quit mid-import, relaunch, and the
    ///      leftover file is either moved because its meeting exists, or re-enqueued once).
    ///   3. For the rest: materializes any iCloud dataless placeholder, runs the quiescence
    ///      gate, and enqueues the files that have settled.
    private func scan() {
        guard let folder else { return }
        let candidates = Self.topLevelMediaFiles(in: folder)

        // Housekeeping: forget gate state for files that are gone.
        gate.retain(only: Set(candidates.map { $0.standardizedFileURL.path }))

        // (2) Reconcile already-imported files → move to Transcribed/ (the done-marker).
        // A file we enqueued whose meeting now exists is done regardless of whether we saw
        // the completion; the move is driven off the persisted meeting, not a callback.
        for url in candidates where isAlreadyImported(url) {
            moveToTranscribed(url)
        }

        // Reconcile FAILURES without a per-file callback: the coordinator exposes no
        // per-file result, but once it is fully idle (nothing importing, nothing queued),
        // any file we enqueued that still has no meeting must have failed. Quarantine it in
        // `failed` — left in place (never moved), not retried until the next launch — so a
        // permanently-bad file can't wedge the in-flight set or cause a retry storm.
        if !coordinator.isImporting, coordinator.queued.isEmpty {
            for key in inFlight where !meetingExists(forPath: key) {
                inFlight.remove(key)
                failed.insert(key)
                gate.forget(URL(fileURLWithPath: key))
                talkieDebugLog("InboxWatcher: import didn't produce a meeting for \(key) — leaving it in place, will retry next launch")
            }
        }

        // Re-read the surviving candidates (the moves above changed the directory).
        let remaining = Self.topLevelMediaFiles(in: folder)
        let toEnqueue = Self.selectForEnqueue(
            candidates: remaining,
            inFlight: inFlight,
            failed: failed,
            isAlreadyImported: { self.isAlreadyImported($0) })

        var needsRescan = false
        for url in toEnqueue {
            // (3a) iCloud dataless placeholder → ask the local iCloud daemon to download it,
            // and re-check on a later pass. Talkie only reads the resulting local bytes.
            if isDatalessPlaceholder(url) {
                requestDownload(url)
                needsRescan = true
                continue
            }
            // (3b) Quiescence gate: only enqueue once the size has held steady.
            guard let size = fileSize(url) else { continue }
            if gate.observe(url, size: size) {
                enqueue(url)
            } else {
                // Not settled yet (or first sighting) — poll again shortly so a file that
                // has finished copying doesn't wait for the next external event.
                needsRescan = true
            }
        }

        // Keep polling while anything is mid-import: the reconcile (move to Transcribed/)
        // is driven off the persisted meeting appearing, so we must re-scan until the
        // in-flight set drains — otherwise a slow import's file wouldn't be moved until the
        // next unrelated directory event. (`enqueue` also kicks a rescan; this covers the
        // case where a running import outlives that single scheduled poll.)
        if needsRescan || !inFlight.isEmpty { scheduleRescan() }
    }

    /// Enqueue one settled file on the import coordinator and remember it as in-flight. The
    /// coordinator has its own dedup + model-exclusivity; when its import lands a meeting,
    /// the next `scan()` reconciles the file into `Transcribed/`.
    private func enqueue(_ url: URL) {
        inFlight.insert(url.standardizedFileURL.path)
        coordinator.enqueue([url])
        // Poll shortly after so the completed import is reconciled (moved) promptly rather
        // than only on the next unrelated directory event.
        scheduleRescan()
    }

    // MARK: Reconcile / move-as-marker

    /// True when a persisted meeting already exists for this file (its `source` embeds D1's
    /// `(imported: <filename>)` fragment) — meaning the import finished and the original can
    /// be moved to `Transcribed/`. Same signal the coordinator's own dedup guard uses.
    private func isAlreadyImported(_ url: URL) -> Bool {
        let marker = Self.importedMarker(for: url)
        return meetingStore.meetings.contains { $0.source.contains(marker) }
    }

    /// Same check keyed by a stored path (the `inFlight`/`failed` sets hold standardized
    /// paths). The marker is filename-based, matching D1's `source` format.
    private func meetingExists(forPath path: String) -> Bool {
        let marker = "(imported: \((path as NSString).lastPathComponent))"
        return meetingStore.meetings.contains { $0.source.contains(marker) }
    }

    /// Move `url` into `<folder>/Transcribed/`, preserving its name (disambiguating on
    /// collision). The move is the done-marker: idempotent and restart-safe, with no
    /// processed-list database to keep in sync. Clears the in-flight/gate state for the
    /// file. A failure to move is logged but not fatal — the meeting already exists, so the
    /// worst case is the file being re-reconciled (moved) on a later pass.
    private func moveToTranscribed(_ url: URL) {
        guard let folder else { return }
        let destDir = folder.appendingPathComponent(Self.transcribedSubfolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let dest = Self.uniqueDestination(for: url.lastPathComponent, in: destDir)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            talkieDebugLog("InboxWatcher: couldn't move \(url.lastPathComponent) into Transcribed/ (\(error.localizedDescription))")
            return
        }
        inFlight.remove(url.standardizedFileURL.path)
        failed.remove(url.standardizedFileURL.path)
        gate.forget(url)
    }

    // MARK: iCloud dataless items

    /// True when `url` is an iCloud placeholder whose contents aren't downloaded yet — we
    /// must not try to transcribe a 0-byte stub. Reads the local ubiquitous-status resource
    /// value; `false` for a normal local file (or when the key is unavailable).
    private func isDatalessPlaceholder(_ url: URL) -> Bool {
        guard let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }

    /// Ask the LOCAL iCloud daemon to materialize a dataless file. This does not fetch
    /// anything from Talkie's process — it hands the request to the system, which syncs the
    /// file down on its own; Talkie only ever reads the resulting local bytes. Failure is
    /// non-fatal (we simply re-check on a later pass).
    private func requestDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    // MARK: Small helpers

    private func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    /// Coalesced short delay before the next `scan()` — lets a still-copying file settle and
    /// lets a just-finished import be reconciled, without spinning.
    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.rescanScheduled = false
            self.scan()
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// The top-level supported media files directly inside `folder`, EXCLUDING the
    /// `Transcribed/` done-marker subfolder (and, via `ImportableMedia`, hidden files and
    /// any subdirectory — the watch never recurses). Pure enough to unit-test with a temp
    /// directory. Reuses D1's `mediaFiles(inFolderAt:)`, which is already shallow + sorted.
    ///
    /// `nonisolated` (like `ExportPreferences.isObsidianVault`) because it reads no
    /// actor state — just the filesystem — so `scan()` and the tests can call it directly.
    nonisolated static func topLevelMediaFiles(in folder: URL) -> [URL] {
        ImportableMedia.mediaFiles(inFolderAt: folder)
            .filter { $0.deletingLastPathComponent().lastPathComponent != transcribedSubfolder }
    }

    /// Choose which candidates to enqueue: drop anything already in flight, anything that
    /// failed this session (retry next launch), and anything already imported (its meeting
    /// exists — it'll be reconciled/moved, not re-imported). Pure so the dedup/exclusion
    /// logic is testable without the filesystem or the coordinator. `nonisolated`: pure.
    nonisolated static func selectForEnqueue(
        candidates: [URL],
        inFlight: Set<String>,
        failed: Set<String>,
        isAlreadyImported: (URL) -> Bool
    ) -> [URL] {
        candidates.filter { url in
            let key = url.standardizedFileURL.path
            if inFlight.contains(key) { return false }
            if failed.contains(key) { return false }
            if isAlreadyImported(url) { return false }
            return true
        }
    }

    /// D1's `source` fragment for an imported file — `(imported: <filename>)`. Matching a
    /// persisted meeting's `source` against this tells us the file was already transcribed.
    nonisolated static func importedMarker(for url: URL) -> String {
        "(imported: \(url.lastPathComponent))"
    }

    /// A non-colliding destination name inside `destDir` for `name`: returns `name` if free,
    /// else `name (2).ext`, `name (3).ext`, … so moving a second same-named file into the
    /// done folder never overwrites the first. `nonisolated`: pure filesystem probe.
    nonisolated static func uniqueDestination(for name: String, in destDir: URL) -> URL {
        let candidate = destDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let stem = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            let url = destDir.appendingPathComponent(stem)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}
