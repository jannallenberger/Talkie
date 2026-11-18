import AVFoundation
import FluidAudio
import Foundation
import XCTest

/// F7: the vendored audio loader must never copy meeting audio into the system temp
/// directory (upstream's `fluidaudio-streaming-*.raw` conversion fallback was removed).
final class VendoredTempFallbackTests: XCTestCase {
    private func streamingFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("fluidaudio-streaming-") })
    }

    private func writeWav(rate: Double, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
        buf.frameLength = 4800
        try file.write(from: buf)
    }

    func testNonTargetRateWavThrowsAndWritesNothingToSystemTemp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav48 = dir.appendingPathComponent("a.wav")
        try writeWav(rate: 48_000, to: wav48)
        let before = streamingFiles()
        XCTAssertThrowsError(try AudioSourceFactory().makeDiskBackedSource(from: wav48, targetSampleRate: 16_000))
        XCTAssertEqual(streamingFiles(), before, "no meeting audio may land in the system temp dir")
    }

    func testTargetRateWavIsReadInPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav16 = dir.appendingPathComponent("b.wav")
        try writeWav(rate: 16_000, to: wav16)
        let before = streamingFiles()
        let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: wav16, targetSampleRate: 16_000)
        XCTAssertEqual(source.sampleCount, 4800)
        XCTAssertEqual(streamingFiles(), before)
    }
}
