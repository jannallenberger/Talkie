// Confidence-gated repair (experiment, bench-only for now).
//
// Apple's recognizer reports a per-word `transcriptionConfidence`. On a real
// German dictation every word below ~0.75 was an actual error, while the ~170
// words above it were right. So instead of letting a model rewrite the whole
// dictation (which dropped and swapped correct words), only the UNCERTAIN spans
// are handed to the model — numbered — and it answers with a replacement per
// span. The sentence is rebuilt here, deterministically: a confident word is
// copied through verbatim and cannot be changed, by construction rather than by
// an after-the-fact diff check.

import Foundation
import FoundationModels

/// One recognized token and how sure the recognizer was about it (0…1).
public struct RecognizedWord: Sendable, Equatable {
    public var text: String
    public var confidence: Double

    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

/// A run of consecutive low-confidence tokens, repaired as one unit so the model
/// can also add a word the recognizer swallowed or drop one it invented.
public struct UncertainSpan: Sendable, Equatable {
    /// 1-based, as shown to the model.
    public let id: Int
    /// Token indices into the word list.
    public let range: Range<Int>
    public let text: String
}

public enum ConfidenceRepair {

    /// Group consecutive tokens below `threshold` into spans. Punctuation-only
    /// tokens never start a span on their own (a low-confidence "," is not worth a
    /// model call) but are absorbed when they sit inside or right after one.
    public static func spans(_ words: [RecognizedWord], threshold: Double) -> [UncertainSpan] {
        var spans: [UncertainSpan] = []
        var i = 0
        while i < words.count {
            guard words[i].confidence < threshold, !isPunctuation(words[i].text) else { i += 1; continue }
            var j = i + 1
            while j < words.count, words[j].confidence < threshold { j += 1 }
            spans.append(UncertainSpan(id: spans.count + 1, range: i..<j,
                                       text: join(words[i..<j].map(\.text))))
            i = j
        }
        return spans
    }

    /// The dictation with each span wrapped as `[[n: text]]` — the model's view.
    /// When a vocabulary term is spelled like the span, it rides along as a hint
    /// (`[[6: CloudMD | vielleicht: CLAUDE.md]]`): the small model can't match a
    /// mishearing to a term list on its own, but it can accept a named candidate.
    public static func markedText(_ words: [RecognizedWord], spans: [UncertainSpan],
                                  vocabulary: [String] = []) -> String {
        rebuild(words, spans: spans) { span in
            if let hint = candidate(for: span.text, in: vocabulary) {
                return "[[\(span.id): \(span.text) | vielleicht: \(hint)]]"
            }
            return "[[\(span.id): \(span.text)]]"
        }
    }

