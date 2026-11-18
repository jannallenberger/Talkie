import Foundation

/// Lane + time -> diarized label, derived from the relabelled segments, so the live
/// summary digest can be kept after diarization instead of rebuilt from the transcript.
///
/// The digest's lines are stamped with a lane ("Me"/"Them") and the segment's audio
/// start. A relabelled segment keeps its original lane in `lane` and its person label
/// in `speaker`, so a line maps to a person iff some segment of its lane starts at
/// that instant. A line with no such segment (a merged multilingual window, a trimmed
/// cue) cannot be mapped honestly and makes the remap fail.
///
/// SPLIT SEGMENTS. Labelling may split one transcript segment into several speaker
/// pieces. A digest line still carries the ORIGINAL segment's start, so a line maps to
/// its source segment, and is relabelled only when one speaker holds at least
/// `majorityShare` of that segment's text; otherwise the line has no honest single
/// speaker and the lookup returns nil, which fails the remap (the caller then rebuilds
/// the digest from the transcript).
struct DigestSpeakerRemap: Sendable {
    /// Share of a split segment's text one speaker must hold for its digest line to be
    /// relabelled by majority.
    static let majorityShare = 0.8

    /// Per lane: segment starts (sorted) and their diarized labels (nil = ambiguous).
    private let starts: [String: [Double]]
    private let labels: [String: [String?]]
    /// Per lane: the single label every segment of the lane got, or nil when the lane
    /// became several people (or has no segments).
    private let singleLabel: [String: String]
    /// Distinct people in the whole meeting.
    let distinctLabels: Int

    /// Start times closer than this are the same segment. Digest pieces of one long
    /// line are stamped `start + i * 0.001` (up to ~50 pieces).
    static let tolerance = 0.06

    /// `segments` are the final (possibly split) segments; `source`/`sourceIndex` are the
    /// pre-split segments the digest lines were stamped from and, per final segment, the
    /// index of its source. Omit both when nothing was split.
    init(segments: [MeetingSegment], source: [MeetingSegment]? = nil, sourceIndex: [Int]? = nil) {
        // One entry per digest-visible segment: lane, start, label (nil = ambiguous).
        var entries: [(lane: String, start: Double, label: String?)] = []
        if let source, let sourceIndex, sourceIndex.count == segments.count {
            var pieces: [Int: [MeetingSegment]] = [:]
            for (k, s) in segments.enumerated() { pieces[sourceIndex[k], default: []].append(s) }
            for (i, src) in source.enumerated() {
                let group = pieces[i] ?? []
                guard !group.isEmpty else { continue }
                entries.append((src.audioKey, src.start, Self.majorityLabel(group)))
            }
        } else {
            for s in segments { entries.append((s.audioKey, s.start, s.speaker)) }
        }
        var byLane: [String: [(Double, String?)]] = [:]
        for e in entries { byLane[e.lane, default: []].append((e.start, e.label)) }
        var starts: [String: [Double]] = [:], labels: [String: [String?]] = [:], single: [String: String] = [:]
        for (lane, items) in byLane {
            let sorted = items.sorted { $0.0 < $1.0 }
            starts[lane] = sorted.map(\.0)
            labels[lane] = sorted.map(\.1)
        }
        // Lane-wide label: every FINAL segment of the lane carries the same label.
        var laneLabels: [String: Set<String>] = [:]
        for s in segments { laneLabels[s.audioKey, default: []].insert(s.speaker) }
        for (lane, set) in laneLabels where set.count == 1 { single[lane] = set.first }
        self.starts = starts
        self.labels = labels
        self.singleLabel = single
        self.distinctLabels = Set(segments.map(\.speaker)).count
    }

    /// The label of a group of pieces from one source segment: the sole label, or the
    /// majority label when it holds at least `majorityShare` of the text, else nil.
    static func majorityLabel(_ group: [MeetingSegment]) -> String? {
        var weight: [String: Int] = [:]
        for p in group { weight[p.speaker, default: 0] += max(1, p.text.filter { !$0.isWhitespace }.count) }
        guard let best = weight.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return nil }
        let total = weight.values.reduce(0, +)
        return weight.count == 1 || Double(best.value) >= majorityShare * Double(total) ? best.key : nil
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
        return best.flatMap { ls[$0] }
    }

    func laneWideLabel(_ lane: MeetingSpeaker) -> String? { singleLabel[lane.rawValue] }
}
