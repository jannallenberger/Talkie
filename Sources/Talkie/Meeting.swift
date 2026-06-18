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
    /// Hard retention cap: the index inlines full data (incl. transcripts) only for
    /// the most-recent N meetings. Beyond N, the oldest are EVICTED from the index —
    /// the `.md` files in the meetings folder stay as the durable copy (and a corrupt
    /// index self-heals from them, see `load`). This bounds `meetings.json` growth and
    /// the O(total) cost of every `save`. We do NOT lazily read an external `.md` to
    /// re-inflate evicted entries: PR #26 lets meetings export to arbitrary Obsidian
    /// vaults, so the `.md` is not always at a known internal path — the index must be
    /// self-sufficient.
    static let maxRetainedMeetings = 200

    @Published private(set) var meetings: [Meeting] = [] // newest first

    private let indexURL: URL
    private let meetingsDirectoryURL: URL

    init(supportDirectory: URL = AppPaths.supportDirectory(),
         meetingsDirectory: URL = AppPaths.meetingsDirectory()) {
        indexURL = supportDirectory.appendingPathComponent("meetings.json")
        meetingsDirectoryURL = meetingsDirectory
        load()
    }

    var folderURL: URL { meetingsDirectoryURL }

    func add(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
        writeMarkdown(meeting)
        enforceRetentionCap()
        save()
    }

    func delete(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
        let url = meetingsDirectoryURL.appendingPathComponent(meeting.fileName)
        try? FileManager.default.removeItem(at: url)
        save()
    }

    /// Keep full data for only the most-recent `maxRetainedMeetings`, evicting the
    /// oldest beyond that from the in-memory/on-disk index. Sorting by date first
    /// makes "most recent N" well-defined regardless of insertion order.
    private func enforceRetentionCap() {
        meetings.sort { $0.startUnix > $1.startUnix } // newest first
        if meetings.count > Self.maxRetainedMeetings {
            meetings.removeLast(meetings.count - Self.maxRetainedMeetings)
        }
    }
    /// A filesystem-safe, collision-proof `.md` filename for a meeting. Minute
    /// granularity alone collided (two meetings in the same minute clobbered the
    /// earlier `.md` via the `.atomic` write, while the JSON index kept both), so we
    /// add seconds AND a short id fragment — unique per meeting even within a second.
    static func fileName(for date: Date, id: UUID) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let frag = id.uuidString.prefix(4).lowercased()
        return "\(f.string(from: date))-\(frag)-meeting.md"
    }

    // MARK: Markdown

    private func writeMarkdown(_ m: Meeting) {
        // Build the neutral note (feature 10's seam — one source of truth for the
        // Markdown), then route it through the user's chosen export destination
        // instead of the hardcoded ~/Talkie Meetings/ folder. `resolvedDestination()`
        // reads the @Published export prefs, so it MUST run on the main actor; the
        // destination value it returns is `Sendable`, so the blocking disk write is
        // handed off to a detached task and never touches @MainActor state.
        let minutes = Int((m.durationSec / 60).rounded())
        let summary = m.summary.isEmpty ? "_(no summary)_" : m.summary
        let note = ExportableNote(
            kind: .meeting,
            title: m.title,
            date: m.date,
            bodyMarkdown: "## Summary\n\n\(summary)\n\n## Transcript\n\n\(m.transcript)",
            frontMatter: [
                "duration_min": "\(minutes)",
                "participants": "[\(m.participants.joined(separator: ", "))]",
                "source": m.source,
            ],
            suggestedFileName: m.fileName
        )
        let url = meetingsDirectoryURL.appendingPathComponent(m.fileName)
        try? Data(TalkieFolderDestination.render(note).utf8).write(to: url, options: .atomic)
        // Resolve ON the main actor (reads @Published prefs); `resolvedDestination()`
        // already falls back to the Talkie folder for an inaccessible custom path.
        let destination = ExportPreferences.shared.resolvedDestination()
        // The on-disk write is fire-and-forget: the in-memory `meetings` list and the
        // JSON index the UI reads are the authority, so the note is never lost to a
        // slow or failed write. A SECOND, independent fallback writes to the default
        // ~/Talkie Meetings/ folder if the chosen destination throws — honouring the
        // "never lose a note" contract even when the resolved destination is healthy
        // at resolve-time but fails mid-write (e.g. a vault unmounts).
        Task.detached {
            do {
                _ = try await destination.write(note)
            } catch {
                _ = try? await TalkieFolderDestination().write(note)
            }
        }
    }

    // MARK: Persistence (lightweight index; the .md files are the durable copy)

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([Meeting].self, from: data) else {
            // The index is missing or corrupt, but the `.md` files in the meetings
            // folder are the durable copy — rebuild from them rather than orphaning
            // them behind an empty list. Best-effort and non-fatal.
            meetings = Self.recoverFromMarkdown(in: meetingsDirectoryURL)
            enforceRetentionCap()
            return
        }
        meetings = decoded
        enforceRetentionCap()
    }

    /// Best-effort self-heal: scan `directory` for `*.md` meeting notes and rebuild
    /// index entries from what's reliably parseable (title + date from the YAML
    /// front-matter, falling back to the filename). Transcripts/summaries are left
    /// empty — the durable `.md` remains the full record — so a corrupt index never
    /// orphans the folder. Never throws; returns `[]` if the folder is unreadable.
    static func recoverFromMarkdown(in directory: URL) -> [Meeting] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var recovered: [Meeting] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let front = parseFrontMatter(text)
            let date = front["date"].flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? dateFromFileName(url.lastPathComponent)
                ?? Date(timeIntervalSince1970: 0)
            let parsedTitle = front["title"].map(unquoteYAML)?
                .trimmingCharacters(in: .whitespaces)
            let title = (parsedTitle?.isEmpty == false)
                ? parsedTitle!
                : url.deletingPathExtension().lastPathComponent
            recovered.append(Meeting(
                title: title,
                startUnix: date.timeIntervalSince1970,
                durationSec: 0,
                transcript: "",
                summary: "",
                fileName: url.lastPathComponent
            ))
        }
        return recovered.sorted { $0.startUnix > $1.startUnix } // newest first
    }

    /// Pull the simple `key: value` pairs out of a leading `---`-fenced YAML block.
    /// Only the keys we need (`title`, `date`) matter; deliberately minimal — not a
    /// full YAML parser — and tolerant of a missing/garbled block.
    private static func parseFrontMatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var pairs: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { pairs[key] = value }
        }
        return pairs
    }

    /// Derive a date from a `yyyy-MM-dd-HHmm-…` filename (the default naming), so a
    /// note without a usable front-matter date still recovers a sensible timestamp.
    private static func dateFromFileName(_ name: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let prefix = name.split(separator: "-").prefix(4).joined(separator: "-")
        return f.date(from: prefix)
    }

    /// Strip the surrounding quotes a YAML scalar may carry (the renderer quotes
    /// titles containing reserved characters).
    private static func unquoteYAML(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
