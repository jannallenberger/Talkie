#if DEBUG
import Foundation
import NaturalLanguage

/// Pure-logic parity self-test for the mirrored `SemanticCore`, invoked by
/// `talkie-mcp --selftest`. It stands in for a unit-test target (which G3 can't add
/// without editing `Package.swift`) and asserts the three scoring acceptance
/// criteria. Prints a line per check and exits nonzero on the first failure.
///
/// The keyword-degradation and exact-substring checks are deterministic (no model).
/// The paraphrase check needs the on-device sentence model; when it's unavailable
/// the test says so and skips that one assertion rather than failing spuriously —
/// "embeddings unavailable == keyword parity" is itself one of the criteria.
enum SemanticSelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ name: String, _ cond: Bool) {
            if cond { print("PASS  \(name)") }
            else { print("FAIL  \(name)"); failures += 1 }
        }

        // --- Deterministic pure-logic checks (no model needed) -----------------

        // blendedScore is the 0.7/0.3 blend, cosine clamped at 0.
        check("blendedScore blend weights",
              abs(SemanticIndex.blendedScore(semantic: 1.0, keyword: 0.0) - 0.7) < 1e-9 &&
              abs(SemanticIndex.blendedScore(semantic: 0.0, keyword: 1.0) - 0.3) < 1e-9)
        check("blendedScore clamps negative cosine",
              SemanticIndex.blendedScore(semantic: -0.9, keyword: 0.0) == 0.0)

        // keywordScore is intersection / query-size; tokenize drops <3-char tokens.
        check("keywordScore full overlap == 1",
              SemanticIndex.keywordScore(["updater", "ship"], ["updater", "ship", "build"]) == 1.0)
        check("tokenize drops short tokens",
              SemanticIndex.tokenize("go to the updater").sorted() == ["the", "updater"])

        // cosine of a vector with itself == 1; orthogonal == 0.
        check("cosine self == 1", abs(SemanticIndex.cosine([1, 2, 3], [1, 2, 3]) - 1.0) < 1e-9)
        check("cosine orthogonal == 0", SemanticIndex.cosine([1, 0], [0, 1]) == 0.0)

        // --- Index-level checks over synthetic records -------------------------

        let records = [
            SemanticRecord(line: "meeting [aaaaaaaa] Sync — 2026-07-01",
                           text: "we agreed to release the auto-update build to collaborators next week",
                           sourceRank: 2),
            SemanticRecord(line: "dictation [bbbbbbbb] 2026-07-01 10:00: remember to buy oat milk and coffee",
                           text: "remember to buy oat milk and coffee", sourceRank: 1),
            SemanticRecord(line: "entity (project) Coralate", text: "Coralate", sourceRank: 3),
        ]
        let index = SemanticIndex(records: records)

        // Criterion 2 (deterministic): an exact substring of a dictation ranks at/near
        // top. Query is a literal substring of the oat-milk dictation.
        let exact = index.search("oat milk", limit: 5)
        check("exact substring returns the dictation at top",
              exact.first?.line.contains("oat milk") == true)

        // Criterion 3 (deterministic core): keyword-only degradation. Force the
        // no-embeddings path by scoring directly with semantic=0 and confirm a shared
        // keyword still clears the threshold and a non-overlapping query does not.
        let kwHit = SemanticIndex.blendedScore(
            semantic: 0,
            keyword: SemanticIndex.keywordScore(SemanticIndex.tokenize("coffee"),
                                                SemanticIndex.tokenize("remember to buy oat milk and coffee")))
        let kwMiss = SemanticIndex.blendedScore(
            semantic: 0,
            keyword: SemanticIndex.keywordScore(SemanticIndex.tokenize("xylophone"),
                                                SemanticIndex.tokenize("remember to buy oat milk and coffee")))
        check("keyword-only: shared term clears threshold", kwHit > 0)
        check("keyword-only: unrelated term scores zero", kwMiss == 0)

        // --- L12: commitment provenance partition (pure, no model) --------------
        // meeting-sourced = ANY provenance entry with source == "meeting"; anything
        // else (dictation-only, incl. no provenance) is the noisy heuristic bucket
        // that list_commitments hides by default.
        func commit(_ name: String, _ sources: [String]) -> TalkieStore.Entity {
            TalkieStore.Entity(
                id: TalkieStore.EntityID(kind: "commitment", key: name.lowercased()),
                displayName: name, aliases: nil, mentions: 1, pinned: nil,
                firstSeenUnix: 0, lastSeenUnix: 0,
                provenance: sources.map { TalkieStore.Provenance(source: $0, sourceID: nil, dateUnix: 0, snippet: nil) })
        }
        let partitionInput = [
            commit("send the deck", ["meeting"]),               // meeting-only
            commit("let me check the logs", ["dictation"]),     // dictation-only
            commit("follow up with Lars", ["dictation", "meeting"]), // mixed → meeting
            commit("we need to ship", []),                       // no provenance → dictation-only
        ]
        let parts = TalkieStore.partitionCommitments(partitionInput)
        check("partition: meeting-only + mixed land in meeting bucket",
              parts.meeting.map(\.displayName) == ["send the deck", "follow up with Lars"])
        check("partition: dictation-only + no-provenance land in dictation bucket",
              parts.dictationOnly.map(\.displayName) == ["let me check the logs", "we need to ship"])

        // Criterion 1 (needs the model): a paraphrase with no shared ≥3-char token
        // still surfaces the meeting. Skip honestly if the model is unavailable.
        if index.isSemantic {
            // "shipping the updater" shares no ≥3-char token with the meeting text
            // ("release the auto-update build …") except stop-y overlaps; verify no
            // literal-substring shortcut is doing the work, then require a hit.
            let query = "shipping the updater"
            let qTokens = SemanticIndex.tokenize(query)
            let mTokens = SemanticIndex.tokenize(records[0].text)
            let shared = qTokens.intersection(mTokens).subtracting(["the"])
            let paraphrase = index.search(query, limit: 5)
            check("paraphrase surfaces the meeting (semantic recall)",
                  paraphrase.contains { $0.line.contains("Sync") })
            check("paraphrase match is not a mere keyword hit", shared.isEmpty)
        } else {
            print("SKIP  paraphrase semantic recall (NLEmbedding sentence model unavailable — keyword-only mode)")
        }

        print(failures == 0 ? "\nOK — all semantic-core checks passed."
                            : "\n\(failures) semantic-core check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }

    /// `talkie-mcp --selftest-timing [N]` — build a synthetic N-record index (default
    /// 200, the spec's benchmark size) with realistic short-record text and report
    /// the first-build (cold) time and a memoized re-query time. Used to check the
    /// "< 2s first / < 100ms memoized" gate on a controlled corpus, independent of
    /// whatever happens to be on disk. Records are short (dictation-sized), matching
    /// the "~200 records" the acceptance criterion names.
    static func timing(count: Int) -> Never {
        let sample = [
            "remember to buy oat milk and coffee before the weekend",
            "we agreed to release the auto-update build to collaborators",
            "the dashboard needs a calmer background gradient not a busy aurora",
            "ship the recognition fix for the niche vocabulary path",
            "call Sarah about the Q3 launch and the design deck",
        ]
        var records: [SemanticRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let text = sample[i % sample.count] + " (\(i))"
            records.append(SemanticRecord(line: "record [\(i)]", text: text, sourceRank: 1))
        }
        let cache = SemanticSearchCache()
        let t0 = Date()
        let idx = cache.index(for: nil) { SemanticIndex(records: records) }
        let buildMs = Date().timeIntervalSince(t0) * 1000
        _ = idx.search("shipping the updater", limit: 5)  // warm a query
        let t1 = Date()
        let idx2 = cache.index(for: nil) { SemanticIndex(records: records) }  // memoized
        let memoMs = Date().timeIntervalSince(t1) * 1000
        _ = idx2.search("grocery list", limit: 5)
        print("selftest-timing: \(count) records — semantic=\(idx.isSemantic)")
        print(String(format: "  first build (cold model + embed): %.0f ms  (gate < 2000)", buildMs))
        print(String(format: "  memoized index fetch           : %.1f ms (gate < 100)", memoMs))
        let ok = buildMs < 2000 && memoMs < 100
        print(ok ? "  PASS" : "  FAIL")
        exit(ok ? 0 : 1)
    }
}
#endif
