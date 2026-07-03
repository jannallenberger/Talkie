import Foundation
import NaturalLanguage

// =============================================================================
// SemanticCore — the pure scoring core of the app's semantic search, mirrored
// into the MCP binary so `search` recalls by meaning, not just substring.
// =============================================================================
//
// MIRROR: Sources/Talkie/Search/SemanticIndex.swift
//
// This is a faithful, standalone copy of the scoring core in the app's
// `SemanticIndex` (the `Embedder`, `LoadedEmbedding`, `tokenize` / `cosine` /
// `keywordScore` / `blendedScore` / `snippet` helpers, and the 2000-char cap).
// TalkieMCP is a SEPARATE executable target that must NOT import the app target
// (the mirror-don't-import convention documented in `TalkieStore.swift`), so the
// logic is duplicated rather than shared — a single library target to de-dupe the
// two copies is a documented later refactor (G3 out-of-scope).
//
// Because it's a copy, it can drift. The guard against that is this header naming
// the source file plus the grep-able `MIRROR:` markers on every function that must
// stay byte-faithful to the app. If you ever change `blendedScore` (the 0.7/0.3
// blend), `cosine`, `tokenize`, or the clamped-cosine rationale in either place,
// update BOTH — grep `MIRROR:` to find the twin.
//
// `NaturalLanguage` is an Apple *system* framework, not a package dependency, so
// this adds no SPM dependency and `scripts/check-no-network.sh` (which scans
// `Sources/TalkieMCP`) still passes — `NLEmbedding` is entirely on-device.
//
// PRIVACY: on-device only. No network, no third-party deps. The sentence model is
// an Apple on-device asset; nothing you search leaves the machine.
// -----------------------------------------------------------------------------

/// A `Sendable` holder for the on-device `NLEmbedding`, so the index can cache the
/// model ONCE and reuse it for both index-build and query (instead of
/// reconstructing it per record and again per search). `vector(for:)` is a pure,
/// read-only lookup against an immutable model, so sharing the instance is safe —
/// hence `@unchecked Sendable`. (Loading it is the expensive part.)
///
/// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`LoadedEmbedding`)
struct LoadedEmbedding: @unchecked Sendable {
    let embedding: NLEmbedding
}

/// Deterministic, pure transcript chunker (L13-b). Splits a record's text into
/// windows of ≤`maxChunkChars` on sentence/paragraph boundaries so a long meeting
/// becomes fully searchable instead of invisible past the first `maxIndexedChars`.
///
/// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`TranscriptChunker`)
///
/// This is a byte-identical copy of the app's chunker: the sidecar vectors are keyed
/// by `contentHash(chunkText)`, so if this split differed from the app's by a single
/// character the two binaries would compute different hashes and stop sharing
/// vectors. Every branch here must match the app's `TranscriptChunker` exactly — if
/// you change one, change BOTH (grep `MIRROR:` / `TranscriptChunker`).
///
/// Guarantees (load-bearing):
///   • **Byte-exact reconstruction:** concatenating all returned chunks reproduces
///     `String(text.prefix(maxChunkChars * maxChunks))` exactly. This makes a SHORT
///     record's single chunk byte-identical to the record's old bounded text, so its
///     content hash (hence its shared sidecar vector) is unchanged.
///   • **Single chunk for short records:** any text of ≤`maxChunkChars` UTF-16
///     length returns exactly `[text]`.
///   • **No overlap; bounded fan-out** (≤`maxChunks` chunks per record).
enum TranscriptChunker {
    /// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`maxChunkChars`)
    static let maxChunkChars = 900
    /// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`maxChunks`)
    static let maxChunks = 80

    /// Split `text` into ≤`maxChunkChars` windows on sentence/paragraph boundaries,
    /// no overlap, at most `maxChunks` chunks. Pure and deterministic.
    ///
    /// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`TranscriptChunker.chunks`)
    static func chunks(for text: String,
                       maxChunkChars: Int = TranscriptChunker.maxChunkChars,
                       maxChunks: Int = TranscriptChunker.maxChunks) -> [String] {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return [] }
        if scalars.count <= maxChunkChars { return [text] }

        func isTerminator(_ s: Unicode.Scalar) -> Bool {
            s == "." || s == "!" || s == "?" || s == "\n"
        }

