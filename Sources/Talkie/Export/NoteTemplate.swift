import Foundation

/// Dependency-free token substitution + Markdown wrapping for note export
/// (feature 10). A pure helper — no model, no audio, no I/O, no third-party app
/// baked in — so any `NoteDestination` (the default Talkie folder, or a community
/// Obsidian/Logseq impl) can render an `ExportableNote` with the *same* rules and
/// only differ in which flags it turns on.
///
/// This is intentionally NOT a general template language: a fixed, known set of
/// `{token}`s keeps "zero dependencies" true and the attack surface nil. Every
/// substituted value is run through a filesystem-safe sanitizer and the result is
/// length-capped and de-collided against what already exists on disk.
enum NoteTemplate {

    // MARK: Filename rendering

    /// The tokens understood by `fileName(_:for:existing:)`.
    /// - `{date}`     → `yyyy-MM-dd`
    /// - `{datetime}` → `yyyy-MM-dd-HHmm`
    /// - `{time}`     → `HHmm`
    /// - `{title}`    → slugified note title
    /// - `{kind}`     → `meeting` / `dictation` / `brief`
    /// - `{app}`      → slugified `frontMatter["app"]` (dictation target app), or ""
    ///
    /// `{n}` is reserved for collision handling and is appended automatically only
    /// when the rendered base already exists in `existing`; authors do not place it.
    static func fileName(_ template: String,
                         for note: ExportableNote,
                         existing: Set<String>) -> String {
        let date = Self.format(note.date, "yyyy-MM-dd")
        let datetime = Self.format(note.date, "yyyy-MM-dd-HHmm")
        let time = Self.format(note.date, "HHmm")
        let titleSlug = slug(note.title)
        let appSlug = slug(note.frontMatter["app"] ?? "")

        var base = template
        base = base.replacingOccurrences(of: "{date}", with: date)
        base = base.replacingOccurrences(of: "{datetime}", with: datetime)
        base = base.replacingOccurrences(of: "{time}", with: time)
        base = base.replacingOccurrences(of: "{title}", with: titleSlug)
        base = base.replacingOccurrences(of: "{kind}", with: note.kind.rawValue)
        base = base.replacingOccurrences(of: "{app}", with: appSlug)

        // Collapse any double separators a missing/empty token may have produced
        // (e.g. "{datetime}-{app}" with no app → "...-1432-").
        base = collapseSeparators(base)

        // A template that resolved to nothing falls back to a stable, unique base.
        if base.isEmpty { base = datetime.isEmpty ? note.kind.rawValue : datetime }

        // Hard length cap (before the extension) so no filesystem rejects it.
        base = capped(base, max: 120)

        return deCollide(base, existing: existing)
    }

    // MARK: Front-matter rendering

    /// Render a YAML front-matter block (including the `---` fences) from the
    /// note's `frontMatter` map. Keys in `priority` come first, in that order;
    /// every other key follows alphabetically — so output is deterministic and
    /// diff-stable. Always includes `title` and an ISO-8601 `date` derived from the
    /// note (callers should not duplicate those in `frontMatter`).
    ///
    /// Returns "" when `pairs`, title and date would all be empty, so a destination
    /// can ask for a block unconditionally and get nothing rather than empty fences.
    static func frontMatterBlock(for note: ExportableNote,
                                 priority: [String] = ["duration_min", "participants", "source", "app"],
                                 includeTags: Bool = false) -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(yamlValue(note.title))")
        lines.append("date: \(ISO8601DateFormatter().string(from: note.date))")
        lines.append("kind: \(note.kind.rawValue)")

        let pairs = note.frontMatter
        for key in priority {
            if let value = pairs[key] { lines.append("\(key): \(renderYAMLField(value))") }
        }
        for key in pairs.keys.sorted() where !priority.contains(key) {
            lines.append("\(key): \(renderYAMLField(pairs[key]!))")
        }

        if includeTags, !note.tags.isEmpty {
            let rendered = note.tags.map { yamlValue($0) }.joined(separator: ", ")
            lines.append("tags: [\(rendered)]")
        }

