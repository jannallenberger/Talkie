import Foundation

/// Watches the on-disk **inbox** where the bundled `talkie-mcp` peer drops
/// dictionary suggestions from a Claude session, and applies each one *visibly* —
/// with the same HUD-Undo pill the LearningEngine uses — so a prompt-injected
/// Claude session can never silently pollute recognition (A5).
///
/// Why an inbox handshake instead of a direct write from the MCP peer? The app's
/// `DictionaryStore.save()` overwrites `dictionary.json` unconditionally, so a peer
/// writing that file would race the app and could clobber the user's curated vocab.
/// The peer therefore writes ONE atomic JSON file per suggestion into
/// `~/Library/Application Support/Talkie/inbox/` (uuid filename — two concurrent
/// Claude sessions can't clobber each other, there's no shared file to contend on),
/// and this class is the ONLY thing that mutates the dictionary from that feed. Each
/// suggestion is validated (length, dedup, a per-minute rate cap), applied through
/// the existing `addVocabularyTerm` / `addLearnedReplacement`, and immediately
/// surfaced with an Undo pill. Suggestions that arrive while the app is closed are
/// picked up by the launch scan and surfaced then — never applied without the pill.
///
/// `@MainActor` because it drives the HUD and the two `@MainActor` stores. The
/// directory watch uses `DispatchSource.makeFileSystemObjectSource` (the app's
/// only file-watch; cf. the `DispatchSourceTimer` in `HotKeyMonitor`), whose event
/// handler hops back to the main actor before touching any state.
@MainActor
final class DictionaryInbox {
    private let dictionary: DictionaryStore
    private let nicheVocab: NicheVocabStore
    /// L15-b: the meeting store, for the meeting-notes management ops (retitle).
    /// Optional so tests that exercise only the dictionary path can omit it; a meeting
    /// op with no store present is a graceful no-op.
    private let meetingStore: MeetingStore?
    private let directory: URL

    /// How a confirmed suggestion is surfaced. In the app this is
    /// `HUDController.showLearned` (pill + Undo chip); tests inject a spy so the
    /// ingest/validation/undo logic can be exercised without spinning a real HUD
    /// panel. `message` is the "Claude added …" line; `onUndo` reverses the apply.
    typealias PillPresenter = @MainActor (_ message: String, _ onUndo: @escaping () -> Void) -> Void
    private let presentPill: PillPresenter
    /// Shown after an Undo ("Reverted"). Injected for the same reason as `presentPill`.
    private let presentReverted: @MainActor () -> Void

    /// Files are validated against these bounds; malformed/oversized ones are
    /// discarded with a debug log and their file deleted (so a flood can't wedge us).
    static let maxTermLength = 40
    /// At most this many suggestions may be APPLIED per rolling minute. Excess
    /// suggestions are left on disk (not deleted) and retried on the next event or
    /// launch, so a burst is throttled, not dropped.
    static let ratePerMinute = 5
    private static let rateWindow: TimeInterval = 60

    /// The current schema version this reader understands (mirrors the peer's writer).
    private static let supportedVersion = 1

    /// Apply timestamps within the rolling window, for the rate cap.
    private var recentApplies: [Date] = []

    /// Serializes pill presentation: a suggestion whose pill can't show yet (an
    /// earlier one is still up, or the rate cap is hit) waits rather than stomping
    /// the visible pill. Drained by `pump()`.
    private var pending: [URL] = []
    /// True while a learned pill from THIS feed is on screen; the next suggestion
    /// waits for its window so pings queue sequentially instead of overwriting.
    private var pillBusyUntil: Date?

    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    /// Coalesces the "scan again shortly" retries (rate-cap backoff, post-pill drain)
    /// into one scheduled pass so overlapping triggers don't fan out.
    private var drainScheduled = false

    /// App-facing init: surfaces suggestions through the live HUD.
    convenience init(dictionary: DictionaryStore, nicheVocab: NicheVocabStore, hud: HUDController,
                     meetingStore: MeetingStore? = nil,
                     directory: URL = AppPaths.supportDirectory().appendingPathComponent("inbox", isDirectory: true)) {
        self.init(dictionary: dictionary, nicheVocab: nicheVocab, meetingStore: meetingStore, directory: directory,
                  presentPill: { message, onUndo in hud.showLearned(message, onUndo: onUndo) },
                  presentReverted: { hud.showReverted() })
    }

