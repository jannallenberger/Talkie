@preconcurrency import CoreML
import FluidAudio
import Foundation

// TalkieDiarization — the ONLY module that imports FluidAudio. The app target
// sees just the Sendable value types and the actor below; no FluidAudio type
// crosses this boundary.
//
// OFFLINE BY CONSTRUCTION
//   • Models are loaded with plain `MLModel(contentsOf:)` from a local folder
//     (the app bundle's Contents/Resources/DiarizationModels). This module never
//     calls `OfflineDiarizerManager.prepareModels`, `OfflineDiarizerModels.load`
//     or anything in `ModelHub` that can download — and it also avoids
//     `prepareModels`' failure path, which PURGES the models folder before a
//     fallback re-download.
//   • `ModelHub.offlineMode` is forced on before anything else is touched, as a
//     second wall should any FluidAudio code path ever reach its downloader.
//   • Nothing is written: the folder can be read-only (a signed app bundle).

/// One contiguous stretch of a single speaker. Turns are non-overlapping
/// ("exclusive" output) and sorted by start, so each instant maps to at most one
/// speaker — what transcript alignment needs.
public struct DiarizedTurn: Sendable, Equatable {
    /// 0-based speaker index, numbered in order of first appearance.
    public let speaker: Int
    /// Seconds from the start of the audio.
    public let start: Double
    public let end: Double

    public init(speaker: Int, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

/// Per-speaker summary: the cluster centroid embedding (for later own-voice
/// matching) and how much speech the speaker has in this audio.
public struct SpeakerProfile: Sendable, Equatable {
    public let speaker: Int
    public let embedding: [Float]
    public let speechSeconds: Double

    public init(speaker: Int, embedding: [Float], speechSeconds: Double) {
        self.speaker = speaker
        self.embedding = embedding
        self.speechSeconds = speechSeconds
    }
}

public struct DiarizationOutput: Sendable, Equatable {
    public let turns: [DiarizedTurn]
    /// Sorted by `speaker`.
    public let speakers: [SpeakerProfile]

    public init(turns: [DiarizedTurn], speakers: [SpeakerProfile]) {
        self.turns = turns
        self.speakers = speakers
    }

    public var speakerCount: Int { speakers.count }

    public static let empty = DiarizationOutput(turns: [], speakers: [])
}

public enum DiarizationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The models folder (or a required file in it) is missing.
    case modelsMissing(path: String)
    /// The `.fluidaudio-revision` marker does not match the linked FluidAudio's pin.
    case modelRevisionMismatch(found: String?, expected: String)
    case modelLoadFailed(String)
    case processingFailed(String)

    public var description: String {
        switch self {
        case .modelsMissing(let path): return "diarization models missing: \(path)"
        case .modelRevisionMismatch(let found, let expected):
            return "diarization models revision \(found ?? "<none>") != expected \(expected)"
        case .modelLoadFailed(let why): return "diarization model load failed: \(why)"
        case .processingFailed(let why): return "diarization failed: \(why)"
        }
    }
}

/// Offline speaker diarization over a local CoreML models folder.
///
/// Models load lazily, once, on the first `prepare()`/`diarize` call. The work is
/// CPU/ANE-bound and NOT cooperatively cancellable inside a CoreML prediction, so
/// callers must time-box it (detached task + timeout) and treat any error as
/// "no diarization" — never block a transcript save on it.
public actor SpeakerDiarizer {
    /// Sample rate `diarize(samples16kMono:)` expects.
    public static let sampleRate: Double = 16_000

    /// Sub-folder of the models root that holds the files (FluidAudio layout).
    public static var modelFolderName: String { Repo.diarizer.folderName }

    /// The Hugging Face revision the linked FluidAudio was validated against.
    /// scripts/fetch_diarization_models.sh pins the same value.
    public static var pinnedRevision: String { Repo.diarizer.revision }

    static let revisionMarkerName = ".fluidaudio-revision"
    static let compiledModelNames = ["Segmentation", "FBank", "Embedding", "PldaRho"]
    static let pldaParametersName = "plda-parameters.json"

    /// `ModelHub.offlineMode = true`, exactly once per process, before any model
    /// work. A `static let` initializer is thread-safe (dispatch_once).
    private static let forceOffline: Void = {
        ModelHub.offlineMode = true
    }()

    private let modelsDirectory: URL
    private var models: OfflineDiarizerModels?

    /// - Parameter modelsDirectory: the root containing
    ///   `speaker-diarization/` (FluidAudio's folder name; e.g. `Contents/Resources/DiarizationModels`).
    public init(modelsDirectory: URL) {
        Self.forceOffline
        self.modelsDirectory = modelsDirectory
    }

    /// Cheap synchronous check (file existence + revision marker) — no model load.
    public nonisolated static func modelsAvailable(at modelsDirectory: URL) -> Bool {
        (try? validateLayout(modelsDirectory)) != nil
    }

    /// Load the models now (otherwise done on the first `diarize`).
    public func prepare() throws {
        _ = try loadedModels()
    }

    public func diarize(samples16kMono samples: [Float]) async throws -> DiarizationOutput {
        if samples.isEmpty { return .empty }
        let models = try loadedModels()
        return Self.convert(try await Self.run(models) { try await $0.process(audio: samples) })
    }

    /// Any format AVFoundation can read; FluidAudio resamples to 16 kHz mono
    /// through a temporary file it deletes afterwards.
    public func diarize(fileURL: URL) async throws -> DiarizationOutput {
        let models = try loadedModels()
        return Self.convert(try await Self.run(models) { try await $0.process(fileURL) })
    }

    // MARK: - Internals

    /// A fresh manager per call over the shared (Sendable, read-only) models.
    /// `OfflineDiarizerManager` is not Sendable, so it is created and used inside
    /// this nonisolated function and never crosses an isolation boundary.
    private static func run(
        _ models: OfflineDiarizerModels,
        _ body: (OfflineDiarizerManager) async throws -> DiarizationResult
    ) async throws -> DiarizationResult {
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        do {
            return try await body(manager)
        } catch {
            throw DiarizationError.processingFailed(String(describing: error))
        }
    }

    static var config: OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        // Non-overlapping output: one speaker per instant, for transcript alignment.
        config.postProcessing.exclusiveSegments = true
        return config
    }

