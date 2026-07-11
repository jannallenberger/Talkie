import XCTest
@testable import Talkie

/// WP6 — correction transparency: `ChangedWord.union` builds the `.inserting`
/// pill's chip list, and `HUDController.rejectFixHandler` wires a rejectable chip's
/// tap to `nicheVocab.recordRejection`. Both are pure/testable without AppKit — the
/// same idiom as `NicheCorrectorTests`/`NicheSanitationTests`.
final class ChangedWordTests: XCTestCase {

    // MARK: - ChangedWord.union

    /// Dictionary and bias-origin words carry only `to` and are never rejectable —
    /// unchanged from the pre-WP6 single-chip behavior. Niche fixes carry `from` and
    /// come back rejectable. Order is preserved: dictionary, then bias, then niche.
    func testUnionOrderAndRejectability() {
        let result = ChangedWord.union(
            dictionaryReplaced: ["foo", "bar"],
            biasApplied: ["baz"],
            nicheFixes: [
                NicheFix(from: "Higgs field", to: "Higgsfield"),
                NicheFix(from: "cloud MD", to: "claude.md"),
            ]
        )
        XCTAssertEqual(result, [
            ChangedWord(from: nil, to: "foo", rejectable: false),
            ChangedWord(from: nil, to: "bar", rejectable: false),
            ChangedWord(from: nil, to: "baz", rejectable: false),
            ChangedWord(from: "Higgs field", to: "Higgsfield", rejectable: true),
            ChangedWord(from: "cloud MD", to: "claude.md", rejectable: true),
        ])
    }

    /// A later source loses to an earlier one that already named the same `to`
    /// surface — the exact dedup semantics the old `!replacedWords.contains(word)`
    /// loops had, now expressed as a `Set`-backed first-occurrence-wins union.
    func testUnionDedupesBySurfaceFormFirstOccurrenceWins() {
        let result = ChangedWord.union(
            dictionaryReplaced: ["Coralate"],
            biasApplied: ["Coralate", "Github"],
            nicheFixes: [
                NicheFix(from: "core relate", to: "Coralate"),   // already named — dropped
                NicheFix(from: "Higgs field", to: "Higgsfield"),
            ]
        )
        XCTAssertEqual(result, [
            ChangedWord(from: nil, to: "Coralate", rejectable: false),
            ChangedWord(from: nil, to: "Github", rejectable: false),
            ChangedWord(from: "Higgs field", to: "Higgsfield", rejectable: true),
        ])
    }

    func testUnionEmptyInputsProduceEmptyList() {
        XCTAssertEqual(ChangedWord.union(dictionaryReplaced: [], biasApplied: [], nicheFixes: []), [])
    }

    // MARK: - HUDController.rejectFixHandler

    @MainActor
    private func makeNicheVocabStore() -> NicheVocabStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("changed-word-test-\(UUID().uuidString)", isDirectory: true)
        return NicheVocabStore(directory: dir)
    }

    /// The exact seam `AppDelegate` wires at the `showInserting` call site: tapping a
    /// rejectable chip must call `nicheVocab.recordRejection(to)` — the `to` surface,
    /// i.e. the canonical spelling that misfired, matching WP4's contract — and run
    /// the confirm callback (the hub wires this to `showReverted()`).
    @MainActor
    func testRejectFixHandlerRecordsRejectionAgainstTheToSurfaceAndConfirms() {
        let store = makeNicheVocabStore()
        let now = Date().timeIntervalSince1970
        store.ingest(["Higgsfield"], provenance: Provenance(source: .dictation, sourceID: "d1", dateUnix: now, snippet: nil))

        var confirmed = false
        let handler = HUDController.rejectFixHandler(nicheVocab: store) { confirmed = true }
        handler(ChangedWord(from: "Higgs field", to: "Higgsfield", rejectable: true))

        XCTAssertTrue(confirmed, "the confirm callback must fire so the hub can show a brief acknowledgment")
        let term = (store.terms[NicheID.default.key] ?? []).first { $0.term == "Higgsfield" }
        XCTAssertEqual(term?.rejections, 1, "recordRejection must be called with the `to` surface, not `from`")
    }

    /// Rejecting a second, distinct chip demotes its own term independently — the
    /// handler doesn't accidentally close over stale state between chips.
    @MainActor
    func testRejectFixHandlerIsIndependentPerChip() {
        let store = makeNicheVocabStore()
        let now = Date().timeIntervalSince1970
        store.ingest(["Higgsfield", "Coralate"], provenance: Provenance(source: .dictation, sourceID: "d1", dateUnix: now, snippet: nil))

        let handler = HUDController.rejectFixHandler(nicheVocab: store) {}
        handler(ChangedWord(from: "Higgs field", to: "Higgsfield", rejectable: true))
        handler(ChangedWord(from: "core relate", to: "Coralate", rejectable: true))

        let terms = store.terms[NicheID.default.key] ?? []
        XCTAssertEqual(terms.first { $0.term == "Higgsfield" }?.rejections, 1)
        XCTAssertEqual(terms.first { $0.term == "Coralate" }?.rejections, 1)
    }
}