    /// Designated init with the pill presentation injected — tests pass a spy and a
    /// temporary directory so the ingest logic is hermetic (no HUD panel, no real
    /// support dir).
    init(dictionary: DictionaryStore, nicheVocab: NicheVocabStore, meetingStore: MeetingStore? = nil,
         directory: URL, presentPill: @escaping PillPresenter, presentReverted: @escaping @MainActor () -> Void) {
        self.dictionary = dictionary
        self.nicheVocab = nicheVocab
        self.meetingStore = meetingStore
        self.directory = directory
        self.presentPill = presentPill
        self.presentReverted = presentReverted
    }

    deinit {
        // `source` cancellation closes the fd (see `startWatching`); if the source
        // never started, close any dangling fd directly.
        source?.cancel()
        if source == nil, dirFD >= 0 { close(dirFD) }
    }

    // MARK: Lifecycle

    /// Create the inbox dir (the peer may not have, if Claude hasn't run yet), scan
    /// for anything already waiting, then watch for new drops. Safe to call once.
    func start() {
        ensureDirectory()
        startWatching()
        // Scan whatever is already there (suggestions written while the app was
        // closed) — surfaced with the pill, exactly like a live drop.
        scan()
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Watch the inbox dir for writes/renames. A vnode source needs an open fd on
    /// the directory; atomic writes land as a rename into the dir, which fires
    /// `.write` on the directory vnode. On any event we re-scan (cheap: the dir holds
    /// at most a handful of tiny files).
    private func startWatching() {
        guard source == nil else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            talkieDebugLog("DictionaryInbox: couldn't open inbox dir for watching (\(directory.path))")
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

    // MARK: Scan + ingest

    /// Read every `*.json` in the inbox, oldest first, and try to apply each. Files
    /// that can't be parsed or fail validation are deleted (with a debug line);
    /// files that are merely rate-capped for now are left for a later pass.
    private func scan() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let jsons = urls.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { modDate($0) < modDate($1) }   // oldest first — FIFO fairness
        for url in jsons where !pending.contains(url) {
            pending.append(url)
        }
        pump()
    }

    private func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Drain the pending queue: apply suggestions one at a time, pausing while a pill
    /// is still on screen or the rate cap is momentarily full, and rescheduling a
    /// short retry in those cases so nothing is dropped.
    private func pump() {
        let now = Date()
        // Hold off while a learned pill from this feed is still visible, so pings
        // don't overwrite each other — surface them sequentially.
        if let until = pillBusyUntil, now < until {
            scheduleDrain(after: until.timeIntervalSince(now) + 0.1)
            return
        }
        pillBusyUntil = nil

        while let url = pending.first {
            pruneRateWindow(now: Date())
            guard recentApplies.count < Self.ratePerMinute else {
                // Rate cap hit: leave the file on disk and retry after the oldest
                // apply ages out of the window. Nothing is discarded.
                let oldest = recentApplies.first ?? now
                let wait = Self.rateWindow - Date().timeIntervalSince(oldest) + 0.1
                talkieDebugLog("DictionaryInbox: rate cap reached (\(Self.ratePerMinute)/min) — deferring \(url.lastPathComponent)")
                scheduleDrain(after: max(wait, 1))
                return
            }

            pending.removeFirst()
            let outcome = ingest(url)
            switch outcome {
            case .appliedPillShown:
                recentApplies.append(Date())
                pillBusyUntil = Date().addingTimeInterval(HUDModel.learnedDuration + 0.2)
                // Let the pill have its window before the next one; then continue.
                scheduleDrain(after: HUDModel.learnedDuration + 0.3)
                return
            case .consumedNoPill:
                // Duplicate / no-op: the file is consumed but nothing was shown, so
                // keep draining immediately (it didn't spend the pill or the cap).
                continue
            case .leftOnDisk:
                // Shouldn't happen here (rate cap handled above), but be safe:
                // stop and let a later pass retry.
                return
            }
        }
    }

    private enum Outcome {
        case appliedPillShown   // a new term/rule was applied and its Undo pill shown
        case consumedNoPill     // file consumed (parsed) but a no-op — no pill, no cap spent
        case leftOnDisk         // not consumed; retry later
    }

    /// Parse and apply one suggestion file. Deletes the file once consumed (whether
    /// it applied or was a validated no-op); a file that can't even be read is left
    /// for one retry then deleted if it reappears unparseable.
    private func ingest(_ url: URL) -> Outcome {
        guard let data = try? Data(contentsOf: url) else {
            // The event can fire before the atomic rename is visible; a missing/short
            // read just means "not ready" — leave it for the next pass.
            return .leftOnDisk
        }
        guard let s = try? JSONDecoder().decode(TalkieMCPSuggestion.self, from: data) else {
            talkieDebugLog("DictionaryInbox: discarding unparseable suggestion \(url.lastPathComponent)")
            delete(url)
            return .consumedNoPill
        }
        guard s.version <= Self.supportedVersion else {
            talkieDebugLog("DictionaryInbox: discarding suggestion with unsupported version \(s.version)")
            delete(url)
            return .consumedNoPill
        }

        defer { delete(url) }   // consumed either way once we've decided

        // An `op` field that's present but unrecognized decodes to nil — discard it
        // rather than fall through to `.add` (a forward-rev op we don't understand
        // must never be silently reinterpreted as an add).
        guard let op = s.operation else {
            talkieDebugLog("DictionaryInbox: discarding suggestion with unknown op \"\(s.op ?? "")\"")
            return .consumedNoPill
        }

        switch (s.kind, op) {
        case ("vocabulary", .add):
            return applyVocabulary(s.term)
        case ("replacement", .add):
            return applyReplacement(from: s.from, to: s.to)
        // L15 management ops.
        case ("replacement", .removeReplacement):
            return applyRemoveReplacement(from: s.from, to: s.to)
        case ("replacement", .updateReplacement):
            return applyUpdateReplacement(from: s.from, to: s.to, newTo: s.newTo)
        case ("vocabulary", .removeVocabularyTerm):
            return applyRemoveVocabulary(s.term)
        // L15-b — meeting-notes management.
        case ("meeting", .retitleMeeting):
            return applyRetitleMeeting(idOrPrefix: s.meetingID, title: s.to)
        default:
            // A well-formed op on the wrong kind (e.g. removeVocabularyTerm on a
            // "replacement" file) — reject rather than guess.
            talkieDebugLog("DictionaryInbox: discarding suggestion with kind/op mismatch \"\(s.kind)\"/\"\(op.rawValue)\"")
            return .consumedNoPill
        }
    }

    // MARK: Apply — vocabulary term

    private func applyVocabulary(_ rawTerm: String?) -> Outcome {
        guard let term = validated(rawTerm) else { return .consumedNoPill }
        // Dedup against the existing vocabulary (case-insensitively — matches the
        // store's own contains-based guard closely enough that re-suggesting an
        // existing term is a silent no-op, not a second pill).
        if dictionary.vocabulary.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            talkieDebugLog("DictionaryInbox: \"\(term)\" already in vocabulary — skipping")
            return .consumedNoPill
        }
        dictionary.addVocabularyTerm(term)
        dictionary.save()   // inbox writes aren't driven by the Dictionary view's onChange, so persist here
        recordIngest(term)
        presentPill(String(format: "Your AI agent added “%@” to dictionary".loc, term)) { [weak self] in
            guard let self else { return }
            self.dictionary.removeVocabularyTerm(term)
            self.dictionary.save()
            self.nicheVocab.recordRejection(term)
            self.presentReverted()
        }
        return .appliedPillShown
    }

