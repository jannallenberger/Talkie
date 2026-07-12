import Foundation

/// Pure `ExportableNote` builder for the on-demand export producer D4 adds: a
/// dictation filed by voice ("note this …"). It is the dictation analogue of
/// `MeetingStore.writeMarkdown`'s inline meeting-note construction — the ONLY other
/// place an `ExportableNote` is produced — but factored out as free functions so
/// they can be exhaustively unit tested without Core Audio, a model, or disk I/O
/// (the offline-core invariant).
///
/// A `.brief` producer once lived here too (Today's Brief → one-click save), but
/// L2-a replaced Today's Brief with the adaptive dashboard Scratchpad, so the
/// Brief-save feature — and its `briefNote` composer — was superseded and removed
/// (reconciled 2026-07-04). The `.brief` `NoteKind` case survives for any note
/// historically written with it and for future reuse; nothing constructs one now.
///
/// Nothing here writes a file or resolves a destination: a composer's whole job is
/// to turn text (+ context) into the neutral note shape. The caller routes the
/// result through `ExportPreferences.shared.resolvedDestination()`, exactly as the
/// meeting writer does, so a plain folder and a wikilink-aware vault diverge only
/// in the destination — never in the producer (the export-genericity invariant in
/// `NoteDestination.swift`).
///
/// `enum` + `static func` is the house idiom for a stateless helper (see
/// `NoteTemplate`, `NumberNormalizer`); every function is `nonisolated`/pure so the
/// dictation finalize path can build the note inline on whatever actor it is on.
enum NoteComposers {

    // MARK: Trigger parsing ("note this …")

    /// The outcome of testing a finalized dictation against the "note this" /
    /// "note that" trigger. `nil` (no case) means "not a note command — dictate
    /// normally"; the two cases distinguish an inline note from a bare trigger that
    /// files the *previous* dictation.
    enum TriggerMatch: Equatable {
        /// "note this <body>" — file `body` as a new note.
        case body(String)
        /// A bare "note this" (nothing after the trigger) — file the previous
        /// dictation. The caller supplies that text (it doesn't live here).
        case previous
    }

    /// Trigger phrases, lowercased. English-only for v1 — localized triggers are
    /// deliberately deferred (documented in the D4 spec/PR): a mistrigger files a
    /// user's sentence to disk, so the phrase set stays small and predictable until
    /// per-locale phrasing is designed. Longest-first isn't needed (both are the
    /// same length) but the set is ordered for readability.
    static let noteTriggers = ["note this", "note that"]

    /// Decide whether `finalText` is a "note this …" command, and if so what to do.
    ///
    /// Matching rules (anchored to the utterance START only, so a sentence that
    /// merely contains "note this" mid-way is untouched):
    /// - case-insensitive match of a trigger at the very beginning;
    /// - the trigger must be followed by end-of-string OR a separator (space, or a
    ///   single trailing `:`/`,` then optional space) — so "notethis" or
    ///   "note thistle" never match;
    /// - one trailing colon or comma right after the trigger is swallowed
    ///   ("Note this," / "note this:") before the body is read;
    /// - a non-empty remainder → `.body(remainder)`; nothing left → `.previous`.
    ///
    /// Returns `nil` when there's no trigger — the common path, reached after a
    /// single `hasPrefix`-class check, so a normal dictation pays almost nothing.
    static func triggerMatch(for finalText: String) -> TriggerMatch? {
        // Cheap reject first: trim only the leading whitespace we need to see the
        // first word; a normal dictation that doesn't start with "note" bails here.
        let leadingTrimmed = finalText.drop(while: { $0.isWhitespace })
        let lowerLead = leadingTrimmed.lowercased()
        guard let trigger = noteTriggers.first(where: { lowerLead.hasPrefix($0) }) else {
            return nil
        }

        // The character immediately after the trigger must be a boundary — end of
        // string, whitespace, or a single ':'/',' — else it's a longer word that
        // merely starts with the trigger letters ("note thistle"): not a command.
        let afterTriggerIndex = leadingTrimmed.index(leadingTrimmed.startIndex,
                                                     offsetBy: trigger.count)
        var rest = leadingTrimmed[afterTriggerIndex...]
        if let first = rest.first {
            if first == ":" || first == "," {
                rest = rest.dropFirst() // swallow one trailing colon/comma
            } else if !first.isWhitespace {
                return nil // "note this" glued to more letters — not a trigger
            }
        }

        let body = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? .previous : .body(body)
    }

    // MARK: Dictation

