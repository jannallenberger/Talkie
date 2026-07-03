import XCTest
@testable import Talkie

/// A5 — the MCP teach-back inbox. A Claude session (via `talkie-mcp`) drops one
/// atomic JSON file per dictionary suggestion into an inbox dir; `DictionaryInbox`
/// validates each (length, dedup, a per-minute rate cap), applies it through the
/// same `addVocabularyTerm` / `addLearnedReplacement` the LearningEngine uses, and
/// surfaces it with an Undo pill — so a prompt-injected session can never silently
/// pollute recognition. These tests drive ingestion synchronously (the live path's
/// DispatchSource watch + pill pacing are async) and assert on the resulting store
/// state + the captured Undo closure.
@MainActor
final class DictionaryInboxTests: XCTestCase {

    // MARK: Test rig

    /// Captures what the inbox would have shown, and lets a test fire the Undo.
    private final class PillSpy {
        struct Shown { let message: String; let onUndo: () -> Void }
        var shown: [Shown] = []
        var revertedCount = 0
    }

    private var tmp: URL!
    private var inboxDir: URL!
    private var dictionary: DictionaryStore!
    private var niche: NicheVocabStore!
    private var spy: PillSpy!
    private var inbox: DictionaryInbox!

    override func setUp() {
        super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkie-inbox-tests-\(UUID().uuidString)", isDirectory: true)
        inboxDir = tmp.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        dictionary = DictionaryStore()
        // Start from a known-empty dictionary so seeded defaults ("talkie"→"Talkie")
        // don't interfere with dedup assertions.
        dictionary.replacements = []
        dictionary.vocabulary = []
        niche = NicheVocabStore(directory: tmp.appendingPathComponent("niche", isDirectory: true))
        spy = PillSpy()
        let spy = self.spy!
        inbox = DictionaryInbox(
            dictionary: dictionary, nicheVocab: niche, directory: inboxDir,
            presentPill: { message, onUndo in spy.shown.append(.init(message: message, onUndo: onUndo)) },
            presentReverted: { spy.revertedCount += 1 })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: File writers (mirror the peer's on-disk shape)

    @discardableResult
    private func writeVocab(_ term: String, note: String? = nil, version: Int = 1) -> URL {
        write(["kind": "vocabulary", "term": term, "note": note as Any,
               "createdUnix": Date().timeIntervalSince1970, "version": version])
    }

    @discardableResult
    private func writeReplacement(from: String, to: String, version: Int = 1) -> URL {
        write(["kind": "replacement", "from": from, "to": to,
               "createdUnix": Date().timeIntervalSince1970, "version": version])
    }

    // L15 management-op writers (op field present).

    @discardableResult
    private func writeRemoveReplacement(from: String, to: String) -> URL {
        write(["kind": "replacement", "op": "removeReplacement", "from": from, "to": to,
               "createdUnix": Date().timeIntervalSince1970, "version": 1])
    }

    @discardableResult
    private func writeUpdateReplacement(from: String, to: String, newTo: String) -> URL {
        write(["kind": "replacement", "op": "updateReplacement", "from": from, "to": to,
               "newTo": newTo, "createdUnix": Date().timeIntervalSince1970, "version": 1])
    }

    @discardableResult
    private func writeRemoveVocab(_ term: String) -> URL {
        write(["kind": "vocabulary", "op": "removeVocabularyTerm", "term": term,
               "createdUnix": Date().timeIntervalSince1970, "version": 1])
    }

    @discardableResult
    private func write(_ dict: [String: Any]) -> URL {
        let clean = dict.filter { !($0.value is NSNull) }
        let data = try! JSONSerialization.data(withJSONObject: clean)
        let url = inboxDir.appendingPathComponent("\(UUID().uuidString).json")
        try! data.write(to: url)
        return url
    }

    private func writeRaw(_ text: String) -> URL {
        let url = inboxDir.appendingPathComponent("\(UUID().uuidString).json")
        try! text.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: Happy path — vocabulary

    func testVocabularySuggestionAppliesAndPings() {
        writeVocab("Higgsfield", note: "user corrected it")
        let applied = inbox.drainSynchronouslyForTesting()

        XCTAssertEqual(applied, 1, "one suggestion applied")
        XCTAssertTrue(dictionary.vocabulary.contains("Higgsfield"),
                      "the term is now in the dictionary vocabulary")
        XCTAssertEqual(spy.shown.count, 1, "exactly one Undo pill was surfaced")
        XCTAssertTrue(spy.shown.first!.message.contains("Higgsfield"),
                      "the pill names the term Claude added")
        XCTAssertTrue(spy.shown.first!.message.contains("Claude"),
                      "the pill attributes the add to Claude (never silent)")
        // The consumed file is deleted.
        XCTAssertTrue(inboxFiles().isEmpty, "the applied suggestion file is removed")
    }

    /// Machine-suggested terms record an `ingest` OCCURRENCE, NOT a userConfirmed —
    /// the strongest signal stays reserved for real human corrections.
    func testVocabularyRecordsIngestNotUserConfirmed() {
        writeVocab("Coralate")
        inbox.drainSynchronouslyForTesting()

        let term = niche.snapshot().termsByNiche[NicheID.default.key]?
            .first { $0.term.caseInsensitiveCompare("Coralate") == .orderedSame }
        XCTAssertNotNil(term, "the term is recorded in the niche store")
        XCTAssertEqual(term?.occurrences, 1, "recorded as a passive occurrence")
        XCTAssertEqual(term?.userConfirmed, 0,
                       "a Claude suggestion is NOT a user-confirmed signal")
    }

    // MARK: Happy path — replacement

    func testReplacementSuggestionAppliesAsLearnedRule() {
        writeReplacement(from: "higgs field", to: "Higgsfield")
        let applied = inbox.drainSynchronouslyForTesting()

        XCTAssertEqual(applied, 1)
        let rule = dictionary.replacements.first { $0.to == "Higgsfield" }
        XCTAssertNotNil(rule, "a replacement rule was added")
        XCTAssertEqual(rule?.from.lowercased(), "higgs field")
        XCTAssertEqual(rule?.isLearned, true, "added as a learned rule (undoable)")
        XCTAssertTrue(spy.shown.first!.message.contains("Higgsfield"))
    }

    // MARK: Undo

    func testUndoRemovesVocabularyAndRecordsRejection() {
        writeVocab("Higgsfield")
        inbox.drainSynchronouslyForTesting()
        XCTAssertTrue(dictionary.vocabulary.contains("Higgsfield"))

        spy.shown.first!.onUndo()

        XCTAssertFalse(dictionary.vocabulary.contains("Higgsfield"),
                       "Undo removes the term from the dictionary")
        XCTAssertEqual(spy.revertedCount, 1, "the 'Reverted' confirmation is shown")
        let term = niche.snapshot().termsByNiche[NicheID.default.key]?
            .first { $0.term.caseInsensitiveCompare("Higgsfield") == .orderedSame }
        XCTAssertEqual(term?.rejections, 1, "Undo records a rejection against the term")
    }

    func testUndoRemovesLearnedReplacement() {
        writeReplacement(from: "higgs field", to: "Higgsfield")
        inbox.drainSynchronouslyForTesting()
        XCTAssertNotNil(dictionary.replacements.first { $0.to == "Higgsfield" })

        spy.shown.first!.onUndo()

        XCTAssertNil(dictionary.replacements.first { $0.to == "Higgsfield" },
                     "Undo removes the learned replacement rule")
        XCTAssertEqual(spy.revertedCount, 1)
    }

    // MARK: Dedup

    func testDuplicateVocabularyIsSilentNoOp() {
        dictionary.vocabulary = ["Higgsfield"]
        writeVocab("higgsfield")   // case-insensitive duplicate
        let applied = inbox.drainSynchronouslyForTesting()

        XCTAssertEqual(applied, 0, "a duplicate term surfaces no pill")
        XCTAssertEqual(spy.shown.count, 0)
        XCTAssertEqual(dictionary.vocabulary, ["Higgsfield"], "no duplicate entry added")
        XCTAssertTrue(inboxFiles().isEmpty, "the duplicate file is still consumed (deleted)")
    }

    func testDuplicateReplacementIsSilentNoOp() {
        _ = dictionary.addLearnedReplacement(from: "higgs field", to: "Higgsfield")
        writeReplacement(from: "Higgs Field", to: "Higgsfield")   // same pair, different case
        let applied = inbox.drainSynchronouslyForTesting()

        XCTAssertEqual(applied, 0, "a duplicate rule surfaces no pill")
        XCTAssertEqual(dictionary.replacements.filter { $0.to == "Higgsfield" }.count, 1,
                       "no duplicate rule added")
    }

    // MARK: L15 — back-compat (an add-only file with no `op` field still works)

    func testAddOnlyFileWithNoOpFieldStillApplies() {
        // The exact pre-L15 shape (no `op` key) must decode + behave as `.add`.
        writeVocab("Higgsfield")   // writeVocab never emits an `op` field
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 1,
                       "a legacy add-only file (no op) is treated as an add")
        XCTAssertTrue(dictionary.vocabulary.contains("Higgsfield"))
    }

    // MARK: L15 — remove replacement rule

    func testRemoveReplacementRemovesRuleAndPings() {
        _ = dictionary.addLearnedReplacement(from: "higgs field", to: "Higgsfield")
        writeRemoveReplacement(from: "higgs field", to: "Higgsfield")
        let applied = inbox.drainSynchronouslyForTesting()

        XCTAssertEqual(applied, 1, "the removal applied and showed a pill")
        XCTAssertNil(dictionary.replacements.first { $0.to == "Higgsfield" },
                     "the rule is gone")
        XCTAssertTrue(spy.shown.first!.message.contains("Claude"),
                      "the pill attributes the change to Claude (never silent)")
        XCTAssertTrue(spy.shown.first!.message.contains("Higgsfield"))
    }

    func testUndoRemoveReplacementRestoresTheRuleVerbatim() {
        _ = dictionary.addLearnedReplacement(from: "higgs field", to: "Higgsfield")
        let originalID = dictionary.replacements.first { $0.to == "Higgsfield" }!.id
        writeRemoveReplacement(from: "higgs field", to: "Higgsfield")
        inbox.drainSynchronouslyForTesting()
        XCTAssertNil(dictionary.replacements.first { $0.to == "Higgsfield" })

        spy.shown.first!.onUndo()

        let restored = dictionary.replacements.first { $0.to == "Higgsfield" }
        XCTAssertNotNil(restored, "Undo restores the removed rule")
        XCTAssertEqual(restored?.id, originalID, "restored verbatim (same id + flags)")
        XCTAssertEqual(restored?.isLearned, true, "the learned flag survives the round-trip")
        XCTAssertEqual(spy.revertedCount, 1)
    }

    func testRemoveReplacementCanRemoveACuratedRuleToo() {
        // Claude can manage curated rules, not just learned ones.
        dictionary.replacements = [Replacement(from: "api", to: "API", learned: false)]
        writeRemoveReplacement(from: "api", to: "API")
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 1)
        XCTAssertTrue(dictionary.replacements.isEmpty, "a curated rule is removable")
    }

    func testRemoveMissingReplacementIsSilentNoOp() {
        writeRemoveReplacement(from: "nope", to: "nada")
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0,
                       "removing a rule that doesn't exist shows no pill")
        XCTAssertEqual(spy.shown.count, 0)
        XCTAssertTrue(inboxFiles().isEmpty, "the no-op file is still consumed")
    }