    /// The vocabulary term spelled most like `span` (letters only), if it's close
    /// enough to be a plausible mishearing.
    static func candidate(for span: String, in vocabulary: [String]) -> String? {
        let a = letters(span)
        guard a.count >= 3 else { return nil }
        let scored = vocabulary.map { ($0, similarity(a, letters($0))) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.5, letters(best.0) != a else { return nil }
        return best.0
    }

    /// Rebuild the text, substituting each span's replacement (or its original text
    /// when there is none). Tokens outside spans are emitted verbatim.
    public static func apply(_ words: [RecognizedWord], spans: [UncertainSpan],
                             replacements: [Int: String]) -> String {
        rebuild(words, spans: spans) { replacements[$0.id] ?? $0.text }
    }

    /// Parse the model's `n: replacement` lines. Unknown ids, and replacements that
    /// balloon past the span (more than two extra words — a sign the model is
    /// rewriting rather than repairing), are dropped so that span stays as heard.
    public static func parseReplacements(_ output: String, spans: [UncertainSpan],
                                         vocabulary: [String] = [],
                                         ordinaryWords: Set<String> = []) -> [Int: String] {
        let byID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
        var out: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":"),
                  let id = Int(trimmed[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " []"))),
                  let span = byID[id] else { continue }
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"„“"))
            let spanWords = span.text.split(separator: " ").count
            let newWords = value.split(separator: " ").count
            guard newWords <= spanWords + 2,
                  isPlausibleRepair(span: span.text, replacement: value, vocabulary: vocabulary,
                                    ordinaryWords: ordinaryWords) else { continue }
            out[id] = value
        }
        return out
    }

    /// Whether `replacement` is a plausible REPAIR of `span` rather than a rewrite
    /// or translation. The model is only trusted when its answer is one of:
    ///   • the span itself, give or take punctuation ("die Wörter." → "die Wörter"),
    ///   • one of the speaker's vocabulary terms ("CloudMD" → "CLAUDE.md"),
    ///   • the span extended by a swallowed word ("von" → "von Hand", "ein" → "einen"),
    ///   • close in spelling — a mishearing sounds and so mostly spells alike
    ///     ("Worky" → "worktree", "Lok" → "Log"), unlike a translation ("von" → "of"),
    ///   • a deletion of a short invented token ("you" from silence → "").
    ///
    /// Two model habits are refused outright: turning a real dictionary word into
    /// one of the terms ("glaube" → "Claude", "Lock" → "/loop" — measured on
    /// Jann's recordings), and changing nothing but capitalization ("jetzt," →
    /// "Jetzt" mid-sentence).
    public static func isPlausibleRepair(span: String, replacement: String, vocabulary: [String],
                                         ordinaryWords: Set<String> = []) -> Bool {
        let a = letters(span), b = letters(replacement)
        let bareSpan = span.trimmingCharacters(in: .punctuationCharacters)
        let isTerm = vocabulary.contains(where: { $0.caseInsensitiveCompare(replacement) == .orderedSame })
        if isTerm, !bareSpan.contains(" "), !isJargonShaped(bareSpan), ordinaryWords.contains(bareSpan) {
            return false
        }
        if a == b, !replacement.isEmpty,
           bareSpan.lowercased() == replacement.trimmingCharacters(in: .punctuationCharacters).lowercased(),
           bareSpan != replacement.trimmingCharacters(in: .punctuationCharacters) {
            return false  // case-only change
        }
        if replacement.trimmingCharacters(in: .whitespaces).isEmpty {
            return a.count <= 4 && !span.contains(" ")
        }
        // Never shrink a multi-word span: dropped words are the failure mode that
        // prompted this whole design ("oder MD D" → "oder" deleted two words).
        let spanWordCount = span.split(separator: " ").count
        if replacement.split(separator: " ").count < spanWordCount { return false }
        if a == b { return true }
        if isTerm { return true }
        if b.hasPrefix(a), b.count - a.count <= 8 { return true }
        return similarity(a, b) >= 0.5
    }

    /// Lowercased letters and digits only.
    static func letters(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// 1 − (Levenshtein distance ÷ longer length).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                let tmp = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }

    /// The sentences that contain a span, in order, each marked — the model's
    /// context. Sentences with no span are left out: they cost time and can't change.
    public static func markedSentences(_ words: [RecognizedWord], spans: [UncertainSpan],
                                       vocabulary: [String] = []) -> String {
        guard !spans.isEmpty else { return "" }
        var sentences: [Range<Int>] = []
        var start = 0
        for (i, w) in words.enumerated() where w.text.hasSuffix(".") || w.text.hasSuffix("?") || w.text.hasSuffix("!") {
            // A span's own trailing period is exactly what may be wrong, so it
            // never ends a sentence here.
            if spans.contains(where: { $0.range.contains(i) }) { continue }
            sentences.append(start..<(i + 1)); start = i + 1
        }
        if start < words.count { sentences.append(start..<words.count) }
        let wanted = sentences.filter { s in spans.contains { $0.range.overlaps(s) } }
        return wanted.map { s in
            let inside = spans.filter { s.contains($0.range.lowerBound) }
                .map { UncertainSpan(id: $0.id, range: ($0.range.lowerBound - s.lowerBound)..<($0.range.upperBound - s.lowerBound), text: $0.text) }
            return markedText(Array(words[s]), spans: inside, vocabulary: vocabulary)
        }.joined(separator: "\n")
    }

    // MARK: Vocabulary snap (no model)

    /// Replace an uncertain span with one of the speaker's terms when it is spelled
    /// or sounds almost the same ("kloud.m" → "CLAUDE.md", "Worktory" → "worktree").
    /// Deterministic and instant. It only ever looks at LOW-confidence spans — the
    /// old always-on phonetic corrector failed precisely because it also rewrote
    /// words the recognizer was sure about. Returns span id → term.
    ///
    /// `isOrdinaryWord` guards single-word spans: a real dictionary word ("Cloud",
    /// "Prima", "anthropisch") that merely resembles a term is left alone — actual
    /// mishearings of jargon ("kloud.m", "Worktory") are not dictionary words.
    public static func vocabularySnaps(_ spans: [UncertainSpan], vocabulary: [String],
                                       minScore: Double = snapMinScore,
                                       isOrdinaryWord: (String) -> Bool = { _ in false }) -> [Int: String] {
        var out: [Int: String] = [:]
        for span in spans {
            let bare = span.text.trimmingCharacters(in: .punctuationCharacters)
            // Jargon-shaped tokens ("CloudMD", "kloud.m") skip the dictionary check:
            // spell checkers wave mixed-case words through, and everyday speech
            // never looks like that anyway.
            if !bare.contains(" "), !isJargonShaped(bare), isOrdinaryWord(bare) { continue }
            if let term = snapTarget(for: span.text, vocabulary: vocabulary, minScore: minScore) {
                out[span.id] = term
            }
        }
        return out
    }

    /// Default cutoff for `vocabularySnaps`, calibrated so ordinary words don't snap.
    public static let snapMinScore = 0.6

    /// The best-scoring term for `text`, if it clears `minScore`. Short tokens and
    /// short terms are excluded: "Log"/"Lok" are too close to too many real words.
    static func snapTarget(for text: String, vocabulary: [String], minScore: Double) -> String? {
        let a = letters(text)
        guard a.count >= 4 else { return nil }
        // Already one of the terms ("Claude") — never trade it for a neighbor
        // ("CLAUDE.md"). Same letters but different spacing ("Higgs field") still snaps.
        let bare = text.trimmingCharacters(in: .punctuationCharacters)
        if vocabulary.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) { return nil }
        // Short spans need a near-exact match: with five letters or fewer one edit
        // is too much coincidence ("kloud." → "iCloud" when "CLAUDE.md" was meant,
        // Jann's first live test, 2026-09-22).
        let cutoff = a.count <= 5 ? max(minScore, 0.9) : minScore
        var best: (term: String, score: Double)?
        for term in vocabulary {
            let b = letters(term)
            guard b.count >= 4 else { continue }
            let score = snapScore(a, b)
            if score >= cutoff, score > (best?.score ?? 0) { best = (term, score) }
        }
        return best?.term
    }

    /// How strongly `a` looks like a mishearing of `b` (letters-only inputs).
    /// Spelling must agree reasonably (≥ 0.6, treating c/k alike — "kloud"/"Claude")
    /// and then EITHER spelling is close (≥ 0.75) OR the words sound alike under
    /// Kölner Phonetik (≥ 0.8 on codes of 4+ digits). Sound alone is too coarse: it
    /// maps "jetzt" to "ist die" and "Wörter" to "worktree". Returns 0 on a miss.
    static func snapScore(_ a: String, _ b: String) -> Double {
        let ka = a.replacingOccurrences(of: "k", with: "c"), kb = b.replacingOccurrences(of: "k", with: "c")
        let spelled = similarity(ka, kb)
        guard spelled >= 0.6 else { return 0 }
        if spelled >= 0.75 { return spelled }
        let pa = colognePhonetic(a), pb = colognePhonetic(b)
        guard pa.count >= 4, pb.count >= 4 else { return 0 }
        let sound = similarity(pa, pb)
        return sound >= 0.8 ? max(spelled, sound) : 0
    }

    /// Whether a term looks like jargon worth snapping TO: a camel/inner capital,
    /// a dot, hyphen or digit, or all caps ("CLAUDE.md", "TestFlight-Build",
    /// "worktree" does not qualify — pass such terms via the vocabulary list).
    public static func isJargonShaped(_ term: String) -> Bool {
        let inner = term.dropFirst()
        return inner.contains(where: \.isUppercase) || term.contains(where: { ".-_0123456789".contains($0) })
    }

    /// Kölner Phonetik (Postel 1969): a phonetic code for German words — words
    /// that sound alike get the same digits. Input: lowercase letters.
    static func colognePhonetic(_ word: String) -> String {
        let c = Array(word.lowercased().map { ch -> Character in
            switch ch { case "ä": return "a"; case "ö": return "o"; case "ü": return "u"; case "ß": return "s"; default: return ch }
        }.filter { $0.isLetter })
        var codes: [Character] = []
        for i in c.indices {
            let ch = c[i]
            let prev: Character? = i > 0 ? c[i - 1] : nil
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil
            let code: Character?
            switch ch {
            case "a", "e", "i", "j", "o", "u", "y": code = "0"
            case "h": code = nil
            case "b": code = "1"
            case "p": code = next == "h" ? "3" : "1"
            case "d", "t": code = (next.map { "csz".contains($0) } ?? false) ? "8" : "2"
            case "f", "v", "w": code = "3"
            case "g", "k", "q": code = "4"
            case "c":
                if i == 0 {
                    code = (next.map { "ahkloqrux".contains($0) } ?? false) ? "4" : "8"
                } else if let p = prev, "sz".contains(p) {
                    code = "8"
                } else {
                    code = (next.map { "ahkoqux".contains($0) } ?? false) ? "4" : "8"
                }
            case "x": code = (prev.map { "ckq".contains($0) } ?? false) ? "8" : "4"
            case "l": code = "5"
            case "m", "n": code = "6"
            case "r": code = "7"
            case "s", "z": code = "8"
            default: code = nil
            }
            if let code {
                if ch == "x", code == "4" { codes.append("4"); codes.append("8") } else { codes.append(code) }
            }
        }
        // Collapse repeats, then drop vowel codes except at the start.
        var collapsed: [Character] = []
        for d in codes where collapsed.last != d { collapsed.append(d) }
        guard let first = collapsed.first else { return "" }
        return String([first] + collapsed.dropFirst().filter { $0 != "0" })
    }

    /// Apply vocabulary snaps to `text` — the app's live entry point. `words` are
    /// the recognizer's tokens for this dictation; `text` is the transcript after
    /// earlier stages, which may differ in spacing ("raus ." vs "raus."). Each
    /// snapped span is located as its token sequence (whitespace-tolerant, in
    /// order); a span no longer found verbatim is skipped, so the pass is a
    /// no-op wherever an earlier stage already rewrote the text.
    public static func snapVocabulary(in text: String, words: [RecognizedWord], vocabulary: [String],
                                      threshold: Double = 0.75,
                                      isOrdinaryWord: (String) -> Bool) -> (text: String, fixes: [(from: String, to: String)]) {
        let spans = spans(words, threshold: threshold)
        let snaps = vocabularySnaps(spans, vocabulary: vocabulary, isOrdinaryWord: isOrdinaryWord)
        guard !snaps.isEmpty else { return (text, []) }
        var out = text
        var cursor = out.startIndex
        var fixes: [(String, String)] = []
        // Walk ALL tokens in order, locating each one, so the cursor tracks the
        // speaker's position: a word repeated earlier in the sentence ("Worktory
        // und Worktory") must not be mistaken for the uncertain occurrence.
        func locate(_ tokens: [String]) -> Range<String.Index>? {
            let pattern = tokens.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"\s*"#)
            guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + pattern + "(?![\\p{L}\\p{N}])"),
                  let match = regex.firstMatch(in: out, range: NSRange(cursor..<out.endIndex, in: out)) else { return nil }
            return Range(match.range, in: out)
        }
        var i = 0
        var s = 0
        while i < words.count {
            if s < spans.count, spans[s].range.lowerBound == i {
                let span = spans[s]
                i = span.range.upperBound
                s += 1
                guard let found = locate(words[span.range].map(\.text)) else { continue }
                guard let term = snaps[span.id] else { cursor = found.upperBound; continue }
                // Keep a trailing mark the span carried ("kloud.m," → "CLAUDE.md,").
                let tail = String(span.text.reversed().prefix(while: { ",;:!?".contains($0) }).reversed())
                let replacement = term + tail
                out.replaceSubrange(found, with: replacement)
                cursor = out.index(found.lowerBound, offsetBy: replacement.count)
                fixes.append((span.text, term))
            } else {
                // A confident token only moves the cursor; if an earlier stage
                // changed it, leave the cursor where it is.
                if let found = locate([words[i].text]) { cursor = found.upperBound }
                i += 1
            }
        }
        return (out, fixes)
    }

    /// `words` with each snapped span collapsed into one confident token holding
    /// the term — so a following model pass sees the fix as settled context.
    public static func applyingSnaps(_ words: [RecognizedWord], spans: [UncertainSpan],
                                     snaps: [Int: String]) -> [RecognizedWord] {
        var out: [RecognizedWord] = []
        var i = 0
        var s = 0
        while i < words.count {
            if s < spans.count, spans[s].range.lowerBound == i {
                if let term = snaps[spans[s].id] {
                    // Keep a trailing mark the span carried ("kloud.m," → "CLAUDE.md,").
                    let tail = String(spans[s].text.reversed().prefix(while: { ",;:!?".contains($0) }).reversed())
                    out.append(RecognizedWord(text: term + tail, confidence: 1))
                } else {
                    out.append(contentsOf: words[spans[s].range])
                }
                i = spans[s].range.upperBound
                s += 1
            } else {
                out.append(words[i]); i += 1
            }
        }
        return out
    }

    // MARK: Internals

    static func isPunctuation(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    /// Join tokens with spaces, attaching punctuation-only tokens to the previous
    /// word ("raus" "." → "raus.").
    static func join(_ tokens: [String]) -> String {
        var out = ""
        for token in tokens where !token.isEmpty {
            if out.isEmpty || isPunctuation(token) { out += token } else { out += " " + token }
        }
        return out
    }

    private static func rebuild(_ words: [RecognizedWord], spans: [UncertainSpan],
                                render: (UncertainSpan) -> String) -> String {
        var pieces: [String] = []
        var i = 0
        var spanIndex = 0
        while i < words.count {
            if spanIndex < spans.count, spans[spanIndex].range.lowerBound == i {
                let span = spans[spanIndex]
                pieces.append(render(span))
                i = span.range.upperBound
                spanIndex += 1
            } else {
                pieces.append(words[i].text)
                i += 1
            }
        }
        return join(pieces)
    }
}

