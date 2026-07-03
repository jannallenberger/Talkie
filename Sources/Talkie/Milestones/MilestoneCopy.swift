import Foundation

/// The COPY layer for the milestone ladder — the human-facing name and the
/// "≈ that's about as many words as …" line for each rung. `MilestoneLadder`
/// owns the arithmetic and the thresholds; this owns nothing but strings, keyed
/// by the SAME tier index, so a caller places a total with the ladder and looks
/// up its label here with the returned index.
///
/// HONESTY: dictated words include commands, repetition, and false starts, so a
/// lifetime count is NOT a word count of finished prose. Every equivalence keeps
/// an explicit "≈"/"about" and rounds to a public, verifiable reference figure —
/// it's a playful sense of scale, never a precise or strict claim ("you have
/// written The Great Gatsby"). All strings go through `.loc`.
enum MilestoneCopy {
    /// Name + equivalence for one rung.
    struct Tier {
        /// The feather-tier title ("First Feathers", "Fledgling", …).
        let name: String
        /// The "≈ …" sense-of-scale line, already localized.
        let equivalence: String
    }

    /// Every rung, index-aligned with `MilestoneLadder.thresholds`. Kept as a
    /// method (not a stored `static let`) so each string is resolved through
    /// `.loc` at call time against the user's current locale.
    static func tier(_ index: Int) -> Tier? {
        guard index >= 0, index < MilestoneLadder.thresholds.count else { return nil }
        return all[index]
    }

    /// The full ladder of copy, index-aligned with `MilestoneLadder.thresholds`.
    static var all: [Tier] {
        [
            Tier(name: "First Feathers".loc,
                 equivalence: "≈ 5 TED talks, or 37× the Gettysburg Address".loc),
            Tier(name: "Fledgling".loc,
                 equivalence: "≈ Alice’s Adventures in Wonderland (~27,000 words)".loc),
            Tier(name: "Finding Your Voice".loc,
                 equivalence: "≈ The Great Gatsby (~47,000) — a whole NaNoWriMo novel".loc),
            Tier(name: "Full Plumage".loc,
                 equivalence: "≈ To Kill a Mockingbird (~100,000)".loc),
            Tier(name: "Storyteller".loc,
                 equivalence: "≈ Moby-Dick (~209,000) with Gatsby stacked on top".loc),
            Tier(name: "Silver Tongue".loc,
                 equivalence: "≈ closing in on War and Peace (~560,000)".loc),
            Tier(name: "Golden Voice".loc,
                 equivalence: "≈ the King James Bible (~783,000)".loc),
            Tier(name: "Legendary".loc,
                 equivalence: "≈ the entire Harry Potter saga (~1.08 million words)".loc),
            Tier(name: "Mythical".loc,
                 equivalence: "≈ twice the Harry Potter saga; A Song of Ice and Fire so far (~1.7 million)".loc),
        ]
    }
}
