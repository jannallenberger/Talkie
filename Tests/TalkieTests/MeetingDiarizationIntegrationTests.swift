@preconcurrency import AVFoundation
import XCTest
import TalkieDiarization
@testable import Talkie

/// End-to-end on synthetic `say` audio: capture-shaped buffers -> tee (the real class,
/// with its resampling path) -> real SpeakerDiarizer on the tee's FILE -> relabel. Skips
/// cleanly when the models (scripts/fetch_diarization_models.sh) or `say` voices are
/// absent. The two lanes deliberately run on DIFFERENT clocks (the system lane starts
/// 2.5 s late and is fed at a different sample rate) to prove lane-local alignment.
final class MeetingDiarizationIntegrationTests: XCTestCase {
    private struct Clip { let voice: String; let start: Double; let end: Double }
    private struct Lane {
        var samples: [Float] = [Float](repeating: 0, count: 0)
        var clips: [Clip] = []
    }

    private static let lines = [
        "The quarterly numbers look better than we expected, mostly thanks to the new onboarding flow.",
        "I agree, but we still need to fix the export bug before the release on Friday.",
        "Let me check with the design team and get back to you by tomorrow afternoon.",
        "Sounds good. Can you also send the updated timeline to everyone on the call?",
        "Sure, I will write it up tonight and share it in the project channel.",
        "Great, then we are done for today. Thanks everyone for joining.",
    ]

    private var tmp: URL!
    private var cache: [String: [Float]] = [:]

    override func setUpWithError() throws {
        XCTAssertNotNil(AppPaths.testSandboxRoot)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diar-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func modelsRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/DiarizationModels", isDirectory: true)
        let env = ProcessInfo.processInfo.environment["TALKIE_DIARIZATION_MODELS"]
        let url = (env?.isEmpty == false) ? URL(fileURLWithPath: env!, isDirectory: true) : root
        guard SpeakerDiarizer.modelsAvailable(at: url) else {
            throw XCTSkip("diarization models not present at \(url.path) — run scripts/fetch_diarization_models.sh")
        }
        return url
    }

