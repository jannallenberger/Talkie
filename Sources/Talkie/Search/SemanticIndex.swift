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

/// On-device sentence embeddings via Apple NaturalLanguage — no network, no
/// dependency. Returns `nil` when the model is unavailable, so callers degrade to
/// keyword-only search.
enum Embedder {
    static func sentenceEmbedding() -> NLEmbedding? {
        NLEmbedding.sentenceEmbedding(for: .english)
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
/// it still returns useful hits when embeddings are unavailable. `Sendable` (it
/// stores only precomputed vectors + token sets, never the NL model).
struct SemanticIndex: Sendable {
    private struct Entry: Sendable {
        let record: SearchRecord
        let vector: [Double]?
        let tokens: Set<String>
    }

    private let entries: [Entry]

    init(records: [SearchRecord]) {
        let embedding = Embedder.sentenceEmbedding()
        entries = records.map { record in
            Entry(record: record,
                  vector: Embedder.vector(for: record.text, embedding: embedding),
                  tokens: SemanticIndex.tokenize(record.text))
        }
    }

    func search(_ query: String, limit: Int = 20) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !entries.isEmpty else { return [] }
        let queryVector = Embedder.vector(for: q, embedding: Embedder.sentenceEmbedding())
        let queryTokens = SemanticIndex.tokenize(q)

        let hits = entries.compactMap { entry -> SearchHit? in
            let semantic = (queryVector != nil && entry.vector != nil)
                ? SemanticIndex.cosine(queryVector!, entry.vector!) : 0
            let keyword = SemanticIndex.keywordScore(queryTokens, entry.tokens)
            let score = 0.7 * semantic + 0.3 * keyword
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

    static func snippet(_ text: String, max: Int = 160) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= max ? t : String(t.prefix(max)) + "…"
    }
}
