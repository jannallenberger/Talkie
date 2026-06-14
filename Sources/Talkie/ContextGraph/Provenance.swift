import Foundation

/// Where a fact in the context graph came from. Provenance is non-negotiable —
/// it is the privacy & trust story (you can always see exactly *why* something is
/// in your graph, and that it came only from your own data), and it lets a
/// consumer cite the source.
enum ProvenanceSource: String, Codable, Sendable {
    case dictation
    case meeting
    case dictionary
    case calendar
    case appContext
}

struct Provenance: Codable, Sendable, Hashable {
    var source: ProvenanceSource
    /// `DictationEntry.id` / `Meeting.id` / calendar event id, when applicable.
    var sourceID: String?
    var dateUnix: Double
    /// A short quote for display ("…why is this here?").
    var snippet: String?

    var date: Date { Date(timeIntervalSince1970: dateUnix) }
}
