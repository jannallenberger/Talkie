import Foundation

/// The bundled profession vocabularies a new user can install in one tap so
/// `NicheCorrector` starts rescuing close misses of field jargon on day one —
/// zero curation. Each pack is a plain `.talkiepack` file (A4's schema) curated
/// in `Resources/Packs/`, shipped read-only inside the app bundle. Installing a
/// pack is just A4's `DictionaryStore.merge` against its decoded `TalkiePack`, so
/// the vocabulary lands in `dictionary.vocabulary` (fed straight to the live
/// corrector) and the replacement rules land in `dictionary.replacements` — no
/// new install machinery, one code path with hand-shared packs.
///
/// Honesty, stated plainly at the call site: this can only fix *close* misses of
/// these terms. The corrector proofreads the transcript at phonetic-skeleton
/// distance ≤ 1; it can't make the recognizer produce a word it never heard. So
/// each pack's vocabulary is curated to genuine close-miss candidates, and terms
/// whose spoken form diverges further ("cube control" → "kubectl", distance 2)
/// ship as explicit replacement *rules* inside the pack, not as vocabulary.
///
/// The curation gate lives in `StarterPackTests`: every bundled pack must decode,
/// be ≤ 300 terms, be 100% `NicheTermGuard.isSafeToInject`-safe, and produce ZERO
/// fixes on the false-positive prose corpus — so a well-meaning pack addition can
/// never regress recognition of ordinary speech.
enum StarterPack: String, CaseIterable, Identifiable, Sendable {
    case developer
    case medicine
    case law
    case research
    case writer

    var id: String { rawValue }

    /// The base filename in `Resources/Packs/` (and, at runtime, in the app
    /// bundle's flat `Contents/Resources/`). Kept equal to the raw value so the
    /// catalog, the build-script copy block, and the tests can't drift.
    var fileBaseName: String { rawValue }

    /// A short, honest one-liner for the card row — what the pack is, no hype.
    /// Localized via `.loc` (keys present in every `.lproj`). The authoritative
    /// name/description also live inside each `.talkiepack` (shown in the import
    /// preview); this is the compact label before you open the preview.
    var shortDescription: String {
        switch self {
        case .developer: return "Tools, languages, and jargon — Kubernetes, SwiftPM, idempotent.".loc
        case .medicine:  return "Conditions, procedures, and common medications.".loc
        case .law:       return "Litigation, contracts, and estates.".loc
        case .research:  return "Statistics, methods, and math.".loc
        case .writer:    return "Literary devices and the editorial workflow.".loc
        }
    }

    /// The pack's display title for the card row. The `.talkiepack` carries its
    /// own `name` too (used by the preview sheet); this is the pre-open label.
    var title: String {
        switch self {
        case .developer: return "Developer".loc
        case .medicine:  return "Medicine".loc
        case .law:       return "Law".loc
        case .research:  return "Research".loc
        case .writer:    return "Writer".loc
        }
    }

    /// An SF Symbol for the row's leading glyph — decorative only.
    var systemImage: String {
        switch self {
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .medicine:  return "cross.case"
        case .law:       return "building.columns"
        case .research:  return "function"
        case .writer:    return "text.book.closed"
        }
    }

    // MARK: Loading

    /// What can go wrong loading a bundled pack. Distinct from `TalkiePackError`
    /// so a "we shipped a broken resource" bug reads differently from "the user
    /// picked a bad file".
    enum LoadError: Error, Equatable {
        /// The `.talkiepack` isn't where it should be in the bundle — a packaging
        /// bug (the build script's copy block didn't run), not a user error.
        case missingResource
        /// The file was found but couldn't be decoded — a curation/corruption bug.
        case malformed
    }

    /// Locate this pack inside the running app bundle. Packs are copied flat into
    /// `Contents/Resources/` (see `scripts/build_app.sh`), mirroring how the
    /// connector `.mcpb` and brand PNGs are bundled, so a plain
    /// `Bundle.main.url(forResource:withExtension:)` finds them.
    func bundleURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: fileBaseName, withExtension: TalkiePack.fileExtension)
    }

    /// Decode this pack from the app bundle. Throws `LoadError` on a packaging or
    /// curation bug — the caller shows a calm message and changes nothing.
    func load(from bundle: Bundle = .main) throws -> TalkiePack {
        guard let url = bundleURL(in: bundle) else { throw LoadError.missingResource }
        guard let data = try? Data(contentsOf: url) else { throw LoadError.missingResource }
        return try Self.decode(data)
    }

    /// The pure decode step, shared by the runtime loader and the test gate (which
    /// reads the curated source files directly, since SwiftPM unit tests run
    /// without the assembled app bundle). Kept here so both paths agree on what a
    /// valid bundled pack is.
    static func decode(_ data: Data) throws -> TalkiePack {
        do {
            return try TalkiePack.decoded(from: data)
        } catch {
            throw LoadError.malformed
        }
    }
}