    // MARK: L15 — update replacement rule target

    func testUpdateReplacementRetargetsRuleAndPings() {
        _ = dictionary.addLearnedReplacement(from: "higgs field", to: "Higgsfield")
        writeUpdateReplacement(from: "higgs field", to: "Higgsfield", newTo: "HiggsField")
        let applied = inbox.drainSynchronouslyForTesting()

        XCTAssertEqual(applied, 1)
        XCTAssertNil(dictionary.replacements.first { $0.to == "Higgsfield" })
        XCTAssertNotNil(dictionary.replacements.first { $0.from.lowercased() == "higgs field" && $0.to == "HiggsField" },
                        "the rule now targets the new spelling")
        XCTAssertTrue(spy.shown.first!.message.contains("Claude"))
    }

    func testUndoUpdateReplacementRestoresPreviousTarget() {
        _ = dictionary.addLearnedReplacement(from: "higgs field", to: "Higgsfield")
        let originalID = dictionary.replacements.first { $0.to == "Higgsfield" }!.id
        writeUpdateReplacement(from: "higgs field", to: "Higgsfield", newTo: "HiggsField")
        inbox.drainSynchronouslyForTesting()

        spy.shown.first!.onUndo()

        let restored = dictionary.replacements.first { $0.from.lowercased() == "higgs field" }
        XCTAssertEqual(restored?.to, "Higgsfield", "Undo restores the previous target")
        XCTAssertEqual(restored?.id, originalID, "same rule (id preserved), not a new one")
        XCTAssertEqual(spy.revertedCount, 1)
    }

