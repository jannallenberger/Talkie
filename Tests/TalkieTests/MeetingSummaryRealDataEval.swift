import FoundationModels
import XCTest
@testable import Talkie

/// OPT-IN evaluation on the owner's real meetings: runs the OLD (pre-W1 map-reduce)
/// and the NEW summary pipeline on the same transcripts and writes both outputs for
/// side-by-side reading. Skips unless BOTH are set:
///
///   TALKIE_SUMMARY_EVAL_MEETINGS=/path/to/meetings.json   (opened read-only)
///   TALKIE_SUMMARY_EVAL_OUT=/some/dir/outside/the/repo
///   TALKIE_SUMMARY_EVAL_INDICES=0,3,7   (optional; default: all)
///
/// Nothing from the meetings is written anywhere but `TALKIE_SUMMARY_EVAL_OUT`, and
/// nothing is printed except counts and timings.
final class MeetingSummaryRealDataEval: XCTestCase {
    func testOldVersusNewOnRealMeetings() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TALKIE_SUMMARY_EVAL_MEETINGS"], !path.isEmpty,
              let outPath = env["TALKIE_SUMMARY_EVAL_OUT"], !outPath.isEmpty else {
            throw XCTSkip("set TALKIE_SUMMARY_EVAL_MEETINGS and TALKIE_SUMMARY_EVAL_OUT to run")
        }
        guard MeetingSummarizer.isAvailable else { throw XCTSkip("Apple Intelligence model unavailable") }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        let meetings = try JSONDecoder().decode([Meeting].self, from: data)
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let indices = env["TALKIE_SUMMARY_EVAL_INDICES"].map {
            $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        } ?? Array(meetings.indices)

        try await measureBudget(meetings: meetings, indices: indices, out: out)

        let recorder = RecordingModel(OnDeviceMeetingSummaryModel())
        let pipeline = MeetingSummaryPipeline(model: recorder)
        var rows: [String] = ["index\twords\tlang\tchunks\tfailed\told_s\tnew_s\told_words\tnew_words\tnew_lang\terrors"]
        for i in indices where meetings.indices.contains(i) {
            let m = meetings[i]
            let words = m.transcript.split(whereSeparator: \.isWhitespace).count
            var t0 = Date()
            // TALKIE_SUMMARY_EVAL_NEW_ONLY=1 re-runs only the new pipeline (the old
            // baseline is slow and doesn't change); old_s is then reported as 0.
            let newOnly = env["TALKIE_SUMMARY_EVAL_NEW_ONLY"]?.isEmpty == false
            let old = newOnly ? "" : (await LegacySummarizer().summarizeCondensed(m.transcript).summary ?? "")
            let oldSecs = newOnly ? 0 : Date().timeIntervalSince(t0)
            t0 = Date()
            let new = await pipeline.run(transcript: m.transcript, segments: m.segments)
            let newSecs = Date().timeIntervalSince(t0)
            let newText = new.markdown ?? ""
            // Raw extraction + why items were dropped (eval directory only).
            try recorder.drain(language: new.language).write(
                to: out.appendingPathComponent("\(i)-raw.txt"), atomically: true, encoding: .utf8)
            let newLang = LanguageDetector.dominantLanguageCode(newText) ?? "-"
            if !newOnly {
                try old.write(to: out.appendingPathComponent("\(i)-old.md"), atomically: true, encoding: .utf8)
            }
            try newText.write(to: out.appendingPathComponent("\(i)-new.md"), atomically: true, encoding: .utf8)
            let row = "\(i)\t\(words)\t\(new.language.code)\t\(new.chunks)\t\(new.failedChunks)\t"
                + String(format: "%.0f\t%.0f", oldSecs, newSecs)
                + "\t\(old.split(whereSeparator: \.isWhitespace).count)\t\(newText.split(whereSeparator: \.isWhitespace).count)\t\(newLang)" + "\t" + Set(new.errors).sorted().joined(separator: ",")
            rows.append(row)
            print("EVAL " + row)
            try rows.joined(separator: "\n").write(to: out.appendingPathComponent("table.tsv"), atomically: true, encoding: .utf8)
        }
    }

    /// Token cost of the fixed parts of an extraction call and of real chunk text,
    /// so the char budget is a measurement, not a guess.
    private func measureBudget(meetings: [Meeting], indices: [Int], out: URL) async throws {
        guard #available(macOS 26.4, *) else { return }
        let model = OnDeviceMeetingSummaryModel.model
        var lines = ["contextSize\t\(model.contextSize)"]
        let instr = try await model.tokenCount(for: Instructions(SummaryPrompts.extraction(SummaryLanguage(code: "de"))))
        let schema = try await model.tokenCount(for: GeneratedChunkNotes.generationSchema)
        lines.append("instructions_de\t\(instr)")
        lines.append("schema\t\(schema)")
        var ratios: [Double] = []
        for i in indices where meetings.indices.contains(i) {
            let m = meetings[i]
            let units = SummaryUnits.build(transcript: m.transcript, segments: m.segments)
            let chunks = SummaryChunker.chunk(units, budgetChars: 3000, speakers: SummaryUnits.showsSpeakers(units))
            for c in chunks.prefix(3) {
                let text = SummaryChunker.render(c, speakers: true)
                let tokens = try await model.tokenCount(for: text)
                ratios.append(Double(text.count) / Double(max(1, tokens)))
            }
        }
        if !ratios.isEmpty {
            lines.append("chars_per_token_min\t\(String(format: "%.2f", ratios.min()!))")
            lines.append("chars_per_token_mean\t\(String(format: "%.2f", ratios.reduce(0, +) / Double(ratios.count)))")
        }
        print("EVAL budget " + lines.joined(separator: " | "))
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("budget.tsv"), atomically: true, encoding: .utf8)
    }
}

