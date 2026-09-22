import AVFoundation
import XCTest
@testable import Talkie

/// The stop-time language check scores only the head of the audio.
final class LanguageProbeHeadTests: XCTestCase {
    private func buffers(count: Int, framesEach: AVAudioFrameCount, rate: Double = 16_000) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        return (0..<count).map { _ in
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesEach)!
            b.frameLength = framesEach
            return b
        }
    }

    func testHeadStopsAfterRequestedSeconds() {
        // 60 one-second buffers → a 12 s head keeps exactly 12.
        let all = buffers(count: 60, framesEach: 16_000)
        XCTAssertEqual(TranscriptionEngine.head(of: all, seconds: 12).count, 12)
    }

    func testShortAudioIsReturnedWhole() {
        let all = buffers(count: 5, framesEach: 16_000)
        XCTAssertEqual(TranscriptionEngine.head(of: all, seconds: 12).count, 5)
    }

    func testPartialBufferIsIncludedNotDropped() {
        // 0.75 s buffers: 16 buffers = 12 s exactly; the head never cuts mid-speech short.
        let all = buffers(count: 40, framesEach: 12_000)
        XCTAssertEqual(TranscriptionEngine.head(of: all, seconds: 12).count, 16)
    }

    func testEmptyInput() {
        XCTAssertTrue(TranscriptionEngine.head(of: [], seconds: 12).isEmpty)
    }
}
