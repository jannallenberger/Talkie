import Foundation
import FoundationModels
import NaturalLanguage

/// Decides, by grammar, what belongs at a full stop the recognizer wrote.
///
/// Apple's `SpeechTranscriber` ends a sentence wherever the speaker pauses to think,
/// also in the middle of one ("make sure that the. Commands option …"). With an AI
/// cleanup style the cleanup model re-punctuates the whole text; without one (the
/// default for people who want their words left alone) nothing did, so the pause
/// stops were pasted as heard.
///
/// This works on the plain text, one full stop at a time, and can only ever do
/// three things there: leave it, remove it, or turn it into a comma (and fix the
/// capital letter of the word after it). No word is added, removed, changed or
/// moved — by construction, not by instruction.
///
/// Each stop is settled in this order:
///   1. a fixed rule, when grammar leaves no doubt (a sentence cannot end on "the");
///   2. the on-device model, asked only about stops that look unfinished, and
///      believed only when it returns the very same words;
///   3. otherwise the stop stays, apart from the few joins the app always made.
enum PauseStops {

    // MARK: Sentences

    /// `text` split into sentences at the terminators the recognizer wrote. Joining
    /// the result with single spaces gives the text back.
    static func sentences(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"(?<=[.!?…])[ \t]+(?=["„“‚‘(\[]?\p{Lu})"#) else {
            return [trimmed]
        }
        let ns = trimmed as NSString
        var pieces: [String] = []
        var start = 0
        for match in regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: start))
        // "z. B. Das", "Dr. Meier", "ca. Drei": the dot belongs to the word.
        var out: [String] = []
        for piece in pieces {
            if let last = out.last, endsWithAbbreviation(last) {
                out[out.count - 1] = last + " " + piece
            } else {
                out.append(piece)
            }
        }
        return out
    }

    private static func endsWithAbbreviation(_ sentence: String) -> Bool {
        guard sentence.hasSuffix("."), !sentence.hasSuffix("..") else { return false }
        guard let word = sentence.dropLast().split(whereSeparator: \.isWhitespace).last else { return false }
        let letters = word.filter(\.isLetter)
        guard letters.count == word.count else { return false }   // "636." ends a sentence
        return letters.count == 1 || abbreviations.contains(letters.lowercased())
    }

    private static let abbreviations: Set<String> = [
        "usw", "bzw", "vgl", "ggf", "evtl", "inkl", "exkl", "zzgl", "abzgl", "etc", "bspw",
        "ca", "nr", "str", "tel", "sog", "insb", "allg", "std", "mio", "mrd",
        "approx", "dept", "est", "misc", "vol", "fig", "incl", "resp", "vs", "mr", "mrs", "ms", "dr", "prof",
    ]

    /// Whether the stop at the end of `sentence` is one this may touch: a single
    /// full stop. Question marks, exclamation marks and ellipses are never a
    /// pause's doing.
    static func endsInPlainStop(_ sentence: String) -> Bool {
        sentence.hasSuffix(".") && !sentence.hasSuffix("..")
    }

    // MARK: Decisions

    enum Mark: Equatable, Sendable {
        case none
        case comma
    }

    enum Decision: Equatable, Sendable {
        /// A real sentence end: leave the stop and the capital.
        case keep
        /// One sentence: remove the stop (or make it a comma). `lead` is how the
        /// first word after it is written from now on; nil leaves it as heard.
        case join(Mark, lead: String?)
    }

    /// The fixed rules: a decision when grammar leaves no doubt, else nil.
    static func certain(before: String, after: String, languageCode: String?) -> Decision? {
        guard endsInPlainStop(before), let next = firstWord(of: after) else { return .keep }
        let nextKey = key(next)
        guard let last = lastWord(of: before) else { return nil }
        let lastKey = key(last)
        // The English-only rules need to know it is English ("Was" starts a German
        // question); the others are words of one language only.
        let english = languageCode == "en"
        let german = languageCode == "de"

        // Already lower-case: the recognizer itself did not see a new sentence.
        if next.first?.isLowercase == true { return .join(.none, lead: nil) }

        // A bare "I" never ends a sentence ("…I. Want to…").
        if !german, last == "I" { return .join(.none, lead: lowered(next)) }

        // Words a sentence cannot end on. After an article or possessive comes a
        // noun (maybe a name): its capital is left alone.
        if danglingBeforeNoun.contains(lastKey) { return .join(.none, lead: nil) }
        if danglingConjunctions.contains(lastKey) { return .join(.none, lead: loweredIfFunctionWord(next)) }

        // English: a statement cannot begin with "is", "was", "does" …; as a
        // question the recognizer would have ended it with "?".
        if english, englishFiniteStarts.contains(nextKey), !after.hasSuffix("?") {
            return .join(.none, lead: lowered(next))
        }

        // A lone opening phrase ("First of all." / "Darüber hinaus.").
        let phrase = words(of: before).map(key).joined(separator: " ")
        if english, englishOpeners.contains(phrase), !englishFiniteStarts.contains(nextKey) {
            return .join(.comma, lead: loweredIfFunctionWord(next))
        }
        // German puts the verb straight after such a phrase, with no comma.
        if german, germanOpeners.contains(phrase), germanFiniteVerbs.contains(nextKey) {
            return .join(.none, lead: lowered(next))
        }
        return nil
    }

    /// The joins the app has always made without a model (`SentenceFlow`): a
    /// sentence that starts with a joining word continues the one before.
    static func habitual(before: String, after: String) -> Decision {
        guard endsInPlainStop(before), let next = firstWord(of: after) else { return .keep }
        return continuationStarts.contains(key(next)) ? .join(.none, lead: lowered(next)) : .keep
    }

    /// Whether the stop is worth a model call: something about the two sentences
    /// looks unfinished. A long, complete sentence followed by another is left alone.
    static func looksUnfinished(before: String, after: String) -> Bool {
        guard endsInPlainStop(before) else { return false }
        let beforeWords = words(of: before), afterWords = words(of: after)
        guard let last = beforeWords.last, let next = afterWords.first else { return false }
        if beforeWords.count <= 4 || afterWords.count <= 3 { return true }
        if functionWords.contains(key(last)) { return true }
        if continuationStarts.contains(key(next)) || prepositionStarts.contains(key(next)) { return true }
        if !hasVerb(before) || startsWithVerb(after) { return true }
        return false
    }

    // MARK: The model's answer

    /// How many words of each sentence the model sees: the end of the one before
    /// the stop, the beginning of the one after.
    static let contextWordsBefore = 40
    static let contextWordsAfter = 30

    /// The two pieces the model is asked to join (see `contextWords…`).
    static func modelPieces(before: String, after: String) -> (before: String, after: String) {
        let b = before.split(whereSeparator: \.isWhitespace).suffix(contextWordsBefore).joined(separator: " ")
        let a = after.split(whereSeparator: \.isWhitespace).prefix(contextWordsAfter).joined(separator: " ")
        return (b, a)
    }

    /// Read the model's joined text. It counts only if it is word for word the two
    /// pieces it was given; then the punctuation it put between them is the
    /// decision. Anything else — a changed, missing or extra word — is no answer.
    static func decision(fromModelOutput output: String, before: String, after: String) -> Decision? {
        let beforeWords = words(of: before).map(key), afterWords = words(of: after).map(key)
        let outputWords = wordRanges(of: output)
        guard !beforeWords.isEmpty, !afterWords.isEmpty,
              outputWords.map({ key(String(output[$0])) }) == beforeWords + afterWords else { return nil }
        let lastBefore = outputWords[beforeWords.count - 1]
        let firstAfter = outputWords[beforeWords.count]
        let between = output[lastBefore.upperBound..<firstAfter.lowerBound]
        if between.contains(where: { ".!?…".contains($0) }) { return .keep }
        let lead = String(output[firstAfter])
        if between.contains(where: { ",;:–—".contains($0) }) { return .join(.comma, lead: lead) }
        return .join(.none, lead: lead)
    }

    // MARK: Applying

    /// `sentences` joined back into text with `decisions[i]` applied to the stop
    /// between sentence `i` and `i + 1`.
    static func apply(_ decisions: [Decision], to sentences: [String]) -> String {
        guard var out = sentences.first else { return "" }
        for (index, sentence) in sentences.dropFirst().enumerated() {
            switch index < decisions.count ? decisions[index] : .keep {
            case .keep:
                out += " " + sentence
            case .join(let mark, let lead):
                if out.hasSuffix(".") { out.removeLast() }
                out += (mark == .comma ? ", " : " ") + replacingFirstWord(of: sentence, with: lead)
            }
        }
        return out
    }

    private static func replacingFirstWord(of sentence: String, with lead: String?) -> String {
        guard let lead, let range = wordRanges(of: sentence).first,
              key(lead) == key(String(sentence[range])) else { return sentence }
        return sentence.replacingCharacters(in: range, with: lead)
    }

    // MARK: Words

    /// A word for comparing: lower-case letters and digits only.
    static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func words(of text: String) -> [String] {
        wordRanges(of: text).map { String(text[$0]) }
    }

    /// The runs of letters, digits and in-word apostrophes in `text`.
    static func wordRanges(of text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            let inWord = ch.isLetter || ch.isNumber || ((ch == "'" || ch == "’") && start != nil)
            if inWord, start == nil { start = index }
            if !inWord, let s = start {
                ranges.append(s..<index)
                start = nil
            }
            index = text.index(after: index)
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        // An apostrophe that only closes a quote is not part of the word.
        return ranges.map { range in
            var end = range.upperBound
            while end > range.lowerBound, "'’".contains(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            return range.lowerBound..<end
        }.filter { !$0.isEmpty }
    }

    private static func firstWord(of sentence: String) -> String? { words(of: sentence).first }
    private static func lastWord(of sentence: String) -> String? { words(of: sentence).last }

    /// Lower-case the first letter — except the pronoun "I" and acronyms (API, DMG).
    static func lowered(_ word: String) -> String {
        guard let first = word.first, first.isUppercase else { return word }
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return word }
        let letters = word.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return word }
        return first.lowercased() + word.dropFirst()
    }

    /// Lower-case only a word that is never a name or a (German) noun; anything
    /// else keeps the capital it was heard with.
    static func loweredIfFunctionWord(_ word: String) -> String? {
        functionWords.contains(key(word)) ? lowered(word) : nil
    }

    private static func hasVerb(_ sentence: String) -> Bool {
        lexicalClasses(of: sentence).contains(.verb)
    }

    private static func startsWithVerb(_ sentence: String) -> Bool {
        lexicalClasses(of: sentence).first == .verb
    }

    private static func lexicalClasses(of sentence: String) -> [NLTag] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        var tags: [NLTag] = []
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag { tags.append(tag) }
            return true
        }
        return tags
    }

    // MARK: Word lists (closed classes only — never content words)

    /// English only: German "Ich möchte auch eine." is a whole sentence.
    private static let danglingBeforeNoun: Set<String> = [
        "the", "an", "my", "your", "our", "their",
    ]
    private static let danglingConjunctions: Set<String> = [
        "and", "or", "because", "und", "oder", "weil", "dass",
    ]
    private static let englishFiniteStarts: Set<String> = [
        "is", "are", "was", "were", "has", "does", "did", "would", "could", "should", "must", "might",
    ]
    private static let englishOpeners: Set<String> = [
        "first of all", "second of all", "firstly", "secondly", "thirdly", "also", "however", "furthermore",
        "moreover", "in addition", "additionally", "on top of that", "other than that", "apart from that",
        "besides that", "for example", "for instance", "by the way", "in general", "in other words",
        "on the other hand", "finally", "lastly", "that said",
    ]
    private static let germanOpeners: Set<String> = [
        "darüber hinaus", "außerdem", "des weiteren", "zudem", "übrigens", "abgesehen davon", "zum beispiel",
        "allerdings", "trotzdem", "deshalb", "deswegen", "danach", "zuletzt", "erstens", "zweitens", "drittens",
    ]
    private static let germanFiniteVerbs: Set<String> = [
        "bin", "ist", "sind", "war", "waren", "habe", "hat", "haben", "kann", "können", "muss", "müssen",
        "möchte", "möchten", "will", "wollen", "wird", "werden", "soll", "sollen", "sollte", "sollten",
        "gibt", "finde", "würde", "würden", "wäre", "hätte",
    ]
    private static let continuationStarts: Set<String> = [
        "and", "but", "so", "or", "nor", "because", "which", "that",
        "then", "though", "although", "yet", "plus", "while", "whereas",
    ]
    private static let prepositionStarts: Set<String> = [
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "into", "as", "than",
        "und", "oder", "aber", "weil", "dass", "sondern", "zu", "von", "mit", "für", "auf", "bei", "um",
    ]
    private static let functionWords: Set<String> = [
        // English
        "the", "a", "an", "and", "or", "but", "so", "because", "if", "when", "while", "that", "which", "who",
        "whose", "where", "to", "of", "in", "on", "at", "for", "with", "from", "by", "about", "into", "onto",
        "over", "under", "as", "than", "then", "is", "are", "was", "were", "be", "been", "has", "have", "had",
        "do", "does", "did", "will", "would", "can", "could", "should", "must", "might", "may", "my", "your",
        "our", "their", "his", "her", "its", "this", "these", "those", "we", "you", "they", "he", "she", "it",
        "there", "also", "just", "not",
        // German ("sie" is left out: the polite "Sie" keeps its capital)
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines", "und",
        "oder", "aber", "weil", "dass", "wenn", "ob", "als", "wie", "zu", "von", "mit", "für", "auf", "an",
        "bei", "aus", "nach", "über", "unter", "um", "durch", "gegen", "ohne", "ist", "sind", "war", "waren",
        "bin", "hat", "haben", "habe", "wird", "werden", "kann", "können", "muss", "müssen", "soll", "sollen",
        "möchte", "will", "wollen", "mein", "meine", "dein", "deine", "unser", "unsere", "ich", "wir", "du",
        "ihr", "er", "es", "man", "nicht", "auch", "noch", "dann", "sonst", "sich",
    ]
}

