import Foundation

/// Lifetime dictation stats for the scoreboard. Persisted SEPARATELY from the
/// 7-day history so the totals keep accumulating even as old entries are pruned.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var totalWords = 0
    @Published private(set) var totalDictations = 0
    @Published private(set) var totalDurationSec = 0.0
    @Published private(set) var bestWPM = 0.0

    // Fixes Talkie has made for you (drives the "Fixes by Talkie" card).
    /// Replacement / vocabulary substitutions applied (e.g. "correlate" → "Coralate").
    @Published private(set) var dictionaryFixes = 0
    /// Filler words stripped ("um", "uh", …).
    @Published private(set) var fillersRemoved = 0
    /// Words changed by the on-device AI cleanup (grammar, self-corrections).
    @Published private(set) var aiWordsChanged = 0

    private let fileURL: URL

    init() {
        fileURL = AppPaths.supportDirectory().appendingPathComponent("stats.json")
        load()
    }

    func record(words: Int, durationSec: Double) {
        guard words > 0 else { return }
        totalWords += words
        totalDictations += 1
        totalDurationSec += max(0, durationSec)

        // Only count a "best WPM" for meaningful samples (avoids 1-word bursts
        // producing absurd rates).
        if durationSec >= 1.5, words >= 4 {
            let wpm = Double(words) / (durationSec / 60)
            if wpm.isFinite, wpm > 0, wpm < 400 {
                bestWPM = max(bestWPM, wpm)
            }
        }
        save()
    }

    /// Tally the corrections Talkie made on one dictation.
    func recordFixes(dictionary: Int, fillers: Int, aiWords: Int) {
        dictionaryFixes += max(0, dictionary)
        fillersRemoved += max(0, fillers)
        aiWordsChanged += max(0, aiWords)
        save()
    }

    /// Lifetime average speaking speed.
    var averageWPM: Double {
        guard totalDurationSec > 0 else { return 0 }
        return Double(totalWords) / (totalDurationSec / 60)
    }

    /// Words Talkie rewrote for you (fillers + AI grammar/self-correction edits).
    var wordsCorrected: Int { fillersRemoved + aiWordsChanged }
    /// All fixes combined — the headline number on the "Fixes by Talkie" card.
    var totalFixes: Int { wordsCorrected + dictionaryFixes }

    func reset() {
        totalWords = 0
        totalDictations = 0
        totalDurationSec = 0
        bestWPM = 0
        dictionaryFixes = 0
        fillersRemoved = 0
        aiWordsChanged = 0
        save()
    }

    // MARK: Persistence

    private struct Payload: Codable {
        var totalWords: Int
        var totalDictations: Int
        var totalDurationSec: Double
        var bestWPM: Double
        // Optional for back-compat with files written before fix-tracking.
        var dictionaryFixes: Int?
        var fillersRemoved: Int?
        var aiWordsChanged: Int?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        totalWords = p.totalWords
        totalDictations = p.totalDictations
        totalDurationSec = p.totalDurationSec
        bestWPM = p.bestWPM
        dictionaryFixes = p.dictionaryFixes ?? 0
        fillersRemoved = p.fillersRemoved ?? 0
        aiWordsChanged = p.aiWordsChanged ?? 0
    }

    private func save() {
        let p = Payload(
            totalWords: totalWords,
            totalDictations: totalDictations,
            totalDurationSec: totalDurationSec,
            bestWPM: bestWPM,
            dictionaryFixes: dictionaryFixes,
            fillersRemoved: fillersRemoved,
            aiWordsChanged: aiWordsChanged
        )
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Shared word-count helper.
enum WordCounter {
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