/// The model's answer, forced into this shape by guided generation — it cannot
/// return free text, so it cannot rewrite the dictation around the spans.
@Generable
struct SpanRepair {
    @Guide(description: "The number n of the marked part [[n: …]]")
    var id: Int
    @Guide(description: "What the speaker most likely said for that part. Empty to delete an invented word.")
    var text: String
}

@Generable
struct RepairAnswer {
    @Guide(description: "One entry per marked part")
    var repairs: [SpanRepair]
}

/// The result of one repair pass, with enough detail for the bench to report.
public struct RepairOutcome: Sendable {
    public let text: String
    public let spans: [UncertainSpan]
    public let replacements: [Int: String]
    /// Model wall time; 0 when no span needed a model call.
    public let modelMs: Double
    /// What was sent and what came back, verbatim — for the bench report.
    public var prompt: String = ""
    public var modelOutput: String = ""
}

/// Runs the on-device model over the uncertain spans only.
public struct ConfidenceRepairer: Sendable {
    public let threshold: Double
    public let vocabulary: [String]
    public let languageName: String

    public init(threshold: Double, vocabulary: [String], languageName: String) {
        self.threshold = threshold
        self.vocabulary = vocabulary
        self.languageName = languageName
    }

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// `ordinaryWords`: which single-word span texts are real dictionary words
    /// (see `isPlausibleRepair`); the caller computes it with a spell checker.
    public func repair(_ words: [RecognizedWord], ordinaryWords: Set<String> = []) async -> RepairOutcome {
        let spans = ConfidenceRepair.spans(words, threshold: threshold)
        let plain = ConfidenceRepair.apply(words, spans: [], replacements: [:])
        guard !spans.isEmpty, Self.isAvailable else {
            return RepairOutcome(text: plain, spans: spans, replacements: [:], modelMs: 0)
        }
        let started = Date()
        let prompt = ConfidenceRepair.markedSentences(words, spans: spans, vocabulary: vocabulary)
        var replacements: [Int: String] = [:]
        var output = ""
        do {
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(sampling: .greedy, temperature: 0)
            let response = try await session.respond(to: prompt, generating: RepairAnswer.self,
                                                     options: options)
            // Reuse the line parser (and its plausibility guard) on the structured answer.
            output = response.content.repairs.map { "\($0.id): \($0.text)" }.joined(separator: "\n")
            replacements = ConfidenceRepair.parseReplacements(output, spans: spans, vocabulary: vocabulary,
                                                              ordinaryWords: ordinaryWords)
        } catch {
            // Any model failure keeps the transcript exactly as heard.
        }
        let ms = Date().timeIntervalSince(started) * 1000
        return RepairOutcome(text: ConfidenceRepair.apply(words, spans: spans, replacements: replacements),
                             spans: spans, replacements: replacements, modelMs: ms,
                             prompt: prompt, modelOutput: output)
    }