    /// Build the note for a "note this …" dictation.
    ///
    /// - `text`: the note body — the remainder after the "note this"/"note that"
    ///   trigger was stripped (for a bare trigger, the caller passes the previous
    ///   dictation's text). Assumed non-empty and already trimmed by the caller;
    ///   defended anyway so a stray call can't produce a blank-titled note.
    /// - `target`: the app that was frontmost — recorded as `frontMatter["app"]`
    ///   (drives `{app}` in a filename template and the note's provenance) so a
    ///   note remembers where it was captured, mirroring `DictationEntry.appName`.
    /// - `date`: capture time — the note date and the `{datetime}` filename token.
    /// - `graph`: the context-graph snapshot; entity display names (and aliases)
    ///   that actually appear in `text` become `links`, which a wikilink-aware
    ///   destination renders as `[[Name]]` so the note joins the knowledge graph.
    ///   A plain folder ignores `links`, so this is free when unused.
    ///
    /// The title is the first ~8 words of the body (a human-readable stub for the
    /// sidebar / `{title}` token); the filename template is `{datetime}-note` so
    /// notes sort chronologically and never collide within reason (the destination
    /// de-collides the rest). Kind is `.dictation`.
    static func dictationNote(text: String,
                              target: TargetApp,
                              date: Date,
                              graph: ContextGraphSnapshot) -> ExportableNote {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleWords(from: body, maxWords: 8)
        let links = mentionedEntities(in: body, graph: graph)

        // `frontMatter["app"]` feeds the `{app}` filename token AND the note's YAML
        // provenance; omit it entirely for the unknown target so a template like
        // "{datetime}-{app}" collapses cleanly instead of writing "Unknown".
        var frontMatter: [String: String] = [:]
        if !target.name.isEmpty, target.name != TargetApp.unknown.name {
            frontMatter["app"] = target.name
        }

        // The body is the note verbatim under a "## Note" heading — a dictation is
        // a single thought, not the Summary/Transcript structure a meeting has, so
        // it gets one clean section rather than empty ceremony.
        let note = ExportableNote(
            kind: .dictation,
            title: title.isEmpty ? "Note" : title,
            date: date,
            bodyMarkdown: "## Note\n\n\(body)",
            frontMatter: frontMatter,
            links: links,
            suggestedFileName: "" // filled below via NoteTemplate so both call sites agree
        )
        return note.withSuggestedFileName(
            NoteTemplate.fileName("{datetime}-note", for: note, existing: [])
        )
    }

    // MARK: - Pure helpers (unit-tested directly)

    /// The first `maxWords` whitespace-separated words of `text`, collapsed to
    /// single spaces and stripped of surrounding punctuation, as a title stub.
    /// Newlines and runs of spaces never leak in (a title is one line). Returns ""
    /// for empty/whitespace input so the caller can substitute a default.
    static func titleWords(from text: String, maxWords: Int) -> String {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(max(0, maxWords))
        return words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The display names of graph entities that are actually mentioned in `text`,
    /// most-recently-seen first (the snapshot's order), de-duplicated. An entity
    /// matches if its display name OR any alias appears in `text` as a
    /// case-insensitive, word-boundary-aware substring — so "GitHub" in the body
    /// lights up the `GitHub` node but "corralated" (no boundary) does not, and a
    /// two-letter alias can't spuriously match inside a longer word.
    ///
    /// Commitments are skipped: they are action-item phrases, not named nodes you'd
    /// wikilink to. The returned strings are the canonical `displayName`s (never the
    /// matched alias) so every note links to the same node spelling.
    static func mentionedEntities(in text: String, graph: ContextGraphSnapshot) -> [String] {
        guard !text.isEmpty else { return [] }
        let haystack = text.lowercased()
        var out: [String] = []
        var seen = Set<String>()
        for entity in graph.entities where entity.kind != .commitment {
            let names = [entity.displayName] + entity.aliases
            let mentioned = names.contains { name in
                containsWord(haystack, name.lowercased())
            }
            guard mentioned, seen.insert(entity.displayName.lowercased()).inserted else { continue }
            out.append(entity.displayName)
        }
        return out
    }

    /// Case-insensitive (both args already lowercased by the caller) word-boundary
    /// containment: is `needle` present in `haystack` not glued to an adjacent
    /// alphanumeric on either side? "graph" matches "the graph is" and "graph."
    /// but not "graphene" or "polygraph". Empty needle never matches (an entity
    /// with a blank name can't spam every note). Multi-word needles are matched
    /// literally as a run, with the same boundary rule at the outer edges.
    static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeOK: Bool = {
                guard range.lowerBound > haystack.startIndex else { return true }
                let before = haystack[haystack.index(before: range.lowerBound)]
                return !isWordChar(before)
            }()
            let afterOK: Bool = {
                guard range.upperBound < haystack.endIndex else { return true }
                let after = haystack[range.upperBound]
                return !isWordChar(after)
            }()
            if beforeOK && afterOK { return true }
            // Overlapping-safe advance: resume one scalar past this start so a near
            // miss ("aXa" looking for "Xa") still finds a later real boundary.
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    /// A "word" character for boundary purposes: a letter or a digit. Underscores
    /// and punctuation count as boundaries, matching how the names read in prose.
    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}

// MARK: - ExportableNote convenience

private extension ExportableNote {
    /// Return a copy with `suggestedFileName` replaced — lets a composer build the
    /// note, then derive the filename from that same note (title/date/app) via
    /// `NoteTemplate.fileName` without a second constructor call.
    func withSuggestedFileName(_ name: String) -> ExportableNote {
        var copy = self
        copy.suggestedFileName = name
        return copy
    }
}
