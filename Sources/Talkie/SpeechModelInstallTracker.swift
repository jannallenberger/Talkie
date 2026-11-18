import Foundation
import Speech

/// Observable view of the on-device speech model's install, for the onboarding
/// try-it steps. macOS performs the one-time model download (Talkie's own code has
/// no networking); this only reports it. The engine calls `begin`/`markInstalled`
/// around its install, and onboarding calls `probe` for the current status.
@MainActor
final class SpeechModelInstallTracker: ObservableObject {
    static let shared = SpeechModelInstallTracker()

    @Published private(set) var phase: SpeechModelPhase = .unknown

    private var progressTask: Task<Void, Never>?

    func markInstalled() {
        progressTask?.cancel()
        progressTask = nil
        phase = .installed
    }

    func markFailed() {
        progressTask?.cancel()
        progressTask = nil
        if phase != .installed { phase = .failed }
    }

    /// A download started. Polls `progress` for a determinate bar.
    func begin(progress: Progress) {
        progressTask?.cancel()
        phase = .downloading(fraction: nil)
        // `Progress` is documented thread-safe; reading it from here is fine.
        nonisolated(unsafe) let progress = progress
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                let total = progress.totalUnitCount
                let fraction: Double? = total > 0 ? progress.fractionCompleted : nil
                guard let self else { return }
                if case .downloading = self.phase { self.phase = .downloading(fraction: fraction) }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// Ask macOS whether the model for `localeIdentifier` is installed. Only ever
    /// promotes to `.installed`: the status is not always reliable inside a running
    /// app, so a "not installed" answer leaves the phase as it was.
    func probe(localeIdentifier: String) async {
        guard SpeechTranscriber.isAvailable, phase != .installed else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else { return }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                       reportingOptions: [], attributeOptions: [])
        let status = await AssetInventory.status(forModules: [module])
        if status == .installed { markInstalled() }
        else if status == .downloading, !phase.showsDownloadNotice { phase = .downloading(fraction: nil) }
    }
}