// MARK: - The model

/// Joins two pieces of dictated text; nil when it cannot answer.
protocol PauseStopJudging: Sendable {
    func joined(before: String, after: String) async -> String?
    /// Get ready for the first question (load the model).
    func prewarm()
}

extension PauseStopJudging {
    func prewarm() {}
}

/// The on-device model as the judge. It writes the two pieces as one text; what it
/// wrote is checked word for word by `PauseStops.decision(fromModelOutput:)`, so a
/// wrong answer can cost a missed join and never a changed word.
struct OnDevicePauseStopJudge: PauseStopJudging {
    /// Off with `defaults write <bundle id> PauseStopModelOn -bool NO`.
    static let defaultsKey = "PauseStopModelOn"

    static var isUsable: Bool {
        guard UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static let instructions = """
    You join two fragments of dictated speech. A speech recognizer cut the speech at a pause, put a full stop there and capitalised the next word, even when the sentence was not finished. Write the two fragments as one text with the punctuation and capitalisation that grammar requires at the place where they meet: nothing, a comma, or a full stop. Do not change, add, remove or reorder any word. Keep the language. Output only the text.
    """

    func prewarm() {
        guard Self.isUsable else { return }
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    func joined(before: String, after: String) async -> String? {
        guard Self.isUsable else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let options = GenerationOptions(sampling: .greedy, temperature: 0)
            let response = try await session.respond(to: "Fragment 1: \(before)\nFragment 2: \(after)",
                                                     options: options)
            return response.content
        } catch {
            return nil
        }
    }
}

// MARK: - One dictation's stops

/// Settles the full stops of one dictation while it is being spoken, so the pill
/// can show the flowing text and the paste at the end does not have to wait.
///
/// `noteFinalized` is fed the committed text as it grows and asks the model about
/// the stops that look unfinished, one call at a time. `live` renders what is known
/// so far without waiting; `settled` is the text for the paste and waits a short
/// while for answers still on their way. Answers are remembered by the two
/// sentences they are about, so it does not matter in which order, or how often,
/// the same text arrives (a language switch replays the audio).
final class PauseStopResolver: @unchecked Sendable {
    private let judge: PauseStopJudging?
    private let onChange: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var answers: [String: PauseStops.Decision] = [:]
    private var asking: [String: Task<Void, Never>] = [:]
    /// The newest model call; the next one waits for it, so calls run one by one.
    private var queueTail: Task<Void, Never>?
    /// Stops already looked at (asked or found not worth asking), so a growing text
    /// is not examined again from the top on every partial result.
    private var examined: Set<String> = []
    /// The last `live` rendering, reused while nothing changed.
    private var lastLive: (text: String, languageCode: String?, answers: Int, waiting: Int, result: String)?
    private var warmed = false
    private var cancelled = false

