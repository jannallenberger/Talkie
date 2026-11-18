import AVFoundation
import FluidAudio
import Foundation
import XCTest

@testable import TalkieDiarization

/// Locates the build-time models (scripts/fetch_diarization_models.sh). Model
/// tests SKIP when they are absent so CI without the models stays green.
private func modelsRoot() -> URL {
    if let env = ProcessInfo.processInfo.environment["TALKIE_DIARIZATION_MODELS"], !env.isEmpty {
        return URL(fileURLWithPath: env, isDirectory: true)
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/DiarizationModels", isDirectory: true)
}

private func requireModels() throws -> URL {
    let root = modelsRoot()
    guard SpeakerDiarizer.modelsAvailable(at: root) else {
        throw XCTSkip("diarization models not present at \(root.path) — run scripts/fetch_diarization_models.sh")
    }
    return root
}

final class SpeakerDiarizerUnitTests: XCTestCase {
    func testOfflineModeIsForcedOnInit() {
        _ = SpeakerDiarizer(modelsDirectory: FileManager.default.temporaryDirectory)
        XCTAssertTrue(ModelHub.offlineMode)
    }

    func testMissingModelsThrowWithoutDownloading() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-diar-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertFalse(SpeakerDiarizer.modelsAvailable(at: empty))
        let diarizer = SpeakerDiarizer(modelsDirectory: empty)
        do {
            _ = try await diarizer.diarize(samples16kMono: [Float](repeating: 0, count: 16_000))
            XCTFail("expected modelsMissing")
        } catch let error as DiarizationError {
            guard case .modelsMissing = error else { return XCTFail("got \(error)") }
        }
        // Nothing was created in the folder (no download staging, no marker).
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
    }

    func testStaleRevisionMarkerIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-diar-stale-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent(SpeakerDiarizer.modelFolderName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in SpeakerDiarizer.compiledModelNames {
            let dir = repo.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: repo.appendingPathComponent(SpeakerDiarizer.pldaParametersName))
        try Data("main\n".utf8).write(to: repo.appendingPathComponent(SpeakerDiarizer.revisionMarkerName))

        XCTAssertThrowsError(try SpeakerDiarizer.validateLayout(root)) { error in
            XCTAssertEqual(
                error as? DiarizationError,
                .modelRevisionMismatch(found: "main", expected: SpeakerDiarizer.pinnedRevision))
        }
    }

    func testPinnedRevisionMatchesFetchScript() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fetch_diarization_models.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(
            text.contains("REVISION=\"\(SpeakerDiarizer.pinnedRevision)\""),
            "fetch script pin drifted from FluidAudio's Repo.diarizer.revision")
    }

    func testConvertRenumbersByFirstAppearanceAndSumsSpeech() {
        func seg(_ id: String, _ s: Float, _ e: Float, _ emb: [Float]) -> TimedSpeakerSegment {
            TimedSpeakerSegment(
                speakerId: id, embedding: emb, startTimeSeconds: s, endTimeSeconds: e, qualityScore: 1)
        }
        let result = DiarizationResult(segments: [
            seg("S7", 5, 7, [0, 2]),
            seg("S3", 0, 2, [1, 0]),
            seg("S3", 8, 9, [3, 0]),
            seg("S7", 3, 3, [9, 9]),  // zero-length: dropped
        ])
        let out = SpeakerDiarizer.convert(result)
        XCTAssertEqual(out.turns, [
            DiarizedTurn(speaker: 0, start: 0, end: 2),
            DiarizedTurn(speaker: 1, start: 5, end: 7),
            DiarizedTurn(speaker: 0, start: 8, end: 9),
        ])
        XCTAssertEqual(out.speakerCount, 2)
        XCTAssertEqual(out.speakers[0].speechSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(out.speakers[1].speechSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(out.speakers[0].embedding, [2, 0])  // mean fallback (no speakerDatabase)
    }
}

/// End-to-end proof on synthetic multi-voice audio made with macOS `say`.
final class SpeakerDiarizerSyntheticTests: XCTestCase {
    private struct Clip { let voice: String; let start: Double; let end: Double }

    private static let lines = [
        "The quarterly numbers look better than we expected, mostly thanks to the new onboarding flow.",
        "I agree, but we still need to fix the export bug before the release on Friday.",
        "Let me check with the design team and get back to you by tomorrow afternoon.",
        "Sounds good. Can you also send the updated timeline to everyone on the call?",
        "Sure, I will write it up tonight and share it in the project channel.",
        "Great, then we are done for today. Thanks everyone for joining.",
    ]

    private func say(_ voice: String, _ text: String, to url: URL) throws -> [Float] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("`say -v \(voice)` unavailable") }
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw XCTSkip("unexpected `say` output format \(file.processingFormat)") }
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    /// Concatenates one `say` clip per voice in `script` with 0.7 s silences.
    private func synth(_ script: [String]) throws -> (samples: [Float], clips: [Clip]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-diar-say-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gap = [Float](repeating: 0, count: Int(0.7 * 16_000))
        var samples: [Float] = gap
        var clips: [Clip] = []
        for (i, voice) in script.enumerated() {
            let pcm = try say(voice, Self.lines[i % Self.lines.count], to: dir.appendingPathComponent("\(i).wav"))
            let start = Double(samples.count) / 16_000
            samples += pcm
            clips.append(Clip(voice: voice, start: start, end: Double(samples.count) / 16_000))
            samples += gap
        }
        return (samples, clips)
    }

    private func overlap(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        max(0, min(a.1, b.1) - max(a.0, b.0))
    }

    /// Asserts: speaker count == distinct voices; each clip's majority speaker is
    /// its voice's speaker (consistent + injective mapping); turns cover the clips.
    private func check(_ script: [String], models: URL, file: StaticString = #filePath, line: UInt = #line)
        async throws
    {
        let (samples, clips) = try synth(script)
        let seconds = Double(samples.count) / 16_000
        let diarizer = SpeakerDiarizer(modelsDirectory: models)

        let loadStart = Date()
        try await diarizer.prepare()
        let loadTime = Date().timeIntervalSince(loadStart)
        let runStart = Date()
        let out = try await diarizer.diarize(samples16kMono: samples)
        let runTime = Date().timeIntervalSince(runStart)
        print(String(
            format: "[diarization] voices=%d audio=%.1fs load=%.2fs diarize=%.2fs (RTF %.3f) speakers=%d turns=%d",
            Set(script).count, seconds, loadTime, runTime, runTime / seconds, out.speakerCount, out.turns.count))
        for t in out.turns { print(String(format: "  S%d %6.2f–%6.2f", t.speaker, t.start, t.end)) }

        let voices = Set(script)
        XCTAssertEqual(out.speakerCount, voices.count, "speaker count", file: file, line: line)

        var voiceToSpeaker: [String: Int] = [:]
        var covered = 0.0
        var total = 0.0
        for clip in clips {
            var bySpeaker: [Int: Double] = [:]
            for t in out.turns { bySpeaker[t.speaker, default: 0] += overlap((clip.start, clip.end), (t.start, t.end)) }
            let best = bySpeaker.max { $0.value < $1.value }
            total += clip.end - clip.start
            covered += best?.value ?? 0
            guard let best else { XCTFail("clip \(clip.voice) has no turn", file: file, line: line); continue }
            if let known = voiceToSpeaker[clip.voice] {
                XCTAssertEqual(best.key, known, "voice \(clip.voice) split across speakers", file: file, line: line)
            } else {
                voiceToSpeaker[clip.voice] = best.key
            }
        }
        XCTAssertEqual(Set(voiceToSpeaker.values).count, voices.count, "two voices merged", file: file, line: line)
        // "Roughly right boundaries": the majority speaker covers most of each clip.
        XCTAssertGreaterThan(covered / total, 0.8, "boundary coverage", file: file, line: line)
        // Exclusive output: turns never overlap.
        for (a, b) in zip(out.turns, out.turns.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start + 1e-3, "overlapping turns", file: file, line: line)
        }
    }

    func testTwoVoices() async throws {
        let models = try requireModels()
        try await check(["Daniel", "Samantha", "Daniel", "Samantha"], models: models)
    }

    /// Note: with ~10 s per voice, the community-1 clustering merges some
    /// same-gender `say` voices (Rishi/Fred with Daniel; Karen/Moira/Tessa with
    /// Samantha). Ralph is acoustically distinct enough to stay separate.
    func testThreeVoices() async throws {
        let models = try requireModels()
        try await check(["Daniel", "Samantha", "Ralph", "Daniel", "Samantha", "Ralph"], models: models)
    }

    /// Opt-in throughput probe (~5 min of audio): TALKIE_DIAR_PERF=1 swift test …
    func testThroughputLongAudio() async throws {
        let models = try requireModels()
        guard ProcessInfo.processInfo.environment["TALKIE_DIAR_PERF"] == "1" else {
            throw XCTSkip("set TALKIE_DIAR_PERF=1 to run the throughput probe")
        }
        let script = Array(repeating: ["Daniel", "Samantha", "Ralph"], count: 10).flatMap { $0 }
        try await check(script, models: models)
    }

    /// The app loads from a signed, read-only bundle: prove nothing needs writing.
    func testLoadsFromReadOnlyCopy() async throws {
        let models = try requireModels()
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appendingPathComponent("tk-diar-ro-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: models, to: copy)
        let chmod = { (mode: String) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/chmod")
            p.arguments = ["-R", mode, copy.path]
            try p.run()
            p.waitUntilExit()
        }
        try chmod("a-w")
        defer {
            try? chmod("u+w")
            try? fm.removeItem(at: copy)
        }
        try await check(["Daniel", "Samantha", "Daniel", "Samantha"], models: copy)
    }

    /// The file entry point (FluidAudio decodes/resamples via a temp file).
    func testDiarizeFileURL() async throws {
        let models = try requireModels()
        let (samples, _) = try synth(["Samantha", "Daniel", "Samantha", "Daniel"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tk-diar-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buf)
        }
        let out = try await SpeakerDiarizer(modelsDirectory: models).diarize(fileURL: url)
        XCTAssertEqual(out.speakerCount, 2)
        XCTAssertEqual(out.turns.first?.speaker, 0)
    }
}
