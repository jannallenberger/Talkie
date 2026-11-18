import Foundation
import TalkieDiarization

/// Where the app finds the speaker-diarization models: bundled read-only at
/// `Contents/Resources/DiarizationModels` by scripts/build_app.sh. No download
/// path exists — if the folder is absent or stale (e.g. a `swift run` build with
/// no bundle), diarization is simply unavailable and meetings keep Me/Them.
enum DiarizationModels {
    static let resourceFolderName = "DiarizationModels"

    /// The bundled models root, or nil when it is missing/incomplete/stale.
    static func bundledDirectory(in bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let root = resources.appendingPathComponent(resourceFolderName, isDirectory: true)
        return SpeakerDiarizer.modelsAvailable(at: root) ? root : nil
    }
}
