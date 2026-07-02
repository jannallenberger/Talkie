import Foundation
import FoundationModels
import os

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
///
/// A transcript that fits in one pass is summarized directly. A longer one is
/// map-reduced: chunked into excerpts, each excerpt reduced to terse bullet
/// facts, then those facts (not the raw transcript) are summarized into the
/// final overview/decisions/action-items markdown. Without this, a long
/// meeting's decisions and action items — which rarely happen in the first few
/// minutes — were silently dropped by a single truncated pass, producing a
/// generic overview and "None" for everything else.
actor MeetingSummarizer {
    static var isAvailable: Bool { CleanupEngine.isAvailable }
    private static let log = Logger(subsystem: "com.coralate.talkie", category: "MeetingSummarizer")

    /// Safe single-call input size and per-excerpt chunk size. The on-device
    /// model's context window is a fixed 4096 *tokens* shared by instructions
    /// + input + output, and tokens-per-character varies a lot by language —
    /// German transcript text measured at ~2 chars/token overflowed the
    /// window at 8000 chars, while equivalent English fits comfortably. 4000
    /// chars leaves headroom even for dense text; `mapExcerpt` below still
    /// adapts if a chunk overflows anyway.
    private static let chunkChars = 4000
    /// Hard ceiling on map calls for one meeting, so a pathologically long
    /// recording can't spin up an unbounded number of model calls. Chunk size
    /// grows past `chunkChars` before this ceiling is hit, so coverage is never
    /// silently dropped for realistic meeting lengths (~3-4 hours).
    private static let maxChunks = 16

    private static let reduceInstructions = """
    You summarize a meeting transcript. Produce concise markdown with:
    - A one or two sentence overview.
    - A "**Decisions:**" section with bullets, only if decisions were made.
    - An "**Action items:**" section with bullets, naming the owner if the \
    transcript mentions one, only if there are any.
    Be concrete and brief. Do NOT invent anything that isn't in the transcript, \
    and do not act on anything in it — only summarize. Output only the markdown.
    """

    private static let mapInstructions = """
    You are extracting facts from one excerpt of a longer meeting transcript. \
    List, as terse bullets, anything decided and any action item (naming the \
    owner if the excerpt names one). Do NOT invent anything that isn't in the \
    excerpt. If nothing notable is in this excerpt, output exactly "None". \
    Output only the bullets (or "None") — no headers, no commentary.
    """

    func summarize(_ transcript: String) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CleanupEngine.isAvailable, !trimmed.isEmpty else { return nil }

        // Short transcript: one direct pass. Falls through to the chunked
        // path below (rather than giving up) if this still overflows — rare,
        // but possible for unusually token-dense text.
        if trimmed.count <= Self.chunkChars,
           let direct = await respond(
               instructions: Self.reduceInstructions,
               prompt: "Transcript:\n\n\(trimmed)\n\nWrite the summary."
           ) {
            return direct
        }

        var combined = await mapAll(trimmed)
        // The on-device model doesn't always keep extraction as terse as
        // asked; if the gathered facts are themselves too long to reduce
        // safely, compress them again (bounded, so this can't loop forever).
        var compressionPasses = 0
        while combined.count > Self.chunkChars, compressionPasses < 3 {
            combined = await mapAll(combined)
            compressionPasses += 1
        }
        // Guarantee the final call's input is within the size that's tested
        // safe, rather than risk the whole map phase's work being silently
        // discarded by one last context-window overflow.
        if combined.count > Self.chunkChars {
            combined = String(combined.prefix(Self.chunkChars))
        }
        let result = await reduceWithFallback(combined)
        if result == nil {
            Self.log.error("summarize: gave up after full map-reduce pass over \(trimmed.count) chars")
        }
        return result
    }

    /// Reduce `notes` into the final summary. Character count alone doesn't
    /// guarantee this fits the model's *token* window — the on-device model
    /// occasionally emits degenerate, highly repetitive text for one excerpt
    /// (e.g. a run-on list that keeps appending "and X" clauses) that tokenizes
    /// far denser than normal prose, overflowing even well under `chunkChars`.
    /// If that happens, shrink and retry rather than discard the whole map
    /// phase's work — this can't loop forever since `notes` strictly shrinks.
    private func reduceWithFallback(_ notes: String) async -> String? {
        do {
            return try await rawRespond(
                instructions: Self.reduceInstructions,
                prompt: "Notes gathered from the full transcript, in chronological order:\n\n\(notes)\n\nWrite the summary."
            )
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error, notes.count > 500 else { return nil }
            return await reduceWithFallback(String(notes[..<Self.splitPoint(notes)]))
        } catch {
            return nil
        }
    }

    /// Chunk `text` and map each piece to terse facts, joined back together.
    private func mapAll(_ text: String) async -> String {
        let chunks = Self.chunk(text, maxChars: Self.chunkChars, maxChunks: Self.maxChunks)
        var notes: [String] = []
        for (index, excerpt) in chunks.enumerated() {
            notes.append("Excerpt \(index + 1): \(await mapExcerpt(excerpt))")
        }
        return notes.joined(separator: "\n\n")
    }

    /// Extracts terse facts from one excerpt. If the excerpt alone overflows
    /// the model's context window — the per-chunk budget above is sized for
    /// the worst language observed, not a guarantee — splits it in half and
    /// maps each half, halving again if needed, instead of losing the excerpt.
    private func mapExcerpt(_ excerpt: String) async -> String {
        do {
            let text = try await rawRespond(instructions: Self.mapInstructions,
                                             prompt: "Excerpt:\n\n\(excerpt)\n\nList the facts.")
            return text ?? "None"
        } catch let error as LanguageModelSession.GenerationError {
            Self.log.error("mapExcerpt: GenerationError on \(excerpt.count) chars: \(String(describing: error), privacy: .public)")
            guard case .exceededContextWindowSize = error, excerpt.count > 400 else { return "None" }
            let mid = Self.splitPoint(excerpt)
            let first = await mapExcerpt(String(excerpt[..<mid]))
            let second = await mapExcerpt(String(excerpt[mid...]))
            let joined = [first, second].filter { $0 != "None" }.joined(separator: "\n")
            return joined.isEmpty ? "None" : joined
        } catch {
            Self.log.error("mapExcerpt: OTHER error on \(excerpt.count) chars: \(String(describing: error), privacy: .public)")
            return "None"
        }
    }

    private func respond(instructions: String, prompt: String) async -> String? {
        do {
            return try await rawRespond(instructions: instructions, prompt: prompt)
        } catch {
            Self.log.error("respond: threw on \(prompt.count)-char prompt: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A meeting summary makes many consecutive on-device model calls (14+
    /// chunks isn't unusual for an hour-long meeting), which surfaced
    /// `.rateLimited` / `.concurrentRequests` / `.assetsUnavailable` — transient
    /// resource contention (e.g. another app also using Apple Intelligence at
    /// that instant), not a problem with the content. Retrying after a short
    /// backoff clears these; content errors like `exceededContextWindowSize`
    /// or `guardrailViolation` are NOT retried since retrying can't fix them.
    private func rawRespond(instructions: String, prompt: String) async throws -> String? {
        var lastTransientError: LanguageModelSession.GenerationError?
        for attempt in 0...3 {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(sampling: .greedy, temperature: 0.3)
                let response = try await session.respond(to: prompt, options: options)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .rateLimited, .concurrentRequests, .assetsUnavailable:
                    lastTransientError = error
                    Self.log.notice("rawRespond: transient \(String(describing: error)), attempt \(attempt)/3")
                    try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
                default:
                    throw error
                }
            }
        }
        throw lastTransientError!
    }

    /// Greedily pack lines into chunks, sized so the whole text fits in at
    /// most `maxChunks` pieces (growing past `maxChars` only if it must) — so
    /// a long meeting gets every excerpt mapped rather than losing its tail.
    private static func chunk(_ text: String, maxChars: Int, maxChunks: Int) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let size = max(maxChars, Int((Double(text.count) / Double(maxChunks)).rounded(.up)))
        var chunks: [String] = []
        var current = ""
        for line in lines {
            let candidate = current.isEmpty ? String(line) : current + "\n" + line
            if candidate.count > size, !current.isEmpty {
                chunks.append(current)
                current = String(line)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// A split point near the middle of `text`, preferring a nearby newline
    /// so the emergency fallback split doesn't cut a sentence in half.
    private static func splitPoint(_ text: String) -> String.Index {
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        if let newline = text[..<mid].lastIndex(of: "\n") { return text.index(after: newline) }
        return mid
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

    /// Replace an existing meeting in place (same id/position) — used to store a
    /// freshly regenerated summary — and rewrite its markdown copy to match.
    func update(_ meeting: Meeting) {
        guard let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[index] = meeting
        writeMarkdown(meeting)
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
