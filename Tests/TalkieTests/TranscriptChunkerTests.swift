import XCTest
import NaturalLanguage
@testable import Talkie

/// L13-b — transcript chunking for long-record recall. The semantic index used to
/// embed only each record's first `maxIndexedChars` (2000) characters, so any phrase
/// past that bound in a long meeting was invisible to search. L13-b splits a record's
/// text into ≤900-char windows on sentence/paragraph boundaries and indexes the
/// CHUNKS, deduping hits per record (best chunk wins) and drawing the snippet from
/// the winning chunk. These tests prove:
///   • **chunk determinism** — the same text always chunks the same way;
///   • **byte-exact reconstruction** — chunks concatenate back to the (bounded) input,
///     which is what makes a short record's single chunk byte-identical to its old
///     bounded text (so its content hash / persisted vector / result are unchanged);
///   • **short-record result-identity** — a short dictation's search result (id,
///     score, snippet) is exactly what it was before chunking;
///   • **per-record dedupe** — a record with many matching chunks surfaces once;
///   • **long-text recall** — a phrase far past the old 2000-char bound is findable,
///     with the snippet drawn from the matching passage.
final class TranscriptChunkerTests: XCTestCase {

    // MARK: Determinism

    func testChunkingIsDeterministic() {
        let text = String(repeating: "The team reviewed the roadmap and the risks. ", count: 300)
        XCTAssertEqual(TranscriptChunker.chunks(for: text),
                       TranscriptChunker.chunks(for: text),
                       "the same text must chunk identically every call")
    }

    // MARK: Byte-exact reconstruction (the hash-reuse / identity foundation)

    /// Concatenating the chunks reproduces the input verbatim, up to the
    /// `maxChunks × maxChunkChars` reach. No character is dropped, added, or reordered.
    func testChunksReconstructInputByteExact() {
        let inputs = [
            String(repeating: "A sentence about the launch. ", count: 200),   // sentence-delimited
            String(repeating: "x", count: 5000),                              // no terminators → hard split
            "para one\n\npara two\n\n" + String(repeating: "word ", count: 400), // paragraphs
            String(repeating: "Hi. ", count: 800),                            // many tiny sentences
        ]
        let reach = TranscriptChunker.maxChunkChars * TranscriptChunker.maxChunks
        for input in inputs {
            let expected = String(input.unicodeScalars.prefix(reach).map(Character.init))
            XCTAssertEqual(TranscriptChunker.chunks(for: input).joined(), expected,
                           "chunks must concatenate back to the input (bounded)")
        }
    }

    /// Every chunk is within the character cap, and there is no overlap (guaranteed by
    /// the exact-reconstruction property — overlap would duplicate characters).
    func testChunksRespectCapAndDoNotOverlap() {
        let text = String(repeating: "Discussed logistics and timelines in detail. ", count: 400)
        let chunks = TranscriptChunker.chunks(for: text)
        XCTAssertGreaterThan(chunks.count, 1, "a long text must produce multiple chunks")
        for c in chunks {
            XCTAssertLessThanOrEqual(c.unicodeScalars.count, TranscriptChunker.maxChunkChars,
                                     "no chunk exceeds the character cap")
        }
    }

