import Foundation

/// On-disk persistence for the semantic index's sentence vectors (L13-a).
///
/// Today the `SemanticIndex` re-embeds every record on every rebuild, and every
/// relaunch starts from zero — the vectors are never persisted. Embedding is the
/// dominant cost of an index build, so this sidecar caches the computed float
/// vectors on disk keyed by a **stable content hash**, letting a rebuild re-embed
/// only records whose bounded text is new or changed (everything else is a cache
/// hit). It is a *derived cache*, never a source of truth: any mismatch,
/// corruption, or missing file is treated as ABSENT and the caller rebuilds from
/// scratch — so a bad sidecar can only cost time, never correctness.
///
/// Layout under `<supportDir>/search/` (siblings, so a human/auditor can inspect):
///   • `vectors.bin`     — `count × dimension` little-endian `Float32` rows.
///   • `vector_ids.json` — the row-ordered content-hash strings (`[String]`),
///                         parallel to the rows in `vectors.bin`.
///   • `index_meta.json` — `{ schemaVersion, dimension, modelKind, builtUnix }`,
///                         so a dimension/model change discards the blob cleanly.
///
/// **Privacy invariant (load-bearing):** the sidecar stores ONLY content hashes
/// and floats. It NEVER writes any literal transcript text — a `grep` of the
/// `search/` directory for something the user dictated must come up empty. The
/// hash is one-way (FNV-1a over the bounded text); the floats are an embedding,
/// not the source. This mirrors the graph's on-disk discipline, one step stricter
/// (the graph keeps 120-char provenance snippets; the sidecar keeps none).
///
/// `Sendable` value type: it owns no mutable shared state, just the target
/// directory, so it can be constructed on any actor and its `load`/`save` run
/// off-main inside the existing detached rebuild task.
struct VectorSidecar: Sendable {
    /// Bump when the on-disk shape changes in a non-back-compatible way. A meta
    /// with a different `schemaVersion` is treated as absent → cold rebuild.
    static let schemaVersion = 1
    /// Identifies the embedding model whose vectors these are. If the app ever
    /// switches embedders (dimension or model family), this string changes and the
    /// old blob is discarded rather than mixed with incompatible vectors. Matches
    /// the default `Embedder.sentenceEmbedding()` (Apple NL English sentence model).
    static let modelKind = "nl-sentence-en"

    /// The `search/` subfolder of the app's Application Support dir (or a test dir).
    /// `nil` disables persistence entirely (load returns empty, save is a no-op) —
    /// used by tests that want the pre-L13-a "always cold" behavior.
    let directory: URL?

    /// Build a sidecar rooted at `<supportDirectory>/search/`. Pass `nil` to
    /// disable persistence. The default resolves the app's real support dir; tests
    /// pass a temp dir (hermetic) or `nil` (no persistence).
    init(supportDirectory: URL?) {
        directory = supportDirectory?.appendingPathComponent("search", isDirectory: true)
    }

    private var vectorsURL: URL? { directory?.appendingPathComponent("vectors.bin") }
    private var idsURL: URL? { directory?.appendingPathComponent("vector_ids.json") }
    private var metaURL: URL? { directory?.appendingPathComponent("index_meta.json") }

    // MARK: Stable content hash