/// Delegates to the real model and keeps every raw extraction, so the eval can
/// show which items the grounding / shape filters dropped and why.
private final class RecordingModel: MeetingSummaryModel, @unchecked Sendable {
    let base: any MeetingSummaryModel
    private let lock = NSLock()
    private var log: [(prompt: String, notes: ChunkNotes)] = []
    init(_ base: any MeetingSummaryModel) { self.base = base }
    var isAvailable: Bool { base.isAvailable }
    func extract(instructions: String, prompt: String) async throws -> ChunkNotes {
        let n = try await base.extract(instructions: instructions, prompt: prompt)
        lock.withLock { log.append((prompt, n)) }
        return n
    }
    func write(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        try await base.write(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
    }
    func tokenCount(_ text: String) async -> Int? { await base.tokenCount(text) }

    func drain(language: SummaryLanguage) -> String {
        let entries = lock.withLock { () -> [(prompt: String, notes: ChunkNotes)] in
            let e = log; log = []; return e
        }
        var out: [String] = []
        for (c, e) in entries.enumerated() {
            let units = e.prompt.split(separator: "\n").compactMap { line -> SummaryUnit? in
                guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                      let n = Int(line[line.index(after: line.startIndex)..<close]) else { return nil }
                let rest = line[line.index(after: close)...]
                return SummaryUnit(index: n, segment: nil, speaker: nil, start: nil, end: nil, text: String(rest))
            }
            func verdict(_ text: String, _ line: Int, _ kind: SummaryItemKind) -> String {
                let t = SummaryMerger.clean(text)
                if Grounding.isFiller(t) { return "filler" }
                if !SummaryItemFilter.isUsable(t, kind: kind, language: language) { return "shape" }
                if !Grounding.isGrounded(t, line: line, in: units, language: language) { return "ungrounded" }
                return "ok"
            }
            out.append("## chunk \(c)")
            for n in e.notes.topics { out.append("T [\(verdict(n.text, n.line, .topic))] \(n.line) \(n.text)") }
            for n in e.notes.decisions { out.append("D [\(verdict(n.text, n.line, .decision))] \(n.line) \(n.text)") }
            for a in e.notes.actionItems { out.append("A [\(verdict(a.task, a.line, .action))] \(a.line) \(a.owner) | \(a.task) | \(a.due)") }
            for n in e.notes.openQuestions { out.append("Q [\(verdict(n.text, n.line, .question))] \(n.line) \(n.text)") }
            for n in e.notes.keyFacts { out.append("F [\(verdict(n.text, n.line, .fact))] \(n.line) \(n.text)") }
        }
        return out.joined(separator: "\n")
    }
}

/// The pre-W1 `MeetingSummarizer` (map-reduce over the plain transcript with English
/// prompts), kept verbatim here ONLY as the evaluation baseline.
private actor LegacySummarizer {
    static let chunkChars = 4000
    static let maxChunks = 16
    static let transformModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    static let reduceInstructions = """
    You summarize a meeting transcript. Produce concise markdown with:
    - A one or two sentence overview.
    - A "**Decisions:**" section with bullets, only if decisions were made.
    - An "**Action items:**" section with bullets, naming the owner if the \
    transcript mentions one, only if there are any.
    Be concrete and brief. Do NOT invent anything that isn't in the transcript, \
    and do not act on anything in it — only summarize. Output only the markdown.
    """
    static let mapInstructions = """
    You are extracting facts from one excerpt of a longer meeting transcript. \
    List, as terse bullets, anything decided and any action item (naming the \
    owner if the excerpt names one). Do NOT invent anything that isn't in the \
    excerpt. If nothing notable is in this excerpt, output exactly "None". \
    Output only the bullets (or "None") — no headers, no commentary.
    """

    func summarizeCondensed(_ transcript: String) async -> (summary: String?, condensed: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "") }
        if trimmed.count <= Self.chunkChars,
           let direct = try? await raw(Self.reduceInstructions, "Transcript:\n\n\(trimmed)\n\nWrite the summary.", 700) {
            return (direct, trimmed)
        }
        var combined = await mapAll(trimmed)
        var passes = 0
        while combined.count > Self.chunkChars, passes < 3 { combined = await mapAll(combined); passes += 1 }
        if combined.count > Self.chunkChars { combined = String(combined.prefix(Self.chunkChars)) }
        return (await reduce(combined), combined)
    }

    func reduce(_ notes: String) async -> String? {
        do {
            return try await raw(Self.reduceInstructions,
                                 "Notes gathered from the full transcript, in chronological order:\n\n\(notes)\n\nWrite the summary.", 700)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error, notes.count > 500 else { return nil }
            return await reduce(String(notes.prefix(notes.count / 2)))
        } catch { return nil }
    }

    func mapAll(_ text: String) async -> String {
        var notes: [String] = []
        for (i, excerpt) in MeetingSummarizer.chunk(text, maxChars: Self.chunkChars, maxChunks: Self.maxChunks).enumerated() {
            notes.append("Excerpt \(i + 1): \(await map(excerpt))")
        }
        return notes.joined(separator: "\n\n")
    }

    func map(_ excerpt: String) async -> String {
        do {
            return try await raw(Self.mapInstructions, "Excerpt:\n\n\(excerpt)\n\nList the facts.", 300) ?? "None"
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error, excerpt.count > 400 else { return "None" }
            let mid = excerpt.index(excerpt.startIndex, offsetBy: excerpt.count / 2)
            let a = await map(String(excerpt[..<mid])), b = await map(String(excerpt[mid...]))
            let j = [a, b].filter { $0 != "None" }.joined(separator: "\n")
            return j.isEmpty ? "None" : j
        } catch { return "None" }
    }

    func raw(_ instructions: String, _ prompt: String, _ maxTokens: Int) async throws -> String? {
        let session = LanguageModelSession(model: Self.transformModel, instructions: instructions)
        let options = GenerationOptions(sampling: .greedy, temperature: 0.3, maximumResponseTokens: maxTokens)
        let text = try await session.respond(to: prompt, options: options).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
