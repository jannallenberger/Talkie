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

    /// Overrides the adaptive/per-category cleanup personality for this app.
    var cleanupStyle: CleanupStyle?
    /// Overrides the global cleanup intensity (used when "Adapt to the app" is off).
    var cleanupLevel: CleanupLevel?
    /// Overrides how dictated text is inserted (paste vs. character-by-character).
    var insertionMode: InsertionMode?
    /// Overrides whether the first letter is auto-capitalized.
    var autoCapitalize: Bool?
    /// Overrides whether spoken fillers (um, uh) are stripped.
    var removeFillers: Bool?

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
        cleanupLevel: CleanupLevel? = nil,
        insertionMode: InsertionMode? = nil,
        autoCapitalize: Bool? = nil,
        removeFillers: Bool? = nil,
        vocabularyFilter: [String]? = nil,
        activeMacroIDs: [String]? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.cleanupStyle = cleanupStyle
        self.cleanupLevel = cleanupLevel
        self.insertionMode = insertionMode
        self.autoCapitalize = autoCapitalize
        self.removeFillers = removeFillers
        self.vocabularyFilter = vocabularyFilter
        self.activeMacroIDs = activeMacroIDs
    }

    /// True when this profile overrides nothing — the row can be dropped so the
    /// list never accumulates no-op entries.
    var isEmpty: Bool {
        cleanupStyle == nil && cleanupLevel == nil && insertionMode == nil
            && autoCapitalize == nil && removeFillers == nil
            && (vocabularyFilter?.isEmpty ?? true)
            && (activeMacroIDs?.isEmpty ?? true)
    }
}

/// The fully-resolved, concrete config the dictation pipeline consumes. No
/// optionals — every field is decided by the global-default → per-category →
/// per-app merge in `AppProfileStore.resolve(for:settings:)`. Snapshotted once at
/// `beginDictation` so a mid-session toggle can't skew the in-flight session.
struct ResolvedProfile: Sendable, Equatable {
    /// Whether the cleanup *personality* (style) path is active. When `true`, the
    /// pipeline uses `cleanupStyle`; when `false`, it uses `cleanupLevel`.
    var appAdaptiveCleanup: Bool
    /// The resolved cleanup personality (meaningful when `appAdaptiveCleanup`).
    var cleanupStyle: CleanupStyle
    /// The resolved cleanup intensity (meaningful when `!appAdaptiveCleanup`).
    var cleanupLevel: CleanupLevel
    var insertionMode: InsertionMode
    var autoCapitalize: Bool
    var removeFillers: Bool
    /// The bundle id this profile resolved for (`nil` for helper apps with none).
    var bundleID: String?
    /// The app's coarse category, kept for downstream display/accounting.
    var category: AppCategory
}
