import Foundation

// Own-voice recognition (WP-C): a locally persisted running-mean speaker embedding of
// the laptop owner, learned automatically, used only to decide which of several mic
// speakers is "Me". Voice embeddings are biometric-like: the profile lives in one
// 0600 file under Application Support (via AppPaths), is never logged, and is never
// part of exports, MCP output, the context graph, diagnostics or the privacy receipt.

/// The running-mean voice profile. `embedding` is the weighted mean of the
/// L2-normalised sample embeddings (compared by cosine, so its scale is irrelevant).
struct OwnVoiceProfile: Codable, Sendable, Equatable {
    var embedding: [Float]
    /// Sum of the sample weights folded in (seconds of speech, each sample capped).
    var weight: Double
    var sampleCount: Int

    /// Evidence thresholds, from measured similarities (`testOwnVoiceSimilarityEvidence`
    /// in MeetingDiarizationIntegrationTests, 9 synthetic `say` voices, community-1
    /// embeddings, ~14-17 s of speech per sample): the same voice in a separate
    /// recording scored 0.92-0.95 (0.80-0.93 through a degraded low-pass/gain channel);
    /// different voices scored -0.04..0.59 (mean 0.21), the high end being near-twin
    /// TTS voices (Ralph/Fred 0.59, Samantha/Karen 0.57) that the diarizer itself
    /// merges. Real rooms and mics are unmeasured, hence conservative values.
    enum Policy {
        /// A mic-only lane must hold at least this much speech from the one speaker
        /// for it to count as a learning sample. Same-voice similarity was already
        /// saturated at 4-13 s of speech (0.88-0.95), but the diarizer needs ~10 s per
        /// voice to keep similar voices apart, so require twice that: a sample must be
        /// a pure, well-estimated cluster before it can move the mean.
        static let minSampleSeconds = 20.0
        /// One meeting can contribute at most this much weight, so a single very long
        /// meeting does not freeze the mean.
        static let maxSampleWeight = 120.0
        /// The existing mean counts for at most this much weight, so the profile keeps
        /// adapting slowly (new mic, cold, tired) instead of becoming immovable.
        static let maxProfileWeight = 1_800.0
        /// A new sample this far from an existing profile is probably another person
        /// alone at the laptop: it is NOT folded in (protects the mean from poisoning).
        static let learnFloor = 0.60
        /// Own-voice match: the best mic cluster must reach this cosine to the profile...
        static let matchThreshold = 0.65
        /// ...and beat the runner-up mic cluster by this much.
        static let matchMargin = 0.15
    }

    static func normalised(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty, v.allSatisfy(\.isFinite) else { return nil }
        let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0 else { return nil }
        return v.map { Float(Double($0) / norm) }
    }

    /// Fold one single-speaker mic-lane sample into `profile` (nil = first sample).
    /// Returns the profile unchanged when the sample is unusable: too little speech,
    /// a non-finite or wrong-sized embedding, or (with an existing profile) too
    /// dissimilar to be the same person.
    static func folding(_ sample: MicSpeakerCandidate, into profile: OwnVoiceProfile?) -> OwnVoiceProfile? {
        guard sample.speechSeconds >= Policy.minSampleSeconds,
              let unit = normalised(sample.embedding) else { return profile }
        let w = min(sample.speechSeconds, Policy.maxSampleWeight)
        guard let old = profile, old.embedding.count == unit.count,
              let oldUnit = normalised(old.embedding) else {
            return OwnVoiceProfile(embedding: unit, weight: w, sampleCount: 1)
        }
        guard SpeakerLabelling.cosine(unit, oldUnit) >= Policy.learnFloor else { return old }
        let wOld = min(old.weight, Policy.maxProfileWeight)
        var mean = [Float](repeating: 0, count: unit.count)
        for i in unit.indices {
            mean[i] = Float((Double(oldUnit[i]) * wOld + Double(unit[i]) * w) / (wOld + w))
        }
        guard let renormed = normalised(mean) else { return old }
        return OwnVoiceProfile(embedding: renormed, weight: wOld + w, sampleCount: old.sampleCount + 1)
    }
}

enum OwnVoiceMatcher {
    /// Which mic cluster is the profile's owner, or nil. Conservative: the best cosine
    /// must clear `matchThreshold` and beat the runner-up by `matchMargin`; a lone
    /// candidate only needs the threshold. No profile / dimension mismatch -> nil.
    static func decide(profile: [Float]?, candidates: [MicSpeakerCandidate]) -> Int? {
        guard let profile, let p = OwnVoiceProfile.normalised(profile) else { return nil }
        var scored: [(cluster: Int, sim: Double)] = []
        for c in candidates where c.embedding.count == p.count {
            guard let u = OwnVoiceProfile.normalised(c.embedding) else { continue }
            scored.append((c.cluster, SpeakerLabelling.cosine(u, p)))
        }
        scored.sort { $0.sim != $1.sim ? $0.sim > $1.sim : $0.cluster < $1.cluster }
        guard let best = scored.first, best.sim >= OwnVoiceProfile.Policy.matchThreshold else { return nil }
        if scored.count > 1, best.sim - scored[1].sim < OwnVoiceProfile.Policy.matchMargin { return nil }
        return best.cluster
    }
}

/// The persisted profile. Thread-safe (lock-guarded, in-memory cache over one JSON
/// file). Failures to read or write are silent: no profile simply means nobody is
/// auto-identified as "Me" in multi-speaker mic lanes.
final class OwnVoiceProfileStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var cache: OwnVoiceProfile?
    private var loaded = false

    /// The one store the app uses (the recorder learns into it, Settings can forget it),
    /// so a deletion also clears the in-memory copy the labeller reads.
    static let shared = OwnVoiceProfileStore()

    init(url: URL = OwnVoiceProfileStore.defaultURL()) { self.url = url }

    /// Whether a usable profile is stored. Presence only.
    var exists: Bool { load() != nil }

    static func defaultURL() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("own-voice-profile.json")
    }

    func load() -> OwnVoiceProfile? {
        lock.withLock { loadLocked() }
    }

    /// Fold one learning sample in and persist. Returns whether the profile changed.
    @discardableResult
    func learn(_ sample: MicSpeakerCandidate) -> Bool {
        lock.withLock {
            let old = loadLocked()
            guard let updated = OwnVoiceProfile.folding(sample, into: old), updated != old else { return false }
            guard persistLocked(updated) else { return false }
            cache = updated
            return true
        }
    }

    /// Remove the profile (overwrite-then-delete, like the other personal data files).
    func delete() {
        lock.withLock {
            FileShredder.shred(url)
            cache = nil
            loaded = true
        }
    }

    /// The resolver the labeller consults when the mic lane has several people.
    var resolver: OwnVoiceResolver {
        { [self] candidates in OwnVoiceMatcher.decide(profile: load()?.embedding, candidates: candidates) }
    }

    private func loadLocked() -> OwnVoiceProfile? {
        if loaded { return cache }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(OwnVoiceProfile.self, from: data),
              !p.embedding.isEmpty, p.embedding.allSatisfy(\.isFinite) else { cache = nil; return nil }
        cache = p
        return p
    }

    private func persistLocked(_ p: OwnVoiceProfile) -> Bool {
        guard let data = try? JSONEncoder().encode(p) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}
