@preconcurrency import AVFoundation
import Foundation
import TalkieDiarization

// Known voices (W2 part C): voices of OTHER people the user explicitly asked Talkie to
// recognise, one person at a time, from the speaker popover. Modelled on the own-voice
// store: one 0600 JSON file under Application Support, never logged, never part of
// exports, MCP output, the context graph, diagnostics or the privacy receipt. A person
// is a PROFILE of several samples (one per meeting the user saved them from), capped.

/// One sample of a person's voice: an L2-normalised embedding from one meeting speaker.
struct VoiceSample: Codable, Sendable, Equatable {
    var embedding: [Float]
    var speechSeconds: Double
    var createdUnix: Double
    /// The meeting + label it was taken from (the popover's switch state, removal).
    var sourceMeetingID: UUID?
    var sourceLabel: String?
}

/// One remembered person: a name and up to `maxSamples` voice samples.
struct KnownVoice: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var samples: [VoiceSample]

    /// Kept samples: the ones with the most speech (best-estimated embeddings).
    static let maxSamples = 8

    var createdUnix: Double { samples.map(\.createdUnix).min() ?? 0 }
    /// How many distinct meetings the profile was built from (for the settings list).
    var meetingCount: Int {
        Set(samples.map { $0.sourceMeetingID?.uuidString ?? "sample-\($0.createdUnix)" }).count
    }

    init(id: UUID = UUID(), name: String, samples: [VoiceSample]) {
        self.id = id; self.name = name; self.samples = samples
    }

    /// Test/legacy convenience: a one-sample person.
    init(name: String, embedding: [Float], speechSeconds: Double, createdUnix: Double,
         sourceMeetingID: UUID? = nil, sourceLabel: String? = nil) {
        self.init(name: name, samples: [VoiceSample(embedding: embedding, speechSeconds: speechSeconds,
                                                    createdUnix: createdUnix, sourceMeetingID: sourceMeetingID,
                                                    sourceLabel: sourceLabel)])
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, samples
        // The first (single-sample) file layout of this branch.
        case embedding, speechSeconds, createdUnix, sourceMeetingID, sourceLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        if let s = try c.decodeIfPresent([VoiceSample].self, forKey: .samples) {
            samples = s
        } else {
            samples = [VoiceSample(embedding: try c.decode([Float].self, forKey: .embedding),
                                   speechSeconds: try c.decodeIfPresent(Double.self, forKey: .speechSeconds) ?? 0,
                                   createdUnix: try c.decodeIfPresent(Double.self, forKey: .createdUnix) ?? 0,
                                   sourceMeetingID: try c.decodeIfPresent(UUID.self, forKey: .sourceMeetingID),
                                   sourceLabel: try c.decodeIfPresent(String.self, forKey: .sourceLabel))]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(samples, forKey: .samples)
    }

    /// Keep the `maxSamples` samples with the most speech (ties: newest).
    static func capped(_ samples: [VoiceSample]) -> [VoiceSample] {
        guard samples.count > maxSamples else { return samples }
        return Array(samples.sorted {
            $0.speechSeconds != $1.speechSeconds ? $0.speechSeconds > $1.speechSeconds : $0.createdUnix > $1.createdUnix
        }.prefix(maxSamples))
    }
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

    /// How a multi-sample profile scores against a candidate.
    enum Aggregation: Sendable { case best, mean }
    /// The MEAN over a person's samples. Evidence (`testKnownVoiceMultiSampleEvidence`:
    /// nine synthetic voices each enrolled from two meetings, one through a degraded
    /// channel, 18 separate probes): both rules got 18/18 right with 0 wrong and 0
    /// leave-one-out false accepts at 0.70 / 0.15. Own-person scores: best-of min 0.964,
    /// mean min 0.906; other-person max: best-of 0.610, mean 0.602. Best-of has a little
    /// more headroom with two samples, but its other-person maximum can only grow as a
    /// profile fills to 8 samples (a stranger needs to resemble just ONE of them), while
    /// the mean keeps a 0.2 margin above the threshold for the right person. Wrong names
    /// cost more than misses, so the mean.
    static let aggregation: Aggregation = .mean

    static func score(_ unit: [Float], _ person: KnownVoice, _ how: Aggregation) -> Double? {
        let sims = person.samples.compactMap { s -> Double? in
            guard let u = OwnVoiceProfile.normalised(s.embedding), u.count == unit.count else { return nil }
            return SpeakerLabelling.cosine(unit, u)
        }
        guard !sims.isEmpty else { return nil }
        switch how {
        case .best: return sims.max()
        case .mean: return sims.reduce(0, +) / Double(sims.count)
        }
    }

    /// Labels -> remembered names. Each candidate needs `minSpeechSeconds` of speech, a
    /// best person at or above `threshold`, and a lead of `margin` over the next-best known
    /// person. Two profiles with the same name count as one person (their best score).
    /// A person matched by two labels names neither. Empty input or a dimension mismatch
    /// -> nothing.
    static func match(candidates: [String: MicSpeakerCandidate], known: [KnownVoice],
                      aggregation: Aggregation = aggregation) -> [String: String] {
        guard !known.isEmpty else { return [:] }
        var display: [String: String] = [:]
        for k in known where !SpeakerNames.key(k.name).isEmpty && display[SpeakerNames.key(k.name)] == nil {
            display[SpeakerNames.key(k.name)] = k.name
        }
        var picked: [String: String] = [:] // label -> person key
        for (label, c) in candidates where SpeakerNames.isNameable(label) && c.speechSeconds >= minSpeechSeconds {
            guard let u = OwnVoiceProfile.normalised(c.embedding) else { continue }
            var byPerson: [String: Double] = [:]
            for k in known {
                let key = SpeakerNames.key(k.name)
                guard !key.isEmpty, let s = score(u, k, aggregation) else { continue }
                byPerson[key] = max(byPerson[key] ?? -2, s)
            }
            let scores = byPerson.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            guard let best = scores.first, best.value >= threshold else { continue }
            if scores.count > 1, best.value - scores[1].value < margin { continue }
            picked[label] = best.key
        }
        var counts: [String: Int] = [:]
        for k in picked.values { counts[k, default: 0] += 1 }
        var out: [String: String] = [:]
        for (label, key) in picked where counts[key] == 1 { out[label] = display[key]! }
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

    /// The person holding a sample taken from this meeting's speaker, if any.
    func entry(meetingID: UUID, label: String) -> KnownVoice? {
        all().first { $0.samples.contains { $0.sourceMeetingID == meetingID && $0.sourceLabel == label } }
    }

    /// The person with this name (case/diacritic-insensitive), if any.
    func person(named name: String) -> KnownVoice? {
        let k = SpeakerNames.key(name)
        return all().first { SpeakerNames.key($0.name) == k }
    }

    /// Remember one sample under `name`. An existing person with that name GAINS the
    /// sample (an earlier sample of the same meeting speaker is replaced; the profile is
    /// capped to the samples with the most speech); otherwise a new person is created.
    /// A sample of this meeting speaker filed under a different person moves here.
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
                for i in list.indices {
                    list[i].samples.removeAll { $0.sourceMeetingID == meetingID && $0.sourceLabel == label }
                }
                list.removeAll { $0.samples.isEmpty }
            }
            let s = VoiceSample(embedding: unit, speechSeconds: sample.speechSeconds,
                                createdUnix: now.timeIntervalSince1970, sourceMeetingID: meetingID, sourceLabel: label)
            let key = SpeakerNames.key(n)
            if let i = list.firstIndex(where: { SpeakerNames.key($0.name) == key }) {
                list[i].samples = KnownVoice.capped(list[i].samples + [s])
            } else {
                list.append(KnownVoice(name: n, samples: [s]))
            }
            guard persistLocked(list) else { return false }
            cache = list
            return true
        }
    }

    /// Keep a remembered sample in step with the user's manual rename: the sample moves
    /// to the person with the new name (merging into an existing profile).
    func rename(meetingID: UUID, label: String, to name: String) {
        let n = SpeakerNames.clean(name)
        guard !n.isEmpty else { return }
        lock.withLock {
            var list = loadLocked()
            guard let i = list.firstIndex(where: { $0.samples.contains { $0.sourceMeetingID == meetingID && $0.sourceLabel == label } }),
                  SpeakerNames.key(list[i].name) != SpeakerNames.key(n) || list[i].name != n else { return }
            if SpeakerNames.key(list[i].name) == SpeakerNames.key(n) {
                list[i].name = n
            } else {
                let moved = list[i].samples.filter { $0.sourceMeetingID == meetingID && $0.sourceLabel == label }
                list[i].samples.removeAll { $0.sourceMeetingID == meetingID && $0.sourceLabel == label }
                if let j = list.firstIndex(where: { SpeakerNames.key($0.name) == SpeakerNames.key(n) }) {
                    list[j].samples = KnownVoice.capped(list[j].samples + moved)
                } else {
                    list.append(KnownVoice(name: n, samples: moved))
                }
                list.removeAll { $0.samples.isEmpty }
            }
            if persistLocked(list) { cache = list }
        }
    }

    /// Forget a whole person.
    func remove(id: UUID) { mutate { $0.removeAll { $0.id == id } } }

    /// Forget only the sample taken from this meeting speaker.
    func remove(meetingID: UUID, label: String) {
        mutate { list in
            for i in list.indices {
                list[i].samples.removeAll { $0.sourceMeetingID == meetingID && $0.sourceLabel == label }
            }
            list.removeAll { $0.samples.isEmpty }
        }
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

    private func mutate(_ change: (inout [KnownVoice]) -> Void) {
        lock.withLock {
            epoch += 1
            let list = loadLocked()
            var kept = list
            change(&kept)
            guard kept != list else { return }
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
        cache = list.compactMap { p in
            var p = p
            p.samples = p.samples.filter { !$0.embedding.isEmpty && $0.embedding.allSatisfy(\.isFinite) }
            return p.samples.isEmpty ? nil : p
        }
        return cache
    }

    private func persistLocked(_ list: [KnownVoice]) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        return OwnerOnlyFile.write(data, to: url)
    }
}

