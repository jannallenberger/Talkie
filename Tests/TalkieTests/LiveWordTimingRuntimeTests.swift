@preconcurrency import AVFoundation
import Speech
import XCTest
@testable import Talkie

/// RUNTIME check (real on-device recognizer, no mocks) that the code the LIVE meeting path
/// uses actually delivers word timings: `TranscriptionEngine.beginSession(timedSegmentHandler:)`
/// (single-locale lanes) and `MultiLangStreamTranscriber` (multilingual lanes, including an
/// analyzer rotation). Audio is synthetic `say` speech fed buffer by buffer, the way the
/// capture classes feed the analyzer. Skips (never downloads) when a speech model is missing.
final class LiveWordTimingRuntimeTests: XCTestCase {
    private static let sentences = [
        "Good morning everyone and welcome to the weekly planning meeting.",
        "Today we will review the budget, the hiring plan and the product roadmap for the next quarter.",
        "Please keep your updates short so that everybody has time to ask questions at the end.",
        "Let us start with the budget because it affects every other decision on the agenda.",
    ]

    private func installed(_ id: String) async -> Bool {
        guard SpeechTranscriber.isAvailable,
              let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { return false }
        let t = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        return await AssetInventory.status(forModules: [t]) == .installed
    }

    /// 16 kHz mono speech, ~20 s, plus its duration.
    private func speechBuffers(target: AVAudioFormat, dir: URL) throws -> (buffers: [AVAudioPCMBuffer], seconds: Double) {
        let wav = dir.appendingPathComponent("speech.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Samantha", "-o", wav.path, "--data-format=LEI16@16000", Self.sentences.joined(separator: " ")]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("`say` unavailable") }
        let file = try AVAudioFile(forReading: wav)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 2)
        let conv = TranscriptionEngine.ConformingConverter()
        var out: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            if let c = conv.convert(buf, to: target) { out.append(c) }
        }
        return (out, Double(file.length) / file.processingFormat.sampleRate)
    }

    private func tempDir() throws -> URL {
        XCTAssertNotNil(AppPaths.testSandboxRoot)
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [TimedSegment] = []
        func add(_ s: TimedSegment) { lock.withLock { items.append(s) } }
        var all: [TimedSegment] { lock.withLock { items } }
    }

    func testSingleLocaleLivePathDeliversWordTimings() async throws {
        guard await installed("en-US") else { throw XCTSkip("en-US speech model not installed") }
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = TranscriptionEngine(localeIdentifier: "en-US")
        let box = Box()
        let session = try await engine.beginSession(timedSegmentHandler: { box.add($0) })
        let (buffers, seconds) = try speechBuffers(target: session.format, dir: dir)
        for b in buffers { session.continuation.yield(AnalyzerInput(buffer: b)) }
        session.continuation.finish()
        _ = await engine.finishSession()

        let segs = box.all.filter { $0.end > $0.start }
        XCTAssertFalse(segs.isEmpty, "the recognizer produced timed segments")
        var withWords = 0
        for s in segs {
            guard let words = s.words else { continue }
            withWords += 1
            XCTAssertNotNil(SegmentWord.validated(words, for: s.text), "words reproduce the segment text: \(s.text)")
            XCTAssertGreaterThanOrEqual(words.first!.start, s.start - 0.5)
            XCTAssertLessThanOrEqual(words.last!.end, min(s.end, seconds) + 0.5)
        }
        XCTAssertEqual(withWords, segs.count, "every finalized segment carries word timings")
        let all = segs.flatMap { $0.words ?? [] }
        XCTAssertGreaterThan(all.count, 20)
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $0.start <= $1.start }, "monotonic on one clock")
    }

    func testMultiLanguageLanesDeliverWordTimingsAcrossARotation() async throws {
        guard await installed("en-US"), await installed("de-DE") else { throw XCTSkip("en-US + de-DE models needed") }
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mm = MultiLangStreamTranscriber()
        let session = try await mm.start(localeIDs: ["en-US", "de-DE"])
        let (buffers, seconds) = try speechBuffers(target: session.format, dir: dir)
        let half = buffers.count / 2
        for b in buffers[..<half] { session.continuation.yield(AnalyzerInput(buffer: b)) }
        try await Task.sleep(nanoseconds: 1_500_000_000) // let the fan-out consume the first half
        await mm.rotate()
        let rotatedAt = await mm.openWindowStart
        for b in buffers[half...] { session.continuation.yield(AnalyzerInput(buffer: b)) }
        session.continuation.finish()
        let spans = await mm.finish(anchorLocale: "en-US")

        XCTAssertFalse(spans.isEmpty)
        XCTAssertGreaterThan(rotatedAt, 3, "the rotation happened mid-stream")
        let all = spans.flatMap(\.words)
        XCTAssertGreaterThan(all.count, 20)
        for s in spans { XCTAssertNotNil(SegmentWord.validated(s.words, for: s.text)) }
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $0.start <= $1.start })
        XCTAssertLessThanOrEqual(all.last!.end, seconds + 1.5, "offset-corrected: never beyond the real audio length")
        XCTAssertGreaterThan(all.last!.end, seconds * 0.8, "words after the rotation sit late in meeting time, not near 0")
        XCTAssertTrue(all.contains { $0.start >= rotatedAt }, "post-rotation words are shifted by the rotation offset")
    }
}
