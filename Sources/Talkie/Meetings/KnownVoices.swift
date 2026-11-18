import Foundation
import TalkieDiarization

// Known voices (W2 part C): voices of OTHER people the user explicitly asked Talkie to
// recognise, one person at a time, from the speaker popover. Modelled on the own-voice
// store: one 0600 JSON file under Application Support, never logged, never part of
// exports, MCP output, the context graph, diagnostics or the privacy receipt. Nothing
// is stored for a person the user did not opt in.

/// One remembered voice: a person's name and an L2-normalised speaker embedding.
struct KnownVoice: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var embedding: [Float]
    var speechSeconds: Double
    var createdUnix: Double
    /// The meeting + label it was taken from, so the popover's switch shows its state
    /// and can turn it off again. Not used for matching.
    var sourceMeetingID: UUID?
    var sourceLabel: String?
}

enum KnownVoiceMatcher {
    /// Evidence (`testKnownVoiceThresholdEvidence`, MeetingDiarizationIntegrationTests:
    /// nine synthetic `say` voices through the real community-1 embeddings, enrolled from
    /// one recording, probed with 18 separate recordings, half through a degraded laptop
    /// channel; 17-24 s of speech each). With margin 0.15 a leave-one-out probe (its own
    /// voice not enrolled) was falsely accepted 5/18 times at 0.55 and 1/18 at 0.60, never
    /// at 0.65-0.85; enrolled probes were all recognised up to 0.80 and the first miss
    /// came at 0.85. 0.70 sits in the middle of that error-free band, one step above the
    /// last false accept. Same voice scored 0.80-0.95, different voices at most 0.59.
    /// Real rooms and microphones are unmeasured: a miss only leaves "Speaker N", a false
    /// match would put a wrong name on someone, hence the strict side of the band.
    static let threshold = 0.70
    static let margin = 0.15
    /// Same floor as own-voice learning: shorter clusters have noisy embeddings.
    static let minSpeechSeconds = 20.0

    /// Labels -> remembered names. Each candidate needs `minSpeechSeconds` of speech,
    /// a best person (max over that person's entries) at or above `threshold`, and a
    /// lead of `margin` over the next-best known person. A person matched by two labels
    /// names neither. Empty input or a dimension mismatch -> nothing.
    static func match(candidates: [String: MicSpeakerCandidate], known: [KnownVoice]) -> [String: String] {
        guard !known.isEmpty else { return [:] }
        var byPerson: [String: (name: String, units: [[Float]])] = [:]
        for k in known {
            guard let u = OwnVoiceProfile.normalised(k.embedding) else { continue }
            let key = SpeakerNames.key(k.name)
            guard !key.isEmpty else { continue }
            byPerson[key, default: (k.name, [])].units.append(u)
        }
        var picked: [String: String] = [:] // label -> person key
        for (label, c) in candidates where SpeakerNames.isNameable(label) && c.speechSeconds >= minSpeechSeconds {
            guard let u = OwnVoiceProfile.normalised(c.embedding) else { continue }
            var scores: [(key: String, sim: Double)] = []
            for (key, p) in byPerson {
                let sims = p.units.filter { $0.count == u.count }.map { SpeakerLabelling.cosine(u, $0) }
                if let best = sims.max() { scores.append((key, best)) }
            }
            scores.sort { $0.sim != $1.sim ? $0.sim > $1.sim : $0.key < $1.key }
            guard let best = scores.first, best.sim >= threshold else { continue }
            if scores.count > 1, best.sim - scores[1].sim < margin { continue }
            picked[label] = best.key
        }
        var counts: [String: Int] = [:]
        for k in picked.values { counts[k, default: 0] += 1 }
        var out: [String: String] = [:]
        for (label, key) in picked where counts[key] == 1 { out[label] = byPerson[key]!.name }
        return out
    }
}