    /// `judge` nil = fixed rules only (no model, or a cleanup style owns the model).
    init(judge: PauseStopJudging?, onChange: (@Sendable () -> Void)? = nil) {
        self.judge = judge
        self.onChange = onChange
    }

    /// The committed text grew: start on the stops that need the model.
    func noteFinalized(_ text: String, languageCode: String?) {
        guard judge != nil else { return }
        let sentences = PauseStops.sentences(of: text)
        guard sentences.count > 1 else { return }
        for index in 0..<(sentences.count - 1) {
            ask(before: sentences[index], after: sentences[index + 1], languageCode: languageCode)
        }
    }

    /// The text with every stop that is already settled applied. Never waits.
    func live(_ text: String, languageCode: String?) -> String {
        let state = lock.withLock { (answers.count, asking.count, lastLive) }
        if let last = state.2, last.text == text, last.languageCode == languageCode,
           last.answers == state.0, last.waiting == state.1 {
            return last.result
        }
        let result = render(text, languageCode: languageCode, final: false)
        lock.withLock { lastLive = (text, languageCode, state.0, state.1, result) }
        return result
    }

    /// The text for the paste: waits up to `budget` seconds in total for answers
    /// that are still on their way, then settles the rest by rule.
    func settled(_ text: String, languageCode: String?, budget: Double) async -> String {
        noteFinalized(text, languageCode: languageCode)
        let pending = lock.withLock { Array(asking.values) }
        if !pending.isEmpty {
            let all = Task { for task in pending { await task.value } }
            _ = await FormatCrossLanguage.value(of: all, within: budget)
        }
        return render(text, languageCode: languageCode, final: true)
    }

