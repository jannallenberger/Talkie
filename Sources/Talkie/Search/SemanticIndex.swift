import Foundation
import NaturalLanguage

/// What a search hit points back to.
enum SearchRecordKind: String, Sendable { case dictation, meeting, entity }

/// A piece of text the index can search over, with a stable id to jump back to.
///
/// `dateUnix` is mirrored by `SemanticRecord.dateUnix` in the MCP twin
/// (Sources/TalkieMCP/SemanticCore.swift) — the mirror had dropped it and L14
/// re-added it so `get_recent_context` can recency-decay a hit by its age. This
/// struct is the app's own (not a byte-faithful copy), so only the field is shared;
/// the scoring helpers below carry the strict `MIRROR:` markers.
struct SearchRecord: Sendable {
    var id: String
    var text: String
    var kind: SearchRecordKind
    var dateUnix: Double
}

struct SearchHit: Sendable, Identifiable {
    var id: String
    var snippet: String
    var kind: SearchRecordKind
    var dateUnix: Double
    var score: Double
}

/// A `Sendable` holder for the on-device `NLEmbedding`, so a `SemanticIndex` can
/// cache the model ONCE and reuse it for both index-build and query (instead of
/// reconstructing it per record and again per search). `vector(for:)` is a pure,
/// read-only lookup against an immutable model, so sharing the instance across
/// actors is safe — hence `@unchecked Sendable`. (Loading it is the expensive part.)
struct LoadedEmbedding: @unchecked Sendable {
    let embedding: NLEmbedding
}

/// Deterministic, pure transcript chunker (L13-b). Splits a record's text into
/// windows of ≤`maxChunkChars` on sentence/paragraph boundaries so a long meeting
/// becomes fully searchable instead of invisible past the first `maxIndexedChars`.
///
/// MIRROR: Sources/TalkieMCP/SemanticCore.swift (`TranscriptChunker`)
///
/// Guarantees (load-bearing — the tests and the L13-a sidecar depend on them):
///   • **Byte-exact reconstruction:** concatenating all returned chunks reproduces
///     `String(text.prefix(SemanticIndex.maxIndexedChars * maxChunks))` exactly (no
///     dropped/added characters — delimiters and whitespace are kept with their
///     sentence). This is what makes a SHORT record's single chunk byte-identical to
///     the record's old bounded text, so its content hash (hence its persisted
///     sidecar vector AND its search result) is unchanged.
///   • **Single chunk for short records:** any text of ≤`maxChunkChars` UTF-16
///     length returns exactly `[text]` (one chunk == the whole text) — the
///     result-identity requirement for short dictations.
///   • **No overlap:** windows are strictly consecutive, non-overlapping slices.
///   • **Bounded fan-out:** at most `maxChunks` chunks per record; text beyond the
///     `maxChunks × maxChunkChars` reach is dropped (a meeting that long is already
///     far past any realistic transcript, and the cap keeps the derived sidecar
///     bounded — plan-19 §6).
///
/// Splitting is on the sentence/paragraph terminators `.`, `!`, `?`, and `\n`: the
/// text is cut into segments AFTER each maximal run of terminators (so "a. b! c"
/// → "a.", " b!", " c"), then consecutive segments are packed greedily into windows
/// of ≤`maxChunkChars`. A single segment longer than `maxChunkChars` (no terminator
/// for a very long stretch) is hard-split on the character boundary so the cap
/// always holds. All operations are on `String.UnicodeScalarView` indices, so the
/// concatenation identity is exact.
enum TranscriptChunker {
    /// Max characters (Unicode scalars) per chunk. ≤900 keeps each window well inside
    /// the sentence model's useful range while staying a meaningful passage.
    static let maxChunkChars = 900
    /// Per-record cap on the number of chunks. Bounds the derived sidecar and the
    /// per-record embed cost; a transcript longer than `maxChunks × maxChunkChars`
    /// (~72k chars) is truncated to this many chunks.
    static let maxChunks = 80

    /// Split `text` into ≤`maxChunkChars` windows on sentence/paragraph boundaries,
    /// no overlap, at most `maxChunks` chunks. Pure and deterministic.
    static func chunks(for text: String,
                       maxChunkChars: Int = TranscriptChunker.maxChunkChars,
                       maxChunks: Int = TranscriptChunker.maxChunks) -> [String] {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return [] }
        // Fast path + identity guarantee: a short record is exactly one chunk equal
        // to the whole text, so its hash/vector/snippet are byte-identical to pre-L13-b.
        if scalars.count <= maxChunkChars { return [text] }

        // Terminators that end a sentence/paragraph. We cut AFTER a maximal run of
        // these, keeping the run attached to the preceding segment, so concatenating
        // the segments reproduces the input verbatim.
        func isTerminator(_ s: Unicode.Scalar) -> Bool {
            s == "." || s == "!" || s == "?" || s == "\n"
        }

