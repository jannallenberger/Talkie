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

    /// Marks this app "Private": dictation still types the text, but Talkie stores
    /// NOTHING and learns NOTHING from it — no history entry, no context-graph
    /// provenance, no app-usage record, no niche-vocabulary harvest, and no
    /// learn-from-edits watcher. `nil` (or `false`) inherits the normal behaviour;
    /// only `true` opts the app out. Kept optional so the field is sparse in
    /// `app_profiles.json` — a profile with only this set is NOT `isEmpty`, and old
    /// files that predate it decode cleanly (absent ⇒ off).
    var neverStore: Bool?

    /// The language this app's finished dictation is *inserted* in (E8). A base
    /// language code — "en", "de", … — that, when set, makes Talkie translate the
    /// finished text ON-DEVICE into that language just before insertion, so a
    /// German speaker can draft an English Slack message by voice. `nil` (the
    /// default and the common case) inserts the text in the language it was spoken.
    /// Commands are still spoken and executed in the input language; only the
    /// dictated body is translated (`OutputTranslator`). Kept optional so the
    /// field stays sparse in `app_profiles.json` — a profile carrying only this
    /// is NOT `isEmpty`, and files written before it existed decode cleanly
    /// (absent ⇒ insert as spoken).
    var outputLanguageCode: String?

    init(
        bundleID: String,
        displayName: String,
        cleanupStyle: CleanupStyle? = nil,
        insertionMode: InsertionMode? = nil,
        vocabularyFilter: [String]? = nil,
        activeMacroIDs: [String]? = nil,
        neverStore: Bool? = nil,
        outputLanguageCode: String? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.cleanupStyle = cleanupStyle
        self.insertionMode = insertionMode
        self.vocabularyFilter = vocabularyFilter
        self.activeMacroIDs = activeMacroIDs
        self.neverStore = neverStore
        self.outputLanguageCode = outputLanguageCode
    }

    /// True when this profile overrides nothing — the row can be dropped so the
    /// list never accumulates no-op entries. `neverStore` counts as an override
    /// (only when actually `true`) so a Private-app row survives the drop even when
    /// the user changed nothing else. `outputLanguageCode` counts as an override
    /// only when it's a non-empty code, so an output-language-only row survives too
    /// (and a picker set back to "Insert as spoken" writes nil and drops cleanly).
    var isEmpty: Bool {
        cleanupStyle == nil && insertionMode == nil
            && (vocabularyFilter?.isEmpty ?? true)
            && (activeMacroIDs?.isEmpty ?? true)
            && !(neverStore ?? false)
            && (outputLanguageCode?.isEmpty ?? true)
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

    /// When true this app is "Private": the session inserts text normally but the
    /// pipeline persists and learns NOTHING from it (no history/graph/app-usage/niche
    /// harvest, no learn-from-edits watcher). Aggregate word counts (lifetime stats +
    /// streak) still increment — they carry no content and no app identity, so the WPM
    /// dashboard stays honest. Resolved from `AppProfile.neverStore` (absent ⇒ false).
    var neverStore: Bool = false

    /// The language the finished dictation is *inserted* in for this app (E8), or
    /// `nil` to insert it as spoken (the default, and the only value for an app with
    /// no per-app rule). When non-nil, `endDictation` runs the on-device
    /// `OutputTranslator` over the finished text just before insertion. Resolved
    /// from `AppProfile.outputLanguageCode` (absent/empty ⇒ nil). Snapshotted at
    /// `beginDictation` like every other field, so a mid-session change can't flip
    /// an in-flight dictation, and so the optimistic-insertion skip below can read it
    /// off the pinned session profile without re-resolving.
    var outputLanguageCode: String? = nil

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
