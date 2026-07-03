import Foundation

/// A7 — read a competitor dictation app's local dictionary/replacement files and turn
/// them into a `TalkiePack`, so a switcher keeps their hard-won jargon. The whole point
/// is that the imported pack then flows through A4's preview/merge sheet — one code
/// path, one UX (`DictionaryStore.previewMerge` → `ImportPreviewSheet` → `merge`). This
/// file only knows how to *read* the other apps' files and shape them into a pack; it
/// never writes anything and never touches the network (it's parsing bytes the user
/// already has on disk).
///
/// Design stance, stated plainly because it's load-bearing:
///
/// - **Best-effort and version-tolerant.** Competitor formats aren't a contract we
///   control; they drift between releases. Every parser reads the fields it recognizes,
///   ignores everything else, and — critically — when it can't make sense of the bytes
///   at all it throws a clear "couldn't read" error rather than crashing or, worse,
///   silently importing garbage. A malformed file changes nothing (the preview sheet is
///   never staged). This mirrors `TalkiePack`'s own tolerant-decode discipline.
/// - **Read-only, the user's OWN files.** We only ever read; we bundle no competitor
///   data; there is no scraping of app databases beyond the documented/plain files. This
///   is the legal/optics line from the package spec, enforced by the code shape (there
///   is no write path here at all).
/// - **Fixtures, not fetched samples.** The parsers were authored against each app's
///   documented/public format *shape* and are verified against committed fixture files
///   (`Tests/TalkieTests/Fixtures/competitor/`). Verifying against a real export from a
///   fresh install of each competitor is a follow-up — noted in the PR — because we
///   can't install three other apps headlessly. The forgiving parse is exactly what
///   lets a real file whose shape drifted slightly still import.
enum CompetitorDictionaryImport {

    /// The competitor apps we can read. Each case carries everything the UI and the
    /// parser need: a display name, the attribution stamped onto the produced pack, the
    /// default on-disk locations to auto-detect, and the parse entry point. Adding an app
    /// later is a new case + a new parser + a fixture — nothing else moves.
    enum App: String, CaseIterable, Sendable {
        case voiceInk
        case superwhisper
        case wisprFlow

        /// Shown in the "Import from another app" menu and used to build the attribution.
        var displayName: String {
            switch self {
            case .voiceInk: return "VoiceInk"
            case .superwhisper: return "Superwhisper"
            case .wisprFlow: return "Wispr Flow"
            }
        }

        /// Stamped onto the produced pack so the import preview shows provenance
        /// ("Imported from VoiceInk") and the merged rules read as curated, not learned.
        var attribution: String {
            String(format: "Imported from %@".loc, displayName)
        }

        /// The pack name suggested in the preview header when we import from this app.
        var packName: String {
            String(format: "%@ dictionary".loc, displayName)
        }

        /// Default on-disk locations where this app is known to keep its dictionary /
        /// replacement data, most-specific first. Auto-detect checks these; the file
        /// picker fallback covers exports the user saved somewhere else. Paths are
        /// home-relative and expanded lazily (see `defaultLocations`).
        ///
        /// These are best-effort guesses at documented/observed locations — if an app
        /// moves its files, auto-detect simply won't light up for it and the user reaches
        /// for the picker. We never fail because a path is absent.
        fileprivate var candidateRelativePaths: [String] {
            switch self {
            case .voiceInk:
                // VoiceInk (open-source macOS app, bundle id com.prakashjoshipax.VoiceInk)
                // keeps user data in its Application Support container. We look for a
                // plain JSON config/export next to the container.
                return [
                    "Library/Application Support/com.prakashjoshipax.VoiceInk/dictionary.json",
                    "Library/Application Support/com.prakashjoshipax.VoiceInk/VoiceInk.json",
                    "Library/Application Support/VoiceInk/dictionary.json",
                ]
            case .superwhisper:
                // Superwhisper keeps a user-facing folder in ~/Documents/superwhisper and
                // also an Application Support container. Its dictionary/replacements are
                // JSON.
                return [
                    "Documents/superwhisper/dictionary.json",
                    "Documents/superwhisper/replacements.json",
                    "Library/Application Support/com.superduper.superwhisper/dictionary.json",
                ]
            case .wisprFlow:
                // Wispr Flow exposes a dictionary export the user saves themselves; we
                // guess the common export drop spots but really expect the picker.
                return [
                    "Library/Application Support/Wispr Flow/dictionary.json",
                    "Downloads/wispr-flow-dictionary.json",
                    "Downloads/flow-dictionary.json",
                ]
            }
        }

