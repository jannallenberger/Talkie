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
    /// duration in seconds of the audio ACTUALLY handed to the recognizer.
    ///
    /// With the default `leadTrimMs == 0` this is byte-for-byte the original
    /// behaviour and `durationSeconds` is the source file's real length. When
    /// `leadTrimMs > 0`, the first N milliseconds of the resampled audio are
    /// dropped (bench work package C3b): this simulates the warm-up window that
    /// live dictation loses before its analyzer is ready, so `talkie-bench
    /// --lead-trim-ms` can measure the first-word cost head-on. The reported
    /// duration then reflects the trimmed audio (what was transcribed), keeping
    /// RTFx honest.
    public static func buffers(
        from url: URL,
        target: AVAudioFormat,
        chunkFrames: AVAudioFrameCount = 16_000,
        leadTrimMs: Int = 0
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

        // Fast path: already in the target format — just (trim then) chunk it.
        if formatsMatch(sourceFormat, target) {
            let trimmed = trimHead(sourceBuffer, into: target, leadTrimMs: leadTrimMs)
            return (chunk(trimmed.buffer, into: target, chunkFrames: chunkFrames),
                    adjustedDuration(durationSeconds, target: target, trimmedFrames: trimmed.droppedFrames))
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

        // Trim AFTER resample so the dropped window is an exact count of target
        // frames (N ms at the analyzer's own sample rate, not the source rate).
        let trimmed = trimHead(output, into: target, leadTrimMs: leadTrimMs)
        return (chunk(trimmed.buffer, into: target, chunkFrames: chunkFrames),
                adjustedDuration(durationSeconds, target: target, trimmedFrames: trimmed.droppedFrames))
    }

    // MARK: - Head trim (C3b: simulate the lost warm-up window)

    /// Number of target-format frames a `leadTrimMs` window covers, clamped to the
    /// buffer's own length so we never ask to drop more audio than exists. Pure and
    /// integer-only so the bench self-test can pin the math without any audio.
    /// A non-positive `leadTrimMs` (the default) yields 0 — the no-op path.
    public static func trimFrameCount(
        leadTrimMs: Int,
        sampleRate: Double,
        availableFrames: AVAudioFrameCount
    ) -> AVAudioFrameCount {
        guard leadTrimMs > 0, sampleRate > 0 else { return 0 }
        let wanted = Int((Double(leadTrimMs) / 1000.0) * sampleRate)
        guard wanted > 0 else { return 0 }
        return AVAudioFrameCount(min(wanted, Int(availableFrames)))
    }

    /// Drop the first `leadTrimMs` of `buffer` (a target-format buffer), returning
    /// a fresh buffer with the head removed plus how many frames were dropped.
    /// `leadTrimMs <= 0` returns the buffer untouched (0 dropped) — the fast, exact
    /// no-op that keeps the standard corpus run byte-identical.
    private static func trimHead(
        _ buffer: AVAudioPCMBuffer,
        into format: AVAudioFormat,
        leadTrimMs: Int
    ) -> (buffer: AVAudioPCMBuffer, droppedFrames: AVAudioFrameCount) {
        let drop = trimFrameCount(leadTrimMs: leadTrimMs,
                                  sampleRate: format.sampleRate,
                                  availableFrames: buffer.frameLength)
        guard drop > 0 else { return (buffer, 0) }

        let remaining = buffer.frameLength - drop
        // Trimming the whole clip away would feed the analyzer nothing; keep an
        // empty buffer of the right format (the run still scores it — a fully
        // absent first word — rather than crashing).
        guard remaining > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else {
            let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) ?? buffer
            empty.frameLength = 0
            return (empty, buffer.frameLength)
        }
        out.frameLength = remaining

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        if let src = buffer.floatChannelData, let dst = out.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                memcpy(dst[ch], src[ch] + Int(drop), Int(remaining) * MemoryLayout<Float>.size)
            }
        } else if let src = buffer.int16ChannelData, let dst = out.int16ChannelData {
            for ch in 0..<Int(format.channelCount) {
                memcpy(dst[ch], src[ch] + Int(drop), Int(remaining) * MemoryLayout<Int16>.size)
            }
        } else if let srcData = buffer.audioBufferList.pointee.mBuffers.mData,
                  let dstData = out.audioBufferList.pointee.mBuffers.mData {
            memcpy(dstData, srcData.advanced(by: Int(drop) * bytesPerFrame), Int(remaining) * bytesPerFrame)
        }
        return (out, drop)
    }

    /// The audio duration after trimming: original length minus the dropped window
    /// (converted from target frames back to seconds). Never negative.
    private static func adjustedDuration(
        _ original: Double,
        target: AVAudioFormat,
        trimmedFrames: AVAudioFrameCount
    ) -> Double {
        guard trimmedFrames > 0, target.sampleRate > 0 else { return original }
        return max(0, original - Double(trimmedFrames) / target.sampleRate)
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
