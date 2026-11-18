import Foundation
import TalkieDiarization

/// The speaker names a diarized meeting can carry. "Me" and "Them" are the legacy
/// lane labels; "Speaker N" is minted by `SpeakerLabelling`.
enum SpeakerLabels {
    static let me = "Me"
    static let them = "Them"
    static let prefix = "Speaker "

    static func numbered(_ n: Int) -> String { "\(prefix)\(n)" }

    /// True for a label that is not a real person's name ("Me", "Them", "Speaker 3"),
    /// so callers like the context graph never mint a person entity from it.
    static func isGeneric(_ name: String) -> Bool {
        if name == me || name == them { return true }
        guard name.hasPrefix(prefix) else { return false }
        let tail = name.dropFirst(prefix.count)
        return !tail.isEmpty && tail.allSatisfy(\.isNumber)
    }

    /// The rendered line prefix `[mm:ss] Me: ` / `Speaker 2: ` (timecode optional).
    private static let linePrefix = try! NSRegularExpression(
        pattern: #"^(?:\[\d+(?::\d{2}){1,2}\]\s*)?(?:Me|Them|Speaker \d+):[ \t]*"#,
        options: [.anchorsMatchLines])

    /// A transcript without its speaker prefixes, for text mining (phrase extraction
    /// must not see "Speaker" / "Me" as content). Never used for display or storage.
    static func stripLabels(from transcript: String) -> String {
        let range = NSRange(transcript.startIndex..., in: transcript)
        return linePrefix.stringByReplacingMatches(in: transcript, range: range, withTemplate: "")
    }
}

/// One mic-lane cluster offered to the "which mic speaker is Me" decision.
struct MicSpeakerCandidate: Sendable, Equatable {
    let cluster: Int
    let embedding: [Float]
    let speechSeconds: Double
}

/// THE seam for own-voice recognition (WP-C). Called only when the mic lane has two
/// or more distinct people (after the bleed guard); returns the cluster to call "Me",
/// or nil when no one can be identified (everybody stays "Speaker N"). Never guesses
/// by dominance. WP-C replaces `SpeakerLabelling.noOwnVoice` with a profile matcher.
typealias OwnVoiceResolver = @Sendable (_ micSpeakers: [MicSpeakerCandidate]) -> Int?

/// Pure speaker labelling: no audio, no actors, no I/O. Takes the transcript segments
/// (lane-labelled "Me"/"Them") and each lane's diarization and decides every
/// segment's final speaker label.
///
/// Time bases: a segment's start/end are in ITS LANE's clock (seconds of audio fed to
/// that lane's recognizer) and each lane's diarization is computed over a recording
/// of exactly that audio, so overlap is only ever computed within one lane. The two
/// lanes' clocks are never compared with each other; cross-lane order for "first
/// appearance" numbering is the order of the segment array (the order the transcript
/// shows).
enum SpeakerLabelling {
    /// Cosine similarity at/above which a mic cluster is treated as the same voice as
    /// a system-lane speaker (laptop speakers audible in the mic). Measured on synthetic
    /// `say` audio with community-1 embeddings: different voices scored 0.11-0.19 against
    /// each other; the same voice pushed through a simulated laptop-speaker path
    /// (attenuation, low-pass, echo) scored 0.71. 0.55 sits well above the different-voice
    /// range and leaves headroom under the degraded same-voice score; real rooms are
    /// unmeasured (needs a live meeting). A missed match only costs one spurious extra
    /// speaker; a false match would merge two real people — hence also `bleedMargin`.
    static let defaultBleedThreshold = 0.55
    /// The best system match must beat the runner-up system speaker by this much, so a
    /// mic voice that resembles two far-end people equally is never merged into either.
    static let bleedMargin = 0.15
    /// A cluster with less speech than this is not trusted to be a separate person
    /// (a cough, a "mm-hm"): it is folded into its most similar substantial cluster in
    /// the same lane, so a stray fragment cannot flip a 1+1 call out of Me/Them.
    static let defaultMinSpeakerSeconds = 3.0

    static let noOwnVoice: OwnVoiceResolver = { _ in nil }

    struct Result: Sendable, Equatable {
        /// Final segments, same order/times/text as the input. Labels are rewritten and
        /// `lane` is set only when `changed`.
        var segments: [MeetingSegment]
        /// Distinct labels, "Me" first, then Speaker 1…N, then any leftover lane label.
        var participants: [String]
        /// Distinct people (== participants.count).
        var speakerCount: Int
        /// False for the legacy Me/Them outcome: labels untouched.
        var changed: Bool
        /// WP-C learning sample: set only when the mic lane held exactly ONE person
        /// after the fold and the bleed guard, and that voice is not a far-end
        /// speaker's. Never set for a multi-speaker mic lane. Biometric-like: callers
        /// feed it to the own-voice store and must not log or persist it elsewhere.
        var ownVoiceSample: MicSpeakerCandidate? = nil
    }