        /// The candidate locations as absolute URLs under the current user's home.
        fileprivate var defaultLocations: [URL] {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return candidateRelativePaths.map { home.appendingPathComponent($0) }
        }

        /// Parse this app's bytes into a `TalkiePack`. Pure, throwing, fixture-driven.
        func parse(_ data: Data) throws -> TalkiePack {
            switch self {
            case .voiceInk: return try CompetitorParsers.voiceInk(data)
            case .superwhisper: return try CompetitorParsers.superwhisper(data)
            case .wisprFlow: return try CompetitorParsers.wisprFlow(data)
            }
        }
    }

    /// One auto-detected app plus the file we found for it. The UI shows a row per
    /// detected app; tapping it reads that file and stages the preview.
    struct Detected: Identifiable, Sendable {
        var id: String { app.rawValue }
        let app: App
        /// The first existing candidate file for this app.
        let fileURL: URL
    }

    /// Scan every supported app's default locations and return the ones actually present
    /// on this Mac. Cheap `fileExists` checks only — no reading, no parsing — so it's safe
    /// to call when the Dictionary pane appears. Apps with nothing on disk are simply
    /// absent from the result (the UI shows only detected apps, per the spec).
    static func detectInstalledApps() -> [Detected] {
        App.allCases.compactMap { app in
            guard let url = app.defaultLocations.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) else { return nil }
            return Detected(app: app, fileURL: url)
        }
    }

    /// Read a file at `url` for a specific app and produce a pack, or throw a clear
    /// error. Handles the "can't even read the bytes" case (permissions, vanished file)
    /// distinctly from "read it but it isn't the shape we expected" so the UI can show
    /// the right calm message. Security-scoped access is the caller's concern (the picker
    /// path wraps this in start/stop) — this stays a pure read of a URL it's handed.
    static func readPack(app: App, from url: URL) throws -> TalkiePack {
        guard let data = try? Data(contentsOf: url) else {
            throw CompetitorImportError.unreadable
        }
        return try app.parse(data)
    }
}

/// What went wrong importing from another app. Deliberately tiny — the UI only needs to
/// tell the user "couldn't read that file", never a decoder backtrace. Kept separate
/// from `TalkiePackError` so a caller can distinguish a competitor-parse failure if it
/// ever wants to, though both map to the same calm on-screen copy.
enum CompetitorImportError: Error, Equatable {
    /// The bytes couldn't be read at all (file vanished, no permission).
    case unreadable
    /// The bytes were read but don't match anything we know how to import.
    case unrecognizedFormat
}

/// The pure parsers, one per app. Each takes the raw file bytes and returns a
/// `TalkiePack`, or throws `CompetitorImportError.unrecognizedFormat` when the bytes
/// aren't a JSON object it can find vocabulary/replacements in. These are the
/// fixture-tested core; they touch no I/O and no global state.
///
/// A shared philosophy across all three: parse the JSON as loosely-typed `Any`, then
/// hunt for the fields under any of the aliases each app has plausibly used across
/// versions. A key present but of the wrong type is skipped, not fatal. An entry missing
/// its required half (a replacement with no "to") is dropped, not fatal. Only when we
/// can't parse JSON at all, or find literally nothing importable, do we throw — because
/// at that point "couldn't read this" is the honest answer.
enum CompetitorParsers {

    // MARK: VoiceInk

    /// VoiceInk keeps a custom-word list and word-replacement rules. Observed/documented
    /// shape (and the tolerant supersets we accept):
    ///
    /// ```json
    /// {
    ///   "dictionaryItems": ["Kubernetes", "kubectl"],
    ///   "wordReplacements": [
    ///     { "originalText": "cube control", "replacementText": "kubectl" }
    ///   ]
    /// }
    /// ```
    ///
    /// We also accept `customWords`/`words`/`vocabulary` for the word list, and
    /// `replacements`/`wordReplacementRules` for the rules, with `from`/`to` as
    /// alternative keys — because the exact field names have shifted between VoiceInk
    /// versions and we'd rather read a superset than reject a slightly-different file.
    static func voiceInk(_ data: Data) throws -> TalkiePack {
        let root = try jsonObject(data)
        let vocab = stringArray(in: root, keys: ["dictionaryItems", "customWords", "words", "vocabulary"])
        let rules = replacementRules(
            in: root,
            arrayKeys: ["wordReplacements", "wordReplacementRules", "replacements"],
            fromKeys: ["originalText", "original", "from", "trigger", "match"],
            toKeys: ["replacementText", "replacement", "to", "result", "value"]
        )
        return try assemble(app: .voiceInk, vocabulary: vocab, replacements: rules)
    }