/// The persisted list. Thread-safe (lock-guarded, cached over one JSON file). A read
/// or write failure means nobody is recognised by voice — never an error the user sees.
final class KnownVoiceStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var cache: [KnownVoice] = []
    private var loaded = false
    private var epoch = 0

    static let shared = KnownVoiceStore()

    init(url: URL = KnownVoiceStore.defaultURL()) { self.url = url }

    static func defaultURL() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("known-voices.json")
    }

    func all() -> [KnownVoice] { lock.withLock { loadLocked() } }

    /// Bumped by every deletion. A sample computed before a deletion started (e.g. a
    /// re-diarization of kept audio) is dropped by `add(_:ifEpoch:)`.
    var currentEpoch: Int { lock.withLock { epoch } }

    /// The entry taken from this meeting's speaker, if any.
    func entry(meetingID: UUID, label: String) -> KnownVoice? {
        all().first { $0.sourceMeetingID == meetingID && $0.sourceLabel == label }
    }

    /// Remember one voice (replacing an earlier sample of the same meeting speaker).
    /// Refuses unusable samples: empty name, too little speech, a bad embedding.
    @discardableResult
    func add(name: String, sample: MicSpeakerCandidate, meetingID: UUID?, label: String?,
             ifEpoch: Int? = nil, now: Date = Date()) -> Bool {
        let n = SpeakerNames.clean(name)
        guard !n.isEmpty, sample.speechSeconds >= KnownVoiceMatcher.minSpeechSeconds,
              let unit = OwnVoiceProfile.normalised(sample.embedding) else { return false }
        return lock.withLock {
            if let ifEpoch, ifEpoch != epoch { return false }
            var list = loadLocked()
            if let meetingID, let label {
                list.removeAll { $0.sourceMeetingID == meetingID && $0.sourceLabel == label }
            }
            list.append(KnownVoice(name: n, embedding: unit, speechSeconds: sample.speechSeconds,
                                   createdUnix: now.timeIntervalSince1970, sourceMeetingID: meetingID,
                                   sourceLabel: label))
            guard persistLocked(list) else { return false }
            cache = list
            return true
        }
    }

    /// Keep a remembered voice's name in step with the user's manual rename.
    func rename(meetingID: UUID, label: String, to name: String) {
        let n = SpeakerNames.clean(name)
        guard !n.isEmpty else { return }
        lock.withLock {
            var list = loadLocked()
            guard let i = list.firstIndex(where: { $0.sourceMeetingID == meetingID && $0.sourceLabel == label }),
                  list[i].name != n else { return }
            list[i].name = n
            if persistLocked(list) { cache = list }
        }
    }

    func remove(id: UUID) { removeWhere { $0.id == id } }

    func remove(meetingID: UUID, label: String) {
        removeWhere { $0.sourceMeetingID == meetingID && $0.sourceLabel == label }
    }

    /// Forget every remembered voice (overwrite-then-delete the file).
    func removeAll() {
        lock.withLock {
            epoch += 1
            FileShredder.shred(url)
            cache = []
            loaded = true
        }
    }

    /// Strict matching for a new meeting's speakers.
    func match(_ candidates: [String: MicSpeakerCandidate]) -> [String: String] {
        KnownVoiceMatcher.match(candidates: candidates, known: all())
    }

    private func removeWhere(_ drop: (KnownVoice) -> Bool) {
        lock.withLock {
            epoch += 1
            let list = loadLocked()
            let kept = list.filter { !drop($0) }
            guard kept.count != list.count else { return }
            // Overwrite-then-delete the old bytes before writing what is left.
            FileShredder.shred(url)
            if kept.isEmpty { cache = []; return }
            if persistLocked(kept) { cache = kept } else { cache = [] }
        }
    }

    private func loadLocked() -> [KnownVoice] {
        if loaded { return cache }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([KnownVoice].self, from: data) else { cache = []; return [] }
        cache = list.filter { !$0.embedding.isEmpty && $0.embedding.allSatisfy(\.isFinite) }
        return cache
    }

    private func persistLocked(_ list: [KnownVoice]) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}

/// Recomputing a speaker's voice from a meeting's kept audio (when this app session no
/// longer holds it). Pure pieces, so the mapping from a fresh diarization of one lane
/// back to the stored label is tested without audio.
enum KeptAudioVoice {
    /// The lane + kept-audio basename that holds most of `label`'s speech, or nil.
    static func audioFile(for label: String, in meeting: Meeting) -> (lane: String, file: String)? {
        guard let segments = meeting.segments, let files = meeting.audioFiles, !files.isEmpty else { return nil }
        var byLane: [String: Double] = [:]
        for s in segments where s.speaker == label { byLane[s.audioKey, default: 0] += max(0, s.end - s.start) }
        guard let lane = byLane.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key,
              let file = Meeting.audioFileName(forSpeaker: lane, in: files),
              !file.isEmpty, !file.contains("/") else { return nil }
        return (lane, file)
    }

    /// Of the clusters in a fresh diarization of `lane`'s audio, the one that IS `label`:
    /// it must cover at least 60 % of the label's speech in that lane, and at least 80 %
    /// of that cluster's overlap with the lane's transcript must be this label (so a
    /// cluster mixing two people is never stored as one person). Nil otherwise.
    static func pick(output: DiarizationOutput, segments: [MeetingSegment], label: String,
                     lane: String) -> MicSpeakerCandidate? {
        let laneSegments = segments.filter { $0.audioKey == lane }
        var withLabel: [Int: Double] = [:], withAll: [Int: Double] = [:]
        var labelTotal = 0.0
        for s in laneSegments where s.end > s.start {
            if s.speaker == label { labelTotal += s.end - s.start }
            for t in output.turns {
                let o = min(s.end, t.end) - max(s.start, t.start)
                guard o > 0 else { continue }
                withAll[t.speaker, default: 0] += o
                if s.speaker == label { withLabel[t.speaker, default: 0] += o }
            }
        }
        guard labelTotal > 0,
              let best = withLabel.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              best.value >= 0.6 * labelTotal,
              let all = withAll[best.key], all > 0, best.value / all >= 0.8,
              let profile = output.speakers.first(where: { $0.speaker == best.key }) else { return nil }
        return MicSpeakerCandidate(cluster: best.key, embedding: profile.embedding, speechSeconds: profile.speechSeconds)
    }
}
