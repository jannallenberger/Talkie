import Foundation

/// One shareable dictionary file: your whole vocabulary + replacement rules in a
/// single human-readable JSON document you can hand to someone over Discord, email,
/// or a dotfiles repo. Zero network — it's just a file. This is also the substrate
/// later curated-pack features build on, so the schema is deliberately boring and
/// the decode is deliberately forgiving: a v1 reader must keep reading v1 files
/// forever even after we add fields, and a file from a newer Talkie must still load
/// on an older one (unknown fields ignored, missing optionals defaulted). Changing
/// this shape later is the expensive part — so we don't, we only add.
struct TalkiePack: Codable, Sendable, Equatable {
    /// Bumped only if the shape changes incompatibly (which the tolerant-decode rule
    /// is designed to avoid). Readers accept any value ≥ 1 and default missing → 1.
    var formatVersion: Int
    /// Human name for the pack ("Kubernetes terms", "Jann's brand words"). Drives the
    /// suggested export filename and the import preview title.
    var name: String
    /// Optional one-liner shown in the import preview so a recipient knows what they're
    /// adding before they confirm.
    var description: String?
    /// Optional credit ("shared by @dave") — surfaced in the preview, never required.
    var attribution: String?
    /// When the pack was authored (Unix seconds). Informational only.
    var createdAtUnix: Double
    /// Names / jargon / brand words fed to the recognizer to bias spelling.
    var vocabulary: [String]
    /// Spoken→written substitutions.
    var replacements: [PackReplacement]

    static let currentFormatVersion = 1

    /// A pack's replacement rule. A deliberately separate wire type from the app's
    /// `Replacement` (which carries a runtime `id` and a `learned` flag that must NOT
    /// travel in a shared file — imported rules are curated, never "learned"). Optional
    /// booleans default the same way `Replacement` does, so a terse pack (`from`/`to`
    /// only) round-trips to the app's defaults.
    struct PackReplacement: Codable, Sendable, Equatable {
        var from: String
        var to: String
        /// Defaults to false (case-insensitive) when omitted — matches `Replacement`.
        var caseSensitive: Bool?
        /// Defaults to true (whole-word) when omitted — matches `Replacement`.
        var wholeWord: Bool?

        var resolvedCaseSensitive: Bool { caseSensitive ?? false }
        var resolvedWholeWord: Bool { wholeWord ?? true }
    }

    // MARK: Tolerant decode