    // MARK: Superwhisper

    /// Superwhisper keeps custom vocabulary and replacement rules. Observed/documented
    /// shape:
    ///
    /// ```json
    /// {
    ///   "vocabulary": ["Coralate", "Talkie"],
    ///   "replacements": [
    ///     { "original": "correlate", "replacement": "Coralate" }
    ///   ]
    /// }
    /// ```
    ///
    /// Some Superwhisper builds nest this under a top-level `dictionary` object, and some
    /// name the word list `words` — we accept both. Replacement halves may be
    /// `original`/`replacement` or `from`/`to`.
    static func superwhisper(_ data: Data) throws -> TalkiePack {
        let root = try jsonObject(data)
        // Superwhisper sometimes wraps the payload in a "dictionary" object; look inside
        // it first, then fall back to the root.
        let scope = (root["dictionary"] as? [String: Any]) ?? root
        let vocab = stringArray(in: scope, keys: ["vocabulary", "words", "customWords", "terms"])
        let rules = replacementRules(
            in: scope,
            arrayKeys: ["replacements", "wordReplacements", "substitutions"],
            fromKeys: ["original", "from", "input", "match", "key"],
            toKeys: ["replacement", "to", "output", "result", "value"]
        )
        return try assemble(app: .superwhisper, vocabulary: vocab, replacements: rules)
    }

    // MARK: Wispr Flow

    /// Wispr Flow's dictionary export leans toward a list of entries, each a term the
    /// user added and optionally a spoken form that should map to it. Observed/documented
    /// shape:
    ///
    /// ```json
    /// {
    ///   "dictionary": [
    ///     { "word": "Coralate" },
    ///     { "word": "kubectl", "pronunciation": "cube control" }
    ///   ]
    /// }
    /// ```
    ///
    /// Each entry's canonical spelling (`word`/`text`/`term`) becomes a vocabulary term.
    /// When an entry also carries a spoken/misheard form (`pronunciation`/`spoken`/
    /// `soundsLike`/`from`) that differs from the word, we additionally synthesize a
    /// replacement (spoken → word) so the correction survives, not just the spelling
    /// bias. A bare top-level array of the same entries is accepted too, as is a plain
    /// `words: [String]` list — Wispr's export shape is the one we've verified least, so
    /// the parser is the most generous.
    static func wisprFlow(_ data: Data) throws -> TalkiePack {
        // Wispr may hand us a top-level array OR an object. Normalize to "the array of
        // entries" plus "the object we can also mine for a plain word list".
        let (root, topLevelEntries) = try jsonObjectOrArray(data)

        var vocab: [String] = []
        var rules: [TalkiePack.PackReplacement] = []

        // The list of rich entries, from either the top-level array or a nested key.
        let entries = topLevelEntries
            ?? (arrayOfObjects(in: root, keys: ["dictionary", "entries", "items", "words"]) ?? [])
        for entry in entries {
            guard let word = firstString(in: entry, keys: ["word", "text", "term", "value", "to"]) else {
                continue
            }
            vocab.append(word)
            if let spoken = firstString(in: entry, keys: ["pronunciation", "spoken", "soundsLike", "from", "original"]),
               spoken.caseInsensitiveCompare(word) != .orderedSame {
                rules.append(.init(from: spoken, to: word, caseSensitive: nil, wholeWord: nil))
            }
        }

        // Also accept a plain string word list if the export used one (or in addition).
        vocab.append(contentsOf: stringArray(in: root, keys: ["words", "vocabulary", "customWords"]))
        // And a conventional replacements array, if present.
        rules.append(contentsOf: replacementRules(
            in: root,
            arrayKeys: ["replacements", "substitutions"],
            fromKeys: ["from", "original", "spoken", "match"],
            toKeys: ["to", "replacement", "word", "result"]
        ))

        return try assemble(app: .wisprFlow, vocabulary: vocab, replacements: rules)
    }

    // MARK: - Shared assembly