    // MARK: Apply — replacement rule

    private func applyReplacement(from rawFrom: String?, to rawTo: String?) -> Outcome {
        guard let from = validated(rawFrom), let to = validated(rawTo) else { return .consumedNoPill }
        // `addLearnedReplacement` already trims, rejects from==to, and dedups against
        // existing rules — returning false on any no-op, so we don't double-show.
        guard dictionary.addLearnedReplacement(from: from, to: to) else {
            talkieDebugLog("DictionaryInbox: replacement \"\(from)\"→\"\(to)\" was a no-op — skipping")
            return .consumedNoPill
        }
        // Record the CANONICAL spelling as a passive occurrence (see `recordIngest`).
        recordIngest(to)
        presentPill(String(format: "Your AI agent added “%@” → “%@” to dictionary".loc, from, to)) { [weak self] in
            guard let self else { return }
            self.dictionary.removeLearnedReplacement(from: from, to: to)
            self.nicheVocab.recordRejection(to)
            self.presentReverted()
        }
        return .appliedPillShown
    }

    // MARK: Apply — L15 management ops (remove rule, update rule, remove vocab)
    //
    // These mutate an EXISTING entry and, like the adds, are applied only behind the
    // HUD-Undo pill (never silent). No `recordIngest` here — that passive-occurrence
    // signal is for *adding* jargon; removing/retargeting a rule isn't evidence a
    // term is real. A target that no longer exists at apply time is a graceful
    // no-op (`.consumedNoPill`): the file is consumed, nothing is shown.

