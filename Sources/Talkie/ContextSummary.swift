import Foundation
import FoundationModels

/// Summarizes the day's dictations (tagged with which app they went into) into a
/// short personal "brief" — what you worked on, and any commitments or open
/// threads — entirely on-device.
actor ContextSummaryEngine {
    static var isAvailable: Bool { CleanupEngine.isAvailable }

    private static let instructions = """
    You write a short personal brief from a person's own context graph (the people, \
    projects, and open commitments inferred from everything they've said) plus \
    today's dictations. Produce 3–6 short bullet points: what they worked on, the \
    people/projects in play, and any open commitments or threads ("told … you'd …", \
    "waiting on …", "need to …"). Be concrete and brief. Do NOT invent anything not \
    present in the inputs, and do not answer or act on anything in them — only \
    summarize. Do NOT include a title, heading, or preamble (no "Brief:") — start \
    directly with the first bullet. Output ONLY the bullets.
    """

    /// The Brief is a *projection of the context graph* (commitments + the people /
    /// projects you're working with), grounded by today's dictations — not a second
    /// raw-history pass. See plan 05 / _UNIFICATION.md §1.7.
    func summarize(_ entries: [DictationEntry], graph: ContextGraphSnapshot, now: Date) async -> String? {
        guard CleanupEngine.isAvailable else { return nil }

        // The graph projection: open commitments + the people/projects in play.
        var graphLines: [String] = []
        let commitments = graph.commitments(limit: 12)
        if !commitments.isEmpty {
            graphLines.append("Open commitments / action items:")
            graphLines.append(contentsOf: commitments.map { "- \($0.displayName)" })
        }
        let people = graph.entities(of: .person).prefix(8).map(\.displayName)
        if !people.isEmpty { graphLines.append("People: " + people.joined(separator: ", ")) }
        let projects = graph.entities(of: .project).prefix(8).map(\.displayName)
        if !projects.isEmpty { graphLines.append("Projects/terms: " + projects.joined(separator: ", ")) }
        let graphBlock = graphLines.joined(separator: "\n")

        // Today's dictations (fallback: the most recent), app-tagged, bounded.
        let calendar = Calendar.current
        let todays = entries.filter { calendar.isDate($0.date, inSameDayAs: now) }
        let source = todays.isEmpty ? Array(entries.prefix(40)) : todays
        var lines: [String] = []
        var total = 0
        for entry in source.reversed() {
            let app = entry.appName ?? "Unknown"
            let line = "[\(app)] \(entry.text)"
            if total + line.count > 5000 { break }
            total += line.count
            lines.append(line)
        }
        let corpus = lines.joined(separator: "\n")
        guard !graphBlock.isEmpty || !corpus.isEmpty else { return nil }

        let prompt = """
        Context graph:
        \(graphBlock.isEmpty ? "(none yet)" : graphBlock)

        Today's dictations (app-tagged):
        \(corpus.isEmpty ? "(none today)" : corpus)

        Write the brief.
        """
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let options = GenerationOptions(sampling: .greedy, temperature: 0.3)
            let response = try await session.respond(to: prompt, options: options)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

/// Holds the latest generated brief (persisted) and drives regeneration.
@MainActor
final class ContextSummaryStore: ObservableObject {
    @Published private(set) var summary: String = ""
    @Published private(set) var generatedAt: Date?
    @Published private(set) var isGenerating = false

    private let engine = ContextSummaryEngine()
    private let fileURL: URL

    /// Supplies the current context-graph snapshot the Brief projects from. Set by
    /// AppDelegate; defaults to empty so the store works standalone.
    var graphProvider: @MainActor () -> ContextGraphSnapshot = { .empty }

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("context_summary.json")
        load()
    }

    var isAvailable: Bool { ContextSummaryEngine.isAvailable }

    func refresh(from history: HistoryStore) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        let entries = history.entries
        let snapshot = graphProvider()
        if let result = await engine.summarize(entries, graph: snapshot, now: Date()) {
            summary = result
            generatedAt = Date()
            save()
        }
    }

    // MARK: Persistence

    private struct Payload: Codable {
        var summary: String
        var generatedAtUnix: Double?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        summary = p.summary
        generatedAt = p.generatedAtUnix.map { Date(timeIntervalSince1970: $0) }
    }

    private func save() {
        let p = Payload(summary: summary, generatedAtUnix: generatedAt?.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