    /// Build the final pack from parsed pieces, or throw when there's genuinely nothing
    /// importable. Trimming/dedup is intentionally light here because A4's
    /// `merge`/`previewMerge` already trim, case-insensitively dedup, and skip blanks —
    /// we don't want to duplicate (or subtly disagree with) that logic. We only drop
    /// obviously-empty strings so an empty-but-parseable file reports "unrecognized"
    /// rather than staging an empty preview.
    private static func assemble(app: CompetitorDictionaryImport.App,
                                 vocabulary: [String],
                                 replacements: [TalkiePack.PackReplacement]) throws -> TalkiePack {
        let cleanVocab = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanRules = replacements.filter {
            !$0.from.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.to.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // A file we could parse as JSON but that yielded nothing importable is, from the
        // user's point of view, not a dictionary we can read — say so plainly.
        guard !cleanVocab.isEmpty || !cleanRules.isEmpty else {
            throw CompetitorImportError.unrecognizedFormat
        }
        return TalkiePack(
            name: app.packName,
            description: nil,
            attribution: app.attribution,
            createdAtUnix: Date().timeIntervalSince1970,
            vocabulary: cleanVocab,
            replacements: cleanRules
        )
    }

    // MARK: - JSON helpers (loosely-typed, forgiving)

    /// Parse bytes into a top-level JSON object, or throw `.unrecognizedFormat`. Anything
    /// that isn't a JSON object (`{...}`) — including a bare array or scalar — is not a
    /// shape these object-rooted parsers understand.
    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else {
            throw CompetitorImportError.unrecognizedFormat
        }
        return obj
    }

    /// Parse bytes that may be EITHER a top-level object or a top-level array. Returns the
    /// object (empty when the root was an array) and the array-of-objects when the root
    /// was an array. Throws `.unrecognizedFormat` on non-JSON or a scalar root.
    private static func jsonObjectOrArray(_ data: Data) throws -> (object: [String: Any], entries: [[String: Any]]?) {
        guard let any = try? JSONSerialization.jsonObject(with: data) else {
            throw CompetitorImportError.unrecognizedFormat
        }
        if let obj = any as? [String: Any] {
            return (obj, nil)
        }
        if let arr = any as? [Any] {
            return ([:], arr.compactMap { $0 as? [String: Any] })
        }
        throw CompetitorImportError.unrecognizedFormat
    }

    /// The first `[String]` found under any of `keys`. Accepts an array whose elements are
    /// strings; non-string elements within it are dropped. A key of the wrong type is
    /// skipped so the next alias gets a chance.
    private static func stringArray(in obj: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            if let arr = obj[key] as? [Any] {
                let strings = arr.compactMap { $0 as? String }
                if !strings.isEmpty { return strings }
            }
        }
        return []
    }

    /// The first array-of-objects found under any of `keys` (for Wispr's rich entries).
    private static func arrayOfObjects(in obj: [String: Any], keys: [String]) -> [[String: Any]]? {
        for key in keys {
            if let arr = obj[key] as? [Any] {
                let objs = arr.compactMap { $0 as? [String: Any] }
                if !objs.isEmpty { return objs }
            }
        }
        return nil
    }

    /// Pull replacement rules from the first present array under `arrayKeys`, reading each
    /// rule's from/to under any of `fromKeys`/`toKeys`. Rules missing either half are
    /// dropped (never fatal). Case-sensitivity / whole-word flags are read when the source
    /// exposes them under common names, else left nil so `TalkiePack` applies its defaults
    /// (case-insensitive, whole-word) — matching how the app treats a curated rule.
    private static func replacementRules(in obj: [String: Any],
                                         arrayKeys: [String],
                                         fromKeys: [String],
                                         toKeys: [String]) -> [TalkiePack.PackReplacement] {
        for key in arrayKeys {
            guard let arr = obj[key] as? [Any] else { continue }
            let rules: [TalkiePack.PackReplacement] = arr.compactMap { element in
                guard let dict = element as? [String: Any],
                      let from = firstString(in: dict, keys: fromKeys),
                      let to = firstString(in: dict, keys: toKeys) else {
                    return nil
                }
                return TalkiePack.PackReplacement(
                    from: from,
                    to: to,
                    caseSensitive: firstBool(in: dict, keys: ["caseSensitive", "matchCase", "isCaseSensitive"]),
                    wholeWord: firstBool(in: dict, keys: ["wholeWord", "wholeWordOnly", "matchWholeWord"])
                )
            }
            if !rules.isEmpty { return rules }
        }
        return []
    }

    /// The first non-blank `String` value found under any of `keys` in `dict`.
    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = dict[key] as? String,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        return nil
    }

    /// The first `Bool` value found under any of `keys`. Tolerates a JSON number (0/1)
    /// or a "true"/"false" string, since exports serialize booleans inconsistently.
    private static func firstBool(in dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let b = dict[key] as? Bool { return b }
            if let n = dict[key] as? NSNumber { return n.boolValue }
            if let s = dict[key] as? String {
                switch s.lowercased() {
                case "true", "yes", "1": return true
                case "false", "no", "0": return false
                default: break
                }
            }
        }
        return nil
    }
}
