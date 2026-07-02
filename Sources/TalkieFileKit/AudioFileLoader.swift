// Decodes an audio file and resamples it to the format SpeechAnalyzer wants.
//
// SpeechAnalyzer's file/buffer path requires the PCM buffers to match
// `SpeechAnalyzer.bestAvailableAudioFormat` exactly (sample rate, channel count,
// common format). LibriSpeech is 16 kHz mono FLAC; the analyzer may want a
// different rate/layout, so we always run an explicit `AVAudioConverter` pass
// rather than risk a silent no-op. This mirrors the conversion AudioCapture does
// for the live mic in the app, but reads from a file instead of a tap.
//
// This file was moved verbatim out of `Sources/TalkieBench` into the shared
// `TalkieFileKit` library (work package G4) so both `talkie-bench` and the new
// `talkie` file-transcription CLI reuse ONE decode/resample implementation. The
// only change from the bench-local original is `public` on the surface the two
// callers use; the decode/resample logic is byte-for-byte unchanged, which is
// what keeps the bench's WER numbers identical before and after the move.

@preconcurrency import AVFoundation
import Foundation

public enum AudioFileLoaderError: LocalizedError {
    case cannotOpen(URL)
    case cannotCreateConverter
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): return "Could not open audio file: \(url.lastPathComponent)"
        case .cannotCreateConverter: return "Could not create an audio converter to the analyzer format."
        case .conversionFailed(let detail): return "Audio conversion failed: \(detail)"
        }
    }
}

public enum AudioFileLoader {
    /// Decode `url`, resample to `target`, and return chunked PCM buffers plus the
    /// audio's duration in seconds (computed from the source file, before resample,
    /// so RTFx reflects real audio length regardless of the analyzer's rate).
    public static func buffers(
        from url: URL,
        target: AVAudioFormat,
        chunkFrames: AVAudioFrameCount = 16_000
    ) throws -> (buffers: [AVAudioPCMBuffer], durationSeconds: Double) {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw AudioFileLoaderError.cannotOpen(url)
        }

        let sourceFormat = file.processingFormat
        let sourceFrames = file.length
        let durationSeconds = sourceFormat.sampleRate > 0
            ? Double(sourceFrames) / sourceFormat.sampleRate
            : 0

        // Read the whole file into one source buffer (utterance-length, small).
        guard sourceFrames > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                  frameCapacity: AVAudioFrameCount(sourceFrames)) else {
            throw AudioFileLoaderError.cannotOpen(url)
        }
        try file.read(into: sourceBuffer)

        // Fast path: already in the target format — just chunk it.
        if formatsMatch(sourceFormat, target) {
            return (chunk(sourceBuffer, into: target, chunkFrames: chunkFrames), durationSeconds)
        }

        // Resample to the analyzer's required format.
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw AudioFileLoaderError.cannotCreateConverter
        }
        converter.primeMethod = .none

        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioFileLoaderError.cannotCreateConverter
        }

        let source = SingleShotInput(sourceBuffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusPtr in
            if let next = source.take() {
                statusPtr.pointee = .haveData
                return next
            }
            statusPtr.pointee = .endOfStream
            return nil
        }
        if status == .error || error != nil {
            throw AudioFileLoaderError.conversionFailed(error?.localizedDescription ?? "unknown")
        }

        return (chunk(output, into: target, chunkFrames: chunkFrames), durationSeconds)
    }

    /// Split one big buffer into analyzer-friendly chunks (so we feed the input
    /// stream incrementally, like live audio, rather than one giant buffer).
    private static func chunk(
        _ buffer: AVAudioPCMBuffer,
        into format: AVAudioFormat,
        chunkFrames: AVAudioFrameCount
    ) -> [AVAudioPCMBuffer] {
        guard buffer.frameLength > 0, chunkFrames > 0 else { return [] }
        var out: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        let total = buffer.frameLength
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)

        while offset < total {
            let thisChunk = min(chunkFrames, total - offset)
            guard let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: thisChunk) else { break }
            piece.frameLength = thisChunk

            // Copy each channel's raw bytes for [offset, offset+thisChunk).
            if let src = buffer.floatChannelData, let dst = piece.floatChannelData {
                for ch in 0..<Int(format.channelCount) {
                    memcpy(dst[ch], src[ch] + Int(offset), Int(thisChunk) * MemoryLayout<Float>.size)
                }
            } else if let src = buffer.int16ChannelData, let dst = piece.int16ChannelData {
                for ch in 0..<Int(format.channelCount) {
                    memcpy(dst[ch], src[ch] + Int(offset), Int(thisChunk) * MemoryLayout<Int16>.size)
                }
            } else if let srcData = buffer.audioBufferList.pointee.mBuffers.mData,
                      let dstData = piece.audioBufferList.pointee.mBuffers.mData {
                // Interleaved fallback: copy raw bytes.
                memcpy(dstData, srcData.advanced(by: Int(offset) * bytesPerFrame), Int(thisChunk) * bytesPerFrame)
            }
            out.append(piece)
            offset += thisChunk
        }
        return out
    }

    /// Compare the load-bearing format fields (not AVAudioFormat.==, which also
    /// compares channel layout and can spuriously differ).
    private static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
    }
}

/// Hands a single buffer to `AVAudioConverter` exactly once, by value, so the
/// converter's input block doesn't capture a mutable local (Swift 6 clean).
/// Mirrors the helper in the app's AudioCapture.
private final class SingleShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
