import XCTest
@testable import Talkie

/// The one-time store heal (WP4/4g): `NicheVocabStore.sanitizeOrdinaryWords` removes
/// auto-learned terms whose surface is an ordinary word — the only way they could
/// have entered the corrector's term list is a harvest/confirm bug (a learned
/// poll→pull rule, a bogus single confirm on "communicates", "For me"/"Italy"
/// harvested straight from a recognizer error) — while sparing anything the user
/// actually curated or confirmed repeatedly. `isOrdinary` is injected as a
/// deterministic closure here (never the live spellchecker), matching the pure-logic
/// idiom of `NicheLoopTests`.
final class NicheSanitationTests: XCTestCase {
    private let now = Date().timeIntervalSince1970

    @MainActor
    private func makeStore() -> NicheVocabStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("niche-sanitation-test-\(UUID().uuidString)", isDirectory: true)
        return NicheVocabStore(directory: dir)
    }

    private func prov(_ id: String? = "d1") -> Provenance {
        Provenance(source: .dictation, sourceID: id, dateUnix: now, snippet: nil)
    }

    /// The live-store poison examples named in the WP4 spec: a harvested/learned
    /// ordinary word or phrase with no protection and under 2 confirmations is
    /// removed; genuine jargon the `isOrdinary` closure never flags survives
    /// untouched.
    @MainActor
    func testSanitizeRemovesOrdinaryUnprotectedLowConfidenceTerms() {
        let store = makeStore()
        store.ingest(["pull"], provenance: prov())                  // auto-learned poison (poll→pull)
        store.recordUserConfirmed("communicates", provenance: prov()) // bogus single confirm
        store.ingest(["For me"], provenance: prov())                 // multi-word filler, mid-sentence
        store.ingest(["Italy"], provenance: prov())                  // harvested from "it also" mis-hear
        store.ingest(["the"], provenance: prov())
        store.ingest(["Talkie"], provenance: prov())                 // real jargon
        store.ingest(["Higgsfield"], provenance: prov())             // real jargon

        let ordinary: Set<String> = ["pull", "communicates", "for me", "italy", "the"]
        let removed = store.sanitizeOrdinaryWords(
            isOrdinary: { ordinary.contains($0.lowercased()) },
            protected: []
        )

        XCTAssertEqual(Set(removed.map { $0.lowercased() }), ordinary,
                       "every ordinary, unprotected, under-confirmed term must be removed")

        let survivors = Set((store.terms[NicheID.default.key] ?? []).map { $0.term.lowercased() })
        XCTAssertEqual(survivors, ["talkie", "higgsfield"],
                       "terms the isOrdinary closure never flags as ordinary must survive untouched")
    }

    /// A term the user explicitly curated (present in `protected`) is NEVER removed,
    /// even when it reads as an ordinary word to the closure — that's real intent,
    /// not a poisoning bug.
    @MainActor
    func testSanitizeSparesProtectedTerms() {
        let store = makeStore()
        store.ingest(["pull"], provenance: prov())
        store.recordUserConfirmed("there", provenance: prov())

        let ordinary: Set<String> = ["pull", "there"]
        let removed = store.sanitizeOrdinaryWords(
            isOrdinary: { ordinary.contains($0.lowercased()) },
            protected: ["there"]
        )

        XCTAssertEqual(removed.map { $0.lowercased() }, ["pull"])
        let survivors = Set((store.terms[NicheID.default.key] ?? []).map { $0.term.lowercased() })
        XCTAssertEqual(survivors, ["there"], "a curated (protected) term must never be demoted")
    }

    /// A term confirmed twice or more is never removed even if ordinary and
    /// unprotected — repeated explicit confirmation is strong enough evidence to
    /// outweigh the ordinary-word heuristic (mirrors `NicheConfidence`'s own
    /// "confirmed beats rejected" asymmetry).
    @MainActor
    func testSanitizeSparesRepeatedlyConfirmedTerms() {
        let store = makeStore()
        store.ingest(["pull"], provenance: prov())
        store.recordUserConfirmed("okay", provenance: prov())
        store.recordUserConfirmed("okay", provenance: prov())   // 2nd confirmation

        let ordinary: Set<String> = ["pull", "okay"]
        let removed = store.sanitizeOrdinaryWords(
            isOrdinary: { ordinary.contains($0.lowercased()) },
            protected: []
        )

        XCTAssertEqual(removed.map { $0.lowercased() }, ["pull"])
        let survivors = Set((store.terms[NicheID.default.key] ?? []).map { $0.term.lowercased() })
        XCTAssertEqual(survivors, ["okay"], "userConfirmed >= 2 must survive regardless of ordinariness")
    }

    /// A store with nothing ordinary in it is a true no-op: nothing removed, nothing
    /// saved unnecessarily.
    @MainActor
    func testSanitizeNoOpWhenNothingOrdinary() {
        let store = makeStore()
        store.ingest(["Talkie"], provenance: prov())
        store.ingest(["Higgsfield"], provenance: prov())

        let removed = store.sanitizeOrdinaryWords(isOrdinary: { _ in false }, protected: [])
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual((store.terms[NicheID.default.key] ?? []).count, 2)
    }
}
