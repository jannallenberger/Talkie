@preconcurrency import AVFoundation
import XCTest
@testable import Talkie

/// Regression tests for the "imported 2 h file only transcribed its first ~34 min" bug.
/// The recognizer is faked: what is verified is the windowing that makes a long import
/// safe — every buffer is fed, sessions roll every window, each window is finalized, and
/// segment times continue on one timeline across windows.
final class ImportWindowingTests: XCTestCase {
    private static let rate = 16_000.0

    private final class Recorder: @unchecked Sendable {
        var opened = 0
        var finished = 0
        var framesPerSession: [Int] = []
    }

    private func buffer(seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * Self.rate))!
        b.frameLength = b.frameCapacity
        return b
    }

    /// A session that, like a healthy recognizer, returns one chunk spanning exactly the
    /// audio it was fed (on the window's own clock).
    private func session(_ rec: Recorder) -> ImportSession {
        rec.opened += 1
        let index = rec.framesPerSession.count
        rec.framesPerSession.append(0)
        return ImportSession(
            feed: { rec.framesPerSession[index] += Int($0.frameLength) },
            finish: {
                rec.finished += 1
                let secs = Double(rec.framesPerSession[index]) / Self.rate
                return [ImportChunk(text: "window \(index)", start: 0, end: secs,
                                    words: [SegmentWord(text: "w\(index)", start: 0, end: 1)])]
            })
    }

    private func drive(totalSeconds: Int, window: Double, rec: Recorder) async throws -> (chunks: [ImportChunk], fed: Int) {
        let windower = ImportWindower(sampleRate: Self.rate, windowSeconds: window,
                                      first: session(rec), open: { self.session(rec) })
        var fed = 0
        for _ in 0..<totalSeconds {
            try await windower.feed(buffer(seconds: 1))
            fed += 1
        }
        return (await windower.finish(), fed)
    }

    func testWholeFileIsCoveredAcrossWindows() async throws {
        let rec = Recorder()
        // 7 072 s like the reported 2 h file would be slow; 2 500 s with 600 s windows
        // exercises 5 sessions (4 full + a 100 s tail).
        let (chunks, fed) = try await drive(totalSeconds: 2_500, window: 600, rec: rec)
        XCTAssertEqual(fed, 2_500)
        XCTAssertEqual(rec.opened, 5)
        XCTAssertEqual(rec.finished, 5, "every window is finalized, none abandoned")
        XCTAssertEqual(chunks.map(\.start), [0, 600, 1_200, 1_800, 2_400])
        XCTAssertEqual(chunks.map(\.end), [600, 1_200, 1_800, 2_400, 2_500])
        XCTAssertEqual(rec.framesPerSession.reduce(0, +), 2_500 * 16_000, "no audio is dropped")
        XCTAssertEqual(chunks.last?.words?.first?.start, 2_400, "word times shift with their window")
    }

    func testBoundaryAtEndOfFileOpensNoEmptySession() async throws {
        let rec = Recorder()
        let (chunks, _) = try await drive(totalSeconds: 1_200, window: 600, rec: rec)
        XCTAssertEqual(rec.opened, 2, "a window that would receive no audio is never opened")
        XCTAssertEqual(chunks.count, 2)
    }

    func testShortFileUsesOneSession() async throws {
        let rec = Recorder()
        let (chunks, _) = try await drive(totalSeconds: 90, window: 600, rec: rec)
        XCTAssertEqual(rec.opened, 1)
        XCTAssertEqual(chunks.map(\.end), [90])
    }

    func testAbortFinishesOpenSessionAndDropsOutput() async throws {
        let rec = Recorder()
        let windower = ImportWindower(sampleRate: Self.rate, windowSeconds: 600,
                                      first: session(rec), open: { self.session(rec) })
        try await windower.feed(buffer(seconds: 1))
        await windower.abort()
        XCTAssertEqual(rec.finished, 1, "the in-flight analyzer is torn down")
        XCTAssertTrue(windower.chunks.isEmpty)
    }

    func testImportUsesLongFinalizeBoundsNotTheLiveOnes() {
        // The live paths cap finalize at 4 s (single) / 10 s (lanes); an import feeding
        // faster than real time needs far longer, or the backlog is cancelled.
        XCTAssertGreaterThan(ImportWindowing.finalizeTimeout, 10 * 6)
        XCTAssertEqual(MultiLangStreamTranscriber.finalizeTimeout, 10, "live meeting bound unchanged")
        XCTAssertLessThanOrEqual(ImportWindowing.windowSeconds, 900, "windows stay far below the ~30 min stall")
    }
}