    /// Remove a replacement rule (from → to). Undo restores the exact prior rule
    /// (id + flags preserved).
    private func applyRemoveReplacement(from rawFrom: String?, to rawTo: String?) -> Outcome {
        guard let from = validated(rawFrom), let to = validated(rawTo) else { return .consumedNoPill }
        guard let removed = dictionary.removeReplacementMatching(from: from, to: to) else {
            talkieDebugLog("DictionaryInbox: remove replacement \"\(from)\"→\"\(to)\" — no such rule, no-op")
            return .consumedNoPill
        }
        presentPill(String(format: "Your AI agent removed “%@” → “%@” from dictionary".loc, removed.from, removed.to)) { [weak self] in
            guard let self else { return }
            self.dictionary.restoreReplacement(removed)
            self.presentReverted()
        }
        return .appliedPillShown
    }

    /// Change a replacement rule's target (from → to  becomes  from → newTo). Undo
    /// restores the prior target (the whole prior rule, id + flags preserved).
    private func applyUpdateReplacement(from rawFrom: String?, to rawTo: String?, newTo rawNewTo: String?) -> Outcome {
        guard let from = validated(rawFrom), let to = validated(rawTo), let newTo = validated(rawNewTo) else {
            return .consumedNoPill
        }
        guard let prior = dictionary.updateReplacementTarget(from: from, to: to, newTo: newTo) else {
            talkieDebugLog("DictionaryInbox: update replacement \"\(from)\"→\"\(to)\" to \"\(newTo)\" — no such rule or no change, no-op")
            return .consumedNoPill
        }
        presentPill(String(format: "Your AI agent changed “%@” → “%@” to “%@”".loc, prior.from, prior.to, newTo)) { [weak self] in
            guard let self else { return }
            self.dictionary.restoreReplacement(prior)
            self.presentReverted()
        }
        return .appliedPillShown
    }

    /// Remove a vocabulary term. Undo re-adds it.
    private func applyRemoveVocabulary(_ rawTerm: String?) -> Outcome {
        guard let term = validated(rawTerm) else { return .consumedNoPill }
        // Find the term as actually stored (case-insensitively) so the pill and the
        // Undo restore use the user's real casing, not Claude's.
        guard let stored = dictionary.vocabulary.first(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
            talkieDebugLog("DictionaryInbox: remove vocab \"\(term)\" — not present, no-op")
            return .consumedNoPill
        }
        dictionary.removeVocabularyTerm(stored)
        dictionary.save()
        presentPill(String(format: "Your AI agent removed “%@” from dictionary".loc, stored)) { [weak self] in
            guard let self else { return }
            self.dictionary.restoreVocabularyTerm(stored)
            self.presentReverted()
        }
        return .appliedPillShown
    }

    // MARK: Apply — L15-b meeting-notes management

    /// Retitle a meeting (matched by id or 8-char prefix) behind the same confirm-with-
    /// Undo pill. No niche bookkeeping — a meeting title isn't dictionary jargon. A
    /// missing store/meeting, a blank/over-long title, or an unchanged title is a
    /// graceful no-op (file consumed, nothing shown).
    private func applyRetitleMeeting(idOrPrefix rawID: String?, title rawTitle: String?) -> Outcome {
        guard let store = meetingStore,
              let id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              title.count <= 200 else {
            return .consumedNoPill
        }
        guard let result = store.retitle(idOrPrefix: id, to: title) else {
            talkieDebugLog("DictionaryInbox: retitle meeting \"\(id)\" → \"\(title)\" — no match or no change, no-op")
            return .consumedNoPill
        }
        presentPill(String(format: "Your AI agent retitled a meeting to “%@”".loc, title)) { [weak self] in
            guard let self, let store = self.meetingStore else { return }
            store.restoreTitle(id: result.id, to: result.oldTitle)
            self.presentReverted()
        }
        return .appliedPillShown
    }

    // MARK: Validation + niche bookkeeping

    /// Trim, reject empty / over-length. Returns the cleaned term or nil (discard).
    private func validated(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= Self.maxTermLength else {
            talkieDebugLog("DictionaryInbox: discarding over-length term (\(trimmed.count) > \(Self.maxTermLength))")
            return nil
        }
        return trimmed
    }

