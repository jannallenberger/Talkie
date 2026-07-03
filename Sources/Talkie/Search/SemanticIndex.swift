import Foundation
import NaturalLanguage

/// What a search hit points back to.
enum SearchRecordKind: String, Sendable { case dictation, meeting, entity }

/// A piece of text the index can search over, with a stable id to jump back to.
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

    private struct Entry: Sendable {
        let record: SearchRecord
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
        entries = records.map { record in
            let bounded = String(record.text.prefix(SemanticIndex.maxIndexedChars))
            // Reuse the cached vector when the bounded text hasn't changed; otherwise
            // embed. The reuse key is the sidecar's stable content hash of the SAME
            // bounded slice we would embed, so a hit is exactly the vector a fresh
            // embed would produce — reuse never changes a search result.
            let hash = VectorSidecar.contentHash(bounded)
            let vector = reuse[hash] ?? Embedder.vector(for: bounded, embedding: loaded?.embedding)
            if let vector { merged[hash] = vector }
            return Entry(record: record, vector: vector,
                         tokens: SemanticIndex.tokenize(bounded))
        }
        vectorsByHash = merged
    }

    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !entries.isEmpty else { return [] }
        let queryVector = Embedder.vector(for: q, embedding: embedding?.embedding)
        let queryTokens = SemanticIndex.tokenize(q)

        let hits = entries.compactMap { entry -> SearchHit? in
            let semantic = (queryVector != nil && entry.vector != nil)
                ? SemanticIndex.cosine(queryVector!, entry.vector!) : 0
            let keyword = SemanticIndex.keywordScore(queryTokens, entry.tokens)
            let score = SemanticIndex.blendedScore(semantic: semantic, keyword: keyword)
            guard score > 0 else { return nil }
            return SearchHit(id: entry.record.id,
                             snippet: SemanticIndex.snippet(entry.record.text),
                             kind: entry.record.kind,
                             dateUnix: entry.record.dateUnix,
                             score: score)
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
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
