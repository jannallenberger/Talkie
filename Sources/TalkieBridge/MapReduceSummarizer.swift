import Foundation

/// Summarizes inputs longer than a model's comfortable window by chunking →
/// summarizing each chunk → summarizing the summaries. Works with any
/// `BridgeSummarizer`. This is the long-meeting fix (the 8000-char truncation TODO)
/// living ABOVE the summarizer seam, so it works with the cloud bridge or, when
/// adapted, the on-device model.
public struct MapReduceSummarizer: Sendable {
    public let summarizer: any BridgeSummarizer
    public var chunkChars: Int

    public init(summarizer: any BridgeSummarizer, chunkChars: Int = 8000) {
        self.summarizer = summarizer
        self.chunkChars = max(1000, chunkChars)
    }

    public func summarize(instructions: String, input: String) async throws -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= chunkChars {
            return try await summarizer.generate(instructions: instructions, input: trimmed)
        }
        // Map: summarize each chunk, preserving the load-bearing facts.
        var partials: [String] = []
        for chunk in Self.chunks(trimmed, size: chunkChars) {
            if let part = try await summarizer.generate(
                instructions: "Summarize this section faithfully; keep names, decisions, and action items. Do not invent.",
                input: chunk
            ) { partials.append(part) }
        }
        guard !partials.isEmpty else { return nil }
        // Reduce: apply the caller's real instructions to the joined partials.
        return try await summarizer.generate(instructions: instructions, input: partials.joined(separator: "\n\n"))
    }

    static func chunks(_ s: String, size: Int) -> [String] {
        var out: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[idx..<end]))
            idx = end
        }
        return out
    }
}
