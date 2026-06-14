import Foundation
import FoundationModels

/// The on-device default `Summarizer`: a thin wrapper over Foundation Models'
/// `LanguageModelSession` using the same greedy / low-temperature pattern as
/// `CleanupEngine`. Stateless and `Sendable`, so any consumer can hold one.
///
/// Existing engines keep their own bespoke prompts and post-processing; they can
/// migrate to call *through* this seam incrementally. Construct with the
/// temperature matching the consumer (cleanup 0.1; summaries / brief 0.3).
struct OnDeviceLLM: Summarizer {
    var temperature: Double = 0.1

    static var isAvailable: Bool { CleanupEngine.isAvailable }
    let requiresNetwork = false

    func generate(instructions: String, input: String) async -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAvailable, !trimmed.isEmpty else { return nil }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(sampling: .greedy, temperature: temperature)
            let response = try await session.respond(to: trimmed, options: options)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
