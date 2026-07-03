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

        // --- L13-b: transcript chunking (pure, mostly no model) ------------------

        // Chunk determinism: same text chunks identically.
        let longText = String(repeating: "The team reviewed the roadmap and the risks. ", count: 200)
        check("chunk determinism",
              TranscriptChunker.chunks(for: longText) == TranscriptChunker.chunks(for: longText))

        // Byte-exact reconstruction (the hash-reuse / short-record identity foundation):
        // chunks concatenate back to the input (bounded by maxChunks × maxChunkChars).
        let reach = TranscriptChunker.maxChunkChars * TranscriptChunker.maxChunks
        let reconExpected = String(longText.unicodeScalars.prefix(reach).map(Character.init))
        check("chunk reconstruction is byte-exact",
              TranscriptChunker.chunks(for: longText).joined() == reconExpected)

        // Short-record single-chunk identity: a short text is one chunk == whole text,
        // so its scoring inputs are byte-identical to the pre-L13-b whole-record entry.
        check("short record is a single whole-text chunk",
              TranscriptChunker.chunks(for: "remember to buy oat milk and coffee")
                == ["remember to buy oat milk and coffee"])

        // Every chunk is within the cap.
        check("chunks respect the character cap",
              TranscriptChunker.chunks(for: longText).allSatisfy { $0.unicodeScalars.count <= TranscriptChunker.maxChunkChars })

        // Per-record dedupe + long-text recall through the index. Build a record with a
        // needle FAR past the old 2000-char bound and a term that repeats across chunks.
        let filler = String(repeating: "The team discussed logistics and timelines. ", count: 60) // >2000 chars
        let recallText = filler + "The launch retro is scheduled for Friday in the annex."
        let dedupeText = String(repeating: "The budget was reviewed carefully here. ", count: 90) // many "budget" chunks
        let chunkRecords = [
            SemanticRecord(line: "meeting [11111111] Long Sync — 2026-07-01", text: recallText, sourceRank: 2),
            SemanticRecord(line: "meeting [22222222] Budget Review — 2026-07-01", text: dedupeText, sourceRank: 2),
        ]
        let chunkIndex = SemanticIndex(records: chunkRecords)

        // Long-text recall: "launch retro annex" only matches the needle, which lives
        // past char 2000 — a hit proves the tail was indexed (keyword floor, no model).
        let recallHits = chunkIndex.search("launch retro annex", limit: 10)
        check("phrase past 2000 chars is findable (chunking)",
              recallHits.contains { $0.line.contains("Long Sync") })
        // The snippet is drawn from the winning (tail) chunk, so it carries the needle.
        check("snippet is the matching passage, not the record head",
              recallHits.first { $0.line.contains("Long Sync") }?.snippet.contains("launch retro") == true)

        // Per-record dedupe: the budget record repeats "budget" across many chunks but
        // must surface exactly once.
        let dedupeHits = chunkIndex.search("budget", limit: 10)
        check("per-record dedupe: multi-chunk record appears once",
              dedupeHits.filter { $0.line.contains("Budget Review") }.count == 1)
        check("no line appears twice in results",
              Set(dedupeHits.map(\.line)).count == dedupeHits.count)

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

        // --- L14: recency decay preserves the tier rule -------------------------
        // The G3 lexical-above-semantic rule must survive decay: an OLD lexical hit
        // (raw ≥ 1.0) must still outrank a FRESH semantic-only hit (raw < 1.0) even at
        // an extreme age. Decay multiplies only the tier's inner term, so a fully
        // decayed lexical hit floors at 1.0 — above any semantic hit's 0.7 ceiling.
        let tauT = TalkieStore.recencyTau(windowSeconds: 15 * 60)
        // Old lexical: a strong lexical raw (1.0 base + ~0.9 inner) aged 30 days.
        let oldLexical = TalkieStore.recencyDecay(rawScore: 1.9, ageSeconds: 30 * 86400, tau: tauT)
        // Fresh semantic-only: the max a semantic hit can score (0.7 · cosine ≤ 0.7),
        // aged 0 seconds (no decay).
        let freshSemantic = TalkieStore.recencyDecay(rawScore: 0.7, ageSeconds: 0, tau: tauT)
        check("decay: old lexical still outranks fresh semantic-only",
              oldLexical > freshSemantic && oldLexical >= 1.0)
        // Within a tier, fresher wins: same raw, younger age scores higher.
        let youngLexInner = TalkieStore.recencyDecay(rawScore: 1.5, ageSeconds: 60, tau: tauT)
        let oldLexInner = TalkieStore.recencyDecay(rawScore: 1.5, ageSeconds: 3600, tau: tauT)
        check("decay: within a tier, fresher outranks older", youngLexInner > oldLexInner)
        // A zero-age hit is undecayed (exp(0)=1): score' == raw.
        check("decay: zero age is a no-op",
              abs(TalkieStore.recencyDecay(rawScore: 1.5, ageSeconds: 0, tau: tauT) - 1.5) < 1e-9)
        // τ floors at 10 min even for a tiny window.
        check("recencyTau floors at 10 minutes",
              TalkieStore.recencyTau(windowSeconds: 60) == 10 * 60 &&
              TalkieStore.recencyTau(windowSeconds: 30 * 60) == 30 * 60)

        // --- L14: window-boundary inclusion (pure interval test) ----------------
        // The report includes items with cutoff ≤ t ≤ now. Verify the boundary is
        // inclusive at both ends and exclusive just outside.
        let nowW = 1_000_000.0
        let windowW = 15.0 * 60
        let cutoffW = nowW - windowW
        func inWindow(_ t: Double) -> Bool { t >= cutoffW && t <= nowW }
        check("window: item exactly at cutoff is included", inWindow(cutoffW))
        check("window: item exactly at now is included", inWindow(nowW))
        check("window: item one second before cutoff is excluded", !inWindow(cutoffW - 1))
        check("window: item in the future (after now) is excluded", !inWindow(nowW + 1))
        // Meeting overlap: a meeting that started before the window but runs into it
        // (start + duration ≥ cutoff) overlaps; one that ended before cutoff does not.
        func overlaps(start: Double, dur: Double) -> Bool { start <= nowW && (start + dur) >= cutoffW }
        check("window: meeting straddling the cutoff overlaps",
              overlaps(start: cutoffW - 120, dur: 300))     // started 2m before, 5m long → into window
        check("window: meeting ending before cutoff does not overlap",
              !overlaps(start: cutoffW - 600, dur: 60))      // ended 9m before cutoff

        // --- L14: co-occurrence join on fixture entities ------------------------
        // Two entities sharing a provenance sourceID must join; shared-count ranks.
        func ent(_ kind: String, _ name: String, _ sourceIDs: [String]) -> TalkieStore.Entity {
            TalkieStore.Entity(
                id: TalkieStore.EntityID(kind: kind, key: name.lowercased()),
                displayName: name, aliases: nil, mentions: sourceIDs.count, pinned: nil,
                firstSeenUnix: 0, lastSeenUnix: 0,
                provenance: sourceIDs.map { TalkieStore.Provenance(source: "meeting", sourceID: $0, dateUnix: 0, snippet: nil) })
        }
        let target = ent("project", "Talkie", ["m1", "m2", "m3"])
        let cohort = [
            target,
            ent("person", "Lars", ["m1", "m2"]),      // 2 shared → ranks first
            ent("term", "MCP", ["m3"]),                 // 1 shared
            ent("person", "Sarah", ["x9"]),             // 0 shared → excluded
        ]
        let cooc = TalkieStore.coOccurring(target: target, all: cohort)
        check("co-occurrence: excludes the target itself and zero-overlap entities",
              cooc.map { $0.entity.displayName } == ["Lars", "MCP"])
        check("co-occurrence: ranked by shared-source count (desc)",
              cooc.first?.entity.displayName == "Lars" && cooc.first?.shared == 2 &&
              cooc.last?.shared == 1)
        // An entity with no sourceIDs on the target yields no co-occurrence at all.
        let lonely = ent("project", "Solo", [])
        check("co-occurrence: target with no shared-able sources returns empty",
              TalkieStore.coOccurring(target: lonely, all: cohort).isEmpty)

        // --- L14: stamp invalidation (touch a temp file ⇒ rebuild observed) ------
        // The cache must rebuild when the store stamp changes. Drive the cache with a
        // real temp file, mutate it, and confirm the build closure re-runs.
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("talkie-mcp-selftest-\(UUID().uuidString).json")
            try? "[]".data(using: .utf8)!.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let cache = SemanticSearchCache()
            var builds = 0
            let mkIndex: () -> SemanticIndex = {
                builds += 1
                return SemanticIndex(records: [SemanticRecord(line: "x", text: "x", sourceRank: 1)])
            }
            _ = cache.index(for: nil, stamp: StoreStamp(files: [tmp]), build: mkIndex)  // build 1
            _ = cache.index(for: nil, stamp: StoreStamp(files: [tmp]), build: mkIndex)  // same stamp → memo
            check("stamp: identical stamp reuses the cached index", builds == 1)
            // Change the file's size (and content) so the stamp differs.
            try? "[1,2,3]".data(using: .utf8)!.write(to: tmp)
            _ = cache.index(for: nil, stamp: StoreStamp(files: [tmp]), build: mkIndex)  // changed → rebuild
            check("stamp: changed store file forces a rebuild", builds == 2)
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
        // A fixed synthetic stamp for both fetches: the memoization gate measures the
        // SAME-stamp fast path, so the two calls must present an identical stamp (an
        // empty file list stamps to an empty, stable fingerprint).
        let fixedStamp = StoreStamp(files: [])
        let t0 = Date()
        let idx = cache.index(for: nil, stamp: fixedStamp) { SemanticIndex(records: records) }
        let buildMs = Date().timeIntervalSince(t0) * 1000
        _ = idx.search("shipping the updater", limit: 5)  // warm a query
        let t1 = Date()
        let idx2 = cache.index(for: nil, stamp: fixedStamp) { SemanticIndex(records: records) }  // memoized
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