    /// Machine-suggested terms record as an `ingest` OCCURRENCE only — deliberately
    /// NOT `recordUserConfirmed`. A confirmed signal is the strongest evidence a term
    /// is real jargon and is reserved for a human explicitly typing a correction over
    /// Talkie's output; a Claude suggestion the user merely didn't undo is weaker, so
    /// it starts as a passive occurrence. Surviving the Undo window is the only
    /// passive confirmation it gets. `ingest` takes an array + a provenance.
    private func recordIngest(_ term: String) {
        nicheVocab.ingest(
            [term],
            provenance: Provenance(source: .dictionary, sourceID: nil,
                                   dateUnix: Date().timeIntervalSince1970,
                                   snippet: "suggested by your AI agent"))
    }

    // MARK: Pill sequencing + housekeeping

    private func pruneRateWindow(now: Date) {
        recentApplies.removeAll { now.timeIntervalSince($0) >= Self.rateWindow }
    }

    private func scheduleDrain(after seconds: TimeInterval) {
        guard !drainScheduled else { return }
        drainScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(seconds, 0)))
            guard let self else { return }
            self.drainScheduled = false
            self.pump()
        }
    }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    #if DEBUG
    // MARK: Test seams
    //
    // The DispatchSource watch + the pill-pacing timers are inherently async, so
    // tests drive ingestion synchronously through these hooks and assert on the
    // resulting store state (matching the house style: exercise the decision, not
    // the I/O). They deliberately bypass ONLY the pill-visibility pause (which is
    // cosmetic sequencing); the rate cap and all validation still apply.

    /// Scan the directory and apply every currently-eligible suggestion right now,
    /// ignoring the inter-pill visibility pause. Returns how many were applied (i.e.
    /// showed a pill). Rate-capped and validated exactly like the live path.
    @discardableResult
    func drainSynchronouslyForTesting(now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        let jsons = urls.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { modDate($0) < modDate($1) }
        var applied = 0
        for url in jsons {
            pruneRateWindow(now: now)
            guard recentApplies.count < Self.ratePerMinute else { break }
            switch ingest(url) {
            case .appliedPillShown:
                recentApplies.append(now)
                applied += 1
            case .consumedNoPill, .leftOnDisk:
                continue
            }
        }
        return applied
    }

    /// Number of applies currently counted against the rolling rate window.
    var appliedInWindowForTesting: Int { recentApplies.count }
    #endif
}

/// The app-side mirror of the peer's `TalkieStore.DictionarySuggestion`. Duplicated
/// (not shared) on purpose: `Sources/TalkieMCP` must not import the app target, so
/// the JSON shape is a contract kept byte-compatible on both sides. Extra/absent
/// fields are tolerated (optionals) for forward/back-compat, matching the store's
/// "new fields optional" persistence rule.
///
/// MIRROR: `Sources/TalkieMCP/TalkieStore.swift` → `DictionarySuggestion`. Any field
/// change here MUST be applied there in the same commit (mirror-don't-import).
///
/// L15 adds the optional `op` (operation) + `newTo`. `op` is absent on every
/// add-only file the A5 writers produced, so it defaults to `.add` (see the
/// `operation` helper below) and old files decode + behave identically.
struct TalkieMCPSuggestion: Codable {
    var kind: String
    /// The operation. Absent/`"add"` = the original add; other values are the L15
    /// edit/remove ops. Optional + defaulted (see `operation`) for back-compat.
    var op: String?
    var term: String?
    var from: String?
    var to: String?
    /// For `updateReplacement` only: the new target the rule should produce.
    var newTo: String?
    /// L15-b: for `kind == "meeting"` — the meeting id (or 8-char prefix) to act on.
    /// (The new title travels in `to`, reusing the existing field.)
    var meetingID: String?
    var note: String?
    var createdUnix: Double
    var version: Int

    /// The five operations this inbox understands. `add` is the default so an
    /// add-only file with no `op` field maps to the original A5 behavior.
    enum Op: String {
        case add
        case removeReplacement
        case updateReplacement
        case removeVocabularyTerm
        case retitleMeeting
    }

    /// The decoded op, defaulting to `.add` when the field is absent, and nil when
    /// the field is present but unrecognized (so the handler can discard it rather
    /// than silently treating an unknown op as an add).
    var operation: Op? {
        guard let op, !op.isEmpty else { return .add }
        return Op(rawValue: op)
    }
}