        var segments: [Range<String.UnicodeScalarIndex>] = []
        var segStart = scalars.startIndex
        var i = scalars.startIndex
        while i < scalars.endIndex {
            if isTerminator(scalars[i]) {
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

        var chunks: [String] = []
        var windowStart = scalars.startIndex
        var windowLen = 0
        func closeWindow(_ end: String.UnicodeScalarIndex) {
            if windowStart < end { chunks.append(String(scalars[windowStart..<end])) }
        }
        for seg in segments {
            if chunks.count >= maxChunks { break }
            var segLen = scalars.distance(from: seg.lowerBound, to: seg.upperBound)
            if segLen > maxChunkChars {
                if windowLen > 0 { closeWindow(seg.lowerBound); windowStart = seg.lowerBound; windowLen = 0 }
                var cut = seg.lowerBound
                while segLen > maxChunkChars && chunks.count < maxChunks {
                    let next = scalars.index(cut, offsetBy: maxChunkChars)
                    chunks.append(String(scalars[cut..<next]))
                    cut = next
                    segLen -= maxChunkChars
                }
                windowStart = cut
                windowLen = scalars.distance(from: cut, to: seg.upperBound)
                continue
            }
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
/// keyword-only search (the acceptance criterion: embeddings unavailable ==
/// today's keyword behavior).
///
/// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`Embedder`)
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

/// One text record the index can search over, with a stable line to emit on a hit.
/// The MCP `search` tool already knows how to format its own output lines, so —
/// unlike the app's `SearchRecord` — a record carries the finished display `line`
/// plus the raw `text` used for scoring/snippet.
struct SemanticRecord: Sendable {
    /// The pre-formatted output line, preserving today's `search` format
    /// (e.g. `meeting [id] title — date`). The score-carrying snippet is appended
    /// by the caller.
    let line: String
    /// The text scored + snippeted (transcript+summary / dictation text / name).
    let text: String
    /// A base tie-breaker mirroring today's fixed per-source scores (2/1/3), so
    /// that when two records blend-tie, the old ordering is preserved.
    let sourceRank: Int
}

/// One ranked hit: the record's line, the blended score, and a snippet.
struct SemanticHit: Sendable {
    let line: String
    let snippet: String
    let score: Double
    let sourceRank: Int
}

/// An immutable on-device semantic + keyword index over text records — built once,
/// queried many times. Blends cosine similarity (semantic) with keyword overlap so
/// it still returns useful hits when embeddings are unavailable. `Sendable`: it
/// stores precomputed vectors + token sets plus the read-only NL model, so it can
/// be built once and queried repeatedly.
///
/// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`SemanticIndex`)
struct SemanticIndex: Sendable {
    /// Cap on the characters embedded/tokenized per record. The sentence model only
    /// needs the gist, and embedding/tokenizing megabyte transcripts in full is the
    /// bulk of the index-build cost — so bound the input. Far above any normal
    /// dictation; only very long meeting transcripts are truncated.
    ///
    /// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`maxIndexedChars`)
    static let maxIndexedChars = 2000

    /// One indexed chunk (L13-b): a slice of a record's text, its embedding, tokens,
    /// and lowercased haystack, plus a backref to the owning record. A short record
    /// yields exactly one chunk equal to its whole text, so its scoring inputs
    /// (vector/tokens/haystack) are byte-identical to the pre-L13-b whole-record
    /// entry — MCP `search` output for a short record is unchanged.
    private struct Entry: Sendable {
        let record: SemanticRecord
        /// The chunk's own text — the snippet source for a winning chunk.
        let chunkText: String
        let vector: [Double]?
        let tokens: Set<String>
        /// The chunk's lowercased text, for the exact-substring floor (§ below).
        let haystack: String
    }

    private let entries: [Entry]
    /// The NL model, loaded ONCE at build time and reused for queries. `nil` →
    /// keyword-only search.
    private let embedding: LoadedEmbedding?

    /// True when the sentence model loaded — i.e. results are semantic, not merely
    /// keyword. Lets the caller phrase the tool output honestly.
    var isSemantic: Bool { embedding != nil }

    init(records: [SemanticRecord]) {
        // Load the NL model ONCE for the whole build (not per record), then keep it
        // for query time. Built from value-type records + precomputed vectors/tokens.
        let loaded = Embedder.loaded()
        embedding = loaded
        var built: [Entry] = []
        built.reserveCapacity(records.count)
        for record in records {
            // L13-b: index CHUNKS, not the whole-record prefix — a phrase past the old
            // 2000-char bound is now embedded and findable. A short record yields one
            // chunk == its whole text (identical hash/vector/tokens/haystack as
            // before), so short-record results are unchanged. MIRROR of the app's init.
            for chunk in TranscriptChunker.chunks(for: record.text) {
                built.append(Entry(record: record,
                                   chunkText: chunk,
                                   vector: Embedder.vector(for: chunk, embedding: loaded?.embedding),
                                   tokens: SemanticIndex.tokenize(chunk),
                                   haystack: chunk.lowercased()))
            }
        }
        entries = built
    }

    func search(_ query: String, limit: Int = 20) -> [SemanticHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !entries.isEmpty else { return [] }
        let queryVector = Embedder.vector(for: q, embedding: embedding?.embedding)
        let queryTokens = SemanticIndex.tokenize(q)
        let queryLower = q.lowercased()

        // Score every chunk, then dedupe per record keeping the best-scoring chunk
        // (L13-b): the winning chunk supplies the snippet, and a record surfaces once.
        // Keyed by `line` (the record's stable identity in this mirror). A short
        // record (one chunk == whole text) collapses to exactly the pre-L13-b hit.
        var best: [String: SemanticHit] = [:]
        best.reserveCapacity(entries.count)
        for entry in entries {
            let semantic = (queryVector != nil && entry.vector != nil)
                ? SemanticIndex.cosine(queryVector!, entry.vector!) : 0
            let keyword = SemanticIndex.keywordScore(queryTokens, entry.tokens)
            let isSubstring = !queryLower.isEmpty && entry.haystack.contains(queryLower)
            // A "lexical" hit is what the old substring grep would have returned:
            // the query is a literal substring OR shares a ≥3-char token. This tool
            // REPLACES that grep, so lexical hits must behave at least as well.
            let lexical = isSubstring || keyword > 0

            let score: Double
            if lexical {
                // Lexical tier — always ranked ABOVE any semantic-only hit (+1.0
                // base), so an exact substring / shared term can never be buried
                // under a merely-similar paraphrase. Within the tier, order by the
                // app's blend (a substring with no shared ≥3-char token, e.g. "MVP"
                // inside a word, still gets the full keyword weight as its floor).
                // This makes the "exact substring ranks at/near top" criterion
                // structural, and — when embeddings are unavailable (semantic == 0
                // everywhere) — collapses to EXACTLY today's keyword/substring
                // behavior: only lexical hits appear, ranked by keyword overlap.
                let blended = SemanticIndex.blendedScore(semantic: semantic, keyword: keyword)
                score = 1.0 + max(blended, isSubstring ? SemanticIndex.substringFloor : 0)
            } else {
                // Semantic-only tier (a paraphrase with no shared token — the whole
                // reason this beats grep). Gate on a minimum cosine to trim the
                // ambient-similarity tail so a genuine query's junk neighbours fall
                // away; real paraphrases score well above it (measured ~0.4-0.66,
                // vs. ~0.2-0.3 for unrelated English text on this store).
                //
                // Honest limitation, inherited from the English sentence model and
                // shared with the app's `SemanticIndex`: out-of-vocabulary or
                // non-English text can act as a semantic attractor (e.g. a nonsense
                // token can score ~0.48 against a non-English sentence — higher than
                // a real paraphrase scores against its true target). No fixed cosine
                // floor fully separates those, so this gate reduces noise without
                // eliminating it; the visible per-hit score lets the caller judge,
                // and any lexical hit always outranks every semantic-only hit above.
                // A margin/rank-relative filter is a deliberate later refinement, not
                // an MCP-search concern (kept in scope: mirror the app's scoring).
                guard semantic >= SemanticIndex.minSemantic else { continue }
                score = 0.7 * semantic
            }

            // Per-record dedupe: keep the highest-scoring chunk. Ties keep the earlier
            // chunk (document order), so the winner is deterministic.
            if let existing = best[entry.record.line], existing.score >= score { continue }
            best[entry.record.line] = SemanticHit(line: entry.record.line,
                                                  snippet: SemanticIndex.snippet(entry.chunkText),
                                                  score: score,
                                                  sourceRank: entry.record.sourceRank)
        }
        // Rank by score; break ties by today's fixed per-source rank (entities 3 >
        // meetings 2 > dictations 1), then by line so equal-rank ties are stable.
        return Array(best.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.sourceRank != $1.sourceRank { return $0.sourceRank > $1.sourceRank }
            return $0.line < $1.line
        }.prefix(limit))
    }

    /// Minimum cosine for a *semantic-only* (no shared token, no substring) hit to
    /// be surfaced. Below this is ambient similarity, not real recall. Chosen from
    /// measured distributions on a real store: genuine paraphrases land ~0.40-0.66,
    /// unrelated English text ~0.20-0.32. Trims the noise tail without dropping real
    /// paraphrases; see the limitation note in `search` about non-English attractors.
    static let minSemantic = 0.35

    /// Floor score (within the lexical tier) for a literal-substring hit that shares
    /// no ≥3-char token with the query — equal to the full keyword weight, so such a
    /// hit ranks with genuine keyword matches rather than below them.
    static let substringFloor = 0.30

    // MARK: Scoring helpers (pure)

    /// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`tokenize`)
    static func tokenize(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 })
    }

    /// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`cosine`)
    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`keywordScore`)
    static func keywordScore(_ query: Set<String>, _ doc: Set<String>) -> Double {
        guard !query.isEmpty else { return 0 }
        return Double(query.intersection(doc).count) / Double(query.count)
    }

    /// Blend semantic similarity with keyword overlap. Cosine is clamped at 0 so a
    /// negative (anti-correlated) embedding can never drag a genuine exact-keyword
    /// hit below the inclusion threshold — a document that literally contains the
    /// query term must never be dropped because its vectors point the other way.
    ///
    /// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`blendedScore`)
    static func blendedScore(semantic: Double, keyword: Double) -> Double {
        0.7 * max(0, semantic) + 0.3 * keyword
    }

    /// MIRROR: Sources/Talkie/Search/SemanticIndex.swift (`snippet`)
    static func snippet(_ text: String, max: Int = 160) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= max ? t : String(t.prefix(max)) + "…"
    }
}
