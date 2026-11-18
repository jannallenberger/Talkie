// MODIFIED FROM UPSTREAM (Talkie): the download/ModelHub path was removed; see VENDORED.md.
#if Diarizer
@preconcurrency import CoreML
import Foundation
import OSLog

@available(macOS 14.0, iOS 17.0, *)
public struct OfflineDiarizerModels: Sendable {
    public let segmentationModel: MLModel
    public let fbankModel: MLModel
    public let embeddingModel: MLModel
    public let pldaRhoModel: MLModel
    public let pldaPsi: [Double]

    public let compilationDuration: TimeInterval

    public init(
        segmentationModel: MLModel,
        fbankModel: MLModel,
        embeddingModel: MLModel,
        pldaRhoModel: MLModel,
        pldaPsi: [Double],
        compilationDuration: TimeInterval
    ) {
        self.segmentationModel = segmentationModel
        self.fbankModel = fbankModel
        self.embeddingModel = embeddingModel
        self.pldaRhoModel = pldaRhoModel
        self.pldaPsi = pldaPsi
        self.compilationDuration = compilationDuration
    }
}

// MODIFIED FROM UPSTREAM (Talkie): `defaultModelsDirectory()`, `load(from:configuration:progressHandler:)`
// and `loadPLDAPsi` were removed (they went through ModelHub, i.e. the Hugging Face
// downloader). Talkie loads the CoreML models from a local folder in TalkieDiarization.
#endif
