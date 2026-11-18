import Foundation
import FoundationModels

// The Foundation Models side of the meeting summary pipeline: guided generation for
// the per-chunk extraction (the model cannot answer with free text, a skeleton, or an
// apology there — only the typed lists), and a plain capped call for the overview.

@Generable
struct GeneratedNote {
    @Guide(description: "Number n of the transcript line [n] this comes from")
    var line: Int
    @Guide(description: "One short, complete statement in the transcript's language")
    var text: String
}

@Generable
struct GeneratedAction {
    @Guide(description: "Number n of the transcript line [n] this comes from")
    var line: Int
    @Guide(description: "Who does it: a name said in the transcript, else the line's speaker label")
    var owner: String
    @Guide(description: "The concrete task, as a short statement")
    var task: String
    @Guide(description: "By when, only if said; else empty")
    var due: String
}

@Generable
struct GeneratedChunkNotes {
    @Guide(description: "Subjects discussed, as short labels, in order", .maximumCount(6))
    var topics: [GeneratedNote]
    @Guide(description: "What the speakers agreed on or settled (chosen, postponed, approved, rejected). Not a topic, not a question", .maximumCount(5))
    var decisions: [GeneratedNote]
    @Guide(description: "Concrete tasks someone will do or was asked to do", .maximumCount(5))
    var actionItems: [GeneratedAction]
    @Guide(description: "Questions raised and not answered, phrased as questions", .maximumCount(4))
    var openQuestions: [GeneratedNote]
    @Guide(description: "Concrete facts stated: names, numbers, amounts, dates, places", .maximumCount(6))
    var keyFacts: [GeneratedNote]
}

struct OnDeviceMeetingSummaryModel: MeetingSummaryModel {
    /// Summarizing transforms the user's own transcript — the case Apple's permissive
    /// guardrails exist for (with the defaults, casual swearing / legal talk made whole
    /// excerpts come back as guardrail violations).
    static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    var isAvailable: Bool { CleanupEngine.isAvailable }

    func extract(instructions: String, prompt: String) async throws -> ChunkNotes {
        try await withTransientRetry {
            let session = LanguageModelSession(model: Self.model, instructions: instructions)
            let options = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 900)
            let r = try await session.respond(to: prompt, generating: GeneratedChunkNotes.self, options: options)
            let c = r.content
            func notes(_ list: [GeneratedNote]) -> [ChunkNotes.Note] { list.map { .init(line: $0.line, text: $0.text) } }
            return ChunkNotes(
                topics: notes(c.topics), decisions: notes(c.decisions),
                actionItems: c.actionItems.map { .init(line: $0.line, owner: $0.owner, task: $0.task, due: $0.due) },
                openQuestions: notes(c.openQuestions), keyFacts: notes(c.keyFacts))
        }
    }

    func write(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        try await withTransientRetry {
            let session = LanguageModelSession(model: Self.model, instructions: instructions)
            let options = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: maxTokens)
            let r = try await session.respond(to: prompt, options: options)
            return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func tokenCount(_ text: String) async -> Int? {
        if #available(macOS 26.4, *) {
            return try? await Self.model.tokenCount(for: text)
        }
        return nil
    }

    /// Back-to-back calls surface transient contention (`rateLimited`,
    /// `concurrentRequests`, `assetsUnavailable`) that clears after a short wait;
    /// content errors are mapped and never retried.
    private func withTransientRetry<T>(_ op: () async throws -> T) async throws -> T {
        for attempt in 0...3 {
            do {
                return try await op()
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .rateLimited, .concurrentRequests, .assetsUnavailable:
                    if attempt == 3 { throw SummaryModelError.unavailable }
                    try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
                case .exceededContextWindowSize:
                    throw SummaryModelError.contextOverflow
                case .guardrailViolation, .refusal:
                    throw SummaryModelError.refused
                default:
                    // The case name only: an error's context may quote model output.
                    let name = String(describing: error).prefix { $0 != "(" }
                    throw SummaryModelError.other(String(name))
                }
            }
        }
        throw SummaryModelError.unavailable
    }
}
