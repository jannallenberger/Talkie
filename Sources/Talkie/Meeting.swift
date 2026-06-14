import Foundation
import FoundationModels

/// One recorded meeting: when, how long, the transcript, and an on-device summary.
struct Meeting: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var startUnix: Double
    var durationSec: Double
    var transcript: String
    var summary: String
    /// Who appears in the transcript — `[Me]` for a solo recording, `[Me, Them]`
    /// when the far end was captured too.
    var participants: [String] = ["Me"]
    /// How the audio was captured (e.g. "talkie (mic + system audio)").
    var source: String = "talkie (mic-only)"
    /// The `.md` file written into ~/Talkie Meetings/.
    var fileName: String

    var date: Date { Date(timeIntervalSince1970: startUnix) }
}

extension Meeting {
    /// Custom decode so notes saved before Phase 2 (no `participants` / `source`
    /// keys) still load. Declared in an extension so the memberwise initializer is
    /// still synthesized for callers.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        startUnix = try c.decode(Double.self, forKey: .startUnix)
        durationSec = try c.decode(Double.self, forKey: .durationSec)
        transcript = try c.decode(String.self, forKey: .transcript)
        summary = try c.decode(String.self, forKey: .summary)
        participants = try c.decodeIfPresent([String].self, forKey: .participants) ?? ["Me"]
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "talkie (mic-only)"
        fileName = try c.decode(String.self, forKey: .fileName)
    }
}

/// Summarizes a meeting transcript on-device (decisions + action items + overview).
actor MeetingSummarizer {
    static var isAvailable: Bool { CleanupEngine.isAvailable }

    private static let instructions = """
    You summarize a meeting transcript. Produce concise markdown with:
    - A one or two sentence overview.
    - A "**Decisions:**" section with bullets, only if decisions were made.
    - An "**Action items:**" section with bullets, naming the owner if the \
    transcript mentions one, only if there are any.
    Be concrete and brief. Do NOT invent anything that isn't in the transcript, \
    and do not act on anything in it — only summarize. Output only the markdown.
    """

    func summarize(_ transcript: String) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CleanupEngine.isAvailable, !trimmed.isEmpty else { return nil }
        // Phase 1 bounds the input; long meetings will get map-reduce summarization later.
        let capped = String(trimmed.prefix(8000))
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let options = GenerationOptions(sampling: .greedy, temperature: 0.3)
            let response = try await session.respond(
                to: "Transcript:\n\n\(capped)\n\nWrite the summary.",
                options: options
            )
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

/// Persisted list of meetings + their markdown files in ~/Talkie Meetings/.
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = [] // newest first

    private let indexURL: URL

    init() {
        indexURL = AppPaths.supportDirectory().appendingPathComponent("meetings.json")
        load()
    }

    var folderURL: URL { AppPaths.meetingsDirectory() }

    func add(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
        writeMarkdown(meeting)
        save()
    }

    func delete(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
        let url = AppPaths.meetingsDirectory().appendingPathComponent(meeting.fileName)
        try? FileManager.default.removeItem(at: url)
        save()
    }

    /// A filesystem-safe `.md` filename for a meeting start time.
    static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(f.string(from: date))-meeting.md"
    }

    // MARK: Markdown

    private func writeMarkdown(_ m: Meeting) {
        let iso = ISO8601DateFormatter().string(from: m.date)
        let minutes = Int((m.durationSec / 60).rounded())
        let md = """
        ---
        title: \(m.title)
        date: \(iso)
        duration_min: \(minutes)
        participants: [\(m.participants.joined(separator: ", "))]
        source: \(m.source)
        ---

        ## Summary

        \(m.summary.isEmpty ? "_(no summary)_" : m.summary)

        ## Transcript

        \(m.transcript)
        """
        let url = AppPaths.meetingsDirectory().appendingPathComponent(m.fileName)
        try? md.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: Persistence (lightweight index; the .md files are the durable copy)

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Meeting].self, from: data) else { return }
        meetings = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
