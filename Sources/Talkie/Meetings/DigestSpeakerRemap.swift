import Foundation

/// Lane + time -> diarized label, derived from the relabelled segments, so the live
/// summary digest can be kept after diarization instead of rebuilt from the transcript.
///
/// The digest's lines are stamped with a lane ("Me"/"Them") and the segment's audio
/// start. A relabelled segment keeps its original lane in `lane` and its person label
/// in `speaker`, so a line maps to a person iff some segment of its lane starts at
/// that instant. A line with no such segment (a merged multilingual window, a trimmed
/// cue) cannot be mapped honestly and makes the remap fail.
struct DigestSpeakerRemap: Sendable {
    /// Per lane: segment starts (sorted) and their diarized labels.
    private let starts: [String: [Double]]
    private let labels: [String: [String]]
    /// Per lane: the single label every segment of the lane got, or nil when the lane
    /// became several people (or has no segments).
    private let singleLabel: [String: String]
    /// Distinct people in the whole meeting.
    let distinctLabels: Int

    /// Start times closer than this are the same segment. Digest pieces of one long
    /// line are stamped `start + i * 0.001` (up to ~50 pieces).
    static let tolerance = 0.06

    init(segments: [MeetingSegment]) {
        var byLane: [String: [(Double, String)]] = [:]
        for s in segments { byLane[s.audioKey, default: []].append((s.start, s.speaker)) }
        var starts: [String: [Double]] = [:], labels: [String: [String]] = [:], single: [String: String] = [:]
        for (lane, items) in byLane {
            let sorted = items.sorted { $0.0 < $1.0 }
            starts[lane] = sorted.map(\.0)
            labels[lane] = sorted.map(\.1)
            let distinct = Set(sorted.map(\.1))
            if distinct.count == 1, let only = distinct.first { single[lane] = only }
        }
        self.starts = starts
        self.labels = labels
        self.singleLabel = single
        self.distinctLabels = Set(segments.map(\.speaker)).count
    }

    func label(lane: MeetingSpeaker, at elapsed: Double) -> String? {
        guard let ts = starts[lane.rawValue], let ls = labels[lane.rawValue], !ts.isEmpty else { return nil }
        // Nearest start by binary search.
        var lo = 0, hi = ts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ts[mid] < elapsed { lo = mid + 1 } else { hi = mid }
        }
        var best: Int?
        for i in [lo - 1, lo] where ts.indices.contains(i) {
            if abs(ts[i] - elapsed) <= Self.tolerance, best.map({ abs(ts[i] - elapsed) < abs(ts[$0] - elapsed) }) ?? true {
                best = i
            }
        }
        return best.map { ls[$0] }
    }

    func laneWideLabel(_ lane: MeetingSpeaker) -> String? { singleLabel[lane.rawValue] }
}
