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
}