        // 1) Segment: walk scalars, closing a segment at the end of each terminator run.
        var segments: [Range<String.UnicodeScalarIndex>] = []
        var segStart = scalars.startIndex
        var i = scalars.startIndex
        while i < scalars.endIndex {
            if isTerminator(scalars[i]) {
                // Extend across the whole terminator run ("...", "?!", "\n\n").
                var j = scalars.index(after: i)
                while j < scalars.endIndex && isTerminator(scalars[j]) {
                    j = scalars.index(after: j)
                }
                segments.append(segStart..<j)
                segStart = j
                i = j
            } else {
                i = scalars.index(after: i)
            }
        }
        if segStart < scalars.endIndex { segments.append(segStart..<scalars.endIndex) }

        // 2) Pack consecutive segments greedily into ≤maxChunkChars windows. A segment
        //    longer than a window on its own is hard-split on the scalar boundary.
        var chunks: [String] = []
        var windowStart = scalars.startIndex
        var windowLen = 0
        func closeWindow(_ end: String.UnicodeScalarIndex) {
            if windowStart < end { chunks.append(String(scalars[windowStart..<end])) }
        }
        for seg in segments {
            if chunks.count >= maxChunks { break }
            var segLen = scalars.distance(from: seg.lowerBound, to: seg.upperBound)
            // Oversized single segment: flush the current window, then emit hard
            // ≤maxChunkChars slices of the segment until it fits.
            if segLen > maxChunkChars {
                if windowLen > 0 { closeWindow(seg.lowerBound); windowStart = seg.lowerBound; windowLen = 0 }
                var cut = seg.lowerBound
                while segLen > maxChunkChars && chunks.count < maxChunks {
                    let next = scalars.index(cut, offsetBy: maxChunkChars)
                    chunks.append(String(scalars[cut..<next]))
                    cut = next
                    segLen -= maxChunkChars
                }
                // The remainder (< maxChunkChars) starts a fresh window.
                windowStart = cut
                windowLen = scalars.distance(from: cut, to: seg.upperBound)
                continue
            }
            // Would this segment overflow the current window? Close it first (no overlap).
            if windowLen > 0 && windowLen + segLen > maxChunkChars {
                closeWindow(seg.lowerBound)
                windowStart = seg.lowerBound
                windowLen = 0
            }
            windowLen += segLen
        }
        if chunks.count < maxChunks { closeWindow(scalars.endIndex) }
        return chunks
    }
}

/// On-device sentence embeddings via Apple NaturalLanguage — no network, no
/// dependency. Returns `nil` when the model is unavailable, so callers degrade to
/// keyword-only search.
enum Embedder {
    static func sentenceEmbedding() -> NLEmbedding? {
        NLEmbedding.sentenceEmbedding(for: .english)
    }

    /// The model wrapped for caching/reuse across the index's build + queries.
    static func loaded() -> LoadedEmbedding? {
        sentenceEmbedding().map(LoadedEmbedding.init)
    }

    /// A vector for `text`, falling back to the mean of its word vectors for
    /// out-of-vocabulary sentences.
    static func vector(for text: String, embedding: NLEmbedding?) -> [Double]? {
        guard let embedding else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let v = embedding.vector(for: trimmed) { return v }
        var sum: [Double] = []
        var count = 0
        for word in trimmed.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            guard let wv = embedding.vector(for: word) else { continue }
            if sum.isEmpty { sum = wv } else { for i in 0..<min(sum.count, wv.count) { sum[i] += wv[i] } }
            count += 1
        }
        guard count > 0 else { return nil }
        return sum.map { $0 / Double(count) }
    }
}

/// An immutable on-device semantic + keyword index over text records — built once,
/// queried many times. Blends cosine similarity (semantic) with keyword overlap so
/// it still returns useful hits when embeddings are unavailable. `Sendable`: it
/// stores precomputed vectors + token sets plus the read-only NL model (wrapped in
/// the `Sendable` `LoadedEmbedding`), so it can be built off-main and queried anywhere.
struct SemanticIndex: Sendable {
    /// Cap on the characters embedded/tokenized per record. The sentence model only
    /// needs the gist, and embedding/tokenizing megabyte transcripts in full is the
    /// bulk of the index-build cost — so bound the input. Far above any normal
    /// dictation; only very long meeting transcripts are truncated.
    static let maxIndexedChars = 2000

    /// One indexed chunk: a slice of a record's text (L13-b), its embedding, its
    /// tokens, and a backref to the owning record + the record's `dateUnix`. A short
    /// record produces exactly one chunk whose text is the whole record text, so its
    /// hash/vector/tokens/snippet are byte-identical to the pre-L13-b whole-record
    /// entry — result-identity for short records is structural, not incidental.
    private struct Entry: Sendable {
        let record: SearchRecord      // backref: id + kind + dateUnix (+ full text for nothing now)
        let chunkText: String         // the winning-chunk snippet source
        let vector: [Double]?
        let tokens: Set<String>
    }

    private let entries: [Entry]
    /// The NL model, loaded ONCE at build time and reused for queries (rather than
    /// reconstructed per record AND per search). `nil` → keyword-only search.
    private let embedding: LoadedEmbedding?

