import Foundation

/// Lifetime dictation stats for the scoreboard. Persisted SEPARATELY from the
/// 7-day history so the totals keep accumulating even as old entries are pruned.
@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var totalWords = 0
    @Published private(set) var totalDictations = 0
    @Published private(set) var totalDurationSec = 0.0
    @Published private(set) var bestWPM = 0.0

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

    /// Lifetime average speaking speed.
    var averageWPM: Double {
        guard totalDurationSec > 0 else { return 0 }
        return Double(totalWords) / (totalDurationSec / 60)
    }

    func reset() {
        totalWords = 0
        totalDictations = 0
        totalDurationSec = 0
        bestWPM = 0
        save()
    }

    // MARK: Persistence

    private struct Payload: Codable {
        var totalWords: Int
        var totalDictations: Int
        var totalDurationSec: Double
        var bestWPM: Double
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        totalWords = p.totalWords
        totalDictations = p.totalDictations
        totalDurationSec = p.totalDurationSec
        bestWPM = p.bestWPM
    }

    private func save() {
        let p = Payload(
            totalWords: totalWords,
            totalDictations: totalDictations,
            totalDurationSec: totalDurationSec,
            bestWPM: bestWPM
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