    func testUpdateMissingReplacementIsSilentNoOp() {
        writeUpdateReplacement(from: "nope", to: "nada", newTo: "whatever")
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0)
        XCTAssertEqual(spy.shown.count, 0)
    }

    func testUpdateReplacementToSameTargetIsNoOp() {
        _ = dictionary.addLearnedReplacement(from: "higgs field", to: "Higgsfield")
        writeUpdateReplacement(from: "higgs field", to: "Higgsfield", newTo: "Higgsfield")
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0,
                       "retargeting to the same value changes nothing → no pill")
    }

    // MARK: L15 — remove vocabulary term

    func testRemoveVocabularyRemovesTermAndPings() {
        dictionary.vocabulary = ["Higgsfield", "Coralate"]
        writeRemoveVocab("Higgsfield")
        let applied = inbox.drainSynchronouslyForTesting()

        XCTAssertEqual(applied, 1)
        XCTAssertFalse(dictionary.vocabulary.contains("Higgsfield"))
        XCTAssertTrue(dictionary.vocabulary.contains("Coralate"), "only the named term is removed")
        XCTAssertTrue(spy.shown.first!.message.contains("Claude"))
    }

    func testRemoveVocabularyMatchesCaseInsensitivelyAndRestoresUserCasing() {
        dictionary.vocabulary = ["Higgsfield"]
        writeRemoveVocab("higgsfield")   // different casing than stored
        inbox.drainSynchronouslyForTesting()
        XCTAssertFalse(dictionary.vocabulary.contains("Higgsfield"), "matched case-insensitively")

        spy.shown.first!.onUndo()
        XCTAssertTrue(dictionary.vocabulary.contains("Higgsfield"),
                      "Undo restores the term in the user's original casing")
        XCTAssertEqual(spy.revertedCount, 1)
    }

    func testRemoveMissingVocabularyIsSilentNoOp() {
        dictionary.vocabulary = ["Coralate"]
        writeRemoveVocab("Higgsfield")
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0)
        XCTAssertEqual(dictionary.vocabulary, ["Coralate"], "unrelated terms untouched")
    }

    // MARK: L15 — an unknown op is rejected, not treated as an add

    func testUnknownOpIsDiscardedNotTreatedAsAdd() {
        _ = write(["kind": "vocabulary", "op": "wipe_everything", "term": "Higgsfield",
                   "createdUnix": Date().timeIntervalSince1970, "version": 1])
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0,
                       "an unrecognized op is discarded, never reinterpreted as an add")
        XCTAssertFalse(dictionary.vocabulary.contains("Higgsfield"))
        XCTAssertTrue(inboxFiles().isEmpty)
    }

    func testKindOpMismatchIsDiscarded() {
        // removeVocabularyTerm on a "replacement" kind is incoherent → discard.
        _ = write(["kind": "replacement", "op": "removeVocabularyTerm", "term": "Higgsfield",
                   "createdUnix": Date().timeIntervalSince1970, "version": 1])
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0)
        XCTAssertTrue(inboxFiles().isEmpty)
    }

    // MARK: Malformed / oversized files are discarded

    func testUnparseableFileDiscarded() {
        _ = writeRaw("{ this is not json ]")
        let applied = inbox.drainSynchronouslyForTesting()
        XCTAssertEqual(applied, 0)
        XCTAssertTrue(inboxFiles().isEmpty, "a malformed file is discarded, not left to wedge the inbox")
    }

    func testOverLengthTermDiscarded() {
        let huge = String(repeating: "x", count: DictionaryInbox.maxTermLength + 1)
        writeVocab(huge)
        let applied = inbox.drainSynchronouslyForTesting()
        XCTAssertEqual(applied, 0, "an over-length term is rejected")
        XCTAssertFalse(dictionary.vocabulary.contains(huge))
        XCTAssertTrue(inboxFiles().isEmpty, "the oversized file is consumed (discarded)")
    }

    func testTermAtLengthLimitAccepted() {
        let exact = String(repeating: "x", count: DictionaryInbox.maxTermLength)
        writeVocab(exact)
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 1, "a term exactly at the limit is accepted")
        XCTAssertTrue(dictionary.vocabulary.contains(exact))
    }

    func testUnknownKindDiscarded() {
        _ = write(["kind": "delete_everything", "term": "oops",
                   "createdUnix": Date().timeIntervalSince1970, "version": 1])
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0, "an unknown kind is ignored")
        XCTAssertTrue(inboxFiles().isEmpty)
    }

    func testFutureVersionDiscarded() {
        writeVocab("Higgsfield", version: 999)
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0, "a newer schema version is rejected")
        XCTAssertFalse(dictionary.vocabulary.contains("Higgsfield"))
    }

    func testEmptyTermDiscarded() {
        writeVocab("   ")
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0)
        XCTAssertTrue(inboxFiles().isEmpty)
    }

    func testReplacementMissingFieldDiscarded() {
        _ = write(["kind": "replacement", "from": "higgs field",
                   "createdUnix": Date().timeIntervalSince1970, "version": 1])   // no `to`
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0, "a replacement without `to` is a no-op")
        XCTAssertTrue(dictionary.replacements.isEmpty)
    }

    // MARK: Rate cap

    func testRateCapHoldsAtFivePerMinute() {
        // Seven distinct valid terms arrive at once.
        for i in 0..<7 { writeVocab("Term\(i)") }
        let now = Date()
        let applied = inbox.drainSynchronouslyForTesting(now: now)

        XCTAssertEqual(applied, DictionaryInbox.ratePerMinute,
                       "no more than the per-minute cap is applied in one burst")
        XCTAssertEqual(inbox.appliedInWindowForTesting, DictionaryInbox.ratePerMinute)
        // The two over-cap files are left on disk (not discarded) for a later pass.
        XCTAssertEqual(inboxFiles().count, 7 - DictionaryInbox.ratePerMinute,
                       "over-cap suggestions are retained, not dropped")
    }

    func testRateWindowFreesUpAfterAMinute() {
        for i in 0..<5 { writeVocab("First\(i)") }
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(now: Date()), 5, "first burst fills the window")

        // A sixth term, a full window later, applies because the earlier five aged out.
        writeVocab("Later")
        let later = Date().addingTimeInterval(61)
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(now: later), 1,
                       "the cap frees up once the window rolls past")
        XCTAssertTrue(dictionary.vocabulary.contains("Later"))
    }

    // MARK: FIFO ordering

    func testOldestSuggestionAppliedFirstUnderCap() {
        // Write three with increasing mod dates; only two fit under a tightened view
        // isn't needed — just assert they all apply in age order (pills in order).
        let a = writeVocab("Alpha"); bump(a, ageSeconds: 300)
        let b = writeVocab("Bravo"); bump(b, ageSeconds: 200)
        let c = writeVocab("Charlie"); bump(c, ageSeconds: 100)
        inbox.drainSynchronouslyForTesting()
        XCTAssertEqual(spy.shown.map { firstQuoted($0.message) }, ["Alpha", "Bravo", "Charlie"],
                       "suggestions surface oldest-first")
    }

    // MARK: Helpers

    private func inboxFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    /// Backdate a file's modification time so FIFO ordering is deterministic.
    private func bump(_ url: URL, ageSeconds: TimeInterval) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
    }

    /// Pull the first curly-quoted token out of a pill message for order assertions.
    private func firstQuoted(_ s: String) -> String {
        guard let open = s.firstIndex(of: "\u{201c}"),
              let close = s[s.index(after: open)...].firstIndex(of: "\u{201d}") else { return s }
        return String(s[s.index(after: open)..<close])
    }
}