    private var instructions: String {
        """
        Du korrigierst Spracherkennungsfehler in einem diktierten Text (\(languageName)). \
        Nur die Stellen [[n: …]] sind unsicher erkannt; alles andere ist richtig. \
        Schreib für jede markierte Stelle, was der Sprecher vermutlich gesagt hat. \
        Übersetze NIE – der Text bleibt in seiner Sprache. Typische Fehler: ein \
        Fachbegriff oder englisches Wort als ähnlich klingendes Wort erkannt, ein \
        verschlucktes kurzes Wort, ein Punkt mitten im Satz an einer Sprechpause, \
        ein aus Stille erfundenes Wort (dann nichts hinter den Doppelpunkt schreiben). \
        Ist eine Stelle schon richtig, gib sie unverändert zurück. Ein Vorschlag \
        „vielleicht: …“ ist ein Begriff des Sprechers, der ähnlich klingt – nimm ihn, \
        wenn er in den Satz passt. \
        Begriffe des Sprechers: \(vocabulary.joined(separator: ", ")).

        Beispiel:
        [[1: you]] Okay, schau dir die [[2: Cloud MD | vielleicht: CLAUDE.md]] an, wie wir [[3: die Wörter.]] nachträglich bearbeiten, und das [[4: von]] korrigiere im [[5: Worky]].
        1:
        2: CLAUDE.md
        3: die Wörter
        4: von Hand
        5: worktree

        Gib für jede markierte Stelle genau einen Eintrag zurück.
        """
    }
}
