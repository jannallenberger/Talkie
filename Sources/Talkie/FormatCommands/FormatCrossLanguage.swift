import Foundation

/// "Format while you dictate" in every enabled language, whatever the recognizer is
/// running in. The running recognizer decodes a whole dictation in ONE language, so a
/// command said in another one ("bullet points" inside a German dictation) can come
/// out mangled. With more than one dictation language enabled, each command span's
/// audio is therefore re-recognised in every OTHER enabled language the moment the
/// format key is released (while you keep talking), and the best phrase match across
/// all readings wins (`FormatPhraseMatcher.bestAcross`). With one language enabled
/// nothing extra runs.
///
/// Budget: the re-recognition of one span stops starting new passes after
/// `spanBudgetSeconds`; at the end of the dictation the paste waits at most
/// `pasteWaitSeconds` for any span still being re-recognised, then goes ahead with
/// what it has (the live reading, the original transcript, the pill's preview).
///
/// What can't be guaranteed: a language's model must already be on the Mac (it is
/// never downloaded mid-dictation); a phrase the recognizer of EVERY language mangles
/// still fails ("not recognised"); a command span shorter than a word or so may be
/// heard as nothing; and when two languages' readings match two different commands
/// equally well, the live reading decides.
enum FormatCrossLanguage {
    /// Audio kept either side of the held interval (key and recognizer clocks differ,
    /// people start talking as they press).
    static let audioPadding: Double = 0.3
    /// Max wall time to start re-recognition passes for one span.
    static let spanBudgetSeconds: Double = 1.5
    /// Max extra wait at the end of a dictation for unfinished span re-recognition.
    static let pasteWaitSeconds: Double = 0.8

    /// Whether to re-recognise at all: only with more than one enabled language.
    static func shouldRecognise(spokenLanguages: [String]) -> Bool {
        LanguageDetector.distinctByCode(spokenLanguages).count > 1
    }

    /// The enabled languages other than the one the recognizer is running in.
    static func otherLanguages(spokenLanguages: [String], currentLocaleID: String) -> [String] {
        let current = LanguageDetector.languageCode(of: currentLocaleID)
        return LanguageDetector.distinctByCode(spokenLanguages).filter {
            LanguageDetector.languageCode(of: $0) != current
        }
    }

    /// Indices of the buffers (with these frame counts, consecutive from time 0) that
    /// overlap `from…to` seconds. Empty when nothing overlaps.
    static func bufferRange(frameCounts: [Int], sampleRate: Double, from: Double, to: Double) -> Range<Int> {
        guard sampleRate > 0, to > from else { return 0..<0 }
        var t = 0.0
        var first: Int?
        var last: Int?
        for (i, frames) in frameCounts.enumerated() {
            let duration = Double(frames) / sampleRate
            let bufferEnd = t + duration
            // A tiny tolerance so float drift never adds a buffer that only touches an edge.
            if bufferEnd > max(0, from) + 1e-9, t < to - 1e-9 {
                if first == nil { first = i }
                last = i
            }
            t = bufferEnd
            if t >= to { break }
        }
        guard let first, let last else { return 0..<0 }
        return first..<(last + 1)
    }

    /// The value of `operation` if it finishes within `seconds`, else nil (the
    /// operation is left to finish on its own; its result is then ignored).
    static func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
        guard seconds > 0 else { return nil }
        // Not a task group: a group waits for every child on exit, and awaiting an
        // unstructured task's value can't be cancelled — the race must not block.
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            Task { once.resume(await task.value) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(nil)
            }
        }
    }

    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func resume(_ value: T?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}