    /// A single unbroken run longer than a window (no sentence terminator) is
    /// hard-split so the cap always holds.
    func testUnbrokenLongRunIsHardSplit() {
        let run = String(repeating: "a", count: 2500) // 2500 / 900 = 3 chunks (900,900,700)
        let chunks = TranscriptChunker.chunks(for: run)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.count), [900, 900, 700])
        XCTAssertEqual(chunks.joined(), run, "hard split still reconstructs exactly")
    }

    /// Per-record cap: a pathologically long transcript is capped at `maxChunks`.
    func testPerRecordChunkCap() {
        let huge = String(repeating: "a", count: TranscriptChunker.maxChunkChars * 200)
        XCTAssertEqual(TranscriptChunker.chunks(for: huge).count, TranscriptChunker.maxChunks,
                       "a very long record is capped at maxChunks chunks")
    }

    // MARK: Short-record single-chunk guarantee

    func testShortTextIsExactlyOneChunkEqualToWholeText() {
        let short = "Discussed the quarterly budget forecast"
        XCTAssertEqual(TranscriptChunker.chunks(for: short), [short])

        // Multi-sentence but still under the window → still one chunk, byte-identical.
        let multi = "Who is Sarah. She leads the launch team! Does she own Q3?"
        XCTAssertEqual(TranscriptChunker.chunks(for: multi), [multi])

        // Exactly at the cap is still a single chunk; one over splits.
        let exactly = String(repeating: "a", count: TranscriptChunker.maxChunkChars)
        XCTAssertEqual(TranscriptChunker.chunks(for: exactly), [exactly])
        XCTAssertEqual(TranscriptChunker.chunks(for: exactly + "a").count, 2)
    }

    func testEmptyTextYieldsNoChunks() {
        XCTAssertEqual(TranscriptChunker.chunks(for: ""), [])
    }

    // MARK: Short-record RESULT identity (the hard requirement)

    /// A short record's single chunk == its whole bounded text, so its content hash is
    /// exactly the L13-a sidecar key `contentHash(prefix(maxIndexedChars))`. This is
    /// what lets a short record reuse its persisted vector verbatim after L13-b — and
    /// is the mechanical proof its search result can't change.
    func testShortRecordChunkHashMatchesLegacyBoundedHash() {
        let text = "remember to buy oat milk and coffee before the weekend"
        let chunks = TranscriptChunker.chunks(for: text)
        XCTAssertEqual(chunks.count, 1, "a short record is a single chunk")
        let legacyKey = VectorSidecar.contentHash(String(text.prefix(SemanticIndex.maxIndexedChars)))
        let chunkKey = VectorSidecar.contentHash(chunks[0])
        XCTAssertEqual(chunkKey, legacyKey,
                       "short-record chunk hash == the L13-a bounded-text key ⇒ vector reused, result unchanged")
    }

    /// End-to-end: a short-record search hit is identical before/after chunking. We
    /// can't run the pre-L13-b index here, but we assert the exact expected hit shape:
    /// id == record id, snippet == snippet(wholeText), positive score. Model-agnostic
    /// (keyword overlap drives inclusion of the exact term).
    func testShortRecordSearchHitIsUnchanged() {
        let records = [
            SearchRecord(id: "dictation:1", text: "Discussed the quarterly budget forecast",
                         kind: .dictation, dateUnix: 10),
            SearchRecord(id: "dictation:2", text: "Lunch plans for the weekend trip",
                         kind: .dictation, dateUnix: 20),
        ]
        let index = SemanticIndex(records: records)
        let hits = index.search("budget")

        let hit = hits.first { $0.id == "dictation:1" }
        XCTAssertNotNil(hit, "an exact keyword match is still returned")
        // Snippet is drawn from the winning chunk, which for a short record IS the whole
        // text — identical to the pre-L13-b `snippet(record.text)`.
        XCTAssertEqual(hit?.snippet, SemanticIndex.snippet("Discussed the quarterly budget forecast"))
        XCTAssertEqual(hit?.kind, .dictation)
        XCTAssertEqual(hit?.dateUnix, 10)
        XCTAssertGreaterThan(hit?.score ?? 0, 0)
    }

    // MARK: Per-record dedupe (one hit per record)

    /// A record whose text repeats the query term across MANY chunks must still surface
    /// exactly once — the best chunk wins, the rest are deduped away.
    func testPerRecordDedupeOneHitPerRecord() {
        // ~4500 chars, so several ≤900 chunks; "budget" appears in every sentence, so
        // multiple chunks would match without dedupe.
        let repeated = String(repeating: "The budget was reviewed carefully in this section. ", count: 90)
        let records = [
            SearchRecord(id: "meeting:long", text: repeated, kind: .meeting, dateUnix: 1),
            SearchRecord(id: "dictation:other", text: "unrelated note about lunch", kind: .dictation, dateUnix: 2),
        ]
        let index = SemanticIndex(records: records)
        XCTAssertGreaterThan(TranscriptChunker.chunks(for: repeated).count, 1,
                             "precondition: the record spans multiple chunks")

        let hits = index.search("budget")
        let matchingRecordIDs = hits.map(\.id).filter { $0 == "meeting:long" }
        XCTAssertEqual(matchingRecordIDs.count, 1,
                       "a multi-chunk record must appear exactly once (per-record dedupe)")
        // And the hit ids overall are unique (no record double-listed).
        XCTAssertEqual(Set(hits.map(\.id)).count, hits.count, "no record id appears twice")
    }

    // MARK: Long-text recall (the whole point of L13-b)

    /// A phrase that sits FAR past the old 2000-char bound is now findable, and the
    /// snippet is drawn from that matching passage (not the head of the record).
    /// Needs the on-device sentence model for the semantic path; the phrase here also
    /// shares literal tokens, so it works in keyword mode too — but we gate on the
    /// model to make the "semantic recall past the bound" claim precisely.
    func testPhrasePastTwoThousandCharsIsFindable() {
        // Filler of ~2600 chars of on-topic-but-different text, THEN the needle. The
        // needle is well past index 2000, where the pre-L13-b index would never look.
        let filler = String(repeating: "The team discussed logistics and timelines. ", count: 60)
        XCTAssertGreaterThan(filler.count, 2000, "precondition: filler alone exceeds the old bound")
        let needle = "The launch retro is scheduled for Friday afternoon in the annex."
        let text = filler + needle
        let records = [
            SearchRecord(id: "meeting:1", text: text, kind: .meeting, dateUnix: 1),
            SearchRecord(id: "dictation:2", text: "buy oat milk", kind: .dictation, dateUnix: 2),
        ]
        let index = SemanticIndex(records: records)

        // Keyword-mode floor: "retro annex" shares literal tokens only with the needle,
        // which lives past char 2000 — so a hit PROVES the tail was indexed.
        let hits = index.search("launch retro annex")
        let hit = hits.first { $0.id == "meeting:1" }
        XCTAssertNotNil(hit, "a phrase past the 2000-char bound must be findable after chunking")
        // The snippet is the WINNING chunk (the tail passage), so it contains the
        // needle — not the record's head.
        XCTAssertTrue(hit?.snippet.contains("launch retro") ?? false,
                      "snippet is drawn from the matching passage, not the record head")
    }

    /// Regression companion: the SAME long record, searched pre-L13-b style, would only
    /// match the head. Here we prove the head is still findable too (chunk 0), so
    /// chunking didn't trade tail recall for head recall.
    func testHeadOfLongRecordStillFindable() {
        let head = "Opening remarks covered the pomegranate initiative and its owner. "
        let text = head + String(repeating: "Later we moved on to other matters entirely. ", count: 80)
        let index = SemanticIndex(records: [
            SearchRecord(id: "meeting:1", text: text, kind: .meeting, dateUnix: 1),
        ])
        let hits = index.search("pomegranate initiative")
        XCTAssertTrue(hits.contains { $0.id == "meeting:1" },
                      "the head passage is still findable after chunking")
    }
}
