import Foundation

/// Read-mostly access to the on-disk Talkie stores for the MCP server. A *peer
/// reader* of the same JSON/Markdown the app writes — it never holds a lock the
/// app holds and works whether or not the app is running. Slim local Codable
/// mirrors avoid importing the app target (keeping this a separate, network-free
/// binary); a shared library to de-dupe them is a later refactor.
struct TalkieStore {
    let supportDir: URL
    let meetingsDir: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        supportDir = home.appendingPathComponent("Library/Application Support/Talkie", isDirectory: true)
        meetingsDir = home.appendingPathComponent("Talkie Meetings", isDirectory: true)
    }

    // MARK: Models (mirror the app's on-disk shapes; extra fields optional)

    struct Meeting: Codable {
        var id: UUID
        var title: String
        var startUnix: Double
        var durationSec: Double
        var transcript: String
        var summary: String
        var participants: [String]?
        var source: String?
        var fileName: String
        var date: Date { Date(timeIntervalSince1970: startUnix) }
    }
    struct EntityID: Codable { var kind: String; var key: String }
    struct Provenance: Codable { var source: String; var sourceID: String?; var dateUnix: Double; var snippet: String? }
    struct Entity: Codable {
        var id: EntityID
        var displayName: String
        var aliases: [String]?
        var mentions: Int?
        var pinned: Bool?
        var firstSeenUnix: Double?
        var lastSeenUnix: Double?
        var provenance: [Provenance]?
    }
    struct DictationEntry: Codable {
        var id: UUID
        var timestampUnix: Double
        var text: String
        var wordCount: Int?
        var appName: String?
    }
    struct Brief: Codable { var summary: String; var generatedAtUnix: Double? }

    // MARK: Loaders

    func meetings() -> [Meeting] { (decode(supportDir.appendingPathComponent("meetings.json")) ?? []) }
    func entities() -> [Entity] { (decode(supportDir.appendingPathComponent("graph/entities.json")) ?? []) }
    func history() -> [DictationEntry] { (decode(supportDir.appendingPathComponent("history.json")) ?? []) }
    func brief() -> Brief? { decode(supportDir.appendingPathComponent("context_summary.json")) }

    private func decode<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
    private func stamp(_ unix: Double) -> String { Self.dateFmt.string(from: Date(timeIntervalSince1970: unix)) }

    // MARK: Tool implementations (return human/model-readable text)

    func listMeetings(limit: Int, query: String?) -> String {
        var ms = meetings().sorted { $0.startUnix > $1.startUnix }
        if let q = query?.lowercased(), !q.isEmpty {
            ms = ms.filter { $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) || $0.transcript.lowercased().contains(q) }
        }
        ms = Array(ms.prefix(max(1, limit)))
        guard !ms.isEmpty else { return "No meetings found." }
        return ms.map { m in
            let mins = Int((m.durationSec / 60).rounded())
            let who = (m.participants ?? []).joined(separator: ", ")
            let oneLine = m.summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? "(no summary)"
            return "• [\(m.id.uuidString.prefix(8))] \(m.title) — \(stamp(m.startUnix)), \(mins) min\(who.isEmpty ? "" : " · \(who)")\n  \(oneLine)"
        }.joined(separator: "\n")
    }

    func getMeeting(idOrTitle: String) -> String {
        let key = idOrTitle.lowercased()
        let ms = meetings()
        let match = ms.first { $0.id.uuidString.lowercased().hasPrefix(key) }
            ?? ms.first { $0.title.lowercased().contains(key) }
            ?? ms.sorted { $0.startUnix > $1.startUnix }.first
        guard let m = match else { return "No meeting found for \"\(idOrTitle)\"." }
        let mins = Int((m.durationSec / 60).rounded())
        let who = (m.participants ?? []).joined(separator: ", ")
        return """
        # \(m.title)
        \(stamp(m.startUnix)) · \(mins) min\(who.isEmpty ? "" : " · \(who)")

        ## Summary
        \(m.summary.isEmpty ? "(no summary)" : m.summary)

        ## Transcript
        \(m.transcript)
        """
    }

    func getBrief() -> String {
        guard let b = brief(), !b.summary.isEmpty else { return "No brief generated yet." }
        let when = b.generatedAtUnix.map { " (generated \(stamp($0)))" } ?? ""
        return "Today's brief\(when):\n\n\(b.summary)"
    }

    func listCommitments(limit: Int) -> String {
        let commitments = entities()
            .filter { $0.id.kind == "commitment" }
            .sorted { ($0.lastSeenUnix ?? 0) > ($1.lastSeenUnix ?? 0) }
            .prefix(max(1, limit))
        guard !commitments.isEmpty else { return "No commitments recorded yet." }
        return commitments.map { e in
            let src = e.provenance?.last.map { " — from \($0.source) on \(stamp($0.dateUnix))" } ?? ""
            return "• \(e.displayName)\(src)"
        }.joined(separator: "\n")
    }

    func lookupEntity(query: String, kinds: [String]?) -> String {
        let q = query.lowercased()
        var es = entities().filter {
            $0.displayName.lowercased().contains(q) || ($0.aliases ?? []).contains { $0.lowercased().contains(q) }
        }
        if let kinds, !kinds.isEmpty { es = es.filter { kinds.contains($0.id.kind) } }
        es = es.sorted { ($0.mentions ?? 0) > ($1.mentions ?? 0) }
        guard !es.isEmpty else { return "No entity matching \"\(query)\"." }
        return es.prefix(10).map { e in
            let prov = (e.provenance ?? []).suffix(3).compactMap { $0.snippet }.joined(separator: " | ")
            return "• \(e.displayName) (\(e.id.kind), \(e.mentions ?? 0)×)\(prov.isEmpty ? "" : "\n  ↳ \(prov)")"
        }.joined(separator: "\n")
    }

    func search(query: String, limit: Int, sources: [String]?) -> String {
        let q = query.lowercased()
        guard !q.isEmpty else { return "Empty query." }
        let want: (String) -> Bool = { sources?.contains($0) ?? true }
        var hits: [(score: Int, line: String)] = []
        if want("meetings") {
            for m in meetings() where m.transcript.lowercased().contains(q) || m.summary.lowercased().contains(q) {
                hits.append((2, "meeting [\(m.id.uuidString.prefix(8))] \(m.title) — \(stamp(m.startUnix))"))
            }
        }
        if want("dictations") {
            for d in history() where d.text.lowercased().contains(q) {
                hits.append((1, "dictation [\(d.id.uuidString.prefix(8))] \(stamp(d.timestampUnix)): \(d.text.prefix(100))"))
            }
        }
        if want("entities") {
            for e in entities() where e.displayName.lowercased().contains(q) {
                hits.append((3, "entity (\(e.id.kind)) \(e.displayName)"))
            }
        }
        guard !hits.isEmpty else { return "No matches for \"\(query)\"." }
        return hits.sorted { $0.score > $1.score }.prefix(max(1, limit)).map { "• \($0.line)" }.joined(separator: "\n")
    }
}