    /// The merged `contentHash → vector` map for exactly the records in THIS index,
    /// so the builder can persist it to the on-disk sidecar (L13-a). Every record
    /// whose bounded text embedded to a vector contributes one entry — whether the
    /// vector came from `reuse` (a cache hit) or a fresh embedding — so persisting
    /// this map writes only the current records' hashes and lets deleted content age
    /// out. Records that don't embed (empty text / unavailable model) are absent.
    let vectorsByHash: [String: [Double]]

    /// - Parameters:
    ///   - records: the corpus to index.
    ///   - reuse: a `contentHash → vector` map from a previously persisted sidecar.
    ///     For each record, its bounded text is hashed the SAME way the sidecar
    ///     keys it; on a hit the cached vector is reused verbatim (byte-identical to
    ///     re-embedding — the model is deterministic), on a miss the record is
    ///     embedded now. When `reuse` is empty, this is byte-identical to the old
    ///     always-embed path.
    init(records: [SearchRecord], reuse: [String: [Double]] = [:]) {
        // Load the NL model ONCE for the whole build (it was previously reconstructed
        // per record via `Embedder.vector`'s default), then keep it for query time.
        // Constructed from value-type `SearchRecord`s + precomputed vectors/tokens,
        // so the result stays `Sendable` and is safe to build off-main.
        let loaded = Embedder.loaded()
        embedding = loaded
        var merged: [String: [Double]] = [:]
        merged.reserveCapacity(records.count)
        var built: [Entry] = []
        built.reserveCapacity(records.count)
        for record in records {
            // L13-b: index CHUNKS, not the whole-record prefix. A short record yields
            // one chunk equal to its whole text (so its hash == the L13-a
            // `contentHash(prefix(maxIndexedChars))` key and its persisted vector is
            // reused verbatim — result-identity for short records). A long record
            // yields up to `maxChunks` non-overlapping ≤`maxChunkChars` windows, so a
            // phrase past the old 2000-char bound is now embedded and findable.
            for chunk in TranscriptChunker.chunks(for: record.text) {
                // Reuse the cached vector when this chunk's text hasn't changed;
                // otherwise embed it now. The reuse key is the sidecar's stable
                // content hash of the SAME text we embed, so a hit is exactly the
                // vector a fresh embed would produce — reuse never changes a result.
                // Chunk text is hashed identically in the MCP mirror, so the app and
                // the MCP binary SHARE these vectors on disk.
                let hash = VectorSidecar.contentHash(chunk)
                let vector = reuse[hash] ?? Embedder.vector(for: chunk, embedding: loaded?.embedding)
                if let vector { merged[hash] = vector }
                built.append(Entry(record: record, chunkText: chunk, vector: vector,
                                   tokens: SemanticIndex.tokenize(chunk)))
            }
        }
        entries = built
        vectorsByHash = merged
    }

    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !entries.isEmpty else { return [] }
        let queryVector = Embedder.vector(for: q, embedding: embedding?.embedding)
        let queryTokens = SemanticIndex.tokenize(q)

        // Score every chunk, then dedupe per record keeping the best-scoring chunk
        // (L13-b). The snippet is drawn from that winning chunk, so a long-meeting hit
        // shows the passage that actually matched — and a short record (one chunk ==
        // whole text) collapses to exactly the pre-L13-b hit (same id, same score,
        // same snippet). Deterministic tie-break: a strictly-greater score wins; an
        // equal score keeps the earlier chunk (document order), so ties are stable.
        var best: [String: SearchHit] = [:]
        best.reserveCapacity(entries.count)
        for entry in entries {
            let semantic = (queryVector != nil && entry.vector != nil)
                ? SemanticIndex.cosine(queryVector!, entry.vector!) : 0
            let keyword = SemanticIndex.keywordScore(queryTokens, entry.tokens)
            let score = SemanticIndex.blendedScore(semantic: semantic, keyword: keyword)
            guard score > 0 else { continue }
            if let existing = best[entry.record.id], existing.score >= score { continue }
            best[entry.record.id] = SearchHit(id: entry.record.id,
                                              snippet: SemanticIndex.snippet(entry.chunkText),
                                              kind: entry.record.kind,
                                              dateUnix: entry.record.dateUnix,
                                              score: score)
        }
        // Stable order: by score desc, then record id asc so equal-score hits have a
        // deterministic order regardless of dictionary iteration.
        let hits = best.values.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id
        }
        return Array(hits.prefix(limit))
    }

    // MARK: Scoring helpers (pure)

    static func tokenize(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 })
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func keywordScore(_ query: Set<String>, _ doc: Set<String>) -> Double {
        guard !query.isEmpty else { return 0 }
        return Double(query.intersection(doc).count) / Double(query.count)
    }

    /// Blend semantic similarity with keyword overlap. Cosine is clamped at 0 so a
    /// negative (anti-correlated) embedding can never drag a genuine exact-keyword
    /// hit below the inclusion threshold — a document that literally contains the
    /// query term must never be dropped because its vectors point the other way.
    static func blendedScore(semantic: Double, keyword: Double) -> Double {
        0.7 * max(0, semantic) + 0.3 * keyword
    }

    static func snippet(_ text: String, max: Int = 160) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= max ? t : String(t.prefix(max)) + "…"
    }
}
