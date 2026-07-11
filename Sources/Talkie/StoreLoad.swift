import Foundation
import OSLog

/// Shared decode-with-quarantine logic for every `XxxStore`'s JSON persistence.
///
/// Every store here follows the same `@MainActor final class ...Store` shape:
/// load a JSON file on init, hold the decoded value in `@Published` state, and
/// atomically rewrite the whole file on every mutation. Before this helper,
/// each store's `load()` was a single `try?`-swallowing guard: ANY failure to
/// read or decode the file — a transient I/O error, a partial write from a
/// crash mid-save, one-off corruption — was silently treated the same as "no
/// file yet" and left the in-memory state empty. The very next mutation's
/// atomic `save()` then overwrote the file with that empty state, permanently
/// destroying whatever was actually on disk (lifetime stats, months of
/// streak/heatmap history, the context graph, the user's own scratchpad
/// notes...).
///
/// `DictionaryStore` already got this right by hand: it tells "file absent"
/// (truly first run — safe to start empty / seed defaults) apart from "file
/// present but undecodable" (never safe to treat as empty-and-then-save; the
/// bytes must be preserved). This type shares that pattern so every store gets
/// it for free instead of re-implementing it — or not — on its own.
enum StoreLoad {
    private static let log = Logger(subsystem: "com.talkie.app", category: "StoreLoad")

    /// The three things that can happen when a store tries to load its file.
    enum Outcome<T> {
        /// No file at the URL — a normal first run (or the file was deleted).
        /// The caller starts empty / seeds defaults; there is nothing to
        /// preserve and nothing was quarantined.
        case absent
        /// The file existed but its bytes couldn't be read or decoded. It has
        /// already been moved aside to a `.corrupt` sibling so the bad bytes
        /// aren't lost. The caller must start empty WITHOUT saving on this
        /// path — writing now would overwrite nothing (the original is
        /// already gone from `url`), but more importantly it establishes the
        /// pattern every call site relies on: no save on the failure path.
        case quarantined
        /// Decoded successfully.
        case loaded(T)
    }

    /// Load and decode JSON at `url`, distinguishing "absent" from
    /// "quarantined" for callers (like `ContextGraphStore`) that need to react
    /// differently to a just-quarantined file — e.g. resetting a watermark
    /// that would otherwise wrongly assume the (now-empty) in-memory state is
    /// already caught up.
    static func loadOutcome<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        decoder: JSONDecoder = JSONDecoder()
    ) -> Outcome<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(T.self, from: data) else {
            quarantine(url)
            return .quarantined
        }
        return .loaded(decoded)
    }

    /// Convenience wrapper over `loadOutcome` for the common case: a store
    /// that just wants "give me the value if I can have it, otherwise I'll
    /// start empty" — with the quarantine side effect already handled either
    /// way. This is what nearly every store's `load()` should call.
    static func loadJSONWithQuarantine<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        decoder: JSONDecoder = JSONDecoder()
    ) -> T? {
        if case .loaded(let value) = loadOutcome(type, from: url, decoder: decoder) {
            return value
        }
        return nil
    }

    /// Move an undecodable store file to `<name>.corrupt` so it's preserved
    /// (and out of the way) rather than silently overwritten by the store's
    /// next save. Clears any stale `.corrupt` sibling from a previous failed
    /// launch first, so the move can't fail just because one already exists.
    /// Best effort: a failure here just leaves the original file in place —
    /// still safe, since the caller never saves on this path either way.
    private static func quarantine(_ url: URL) {
        let corruptURL = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: corruptURL)
        do {
            try FileManager.default.moveItem(at: url, to: corruptURL)
            log.error("Quarantined undecodable store file \(url.lastPathComponent, privacy: .public) -> \(corruptURL.lastPathComponent, privacy: .public)")
        } catch {
            log.error("Failed to quarantine undecodable store file \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