    private struct Cluster: Hashable { let lane: Int; let id: Int } // lane 0 = mic, 1 = system

    static func label(
        segments: [MeetingSegment],
        mic: DiarizationOutput?,
        system: DiarizationOutput?,
        bleedThreshold: Double = defaultBleedThreshold,
        minSpeakerSeconds: Double = defaultMinSpeakerSeconds,
        resolveMe: OwnVoiceResolver = noOwnVoice
    ) -> Result {
        let unchanged = Result(
            segments: segments,
            participants: distinct(segments.map(\.speaker)),
            speakerCount: distinct(segments.map(\.speaker)).count,
            changed: false)

        let outputs: [DiarizationOutput?] = [mic, system]
        let laneNames = [SpeakerLabels.me, SpeakerLabels.them]

        // 1. Fold fragment clusters, then assign each segment its max-overlap cluster.
        var canon: [[Int: Int]] = [[:], [:]]
        for lane in 0..<2 {
            if let out = outputs[lane] { canon[lane] = foldFragments(out, minSeconds: minSpeakerSeconds) }
        }
        var assigned: [Cluster?] = Array(repeating: nil, count: segments.count)
        for (i, seg) in segments.enumerated() {
            guard let lane = laneNames.firstIndex(of: seg.speaker), let out = outputs[lane] else { continue }
            if let raw = dominantSpeaker(start: seg.start, end: seg.end, turns: out.turns) {
                assigned[i] = Cluster(lane: lane, id: canon[lane][raw] ?? raw)
            }
        }
        let active: [[Int]] = (0..<2).map { lane in
            Array(Set(assigned.compactMap { $0?.lane == lane ? $0?.id : nil })).sorted()
        }
        let micActive = active[0], sysActive = active[1]

        func embedding(_ lane: Int, _ id: Int) -> [Float]? {
            outputs[lane]?.speakers.first { $0.speaker == id }?.embedding
        }
        // The single mic voice as a learning sample: all raw clusters folded into it
        // count toward its speech. Declined when it sounds like ANY active system
        // speaker (threshold only, no margin — for learning, doubt means skip), since a
        // mic lane holding only laptop-speaker bleed is not the owner talking.
        func learningSample(_ id: Int) -> MicSpeakerCandidate? {
            guard let emb = embedding(0, id), !emb.isEmpty else { return nil }
            for s in sysActive {
                if let se = embedding(1, s), cosine(emb, se) >= bleedThreshold { return nil }
            }
            let secs = (outputs[0]?.speakers ?? []).filter { (canon[0][$0.speaker] ?? $0.speaker) == id }
                .reduce(0.0) { $0 + $1.speechSeconds }
            return MicSpeakerCandidate(cluster: id, embedding: emb, speechSeconds: secs)
        }

        // 2. Legacy outcome: at most one person per lane keeps Me/Them exactly.
        if micActive.count <= 1 && sysActive.count <= 1 {
            var legacy = unchanged
            if micActive.count == 1 { legacy.ownVoiceSample = learningSample(micActive[0]) }
            return legacy
        }

        // 3. Bleed guard: a mic cluster that sounds like an active system speaker IS
        //    that person (their voice through the laptop speakers).
        var identity: [Cluster: Cluster] = [:] // mic cluster -> system cluster
        for m in micActive {
            guard let me = embedding(0, m) else { continue }
            var sims: [(id: Int, sim: Double)] = []
            for s in sysActive {
                if let se = embedding(1, s) { sims.append((s, cosine(me, se))) }
            }
            sims.sort { $0.sim > $1.sim }
            if let best = sims.first, best.sim >= bleedThreshold,
               sims.count < 2 || best.sim - sims[1].sim >= bleedMargin {
                identity[Cluster(lane: 0, id: m)] = Cluster(lane: 1, id: best.id)
            }
        }
        func person(_ c: Cluster) -> Cluster { identity[c] ?? c }

        // 4. Who is Me. THE plug-in point for own-voice recognition.
        let micOwn = micActive.filter { identity[Cluster(lane: 0, id: $0)] == nil }
        let meCluster: Cluster?
        if micOwn.count == 1 {
            // One own voice left AFTER the bleed guard (a call whose mic also hears the
            // far side through the laptop speakers still has exactly one local person).
            meCluster = Cluster(lane: 0, id: micOwn[0])
        } else if micOwn.isEmpty {
            meCluster = nil
        } else {
            let candidates = micOwn.map { id -> MicSpeakerCandidate in
                let p = outputs[0]?.speakers.first { $0.speaker == id }
                return MicSpeakerCandidate(cluster: id, embedding: p?.embedding ?? [],
                                           speechSeconds: p?.speechSeconds ?? 0)
            }
            meCluster = resolveMe(candidates).flatMap { micOwn.contains($0) ? Cluster(lane: 0, id: $0) : nil }
        }

        // 5. Number the other people by first appearance in transcript order.
        let order = segments.indices.sorted {
            segments[$0].start != segments[$1].start ? segments[$0].start < segments[$1].start : $0 < $1
        }
        var numbers: [Cluster: Int] = [:]
        for i in order {
            guard let c = assigned[i].map(person), c != meCluster, numbers[c] == nil else { continue }
            numbers[c] = numbers.count + 1
        }

        // The spec's unchanged 1+1 shape, judged on POST-guard counts: one own mic voice
        // (Me) and one far-end person (even when the mic also hears them as bleed) is
        // still Me / Them, never "Speaker 1".
        let farPeople = Set(assigned.compactMap { $0.map(person) }.filter { $0 != meCluster })
        let oneToOne = meCluster != nil && micOwn.count == 1 && sysActive.count == 1 && farPeople.count == 1

        // 6. Write labels. A segment with no overlap takes the label of the nearest-in-time
        //    segment of the SAME lane that was resolved, so a leftover lane label ("Them",
        //    or "Me" when nobody was recognised) never sits next to "Speaker N" or inflates
        //    the speaker count. Only a lane with no resolved segment at all keeps its label.
        var out = segments
        var resolved: [Int: String] = [:]
        for (i, seg) in segments.enumerated() {
            guard let c = assigned[i].map(person) else { continue }
            out[i].lane = seg.speaker
            let label = (c == meCluster) ? SpeakerLabels.me
                : (oneToOne ? SpeakerLabels.them : SpeakerLabels.numbered(numbers[c] ?? 0))
            out[i].speaker = label
            resolved[i] = label
        }
        for (i, seg) in segments.enumerated() where resolved[i] == nil {
            var best: (gap: Double, label: String)?
            for (j, label) in resolved.sorted(by: { $0.key < $1.key }) where segments[j].speaker == seg.speaker {
                let other = segments[j]
                let gap = max(0, max(seg.start, other.start) - min(seg.end, other.end))
                if best == nil || gap < best!.gap { // ties keep the earlier segment
                    best = (gap, label)
                }
            }
            if let best {
                out[i].lane = seg.speaker
                out[i].speaker = best.label
            }
        }
        var participants = distinct(out.map(\.speaker))
        participants.sort { rank($0) < rank($1) }
        return Result(segments: out, participants: participants, speakerCount: participants.count, changed: true,
                      ownVoiceSample: micOwn.count == 1 ? learningSample(micOwn[0]) : nil)
    }