    private func say(_ voice: String, _ line: Int) throws -> [Float] {
        let key = "\(voice)#\(line)"
        if let c = cache[key] { return c }
        let url = tmp.appendingPathComponent("\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000",
                       Self.lines[line % Self.lines.count]]
        do { try p.run() } catch { throw XCTSkip("`say` unavailable") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("`say -v \(voice)` unavailable") }
        let f = try AVAudioFile(forReading: url)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard f.processingFormat.sampleRate == 16_000,
              let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw XCTSkip("unexpected `say` format")
        }
        try f.read(into: b)
        let out = Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
        cache[key] = out
        return out
    }

    /// Simulates laptop-speaker bleed: attenuation, a one-pole low-pass, a 40 ms echo.
    private func throughLaptopSpeakers(_ x: [Float], gain: Float = 0.3) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var lp: Float = 0
        for i in x.indices {
            lp += 0.35 * (x[i] - lp)
            y[i] = lp * gain
        }
        let d = 640
        for i in d..<y.count { y[i] += 0.3 * y[i - d] }
        return y
    }

    /// Build a lane: `lead` seconds of silence, then clips separated by 0.7 s gaps.
    private func lane(lead: Double, _ script: [(voice: String, transform: (([Float]) -> [Float])?)]) throws -> Lane {
        let gap = [Float](repeating: 0, count: Int(0.7 * 16_000))
        var l = Lane()
        l.samples = [Float](repeating: 0, count: Int(lead * 16_000)) + gap
        for (i, item) in script.enumerated() {
            var pcm = try say(item.voice, i)
            if let t = item.transform { pcm = t(pcm) }
            l.clips.append(Clip(voice: item.voice, start: Double(l.samples.count) / 16_000,
                                end: Double(l.samples.count + pcm.count) / 16_000))
            l.samples += pcm + gap
        }
        return l
    }

    /// Push a lane through the real tee as capture-shaped buffers at `rate`
    /// (linear-interpolated up when != 16 kHz) and return the closed tee file.
    private func tee(_ lane: Lane, name: String, rate: Double) throws -> URL {
        let tee = MeetingDiarizationTee(url: tmp.appendingPathComponent(name))
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let ratio = rate / 16_000
        let total = Int(Double(lane.samples.count) * ratio)
        var pos = 0
        while pos < total {
            let n = min(4096, total - pos)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let p = buf.floatChannelData![0]
            for i in 0..<n {
                let src = Double(pos + i) / ratio
                let i0 = min(Int(src), lane.samples.count - 1), i1 = min(i0 + 1, lane.samples.count - 1)
                let f = Float(src - Double(i0))
                p[i] = lane.samples[i0] * (1 - f) + lane.samples[i1] * f
            }
            tee.append(buf)
            pos += n
        }
        return try XCTUnwrap(tee.close()).url
    }

    private func segments(_ lane: Lane, as label: String) -> [MeetingSegment] {
        lane.clips.map { MeetingSegment(speaker: label, start: $0.start, end: $0.end, text: $0.voice) }
    }

    private func interleaved(_ a: [MeetingSegment], _ b: [MeetingSegment]) -> [MeetingSegment] {
        (a + b).enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)
    }

    private func run(mic: Lane, sys: Lane?, micRate: Double, sysRate: Double, models: URL)
        async throws -> (SpeakerLabelling.Result, DiarizationOutput, DiarizationOutput?)
    {
        let diarizer = SpeakerDiarizer(modelsDirectory: models)
        let micURL = try tee(mic, name: "mic.wav", rate: micRate)
        let micOut = try await diarizer.diarize(fileURL: micURL)
        var sysOut: DiarizationOutput?
        var segs = segments(mic, as: "Me")
        if let sys {
            let sysURL = try tee(sys, name: "sys.wav", rate: sysRate)
            sysOut = try await diarizer.diarize(fileURL: sysURL)
            segs = interleaved(segs, segments(sys, as: "Them"))
        }
        return (SpeakerLabelling.label(segments: segs, mic: micOut, system: sysOut), micOut, sysOut)
    }

    /// 2 people share the laptop mic, 1 on the far end -> 3 distinct people.
    func testCallWithTwoOnTheMicAndOneFarSpeaker() async throws {
        let models = try modelsRoot()
        let mic = try lane(lead: 0, [("Daniel", nil), ("Samantha", nil), ("Daniel", nil), ("Samantha", nil)])
        let sys = try lane(lead: 2.5, [("Ralph", nil), ("Ralph", nil), ("Ralph", nil)])
        let (r, micOut, sysOut) = try await run(mic: mic, sys: sys, micRate: 48_000, sysRate: 16_000, models: models)
        print("[int] call: micSpeakers=\(micOut.speakerCount) sysSpeakers=\(sysOut?.speakerCount ?? -1) labels=\(r.segments.map(\.speaker))")
        XCTAssertTrue(r.changed)
        XCTAssertEqual(r.speakerCount, 3)
        let byVoice = Dictionary(grouping: r.segments, by: \.text).mapValues { Set($0.map(\.speaker)) }
        XCTAssertEqual(byVoice["Daniel"]?.count, 1, "Daniel is one person")
        XCTAssertEqual(byVoice["Samantha"]?.count, 1)
        XCTAssertEqual(byVoice["Ralph"]?.count, 1)
        XCTAssertEqual(Set(byVoice.values.flatMap { $0 }).count, 3, "three different labels")
        XCTAssertFalse(r.participants.contains("Me") || r.participants.contains("Them"))
        XCTAssertEqual(r.segments.first(where: { $0.text == "Daniel" })?.speaker, "Speaker 1", "first heard = Speaker 1")
    }

    /// One person per lane: Me/Them untouched.
    func testOnePersonPerLaneKeepsMeThem() async throws {
        let models = try modelsRoot()
        let mic = try lane(lead: 0, [("Daniel", nil), ("Daniel", nil)])
        let sys = try lane(lead: 1.0, [("Ralph", nil), ("Ralph", nil)])
        let (r, _, _) = try await run(mic: mic, sys: sys, micRate: 16_000, sysRate: 48_000, models: models)
        XCTAssertFalse(r.changed)
        XCTAssertEqual(Set(r.segments.map(\.speaker)), ["Me", "Them"])
        XCTAssertEqual(r.participants, ["Me", "Them"])
    }

    /// The far speaker leaks into the mic through the laptop speakers: the guard must
    /// make it the same person, not a fourth one. Also reports the measured cosines.
    func testBleedIntoMicIsTheSamePersonAsTheSystemSpeaker() async throws {
        let models = try modelsRoot()
        let mic = try lane(lead: 0, [("Samantha", nil), ("Ralph", { self.throughLaptopSpeakers($0) }),
                                     ("Samantha", nil), ("Ralph", { self.throughLaptopSpeakers($0) })])
        let sys = try lane(lead: 2.0, [("Ralph", nil), ("Daniel", nil), ("Ralph", nil), ("Daniel", nil)])
        let (r, micOut, sysOut) = try await run(mic: mic, sys: sys, micRate: 16_000, sysRate: 16_000, models: models)
        for m in micOut.speakers {
            for s in sysOut?.speakers ?? [] {
                print(String(format: "[int] bleed cosine mic#%d vs sys#%d = %.3f", m.speaker, s.speaker,
                             SpeakerLabelling.cosine(m.embedding, s.embedding)))
            }
        }
        print("[int] bleed: mic=\(micOut.speakerCount) sys=\(sysOut?.speakerCount ?? -1) labels=\(r.segments.map { "\($0.text):\($0.speaker)" })")
        let micRalph = r.segments.filter { $0.lane == "Me" && $0.text == "Ralph" }.map(\.speaker)
        let sysRalph = r.segments.filter { $0.lane == "Them" && $0.text == "Ralph" }.map(\.speaker)
        XCTAssertEqual(Set(micRalph).count, 1)
        XCTAssertEqual(Set(micRalph), Set(sysRalph), "bleed is merged into the system speaker")
        XCTAssertEqual(r.speakerCount, 3, "Samantha, Ralph, Daniel")
    }

    // MARK: opt-in lane-concurrency probe

    private static func peakRSSMB() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_maxrss) / 1_048_576 // bytes on macOS
    }

    /// TALKIE_DIAR_PERF=1 (use a release build): two ~15 min lanes, serial vs concurrent.
    func testLaneConcurrencyProbe() async throws {
        guard ProcessInfo.processInfo.environment["TALKIE_DIAR_PERF"] == "1" else {
            throw XCTSkip("set TALKIE_DIAR_PERF=1 to run the lane-concurrency probe")
        }
        let models = try modelsRoot()
        let micScript = (0..<90).map { ($0 % 2 == 0 ? "Daniel" : "Samantha", nil as (([Float]) -> [Float])?) }
        let sysScript = (0..<90).map { _ in ("Ralph", nil as (([Float]) -> [Float])?) }
        let mic = try lane(lead: 0, micScript), sys = try lane(lead: 1, sysScript)
        let micURL = try tee(mic, name: "pm.wav", rate: 16_000), sysURL = try tee(sys, name: "ps.wav", rate: 16_000)
        let minutes = Double(mic.samples.count) / 16_000 / 60
        let diarizer = SpeakerDiarizer(modelsDirectory: models)
        _ = try await diarizer.diarize(fileURL: micURL.deletingLastPathComponent().appendingPathComponent("pm.wav")) // warm: load + CoreML compile
        let inputs = [MeetingDiarizationPipeline.LaneInput(lane: "Me", fileURL: micURL),
                      MeetingDiarizationPipeline.LaneInput(lane: "Them", fileURL: sysURL)]
        let segs = segments(mic, as: "Me") + segments(sys, as: "Them")
        for round in 1...3 {
            for concurrent in [false, true] {
                let t0 = Date()
                let outcome = await MeetingDiarizationPipeline.run(
                    inputs: inputs, segments: segs, diarizer: diarizer, budgetSeconds: 1800, concurrent: concurrent)
                let wall = Date().timeIntervalSince(t0)
                guard case .labelled = outcome else { return XCTFail("pass did not label: \(outcome)") }
                print(String(format: "[perf] round %d %@ 2 lanes x %.1f min: wall %.1f s, peak RSS %.0f MB",
                             round, concurrent ? "CONCURRENT" : "SERIAL    ", minutes, wall, Self.peakRSSMB()))
            }
        }
    }

    // MARK: own-voice evidence (WP-C)

    /// One mic lane of a single voice reading `lines` (indices into `lines`), with an
    /// optional channel transform; returns the diarized dominant cluster.
    private func voiceSample(_ voice: String, lines idx: [Int], models: URL,
                             channel: (([Float]) -> [Float])? = nil) async throws -> MicSpeakerCandidate {
        let gap = [Float](repeating: 0, count: Int(0.7 * 16_000))
        var l = Lane()
        l.samples = gap
        for i in idx {
            var pcm = try say(voice, i)
            if let channel { pcm = channel(pcm) }
            l.samples += pcm + gap
        }
        let url = try tee(l, name: "vs-\(UUID().uuidString).wav", rate: 16_000)
        let out = try await SpeakerDiarizer(modelsDirectory: models).diarize(fileURL: url)
        let top = try XCTUnwrap(out.speakers.max { $0.speechSeconds < $1.speechSeconds })
        return MicSpeakerCandidate(cluster: top.speaker, embedding: top.embedding, speechSeconds: top.speechSeconds)
    }

    /// Prints the similarity evidence the thresholds in `OwnVoiceProfile.Policy` rest on:
    /// same voice across SEPARATE recordings (different lines, and a different channel)
    /// versus different voices, and same-voice similarity versus amount of speech.
    func testOwnVoiceSimilarityEvidence() async throws {
        let models = try modelsRoot()
        let voices = ["Daniel", "Samantha", "Ralph", "Fred", "Karen", "Kathy", "Tara", "Reed", "Rishi"]
        var ref: [String: MicSpeakerCandidate] = [:], again: [String: MicSpeakerCandidate] = [:]
        var degraded: [String: MicSpeakerCandidate] = [:]
        for v in voices {
            ref[v] = try await voiceSample(v, lines: [0, 1, 2], models: models)
            again[v] = try await voiceSample(v, lines: [3, 4, 5], models: models)
            degraded[v] = try await voiceSample(v, lines: [3, 4, 5], models: models,
                                                channel: { self.throughLaptopSpeakers($0, gain: 0.6) })
        }
        var same: [Double] = [], sameDeg: [Double] = [], diff: [Double] = []
        for v in voices {
            same.append(SpeakerLabelling.cosine(ref[v]!.embedding, again[v]!.embedding))
            sameDeg.append(SpeakerLabelling.cosine(ref[v]!.embedding, degraded[v]!.embedding))
            for w in voices where w != v { diff.append(SpeakerLabelling.cosine(ref[v]!.embedding, again[w]!.embedding)) }
        }
        func stat(_ x: [Double]) -> String {
            String(format: "min %.3f mean %.3f max %.3f (n=%d)", x.min()!, x.reduce(0, +) / Double(x.count), x.max()!, x.count)
        }
        print("[own] speech per sample: \(voices.map { String(format: "%@=%.1fs", $0, ref[$0]!.speechSeconds) })")
        print("[own] SAME voice, separate recordings:       \(stat(same))")
        print("[own] SAME voice, degraded channel (lp+gain): \(stat(sameDeg))")
        print("[own] DIFFERENT voices:                      \(stat(diff))")
        for v in voices {
            let row = voices.map { w in String(format: "%.2f", SpeakerLabelling.cosine(ref[v]!.embedding, again[w]!.embedding)) }
            print("[own] \(v.padding(toLength: 9, withPad: " ", startingAt: 0)) \(row.joined(separator: " "))")
        }
        // Same voice vs how much speech the probe sample holds.
        for v in ["Daniel", "Samantha", "Ralph"] {
            var line = "[own] \(v) vs 3-line reference by sample length:"
            for n in 1...3 {
                let s = try await voiceSample(v, lines: Array(3..<(3 + n)), models: models)
                line += String(format: "  %.1fs->%.3f", s.speechSeconds, SpeakerLabelling.cosine(ref[v]!.embedding, s.embedding))
            }
            print(line)
        }
    }

    /// Evidence for `KnownVoiceMatcher` (W2): enrol nine synthetic voices from one
    /// recording each, then probe with SEPARATE recordings (clean and through a degraded
    /// laptop channel). "Enrolled" probes should match their own voice; leave-one-out
    /// probes (the probe's own voice removed from the known list) must match nobody.
    /// Prints a threshold sweep; asserts the shipped 0.70 / 0.15 makes no wrong or
    /// false match on this set. The 20 s speech floor is a separate rule and is held
    /// constant here (candidates are given 30 s) so only threshold and margin vary.
    func testKnownVoiceThresholdEvidence() async throws {
        let models = try modelsRoot()
        let voices = ["Daniel", "Samantha", "Ralph", "Fred", "Karen", "Kathy", "Tara", "Reed", "Rishi"]
        var known: [KnownVoice] = []
        var probes: [(voice: String, sample: MicSpeakerCandidate)] = []
        for v in voices {
            let ref = try await voiceSample(v, lines: [0, 1, 2, 3], models: models)
            known.append(KnownVoice(name: v, embedding: ref.embedding, speechSeconds: ref.speechSeconds, createdUnix: 0))
            probes.append((v, try await voiceSample(v, lines: [4, 5, 6, 7], models: models)))
            probes.append((v, try await voiceSample(v, lines: [4, 5, 6, 7], models: models,
                                                    channel: { self.throughLaptopSpeakers($0, gain: 0.6) })))
        }
        func sweep(_ t: Double, _ margin: Double) -> (right: Int, missed: Int, wrong: Int, falseAccept: Int) {
            var right = 0, missed = 0, wrong = 0, fa = 0
            func decide(_ c: MicSpeakerCandidate, _ list: [KnownVoice]) -> String? {
                var best: (String, Double)?, second = -1.0
                for k in list {
                    let sim = SpeakerLabelling.cosine(OwnVoiceProfile.normalised(c.embedding)!, OwnVoiceProfile.normalised(k.samples[0].embedding)!)
                    if best == nil || sim > best!.1 { if let b = best { second = max(second, b.1) }; best = (k.name, sim) }
                    else { second = max(second, sim) }
                }
                guard let best, best.1 >= t, best.1 - second >= margin else { return nil }
                return best.0
            }
            for p in probes {
                let c = MicSpeakerCandidate(cluster: 0, embedding: p.sample.embedding, speechSeconds: 30)
                switch decide(c, known) { case p.voice: right += 1; case nil: missed += 1; default: wrong += 1 }
                if decide(c, known.filter { $0.name != p.voice }) != nil { fa += 1 }
            }
            return (right, missed, wrong, fa)
        }
        print("[known] speech per probe: \(probes.map { String(format: "%.1fs", $0.sample.speechSeconds) }.joined(separator: " "))")
        for t in [0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85] {
            let r = sweep(t, KnownVoiceMatcher.margin)
            print(String(format: "[known] threshold %.2f margin %.2f: right %d missed %d wrong %d falseAccept(leave-one-out) %d of %d",
                         t, KnownVoiceMatcher.margin, r.right, r.missed, r.wrong, r.falseAccept, probes.count))
        }
        // The shipped matcher itself, with all nine known.
        var shippedRight = 0
        for p in probes {
            let c = MicSpeakerCandidate(cluster: 0, embedding: p.sample.embedding, speechSeconds: 30)
            if KnownVoiceMatcher.match(candidates: ["Speaker 1": c], known: known)["Speaker 1"] == p.voice { shippedRight += 1 }
        }
        print("[known] shipped matcher right: \(shippedRight) of \(probes.count)")
        let shipped = sweep(KnownVoiceMatcher.threshold, KnownVoiceMatcher.margin)
        XCTAssertEqual(shipped.wrong, 0)
        XCTAssertEqual(shipped.falseAccept, 0)
        XCTAssertEqual(shippedRight, shipped.right)
    }

    /// Evidence for `KnownVoiceMatcher.aggregation` (multi-sample profiles): each of nine
    /// synthetic voices is enrolled from TWO meetings (a clean recording and one through a
    /// degraded laptop channel, different lines), then probed with separate clean and
    /// degraded recordings. Compares scoring a person by their best sample vs the mean of
    /// their samples at the shipped threshold/margin, plus leave-one-out false accepts.
    func testKnownVoiceMultiSampleEvidence() async throws {
        let models = try modelsRoot()
        let voices = ["Daniel", "Samantha", "Ralph", "Fred", "Karen", "Kathy", "Tara", "Reed", "Rishi"]
        var known: [KnownVoice] = []
        var probes: [(voice: String, sample: MicSpeakerCandidate)] = []
        func sample(_ c: MicSpeakerCandidate) -> VoiceSample {
            VoiceSample(embedding: c.embedding, speechSeconds: c.speechSeconds, createdUnix: 0)
        }
        for v in voices {
            let a = try await voiceSample(v, lines: [0, 1, 2, 3], models: models)
            let b = try await voiceSample(v, lines: [8, 9, 0, 1], models: models,
                                          channel: { self.throughLaptopSpeakers($0, gain: 0.5) })
            known.append(KnownVoice(name: v, samples: [sample(a), sample(b)]))
            probes.append((v, try await voiceSample(v, lines: [4, 5, 6, 7], models: models)))
            probes.append((v, try await voiceSample(v, lines: [4, 5, 6, 7], models: models,
                                                    channel: { self.throughLaptopSpeakers($0, gain: 0.6) })))
        }
        var results: [KnownVoiceMatcher.Aggregation: (right: Int, wrong: Int, fa: Int)] = [:]
        for how in [KnownVoiceMatcher.Aggregation.best, .mean] {
            var right = 0, wrong = 0, fa = 0
            for p in probes {
                let c = MicSpeakerCandidate(cluster: 0, embedding: p.sample.embedding, speechSeconds: 30)
                switch KnownVoiceMatcher.match(candidates: ["S": c], known: known, aggregation: how)["S"] {
                case p.voice?: right += 1
                case nil: break
                default: wrong += 1
                }
                if KnownVoiceMatcher.match(candidates: ["S": c], known: known.filter { $0.name != p.voice },
                                           aggregation: how)["S"] != nil { fa += 1 }
            }
            // Headroom: the lowest own-person score vs the highest other-person score.
            var own: [Double] = [], others: [Double] = []
            for p in probes {
                let u = OwnVoiceProfile.normalised(p.sample.embedding)!
                for k in known {
                    guard let sc = KnownVoiceMatcher.score(u, k, how) else { continue }
                    if k.name == p.voice { own.append(sc) } else { others.append(sc) }
                }
            }
            print(String(format: "[known-multi] %@: own min %.3f mean %.3f | other max %.3f mean %.3f",
                         "\(how)", own.min()!, own.reduce(0, +) / Double(own.count), others.max()!,
                         others.reduce(0, +) / Double(others.count)))
            results[how] = (right, wrong, fa)
            print("[known-multi] \(how): right \(right) wrong \(wrong) falseAccept(leave-one-out) \(fa) of \(probes.count)")
        }
        let shipped = results[KnownVoiceMatcher.aggregation]!
        XCTAssertEqual(shipped.wrong, 0)
        XCTAssertEqual(shipped.fa, 0)
    }

    // MARK: own-voice learning + recognition (WP-C)

    private func laneOfLines(_ script: [(voice: String, line: Int)]) throws -> Lane {
        let gap = [Float](repeating: 0, count: Int(0.7 * 16_000))
        var l = Lane()
        l.samples = gap
        for item in script {
            let pcm = try say(item.voice, item.line)
            l.clips.append(Clip(voice: item.voice, start: Double(l.samples.count) / 16_000,
                                end: Double(l.samples.count + pcm.count) / 16_000))
            l.samples += pcm + gap
        }
        return l
    }

    private func label(mic: Lane, sys: Lane? = nil, models: URL, resolve: @escaping OwnVoiceResolver)
        async throws -> SpeakerLabelling.Result
    {
        let diarizer = SpeakerDiarizer(modelsDirectory: models)
        let micOut = try await diarizer.diarize(fileURL: try tee(mic, name: "m-\(UUID().uuidString).wav", rate: 16_000))
        var sysOut: DiarizationOutput?
        var segs = segments(mic, as: "Me")
        if let sys {
            sysOut = try await diarizer.diarize(fileURL: try tee(sys, name: "s-\(UUID().uuidString).wav", rate: 16_000))
            segs = interleaved(segs, segments(sys, as: "Them"))
        }
        return SpeakerLabelling.label(segments: segs, mic: micOut, system: sysOut, resolveMe: resolve)
    }

    /// Learn voice A (Daniel) from a single-speaker mic-only meeting, then: A+B on the
    /// mic (with a far-end speaker) -> A is "Me", B is "Speaker N"; B+C (A absent) ->
    /// nobody is "Me".
    func testLearnedVoiceBecomesMeOnlyWhenPresent() async throws {
        let models = try modelsRoot()
        let store = OwnVoiceProfileStore(url: tmp.appendingPathComponent("ovp.json"))

        // 1. Single-speaker meeting teaches the profile.
        let solo = try laneOfLines((0..<6).map { ("Daniel", $0) })
        let first = try await label(mic: solo, models: models, resolve: store.resolver)
        XCTAssertFalse(first.changed)
        let sample = try XCTUnwrap(first.ownVoiceSample, "one mic speaker -> learning sample")
        print(String(format: "[own] learned sample: %.1f s of speech", sample.speechSeconds))
        XCTAssertGreaterThanOrEqual(sample.speechSeconds, OwnVoiceProfile.Policy.minSampleSeconds)
        XCTAssertTrue(store.learn(sample))

        // 2. A + B on the mic (separate recording, different lines), C far end.
        let micAB = try laneOfLines([("Samantha", 0), ("Daniel", 3), ("Samantha", 1), ("Daniel", 4), ("Samantha", 2)])
        let sysC = try laneOfLines([("Ralph", 1), ("Ralph", 2), ("Ralph", 3)])
        let ab = try await label(mic: micAB, sys: sysC, models: models, resolve: store.resolver)
        print("[own] A+B+C labels: \(ab.segments.map { "\($0.text):\($0.speaker)" })")
        XCTAssertNil(ab.ownVoiceSample, "multi-speaker mic lane never teaches")
        XCTAssertTrue(ab.changed)
        let labelsOf = { (voice: String) in Set(ab.segments.filter { $0.text == voice }.map(\.speaker)) }
        XCTAssertEqual(labelsOf("Daniel"), ["Me"], "the learned voice is Me")
        XCTAssertEqual(labelsOf("Samantha").count, 1)
        XCTAssertTrue(labelsOf("Samantha").first?.hasPrefix("Speaker ") == true)
        XCTAssertEqual(labelsOf("Ralph").count, 1)
        XCTAssertEqual(Set(ab.participants), ["Me", "Speaker 1", "Speaker 2"], "gap-free numbering")

        // 3. B + C on the mic, A absent -> nobody is Me.
        let micBC = try laneOfLines([("Samantha", 0), ("Ralph", 3), ("Samantha", 1), ("Ralph", 4), ("Samantha", 2)])
        let bc = try await label(mic: micBC, models: models, resolve: store.resolver)
        print("[own] B+C labels: \(bc.segments.map { "\($0.text):\($0.speaker)" })")
        XCTAssertTrue(bc.changed)
        XCTAssertFalse(bc.participants.contains("Me"), "A is absent: nobody is Me")
        XCTAssertEqual(bc.speakerCount, 2)
    }
}
