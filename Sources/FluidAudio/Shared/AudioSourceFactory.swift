@preconcurrency import AVFoundation
import Foundation
import OSLog
import os

public struct AudioSourceFactory {
    private let logger = AppLogger(category: "AudioSourceFactory")

    public init() {}

    public func makeDiskBackedSource(
        from url: URL,
        targetSampleRate: Int
    ) throws -> (source: DiskBackedAudioSampleSource, loadDuration: TimeInterval) {
        do {
            let startTime = Date()

            // A 16-bit mono wav already at the target rate is read in place —
            // no conversion pass, no temporary copy — so a day of audio opens
            // in the time it takes to map the file.
            if url.pathExtension.lowercased() == "wav" {
                let mapped = try Data(contentsOf: url, options: [.mappedIfSafe])
                if let layout = PcmWavLayout.parse(mapped, sampleRate: targetSampleRate) {
                    logger.debug("Mapped PCM wav in place: \(layout.sampleCount) samples")
                    let source = DiskBackedAudioSampleSource(
                        pcm16MappedWav: mapped, dataOffset: layout.dataOffset, sampleCount: layout.sampleCount)
                    return (source, Date().timeIntervalSince(startTime))
                }
            }

            // MODIFIED FROM UPSTREAM (Talkie): upstream converts any other input through
            // a `fluidaudio-streaming-*.raw` file in the SYSTEM temp directory. Talkie
            // feeds meeting audio, which must never land outside its own private
            // diarization folder, so that fallback is removed: only a 16-bit mono PCM wav
            // at the target rate is accepted (Talkie's recorder always writes exactly that).
            throw AudioSourceError.processingFailed(
                "Unsupported audio file: expected 16-bit mono PCM wav at \(targetSampleRate) Hz")
        } catch let streamingError as AudioSourceError {
            throw streamingError
        } catch {
            logger.error("Streaming audio source creation failed: \(error.localizedDescription)")
            throw AudioSourceError.processingFailed(
                "Streaming audio source creation failed: \(error.localizedDescription)"
            )
        }
    }
}

public enum AudioSourceError: Error, LocalizedError {
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        }
    }
}

extension AudioSourceError {
    fileprivate static func failedToAllocateBuffer(_ name: String, requestedFrames: Int) -> AudioSourceError {
        .processingFailed("Failed to allocate \(name.lowercased()) buffer (\(requestedFrames) frames)")
    }
}
