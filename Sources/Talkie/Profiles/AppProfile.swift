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
    /// (absent ⇒ insert as spoken). Mutually exclusive with `outputLanguageAdaptive`
    /// — the editor sheet clears one whenever the other is set (see
    /// `AppProfileEditor.outputLanguageCode`'s setter).
    var outputLanguageCode: String?

    /// Adaptive output language (this feature): instead of a FIXED per-app target,
    /// each dictation's insert-language is DETECTED from the text already in the
    /// app — so one profile handles a channel that mixes languages (a German/English
    /// Slack thread) instead of forcing a single fixed code. `nil`/`false` (the
    /// default) is fixed/off mode, governed by `outputLanguageCode` as before; only
    /// `true` turns adaptive on. Still opt-in per app, still zero new GLOBAL
    /// settings — same justification as `outputLanguageCode` itself, just a second
    /// mode on the same per-app dial rather than a new surface. When this is `true`
    /// it WINS over any stale `outputLanguageCode` (`AppProfileStore.resolve` reads
    /// this first) — the two are meant to be mutually exclusive, and the Settings
    /// picker enforces that by construction (picking one clears the other). Kept
    /// optional so the field stays sparse — a profile carrying only this is NOT
    /// `isEmpty`, and files written before it existed decode cleanly (absent ⇒ off).
    var outputLanguageAdaptive: Bool?

    init(
        bundleID: String,
        displayName: String,
        cleanupStyle: CleanupStyle? = nil,
        insertionMode: InsertionMode? = nil,
        vocabularyFilter: [String]? = nil,
        activeMacroIDs: [String]? = nil,
        neverStore: Bool? = nil,
        outputLanguageCode: String? = nil,
        outputLanguageAdaptive: Bool? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.cleanupStyle = cleanupStyle
        self.insertionMode = insertionMode
        self.vocabularyFilter = vocabularyFilter
        self.activeMacroIDs = activeMacroIDs
        self.neverStore = neverStore
        self.outputLanguageCode = outputLanguageCode
        self.outputLanguageAdaptive = outputLanguageAdaptive
    }

    /// True when this profile overrides nothing — the row can be dropped so the
    /// list never accumulates no-op entries. `neverStore` counts as an override
    /// (only when actually `true`) so a Private-app row survives the drop even when
    /// the user changed nothing else. `outputLanguageCode` counts as an override
    /// only when it's a non-empty code, so an output-language-only row survives too
    /// (and a picker set back to "Insert as spoken" writes nil and drops cleanly).
    /// `outputLanguageAdaptive` counts as an override only when actually `true`,
    /// mirroring `neverStore`'s bool convention.
    var isEmpty: Bool {
        cleanupStyle == nil && insertionMode == nil
            && (vocabularyFilter?.isEmpty ?? true)
            && (activeMacroIDs?.isEmpty ?? true)
            && !(neverStore ?? false)
            && (outputLanguageCode?.isEmpty ?? true)
            && !(outputLanguageAdaptive ?? false)
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
    /// off the pinned session profile without re-resolving. When `outputLanguageAdaptive`
    /// is true this is ALWAYS nil (`AppProfileStore.resolve` never populates both —
    /// adaptive wins over a stale fixed code), so a call site can keep treating a
    /// non-nil value here as "translate to this fixed code" without re-checking
    /// adaptive itself, UNLESS it specifically needs to branch on adaptive (only
    /// `endDictation`'s translate hook does).
    var outputLanguageCode: String? = nil

    /// Adaptive output language (this feature): when true, `endDictation` DETECTS
    /// this dictation's insert-language from text already present in the target app
    /// instead of using a fixed `outputLanguageCode` (which is always nil alongside
    /// this — see above). Resolved from `AppProfile.outputLanguageAdaptive` (absent
    /// ⇒ false, i.e. fixed/off mode via `outputLanguageCode`). Snapshotted at
    /// `beginDictation` like every other field.
    ///
    /// Representation note: this sits as a SECOND field next to `outputLanguageCode`
    /// rather than folding both into one `OutputLanguageMode` enum. An enum would
    /// touch every existing E8 call site that pattern-matches `outputLanguageCode`
    /// as a plain optional (the `AppDelegate` translate hook, the optimistic-insertion
    /// skip, the Settings subtitle, and the E8 test suite's `ResolvedProfile(...)`
    /// initializers) — for a purely additive one-bit mode, a second sparse-bool field
    /// (the same shape as `neverStore`) is the smaller, more idiomatic diff and keeps
    /// every pre-existing `if let outputLanguageCode` correct unchanged: it's simply
    /// never populated in adaptive mode, so those call sites silently no-op exactly
    /// as they do for "no per-app rule" today. Only the one call site that needs to
    /// tell "no translation" apart from "adaptive translation" (`endDictation`'s
    /// translate hook) reads this second field.
    var outputLanguageAdaptive: Bool = false

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

/// Adaptive per-app output language: the multi-language sibling of E8's fixed
/// `outputLanguageCode`. Where E8 requires the user to hand-pick ONE target
/// language for an app, Adaptive mode (`AppProfile.outputLanguageAdaptive`)
/// requires no manual pick at all — each dictation's target is DETECTED from
/// text already present in the target app, so one profile can follow a
/// conversation that itself switches languages (a mixed German/English Slack
/// thread) instead of forcing a single fixed code onto it.
///
/// This is still SAFETY-FIRST, same doctrine as `OutputTranslator`: a guard
/// tripping must always fall back to inserting the dictation AS SPOKEN — never a
/// guess, never a wrong-language surprise, never an extra AX read the user didn't
/// consent to. `decide(...)` is the pure, deterministic core of that fail-closed
/// logic, kept model- and AX-free so it can be exercised by a plain unit test —
/// the same shape as `OutputTranslator.preflight`/`decideOutput`.
enum AdaptiveOutputLanguage {

    /// The outcome of the pure gate core.
    enum Decision: Equatable {
        /// A gate tripped before any detection was even attempted (consent off,
        /// Private app, or adaptive isn't even on for this app) — insert as spoken,
        /// and — critically — never perform the AX read at all. `reason` is a short
        /// marker for the debug log.
        case noAttempt(reason: String)
        /// Detection was attempted but came back unusable (empty/too-short AX text,
        /// or a context language that couldn't be scored) — insert as spoken.
        case fallback(reason: String)
        /// The context app is already in the language you spoke — nothing to
        /// translate, skip the model entirely (mirrors `OutputTranslator`'s own
        /// guard (d), and for the same reason: cheap common case, zero LLM calls).
        case skipSameLanguage
        /// A confident, DIFFERENT context language was detected — translate the
        /// dictation to this code via `OutputTranslator.translate`.
        case detected(languageCode: String)
    }

    /// Gate 1 (consent + privacy), evaluated BEFORE any AX read is attempted — the
    /// two conditions that make reading the target app's existing content
    /// permissible at all. Mirrors the exact pattern `AppDelegate.beginDictation`
    /// already uses to gate `ContextCapture.mine` (`settings.contextAwareness &&
    /// !profile.neverStore`): adaptive detection piggybacks on the SAME consent,
    /// it does not add a new one, and it must never read a Private app's focused
    /// content, full stop.
    ///
    /// Returns the `.noAttempt` decision when a gate trips, or `nil` meaning
    /// "gates cleared, proceed to read the app's existing text."
    static func preflightGate(contextAwareness: Bool, neverStore: Bool) -> Decision? {
        guard contextAwareness else { return .noAttempt(reason: "context-awareness-off") }
        guard !neverStore else { return .noAttempt(reason: "never-store") }
        return nil
    }

    /// Gate 2 (usable signal), evaluated AFTER the bounded AX read returns. Given
    /// the raw (possibly nil/empty) text read from the target app's focused field,
    /// the input dictation's language code, and that same text's detected
    /// language, decide whether there's anything to act on.
    ///
    /// - `contextText`: the bounded sample read from the app's existing content
    ///   (e.g. `AXFieldReader.focusedElementValue()`'s value), or `nil` if the read
    ///   failed/found nothing readable.
    /// - `inputCode`: the base language code of the JUST-DICTATED text (from the
    ///   session's pinned `cleanupLangCode`, falling back to content detection —
    ///   same source `OutputTranslator.preflight` uses for its own `inputCode`).
    /// - `contextCode`: `LanguageDetector.dominantLanguageCode` run over
    ///   `contextText`, precomputed by the caller so this stays a pure function
    ///   (no `NLLanguageRecognizer` call inside the decision core itself).
    static func decide(
        contextText: String?,
        inputCode: String?,
        contextCode: String?
    ) -> Decision {
        guard let contextText,
              !contextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              LanguageDetector.canScore(contextText) else {
            // Unreadable, empty, or too short to language-ID at all ⇒ cannot detect
            // ⇒ insert as spoken. Never guess from a fragment.
            return .fallback(reason: "context-unreadable")
        }
        guard let contextCode, !contextCode.isEmpty else {
            // Read plenty of text but couldn't call its language — same honest
            // fallback as above, just a different reason for the log.
            return .fallback(reason: "context-undetected")
        }
        guard let inputCode, !inputCode.isEmpty else {
            // We don't know what language was just spoken, so we can't tell
            // "same" from "different" — don't gamble a translation.
            return .fallback(reason: "input-undetected")
        }
        // Lowercased before comparing — matches `OutputTranslator.base(_:)`'s own
        // defensive normalization for the identical "are these the same base code"
        // question, so the two language-comparison call sites in this feature area
        // can never disagree over a casing quirk (`languageCode(of:)`/`NLLanguage`
        // raw values are lowercase in practice, but this costs nothing and removes
        // the assumption).
        if contextCode.lowercased() == inputCode.lowercased() {
            // Guard (d)'s sibling: the app is already in the language you spoke —
            // zero LLM calls, insert as spoken (this IS the correct outcome, not a
            // fallback).
            return .skipSameLanguage
        }
        return .detected(languageCode: contextCode)
    }
}