/// Owner-only file writes for voice data: the folder 0700, the file 0600.
enum OwnerOnlyFile {
    static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}

// MARK: - Per-meeting voice sidecar

/// Each diarized speaker's voice (embedding + speech seconds) for one meeting, written
/// at diarization time so "Recognise this voice" works later without kept audio.
/// One owner-only file per meeting in App Support/meeting-voices/; it lives exactly as
/// long as the meeting: removed by `MeetingStore.delete`, by the retention cap, and
/// swept for meetings no longer in the index. Never part of exports, MCP or the graph.
final class MeetingVoiceSidecar: @unchecked Sendable {
    let directory: URL
    static let shared = MeetingVoiceSidecar()

    init(directory: URL = MeetingVoiceSidecar.defaultDirectory()) { self.directory = directory }

    static func defaultDirectory() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("meeting-voices", isDirectory: true)
    }

    struct Payload: Codable, Equatable {
        struct Voice: Codable, Equatable { var embedding: [Float]; var speechSeconds: Double }
        var voices: [String: Voice]
    }

    func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    /// Store this meeting's speakers ("Me" excluded). An empty set removes the file.
    func save(_ voices: [String: MicSpeakerCandidate], for id: UUID) {
        let usable = voices.filter { SpeakerNames.isNameable($0.key) && !$0.value.embedding.isEmpty
            && $0.value.embedding.allSatisfy(\.isFinite) }
        guard !usable.isEmpty else { remove(id); return }
        let payload = Payload(voices: usable.mapValues { .init(embedding: $0.embedding, speechSeconds: $0.speechSeconds) })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        if OwnerOnlyFile.write(data, to: url(for: id)) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// Add or replace one speaker's voice (a voice recomputed from kept audio).
    func saveOne(_ voice: MicSpeakerCandidate, label: String, for id: UUID) {
        var all = load(id)?.voices.mapValues { MicSpeakerCandidate(cluster: 0, embedding: $0.embedding, speechSeconds: $0.speechSeconds) } ?? [:]
        all[label] = voice
        save(all, for: id)
    }

    private func load(_ id: UUID) -> Payload? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    func voice(meetingID: UUID, label: String) -> MicSpeakerCandidate? {
        guard let data = try? Data(contentsOf: url(for: meetingID)),
              let p = try? JSONDecoder().decode(Payload.self, from: data), let v = p.voices[label] else { return nil }
        return MicSpeakerCandidate(cluster: 0, embedding: v.embedding, speechSeconds: v.speechSeconds)
    }

    func remove(_ id: UUID) {
        let u = url(for: id)
        if FileManager.default.fileExists(atPath: u.path) { FileShredder.shred(u) }
    }

    /// Delete sidecars of meetings that are no longer in the index. Returns how many.
    @discardableResult
    func sweep(keeping ids: Set<UUID>) -> Int {
        var n = 0
        for id in storedIDs() where !ids.contains(id) { remove(id); n += 1 }
        return n
    }

    func storedIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { $0.hasSuffix(".json") ? UUID(uuidString: String($0.dropLast(5))) : nil }
    }

    func removeAll() { for id in storedIDs() { remove(id) } }
}