    /// Decode by hand so unknown keys are ignored and every optional/missing field
    /// gets a sane default. This is the load-bearing forward-compat rule: a v1 build
    /// must read a file written by a future v2 build (dropping fields it doesn't know)
    /// rather than refusing it. `formatVersion` defaults to 1 and `createdAtUnix` to 0
    /// when absent; `name` defaults to a neutral placeholder so a nameless file still
    /// imports. A rule missing `from`/`to` is dropped rather than failing the whole
    /// decode — one malformed entry can't poison an otherwise good pack.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? 1
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Imported dictionary"
        self.description = try? c.decodeIfPresent(String.self, forKey: .description)
        self.attribution = try? c.decodeIfPresent(String.self, forKey: .attribution)
        self.createdAtUnix = (try? c.decode(Double.self, forKey: .createdAtUnix)) ?? 0
        self.vocabulary = ((try? c.decode([String].self, forKey: .vocabulary)) ?? [])
        // Decode rules through a lenient wrapper whose `from`/`to` are optional, so a
        // single entry missing a required field is DROPPED rather than throwing and
        // discarding the whole list. Then keep only entries with both strings present
        // and non-blank.
        let rawRules = (try? c.decode([LenientRule].self, forKey: .replacements)) ?? []
        self.replacements = rawRules.compactMap { $0.resolved() }
    }

    /// A permissive shape used ONLY while decoding: both required strings are optional
    /// here so one malformed rule can't fail the array decode. `resolved()` returns a
    /// real `PackReplacement` when the entry is complete, else nil (drop it).
    private struct LenientRule: Decodable {
        var from: String?
        var to: String?
        var caseSensitive: Bool?
        var wholeWord: Bool?

        func resolved() -> PackReplacement? {
            guard let from, let to,
                  !from.trimmingCharacters(in: .whitespaces).isEmpty,
                  !to.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return PackReplacement(from: from, to: to,
                                   caseSensitive: caseSensitive, wholeWord: wholeWord)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, description, attribution, createdAtUnix, vocabulary, replacements
    }

    /// Memberwise init for building a pack to export (the synthesized one is shadowed
    /// by our custom `init(from:)`).
    init(formatVersion: Int = TalkiePack.currentFormatVersion,
         name: String,
         description: String? = nil,
         attribution: String? = nil,
         createdAtUnix: Double,
         vocabulary: [String],
         replacements: [PackReplacement]) {
        self.formatVersion = formatVersion
        self.name = name
        self.description = description
        self.attribution = attribution
        self.createdAtUnix = createdAtUnix
        self.vocabulary = vocabulary
        self.replacements = replacements
    }

    // MARK: Codec (the pure, unit-tested core)

    /// Encode to pretty, sorted JSON — a `.talkiepack` file is meant to be read and
    /// diffed by a human, so we don't minify it.
    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    /// Decode from file bytes. Throws `TalkiePackError.malformed` on anything that
    /// isn't a JSON object we can read — the caller shows an error and changes nothing.
    static func decoded(from data: Data) throws -> TalkiePack {
        do {
            return try JSONDecoder().decode(TalkiePack.self, from: data)
        } catch {
            throw TalkiePackError.malformed
        }
    }

    /// A conventional, filesystem-safe export filename: "<Name> Dictionary.talkiepack".
    var suggestedFileName: String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = base.isEmpty ? "Talkie" : base
        // Strip path separators / colon so the save panel gets a legal name.
        let safe = cleanName.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return "\(safe) Dictionary.\(TalkiePack.fileExtension)"
    }

    /// The file extension + UTI, defined once so the picker, the drop target, the
    /// exporter, and the Info.plist document type can't drift apart.
    static let fileExtension = "talkiepack"
    static let utTypeIdentifier = "com.coralate.talkie.talkiepack"
}

/// What went wrong reading a pack. Kept tiny — the UX only needs "this file isn't a
/// valid Talkie dictionary," never a decoder backtrace.
enum TalkiePackError: Error, Equatable {
    case malformed
    case unreadable
}

/// The result of merging a pack into the dictionary: what actually changed. Surfaced
/// after a confirmed import ("Added 12 terms, 3 rules") and asserted by the tests.
struct MergeSummary: Sendable, Equatable {
    var vocabularyAdded: Int = 0
    var vocabularySkipped: Int = 0
    var replacementsAdded: Int = 0
    var replacementsSkipped: Int = 0

    var totalAdded: Int { vocabularyAdded + replacementsAdded }
    var isEmpty: Bool { totalAdded == 0 }
}

/// A dry-run of a merge, computed BEFORE anything is written, so the import sheet can
/// show exactly what will be added vs. what already exists (collisions greyed out) and
/// the user confirms once. Pure function of (pack, current state) — see
/// `DictionaryStore.previewMerge`. `existingVocabulary`/`existingReplacement` mark the
/// rows that are collisions so the UI can dim them.
struct MergePreview: Sendable, Equatable {
    struct VocabRow: Sendable, Equatable, Identifiable {
        var id: String { term }
        var term: String
        var existing: Bool
    }
    struct RuleRow: Sendable, Equatable, Identifiable {
        var id: String { "\(from)→\(to)" }
        var from: String
        var to: String
        var existing: Bool
    }

    var packName: String
    var packDescription: String?
    var attribution: String?
    var vocab: [VocabRow]
    var rules: [RuleRow]

    /// Only the rows that would actually be added (collisions excluded) — the numbers
    /// the confirm button acts on and the sheet headlines.
    var newVocabCount: Int { vocab.filter { !$0.existing }.count }
    var newRuleCount: Int { rules.filter { !$0.existing }.count }
    var hasSomethingToAdd: Bool { newVocabCount + newRuleCount > 0 }
}
