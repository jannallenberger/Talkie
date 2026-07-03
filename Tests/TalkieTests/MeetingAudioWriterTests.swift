import AVFoundation
import XCTest
@testable import Talkie

/// D9 — the confined keep-audio writer. Writes synthetic PCM (generated in-memory, no
/// capture device, no model, no network) to a real `.m4a` and checks it produced a
/// playable file, that an unused writer reports no file, and that close is idempotent.
/// The realtime-safety of the tap (copy-free handoff, serial-queue confinement) is a
/// property of the class shape; here we just prove it writes and closes correctly.
final class MeetingAudioWriterTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAudioWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    /// One second of a quiet sine at the analyzer's typical mono format (16 kHz), the
    /// shape the capture classes hand to `onBuffer`.
    private func makeBuffer(seconds: Double = 0.25, sampleRate: Double = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = 0.1 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
        return buffer
    }

    func testWriterProducesPlayableFile() throws {
        let url = tmp.appendingPathComponent("out-me.m4a")
        let writer = MeetingAudioFileWriter(url: url)
        for _ in 0..<8 { writer.append(makeBuffer()) } // ~2 s total
        let produced = writer.close()

        XCTAssertTrue(produced, "close() reports a usable file after buffers were written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the .m4a exists on disk")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0, "the .m4a is non-empty")

        // It reads back as a real, non-trivial audio file (~2 s at 16 kHz).
        let readback = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(readback.length, 0, "the written file decodes with frames")
    }

    func testUnusedWriterReportsNoFile() {
        // A stream that opened but never delivered a buffer (e.g. a mic that produced
        // nothing) must NOT claim a usable file — so the recorder won't record an
        // audioFiles entry pointing at a file that was never created.
        let url = tmp.appendingPathComponent("empty-them.m4a")
        let writer = MeetingAudioFileWriter(url: url)
        XCTAssertFalse(writer.close(), "no buffers written → close() reports no file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "nothing was created for an unused writer")
    }

    func testCloseIsIdempotent() throws {
        let url = tmp.appendingPathComponent("twice-me.m4a")
        let writer = MeetingAudioFileWriter(url: url)
        writer.append(makeBuffer())
        XCTAssertTrue(writer.close(), "first close succeeds")
        // A second close must not throw or change the outcome (still reports produced).
        XCTAssertTrue(writer.close(), "second close is a harmless no-op")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