// MARK: - Recomputing a voice from audio

/// Recomputing a speaker's voice from a meeting's kept audio (meetings diarized before
/// the sidecar existed). Pure pieces, so the mapping from a fresh diarization of one
/// lane back to the stored label is tested without audio.
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

    /// Whether a meeting was imported from a file (vs recorded live).
    static func isImport(_ meeting: Meeting) -> Bool {
        meeting.participants == ["Imported"] || meeting.source.hasPrefix("talkie (imported")
    }

    /// The diarizer reads only 16 kHz mono files (the vendored loader's temp-file
    /// conversion was removed on purpose so no meeting audio lands in /tmp), and kept
    /// audio is m4a/mp3/…: convert it into Talkie's private diarization scratch folder
    /// first. The caller deletes the result.
    static func transcodeTo16kMono(_ source: URL, into dir: URL = AppPaths.diarizationTempDirectory()) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("voice-\(UUID().uuidString).wav")
        let input = try AVAudioFile(forReading: source)
        let tee = MeetingDiarizationTee(url: out)
        let format = input.processingFormat
        // Down-mix to mono here (the tee's resampler is proven on mono sources).
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: 1, interleaved: false) else { throw CocoaError(.fileReadCorruptFile) }
        while input.framePosition < input.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { break }
            try input.read(into: buf, frameCount: 16_384)
            if buf.frameLength == 0 { break }
            guard let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
                  let src = buf.floatChannelData, let dst = out.floatChannelData else { break }
            out.frameLength = buf.frameLength
            let channels = Int(format.channelCount)
            for i in 0..<Int(buf.frameLength) {
                var sum: Float = 0
                for c in 0..<channels { sum += src[c][i] }
                dst[0][i] = sum / Float(max(1, channels))
            }
            tee.append(out)
        }
        guard let summary = tee.close() else { throw CocoaError(.fileReadCorruptFile) }
        return summary.url
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