    // MARK: - Pieces (internal for tests)

    /// The speaker with the most overlap with [start, end]; nil when none overlaps.
    /// A zero-length cue matches the turn that contains its instant. Ties go to the
    /// lower speaker index.
    static func dominantSpeaker(start: Double, end: Double, turns: [DiarizedTurn]) -> Int? {
        var total: [Int: Double] = [:]
        if end > start {
            for t in turns {
                let o = min(end, t.end) - max(start, t.start)
                if o > 0 { total[t.speaker, default: 0] += o }
            }
        } else {
            for t in turns where t.start <= start && start < t.end { total[t.speaker, default: 0] = 1 }
        }
        return total.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }

    /// Cluster -> canonical cluster. Clusters under `minSeconds` of speech map to their
    /// most similar substantial cluster; if none is substantial the largest survives.
    static func foldFragments(_ out: DiarizationOutput, minSeconds: Double) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for s in out.speakers { map[s.speaker] = s.speaker }
        guard let largest = out.speakers.max(by: { $0.speechSeconds < $1.speechSeconds }) else { return map }
        var keepers = out.speakers.filter { $0.speechSeconds >= minSeconds }
        if keepers.isEmpty { keepers = [largest] }
        let keeperIDs = Set(keepers.map(\.speaker))
        for s in out.speakers where !keeperIDs.contains(s.speaker) {
            let nearest = keepers.max { cosine(s.embedding, $0.embedding) < cosine(s.embedding, $1.embedding) }
            map[s.speaker] = nearest?.speaker ?? largest.speaker
        }
        return map
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += Double(a[i]) * Double(b[i]); na += Double(a[i]) * Double(a[i]); nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private static func distinct(_ labels: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for l in labels where seen.insert(l).inserted { out.append(l) }
        return out
    }

    /// Me, then Speaker 1…N numerically, then anything else (a leftover "Them").
    private static func rank(_ label: String) -> Int {
        if label == SpeakerLabels.me { return 0 }
        if label.hasPrefix(SpeakerLabels.prefix), let n = Int(label.dropFirst(SpeakerLabels.prefix.count)) { return n }
        return Int.max
    }
}