    /// Stop asking (the dictation was abandoned).
    func cancel() {
        let tasks = lock.withLock { () -> [Task<Void, Never>] in
            cancelled = true
            let t = Array(asking.values)
            asking.removeAll()
            return t
        }
        for task in tasks { task.cancel() }
    }

    private func render(_ text: String, languageCode: String?, final: Bool) -> String {
        let sentences = PauseStops.sentences(of: text)
        guard sentences.count > 1 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let known = lock.withLock { answers }
        let waiting = lock.withLock { Set(asking.keys) }
        var decisions: [PauseStops.Decision] = []
        for index in 0..<(sentences.count - 1) {
            let before = sentences[index], after = sentences[index + 1]
            if let fixed = PauseStops.certain(before: before, after: after, languageCode: languageCode) {
                decisions.append(fixed)
            } else if let answer = known[Self.memoKey(before, after)] {
                decisions.append(answer)
            } else if !final, waiting.contains(Self.memoKey(before, after)) {
                decisions.append(.keep)   // still being asked: show it as heard for now
            } else {
                decisions.append(PauseStops.habitual(before: before, after: after))
            }
        }
        return PauseStops.apply(decisions, to: sentences)
    }

    private func ask(before: String, after: String, languageCode: String?) {
        guard let judge else { return }
        let memo = Self.memoKey(before, after)
        guard lock.withLock({ examined.insert(memo).inserted }) else { return }
        guard PauseStops.certain(before: before, after: after, languageCode: languageCode) == nil,
              PauseStops.looksUnfinished(before: before, after: after) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, answers[memo] == nil, asking[memo] == nil else { return }
        if !warmed {
            warmed = true
            Task.detached(priority: .utility) { judge.prewarm() }
        }
        let previous = queueTail
        let pieces = PauseStops.modelPieces(before: before, after: after)
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let output = await judge.joined(before: pieces.before, after: pieces.after)
            let decision = output.flatMap {
                PauseStops.decision(fromModelOutput: $0, before: pieces.before, after: pieces.after)
            }
            guard let self else { return }
            self.lock.withLock {
                // No usable answer is remembered too, as "settle it by rule".
                self.answers[memo] = decision ?? PauseStops.habitual(before: before, after: after)
                self.asking[memo] = nil
            }
            self.onChange?()
        }
        asking[memo] = task
        queueTail = task
    }

    private static func memoKey(_ before: String, _ after: String) -> String {
        before + "\u{1F}" + after
    }
}
