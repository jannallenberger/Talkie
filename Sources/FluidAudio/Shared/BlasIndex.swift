// MODIFIED FROM UPSTREAM (Talkie): upstream defines this in
// ASR/Parakeet/SlidingWindow/TDT/Decoder/BlasIndex.swift and throws `ASRError`.
// The ASR subsystem is not vendored, so the error type is `OfflineDiarizationError`.
import Accelerate

typealias BlasIndex = Int32

@inline(__always)
func makeBlasIndex(_ value: Int, label: String) throws -> BlasIndex {
    guard let cast = BlasIndex(exactly: value) else {
        throw OfflineDiarizationError.processingFailed("\(label) exceeds supported range")
    }
    return cast
}