    /// A stable, process- and machine-independent hash of a record's *bounded* text
    /// (the same `prefix(maxIndexedChars)` slice the `SemanticIndex` embeds), used
    /// as the reuse key. `Swift.Hashable` is per-run seeded, so it would make the
    /// key differ across launches and defeat cross-process reuse; this is the same
    /// FNV-1a construction `ContextGraphPolicy.stableHash` uses for commitment keys,
    /// so the same text always maps to the same key on every run.
    static func contentHash(_ boundedText: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in boundedText.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Load

    /// The persisted meta, if present and decodable.
    private struct Meta: Codable {
        var schemaVersion: Int
        var dimension: Int
        var modelKind: String
        var builtUnix: Double
    }

    /// Load the cached vectors as a `hash → vector` map for reuse. Returns EMPTY on
    /// ANY of: persistence disabled, missing files, meta decode failure, a
    /// `schemaVersion`/`modelKind` mismatch, a row-count vs id-count mismatch, or a
    /// `vectors.bin` length that isn't an exact multiple of the meta `dimension`.
    /// Empty means "no reuse" → the caller re-embeds everything (a cold rebuild),
    /// which is always correct, just slower.
    func load() -> [String: [Double]] {
        guard let vectorsURL, let idsURL, let metaURL else { return [:] }

        guard
            let metaData = try? Data(contentsOf: metaURL),
            let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
            meta.schemaVersion == Self.schemaVersion,
            meta.modelKind == Self.modelKind,
            meta.dimension > 0
        else { return [:] }

        guard
            let idsData = try? Data(contentsOf: idsURL),
            let ids = try? JSONDecoder().decode([String].self, from: idsData),
            let blob = try? Data(contentsOf: vectorsURL)
        else { return [:] }

        let dim = meta.dimension
        let bytesPerRow = dim * MemoryLayout<Float32>.size
        // The blob must be an exact grid of `count × dimension` Float32s, and its
        // row count must match the id count — any drift means a torn/foreign file,
        // so bail to a cold rebuild rather than trust a partial cache.
        guard bytesPerRow > 0, blob.count == ids.count * bytesPerRow else { return [:] }

        var result: [String: [Double]] = [:]
        result.reserveCapacity(ids.count)
        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for (row, hash) in ids.enumerated() {
                var vector = [Double](repeating: 0, count: dim)
                let base = row * bytesPerRow
                for i in 0..<dim {
                    // Little-endian Float32 read; `loadUnaligned` avoids any
                    // alignment assumption about where the row starts in the blob.
                    let bits = raw.loadUnaligned(fromByteOffset: base + i * MemoryLayout<Float32>.size,
                                                 as: UInt32.self)
                    vector[i] = Double(Float(bitPattern: UInt32(littleEndian: bits)))
                }
                result[hash] = vector
            }
        }
        return result
    }

    // MARK: Save

    /// Persist exactly the CURRENT records' vectors, keyed by content hash. Writing
    /// only the hashes passed here is how deleted/pruned content ages out: a record
    /// that's gone on this rebuild simply isn't in `vectorsByHash`, so its row is
    /// not re-written and the old row is dropped on the atomic overwrite.
    ///
    /// - Only entries with a vector of the model's expected dimension are written
    ///   (records that failed to embed — e.g. empty text — are skipped, exactly as
    ///   they're skipped in the index). If nothing qualifies, the sidecar is cleared
    ///   so it never keeps a stale blob.
    /// - All three files are written `.atomic` so a crash mid-write can't leave a
    ///   torn set (and even if it somehow did, `load()`'s count/dimension checks
    ///   would reject it).
    func save(vectorsByHash: [String: [Double]]) {
        guard let directory, let vectorsURL, let idsURL, let metaURL else { return }

        // Determine the dimension from the data itself (the model's output width),
        // taking the modal vector length and keeping only rows that match it — a
        // ragged map (shouldn't happen, but be defensive) can't corrupt the grid.
        guard let dimension = vectorsByHash.values.map(\.count).filter({ $0 > 0 }).first else {
            clear() // nothing embeddable → don't leave a stale cache around
            return
        }

        // Stable row order: sort hashes so the blob + ids are deterministic (helps
        // reproducibility and makes a byte-diff meaningful). Order is otherwise
        // irrelevant to correctness — the ids file records it.
        let orderedHashes = vectorsByHash.keys
            .filter { (vectorsByHash[$0]?.count ?? 0) == dimension }
            .sorted()

        guard !orderedHashes.isEmpty else { clear(); return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var blob = Data(capacity: orderedHashes.count * dimension * MemoryLayout<Float32>.size)
        for hash in orderedHashes {
            let vector = vectorsByHash[hash]! // length == dimension by the filter above
            for value in vector {
                var le = Float32(value).bitPattern.littleEndian
                withUnsafeBytes(of: &le) { blob.append(contentsOf: $0) }
            }
        }

        let meta = Meta(schemaVersion: Self.schemaVersion, dimension: dimension,
                        modelKind: Self.modelKind, builtUnix: Date().timeIntervalSince1970)

        guard
            let idsData = try? JSONEncoder().encode(orderedHashes),
            let metaData = try? JSONEncoder().encode(meta)
        else { return }

        // Write vectors + ids first, then meta last: meta is the "commit" record
        // load() gates on, so if a crash interrupts the sequence a missing/older
        // meta simply makes load() treat the set as absent (cold rebuild).
        try? blob.write(to: vectorsURL, options: .atomic)
        try? idsData.write(to: idsURL, options: .atomic)
        try? metaData.write(to: metaURL, options: .atomic)
    }

    // MARK: Clear

    /// Delete the sidecar files (best effort). Used by the "Clear everything" flow
    /// so the wipe is immediate and doesn't depend on the debounced rebuild to
    /// eventually rewrite an empty cache. Idempotent; safe if the files are absent.
    func clear() {
        for url in [vectorsURL, idsURL, metaURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