    private func loadedModels() throws -> OfflineDiarizerModels {
        if let models { return models }
        Self.forceOffline
        let repo = try Self.validateLayout(modelsDirectory)
        let loaded = try Self.loadModels(from: repo)
        models = loaded
        return loaded
    }

    /// Returns the `speaker-diarization` folder if it is complete and
    /// carries the expected revision marker.
    static func validateLayout(_ root: URL) throws -> URL {
        let fm = FileManager.default
        let repo = root.appendingPathComponent(modelFolderName, isDirectory: true)
        for name in compiledModelNames {
            let bin = repo.appendingPathComponent("\(name).mlmodelc/coremldata.bin")
            guard fm.fileExists(atPath: bin.path) else {
                throw DiarizationError.modelsMissing(path: bin.path)
            }
        }
        let plda = repo.appendingPathComponent(pldaParametersName)
        guard fm.fileExists(atPath: plda.path) else {
            throw DiarizationError.modelsMissing(path: plda.path)
        }
        let marker = repo.appendingPathComponent(revisionMarkerName)
        let found = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard found == pinnedRevision else {
            throw DiarizationError.modelRevisionMismatch(found: found, expected: pinnedRevision)
        }
        return repo
    }

    /// Mirrors `OfflineDiarizerModels.load` (compute units, FBank on CPU) but
    /// with direct `MLModel(contentsOf:)` loads — no ModelHub, no download, no
    /// cache purge, no writes.
    static func loadModels(from repo: URL) throws -> OfflineDiarizerModels {
        let start = Date()
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = units
            config.allowLowPrecisionAccumulationOnGPU = true
            do {
                return try MLModel(
                    contentsOf: repo.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                    configuration: config)
            } catch {
                throw DiarizationError.modelLoadFailed("\(name): \(error.localizedDescription)")
            }
        }
        let segmentation = try load("Segmentation", .all)
        let embedding = try load("Embedding", .all)
        let pldaRho = try load("PldaRho", .all)
        let fbank = try load("FBank", .cpuOnly)
        let psi = try loadPLDAPsi(repo.appendingPathComponent(pldaParametersName))
        return OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: pldaRho,
            pldaPsi: psi,
            compilationDuration: Date().timeIntervalSince(start))
    }

    /// Same decoding as FluidAudio's (private) `loadPLDAPsi`: tensors.psi.data_base64
    /// holds little-endian Float32 values.
    static func loadPLDAPsi(_ url: URL) throws -> [Double] {
        guard
            let data = try? Data(contentsOf: url),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let tensors = root["tensors"] as? [String: Any],
            let psi = tensors["psi"] as? [String: Any],
            let base64 = psi["data_base64"] as? String,
            let decoded = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters])
        else {
            throw DiarizationError.modelLoadFailed("cannot decode PLDA psi in \(url.lastPathComponent)")
        }
        let count = decoded.count / MemoryLayout<Float>.size
        guard count > 0 else { throw DiarizationError.modelLoadFailed("PLDA psi tensor is empty") }
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { decoded.copyBytes(to: $0) }
        return floats.map(Double.init)
    }

    /// FluidAudio result → Talkie types. Speakers renumbered 0… by first
    /// appearance; profile embedding = FluidAudio's per-speaker centroid
    /// (`speakerDatabase`), falling back to the mean of that speaker's segments.
    static func convert(_ result: DiarizationResult) -> DiarizationOutput {
        let segments = result.segments
            .filter { $0.endTimeSeconds > $0.startTimeSeconds }
            .sorted { ($0.startTimeSeconds, $0.endTimeSeconds) < ($1.startTimeSeconds, $1.endTimeSeconds) }
        var index: [String: Int] = [:]
        var order: [String] = []
        var turns: [DiarizedTurn] = []
        var seconds: [Int: Double] = [:]
        var sums: [Int: [Float]] = [:]
        var counts: [Int: Int] = [:]
        for seg in segments {
            let speaker: Int
            if let known = index[seg.speakerId] {
                speaker = known
            } else {
                speaker = order.count
                index[seg.speakerId] = speaker
                order.append(seg.speakerId)
            }
            let turn = DiarizedTurn(
                speaker: speaker, start: Double(seg.startTimeSeconds), end: Double(seg.endTimeSeconds))
            turns.append(turn)
            seconds[speaker, default: 0] += turn.duration
            if !seg.embedding.isEmpty {
                if var acc = sums[speaker], acc.count == seg.embedding.count {
                    for i in acc.indices { acc[i] += seg.embedding[i] }
                    sums[speaker] = acc
                } else if sums[speaker] == nil {
                    sums[speaker] = seg.embedding
                }
                counts[speaker, default: 0] += 1
            }
        }
        let speakers = order.enumerated().map { speaker, id -> SpeakerProfile in
            var embedding = result.speakerDatabase?[id] ?? []
            if embedding.isEmpty, let sum = sums[speaker], let n = counts[speaker], n > 0 {
                embedding = sum.map { $0 / Float(n) }
            }
            return SpeakerProfile(
                speaker: speaker, embedding: embedding, speechSeconds: seconds[speaker] ?? 0)
        }
        return DiarizationOutput(turns: turns, speakers: speakers)
    }
}
