import Foundation

/// A per-app *override sheet*. Every behaviour field is optional: `nil` = inherit
/// the global default (or, for cleanup style, the per-category default). Keyed by
/// bundle id, so it survives an app being renamed or moved.
///
/// Persisted sparsely — an app with only an insertion override stores only that
/// one field. Decode tolerates missing fields, so files written before a field
/// existed (and files from a future feature that adds one) round-trip cleanly.
struct AppProfile: Codable, Identifiable, Sendable, Hashable {
    /// The key, e.g. `"com.tinyspeck.slackmacgap"`.
    var bundleID: String
    /// Freshest known display name, for the Settings list (refreshed on upsert).
    var displayName: String

    var id: String { bundleID }

    // MARK: Behaviour overrides (nil = inherit)

    /// Overrides the per-category cleanup *style* for this app — the whole cleanup
    /// story (its own intensity + tone). `nil` inherits the category style.
    var cleanupStyle: CleanupStyle?
    /// Overrides how dictated text is inserted (paste vs. character-by-character).
    var insertionMode: InsertionMode?

    /// Subset of the global dictionary's vocabulary terms to bias toward in this
    /// app (`nil`/empty = all). So terminal dictation isn't biased toward your
    /// contacts' names. Post-feature-05 this becomes a tag/entity filter on the
    /// context graph rather than a literal whitelist (the body of
    /// `AppProfileStore.biasVocabulary` swaps; this field stays the parameter).
    var vocabularyFilter: [String]?

    /// Voice-macro ids active in this app (feature 11; `nil`/empty = all). A parked
    /// field — the model carries it now so feature 11 needs no data migration later.
    var activeMacroIDs: [String]?

    init(
        bundleID: String,
        displayName: String,
        cleanupStyle: CleanupStyle? = nil,
        insertionMode: InsertionMode? = nil,
        vocabularyFilter: [String]? = nil,
        activeMacroIDs: [String]? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.cleanupStyle = cleanupStyle
        self.insertionMode = insertionMode
        self.vocabularyFilter = vocabularyFilter
        self.activeMacroIDs = activeMacroIDs
    }

    /// True when this profile overrides nothing — the row can be dropped so the
    /// list never accumulates no-op entries.
    var isEmpty: Bool {
        cleanupStyle == nil && insertionMode == nil
            && (vocabularyFilter?.isEmpty ?? true)
            && (activeMacroIDs?.isEmpty ?? true)
    }
}

/// The fully-resolved, concrete config the dictation pipeline consumes. No
/// optionals — every field is decided by the per-category → per-app merge in
/// `AppProfileStore.resolve(for:settings:)`. Snapshotted once at `beginDictation`
/// so a mid-session toggle can't skew the in-flight session.
///
/// Cleanup is now a single model: the resolved `cleanupStyle` is the whole story
/// (its own intensity + tone). Capitalization and filler-stripping are no longer
/// per-app fields — they're derived from `cleanupStyle`/`category` at the call
/// site (a dictated shell command in a faithful terminal/coding app keeps its
/// lowercase; everything else capitalizes; fillers strip whenever the AI didn't).
struct ResolvedProfile: Sendable, Equatable {
    /// The resolved cleanup style — Talkie's sole cleanup instruction source.
    var cleanupStyle: CleanupStyle
    var insertionMode: InsertionMode
    /// The bundle id this profile resolved for (`nil` for helper apps with none).
    var bundleID: String?
    /// The app's coarse category, kept for downstream display/accounting and for
    /// the capitalization rule (terminal/coding + faithful ⇒ no leading capital).
    var category: AppCategory

    /// Whether to auto-capitalize the first letter. A smart, always-on default now
    /// that the per-app toggle is gone: capitalize everywhere EXCEPT a dictated
    /// shell command / code line — when the target is a terminal or coding app AND
    /// the resolved style is `.faithful` (verbatim), forcing a leading capital would
    /// corrupt `git status` into `Git status`, so leave it lowercase.
    var autoCapitalize: Bool {
        if (category == .terminal || category == .coding), cleanupStyle == .faithful {
            return false
        }
        return true
    }
}