        lines.append("---")
        return lines.joined(separator: "\n")
    }

    // MARK: Body wrapping

    /// Wrap a producer-composed body with optional front-matter, a trailing tag
    /// line, and an optional links block — the one place every destination shares
    /// so a plain folder and a wikilink-aware vault diverge only in their flags.
    ///
    /// - Parameters:
    ///   - note: the neutral note (its `bodyMarkdown` is already composed).
    ///   - frontMatter: prepend a YAML block.
    ///   - tags: append a `#tag #tag` line built from `note.tags` (and `extraTags`).
    ///   - wikilinks: render `note.links` as a "Related" block; `[[Name]]` when
    ///     `true`, plain `Name` when `false`. No block when `note.links` is empty.
    ///   - extraTags: destination/global tags appended to the note's own.
    static func wrap(_ note: ExportableNote,
                     frontMatter: Bool,
                     tags: Bool,
                     wikilinks: Bool,
                     extraTags: [String] = []) -> String {
        var parts: [String] = []

        if frontMatter {
            parts.append(frontMatterBlock(for: note, includeTags: false))
        }

        parts.append(note.bodyMarkdown)

        if !note.links.isEmpty {
            let rendered = note.links.map { wikilinks ? "[[\($0)]]" : $0 }
            parts.append("## Related\n\n" + rendered.map { "- \($0)" }.joined(separator: "\n"))
        }

        if tags {
            let all = (note.tags + extraTags).filter { !$0.isEmpty }
            if !all.isEmpty {
                let line = all.map { "#" + slug($0) }.joined(separator: " ")
                parts.append(line)
            }
        }

        // Front-matter is glued to the body by a single blank line; the optional
        // trailing blocks are separated by a blank line too.
        return parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: Primitives

    /// Filesystem-safe slug: ascii-folded, lowercased, every run of non
    /// `[a-z0-9]` collapsed to a single `-`, trimmed, length-capped.
    static func slug(_ s: String, max: Int = 60) -> String {
        // Fold accents/diacritics to ASCII (é → e, ñ → n) and drop the rest.
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var out = ""
        out.reserveCapacity(folded.count)
        var lastWasDash = false
        for scalar in folded.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return capped(trimmed, max: max)
    }

    /// YAML-escape a scalar: quote when it contains a character that would confuse
    /// a flow-context parser (`: # [ ] { } , & * ! | > ' " % @ \``), starts with a
    /// space, or is empty; escape embedded double-quotes.
    static func yamlValue(_ s: String) -> String {
        let needsQuote = s.isEmpty
            || s.first == " " || s.last == " "
            || s.rangeOfCharacter(from: CharacterSet(charactersIn: ":#[]{},&*!|>'\"%@`")) != nil
        guard needsQuote else { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// A value already wrapped in `[...]` (an array literal a producer composed,
    /// e.g. `"[Me, Them]"`) is passed through untouched; everything else is
    /// YAML-escaped as a scalar. Internal (not `private`) so destinations that
    /// build front-matter line-by-line — e.g. `TalkieFolderDestination.render` —
    /// can reuse the same escaping rule instead of raw-interpolating values.
    static func renderYAMLField(_ value: String) -> String {
        if value.hasPrefix("[") && value.hasSuffix("]") { return value }
        return yamlValue(value)
    }

    // MARK: Private

    private static func format(_ date: Date, _ fmt: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f.string(from: date)
    }

    /// Append `-2`, `-3`, … only when the base already exists on disk. Never
    /// overwrites a different note.
    private static func deCollide(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Collapse runs of `-`, `_`, `.` separators and trim leading/trailing ones,
    /// so a missing token never leaves a dangling separator in the filename.
    private static func collapseSeparators(_ s: String) -> String {
        var out = ""
        var lastSep: Character? = nil
        for ch in s {
            if ch == "-" || ch == "_" || ch == "." {
                if lastSep == nil { out.append(ch) }
                lastSep = ch
            } else {
                out.append(ch)
                lastSep = nil
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
    }

    private static func capped(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max)).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
    }
}
