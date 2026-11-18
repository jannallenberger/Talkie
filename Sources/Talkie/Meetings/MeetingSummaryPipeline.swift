import Foundation
import NaturalLanguage

// The meeting summary pipeline (W1). Replaces the free-form map-reduce that produced
// near-empty English skeletons for German meetings:
//
//   transcript/segments → units (one per speaker turn, long turns split)
//     → echo-dedup (the mic hears the far end too) → chunks within the model budget
//     → per-chunk STRUCTURED extraction (guided generation, each item cites its line)
//     → grounding filter (the cited line exists and shares content words with the item)
//     → merge + de-dup IN CODE → one short overview call → length-scaled markdown
//     in the meeting's own language.
//
// Everything here except `MeetingSummaryPipeline.run` is pure and unit-tested; the
// model sits behind `MeetingSummaryModel` so the orchestration is tested with a fake.

// MARK: - Language

/// The meeting's dominant language plus the note's section titles in it.
struct SummaryLanguage: Equatable, Sendable {
    /// Base language code ("de", "en", "zh").
    let code: String

    /// English name for the prompt ("German"); the model follows a named language
    /// far more reliably than a code.
    var englishName: String { LanguageDetector.displayName(forLanguageCode: code) ?? "English" }

    /// Languages without spaces between words: word counts and content words differ.
    var isCJK: Bool { ["ja", "zh", "ko"].contains(code) }

    struct Titles: Equatable, Sendable {
        let overview, decisions, actionItems, openQuestions, topics: String
    }

    /// Section titles for the note. These belong to the MEETING's language, not the
    /// UI language, so they are data here rather than `.loc` strings.
    static let titleTable: [String: Titles] = [
        "en": .init(overview: "Overview", decisions: "Decisions", actionItems: "Action items",
                    openQuestions: "Open questions", topics: "Topics"),
        "de": .init(overview: "Überblick", decisions: "Entscheidungen", actionItems: "Aufgaben",
                    openQuestions: "Offene Fragen", topics: "Themen"),
        "fr": .init(overview: "Aperçu", decisions: "Décisions", actionItems: "Actions à mener",
                    openQuestions: "Questions ouvertes", topics: "Sujets"),
        "es": .init(overview: "Resumen", decisions: "Decisiones", actionItems: "Tareas",
                    openQuestions: "Preguntas abiertas", topics: "Temas"),
        "it": .init(overview: "Panoramica", decisions: "Decisioni", actionItems: "Azioni",
                    openQuestions: "Domande aperte", topics: "Argomenti"),
        "nl": .init(overview: "Overzicht", decisions: "Besluiten", actionItems: "Actiepunten",
                    openQuestions: "Open vragen", topics: "Onderwerpen"),
        "pt": .init(overview: "Visão geral", decisions: "Decisões", actionItems: "Ações",
                    openQuestions: "Perguntas em aberto", topics: "Tópicos"),
        "ja": .init(overview: "概要", decisions: "決定事項", actionItems: "アクションアイテム",
                    openQuestions: "未解決の質問", topics: "トピック"),
        "ko": .init(overview: "개요", decisions: "결정 사항", actionItems: "할 일",
                    openQuestions: "미해결 질문", topics: "주제"),
        "zh": .init(overview: "概述", decisions: "决定", actionItems: "待办事项",
                    openQuestions: "待解决问题", topics: "主题"),
    ]

    var titles: Titles { Self.titleTable[code] ?? Self.titleTable["en"]! }

    /// The meeting's language: the recognizer locale when the caller knows it, else
    /// the dominant language of the transcript text (sampled across the whole
    /// meeting, not just its start). Falls back to English for undecidable text.
    static func detect(transcript: String, localeHint: String? = nil) -> SummaryLanguage {
        if let hint = localeHint, let code = LanguageDetector.languageCode(of: hint), !code.isEmpty {
            return SummaryLanguage(code: normalize(code))
        }
        let sample = spreadSample(of: transcript, maxChars: 12_000)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let code = recognizer.dominantLanguage?.rawValue ?? "en"
        return SummaryLanguage(code: normalize(code))
    }

    /// "zh-Hans" → "zh", "pt-BR" → "pt".
    static func normalize(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en").lowercased()
    }

    /// Up to `maxChars` taken from evenly spaced windows across `text`.
    static func spreadSample(of text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let windows = 6
        let size = maxChars / windows
        let step = text.count / windows
        var out: [Substring] = []
        for w in 0..<windows {
            let start = text.index(text.startIndex, offsetBy: w * step)
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(text[start..<end])
        }
        return out.joined(separator: " ")
    }
}

// MARK: - Units and chunks

/// One numbered transcript line the model sees: a speaker turn (or a piece of a long
/// one). `index` is global across the meeting so an extracted item's citation can be
/// checked against the exact text it claims to come from.
struct SummaryUnit: Equatable, Sendable {
    var index: Int
    /// The `Meeting.segments` index this unit came from (nil for unsegmented text).
    var segment: Int?
    var speaker: String?
    var start: Double?
    var end: Double?
    var text: String
}

enum SummaryUnits {
    /// Longest unit text: a single turn can run for minutes; pieces keep each unit
    /// small enough that several fit a chunk and that grounding stays local.
    static let maxUnitChars = 700

    /// Units from the meeting's timed segments when it has them (real speaker
    /// labels and times), else from the rendered transcript's `[mm:ss] Speaker:`
    /// lines, else from plain prose split at sentence ends.
    static func build(transcript: String, segments: [MeetingSegment]?) -> [SummaryUnit] {
        var raw: [(segment: Int?, speaker: String?, start: Double?, end: Double?, text: String)] = []
        if let segments, !segments.isEmpty {
            for (i, s) in segments.enumerated() {
                raw.append((i, s.speaker, s.start, s.end, s.text))
            }
        } else {
            for line in transcript.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                let parsed = parseRenderedLine(t)
                raw.append((nil, parsed.speaker, parsed.start, nil, parsed.text))
            }
        }
        var units: [SummaryUnit] = []
        for r in raw {
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let pieces = text.count > maxUnitChars
                ? MeetingSummarizer.splitLongLine(text, size: maxUnitChars) : [text]
            for piece in pieces where !piece.isEmpty {
                units.append(SummaryUnit(index: units.count, segment: r.segment, speaker: r.speaker,
                                         start: r.start, end: r.end, text: piece))
            }
        }
        return units
    }

    /// `[12:34] Speaker 2: text` → (speaker, seconds, text). Lines without the
    /// prefix come back as plain text.
    static func parseRenderedLine(_ line: String) -> (speaker: String?, start: Double?, text: String) {
        var rest = Substring(line)
        var start: Double?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let stamp = rest[rest.index(after: rest.startIndex)..<close]
            let parts = stamp.split(separator: ":").compactMap { Double($0) }
            if parts.count >= 2 {
                start = parts.reduce(0) { $0 * 60 + $1 }
                rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })
            }
        }
        if let colon = rest.firstIndex(of: ":") {
            let label = rest[..<colon]
            if label.count <= 24, !label.isEmpty, label.split(separator: " ").count <= 3,
               label.first?.isUppercase == true {
                let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return (String(label), start, text)
            }
        }
        return (nil, start, String(rest))
    }

    /// Drop echo duplicates: the mic lane often re-transcribes the far end through
    /// the speakers, so the same words appear twice under two labels. A unit is an
    /// echo when a unit of ANOTHER speaker overlapping it in time carries mostly the
    /// same content words; the longer of the two is kept. Untimed units are kept.
    static func dropEchoes(_ units: [SummaryUnit], language: SummaryLanguage,
                           threshold: Double = 0.5, slack: Double = 20) -> [SummaryUnit] {
        let words = units.map { Set(Grounding.contentWords($0.text, language: language)) }
        var dropped = Set<Int>()
        for i in units.indices where !dropped.contains(i) {
            guard let si = units[i].start, let speakerI = units[i].speaker else { continue }
            let ei = units[i].end ?? si
            for j in units.indices where j > i && !dropped.contains(j) {
                guard let sj = units[j].start, let speakerJ = units[j].speaker, speakerJ != speakerI else { continue }
                let ej = units[j].end ?? sj
                guard sj <= ei + slack, si <= ej + slack else { continue }
                guard Grounding.overlap(words[i], words[j]) >= threshold else { continue }
                if units[i].text.count >= units[j].text.count { dropped.insert(j) } else { dropped.insert(i); break }
            }
        }
        return units.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    /// Whether to show speaker labels to the model (only when more than one spoke).
    static func showsSpeakers(_ units: [SummaryUnit]) -> Bool {
        Set(units.compactMap(\.speaker)).count > 1
    }

    /// One prompt line: `[n] Speaker: text` (speaker only when it adds information).
    static func line(_ u: SummaryUnit, speakers: Bool) -> String {
        if speakers, let s = u.speaker { return "[\(u.index)] \(s): \(u.text)" }
        return "[\(u.index)] \(u.text)"
    }
}

enum SummaryChunker {
    /// Pack consecutive units into chunks whose rendered prompt text stays within
    /// `budgetChars`. Never splits a unit (units are already capped), never drops
    /// one, and preserves order — so every part of the transcript is read once.
    static func chunk(_ units: [SummaryUnit], budgetChars: Int, speakers: Bool) -> [[SummaryUnit]] {
        var chunks: [[SummaryUnit]] = []
        var current: [SummaryUnit] = []
        var size = 0
        for u in units {
            let cost = SummaryUnits.line(u, speakers: speakers).count + 1
            if !current.isEmpty, size + cost > budgetChars {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(u)
            size += cost
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func render(_ chunk: [SummaryUnit], speakers: Bool) -> String {
        chunk.map { SummaryUnits.line($0, speakers: speakers) }.joined(separator: "\n")
    }
}

// MARK: - Extracted items

/// What one chunk's guided generation returns, in plain types (the `@Generable`
/// mirror lives with the on-device model so tests never touch Foundation Models).
struct ChunkNotes: Equatable, Sendable {
    struct Note: Equatable, Sendable { var line: Int; var text: String }
    struct Action: Equatable, Sendable { var line: Int; var owner: String; var task: String; var due: String }
    var topics: [Note] = []
    var decisions: [Note] = []
    var actionItems: [Action] = []
    var openQuestions: [Note] = []
    var keyFacts: [Note] = []
}

/// One grounded, merged item with its source.
struct SummaryItem: Equatable, Sendable {
    var text: String
    var unit: Int
    var segment: Int?
    var start: Double?
    var owner: String? = nil
    var due: String? = nil
}

struct MergedNotes: Equatable, Sendable {
    var topics: [SummaryItem] = []
    var decisions: [SummaryItem] = []
    var actionItems: [SummaryItem] = []
    var openQuestions: [SummaryItem] = []
    var keyFacts: [SummaryItem] = []
    var isEmpty: Bool {
        topics.isEmpty && decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty && keyFacts.isEmpty
    }
}

// MARK: - Grounding

enum Grounding {
    private static let stopwords: Set<String> = [
        // German
        "aber", "alle", "also", "auch", "dann", "dass", "denn", "dein", "deine", "diese", "dieser",
        "dieses", "doch", "eine", "einem", "einen", "einer", "eines", "etwas", "euch", "habe", "haben",
        "hast", "hatte", "immer", "jetzt", "kann", "kannst", "keine", "mach", "machen", "mein", "meine",
        "mich", "mir", "mit", "muss", "nach", "nicht", "noch", "nur", "oder", "schon", "sein", "sich",
        "sind", "soll", "über", "und", "uns", "unser", "viel", "wenn", "werden", "wird", "wieder",
        "wir", "wollen", "wäre", "würde", "weil", "halt", "eben", "einfach", "genau", "irgendwie",
        "ganz", "gerade", "mal", "okay", "dass", "sollte", "sollen", "hier", "dort", "beim", "einmal",
        // English
        "about", "also", "been", "being", "could", "does", "doing", "from", "have", "having", "into",
        "just", "like", "more", "much", "only", "other", "over", "should", "some", "such", "than",
        "that", "their", "them", "then", "there", "these", "they", "this", "those", "very", "want",
        "were", "what", "when", "where", "which", "will", "with", "would", "your", "yeah", "really",
        "going", "thing", "things", "know", "think",
        // filler the model writes about any meeting
        "meeting", "besprechung", "discussed", "discussion", "besprochen", "diskutiert", "speaker",
        "sprecher", "team",
    ]

    /// Lower-cased content words: letters/digits, at least 4 letters (or any token
    /// with a digit — numbers are the facts worth keeping), minus stopwords, cut to
    /// a 6-letter stem so inflections still match ("Termine" ~ "Termin"). CJK text
    /// has no spaces, so it is compared as character bigrams instead.
    static func contentWords(_ text: String, language: SummaryLanguage) -> [String] {
        let lower = text.lowercased()
        if language.isCJK {
            let chars = lower.filter { $0.isLetter || $0.isNumber }.map(String.init)
            guard chars.count >= 2 else { return chars }
            return (0..<(chars.count - 1)).map { chars[$0] + chars[$0 + 1] }
        }
        var out: [String] = []
        for token in lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let t = String(token)
            let hasDigit = t.contains(where: \.isNumber)
            guard hasDigit || t.count >= 4, !stopwords.contains(t) else { continue }
            out.append(hasDigit ? t : String(t.prefix(6)))
        }
        return out
    }

    /// Shared fraction relative to the smaller set (an echo is usually a subset).
    static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let smaller = min(a.count, b.count)
        guard smaller > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(smaller)
    }

    /// Content words the item must share with its source: one for a short item, two
    /// once it has four or more content words.
    static func requiredShared(itemWords: Int) -> Int { itemWords >= 4 ? 2 : 1 }

    /// Whether `text`, citing unit `line`, is supported by the transcript. The cited
    /// unit must exist in this chunk; the item must share content words with it or
    /// an immediate neighbour (the model is often one line off). An item with no
    /// content words at all ("Ja.") is never kept.
    static func isGrounded(_ text: String, line: Int, in chunk: [SummaryUnit],
                           language: SummaryLanguage) -> Bool {
        guard let pos = chunk.firstIndex(where: { $0.index == line }) else { return false }
        let item = Set(contentWords(text, language: language))
        guard !item.isEmpty else { return false }
        let lo = max(chunk.startIndex, pos - 1), hi = min(chunk.endIndex - 1, pos + 1)
        var source = Set<String>()
        for k in lo...hi { source.formUnion(contentWords(chunk[k].text, language: language)) }
        return item.intersection(source).count >= requiredShared(itemWords: item.count)
    }

    /// The owner to show: a name the chunk actually contains, or a speaker label.
    /// A name the model made up is replaced by the cited line's speaker label (when
    /// the meeting has more than one speaker) or dropped.
    static func resolveOwner(_ owner: String, line: Int, in chunk: [SummaryUnit],
                             speakers: Bool) -> String? {
        let o = owner.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        let source = chunk.first(where: { $0.index == line })
        let fallback = speakers ? source?.speaker : nil
        guard !o.isEmpty, !isPlaceholder(o) else { return fallback }
        let labels = Set(chunk.compactMap(\.speaker).map { $0.lowercased() })
        if labels.contains(o.lowercased()) { return o }
        let haystack = chunk.map(\.text).joined(separator: " ").lowercased()
        let nameParts = o.lowercased().split(separator: " ").filter { $0.count >= 2 }
        if !nameParts.isEmpty, nameParts.allSatisfy({ haystack.contains($0) }) { return o }
        return fallback
    }

    private static func isPlaceholder(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["unknown", "unbekannt", "none", "keiner", "keine", "n/a", "-", "niemand", "nobody",
                "unspecified", "nicht genannt", "not mentioned", "team", "everyone", "alle",
                // pronouns and address words are not names
                "ich", "du", "er", "sie", "es", "wir", "ihr", "man", "jemand", "i", "you", "he", "she",
                "they", "we", "someone", "digga", "bro", "alter", "dude"].contains(l)
    }

    /// Items the model writes when it has nothing ("no decisions were made").
    static func isFiller(_ text: String) -> Bool {
        let l = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if l.isEmpty || l.count < 3 { return true }
        let markers = [
            "no decision", "no action", "none", "not mentioned", "no specific", "nothing",
            "keine entscheid", "keine aufgabe", "keine action", "nicht erwähnt", "keine konkreten",
            "nichts", "n/a", "unclear", "unverständlich", "unintelligible", "not specified",
            "nicht angegeben", "nicht genannt",
        ]
        return markers.contains(where: { l.hasPrefix($0) || l == $0 })
            || l.hasPrefix("no ") && l.count < 30
            || l.hasPrefix("keine ") && l.count < 30
    }
}

// MARK: - Item shape

/// What kind of entry an extracted text is, for the shape checks below.
enum SummaryItemKind: Sendable { case topic, decision, action, question, fact }

enum SummaryItemFilter {
    private static let discourseOpeners: Set<String> = [
        "ja", "nein", "und", "also", "okay", "ok", "aber", "genau", "naja", "äh", "ähm", "hm", "ach",
        "yeah", "yes", "no", "so", "well", "oh", "um", "uh", "digga", "bro", "alter", "warte",
    ]
    private static let firstSecondPerson: Set<String> = [
        "ich", "du", "dir", "dich", "mich", "mir", "mein", "meine", "dein", "deine",
        "i", "you", "me", "my", "your",
    ]

    /// Whether an extracted entry reads like a note rather than a copied snippet of
    /// conversation: not opening with a discourse word ("Ja, …", "Und dann …"), no
    /// first/second-person speech ("ich habe …" is a quote, not a note), bounded
    /// length (topics are labels), a question mark only on open questions, and in
    /// the meeting's language once it is long enough to tell.
    static func isUsable(_ text: String, kind: SummaryItemKind, language: SummaryLanguage) -> Bool {
        let tokens = text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        guard let first = tokens.first else { return false }
        if !language.isCJK {
            if discourseOpeners.contains(first) { return false }
            if tokens.contains(where: firstSecondPerson.contains) { return false }
            let limit: Int
            switch kind {
            case .topic: limit = 8
            case .question: limit = 18
            default: limit = 20
            }
            if tokens.count > limit { return false }
        }
        let asks = text.contains("?") || text.contains("？")
        if kind == .question { if !asks { return false } } else if asks { return false }
        if tokens.count >= 5, let detected = LanguageDetector.dominantLanguageCode(text),
           SummaryLanguage.normalize(detected) != language.code {
            return false
        }
        return true
    }
}

// MARK: - Failure detection

enum SummaryFailure {
    /// A refusal or apology instead of a summary, in English or German (the model
    /// answers in either, regardless of the asked language). Reuses the cleanup
    /// engine's refusal register, plus the shorter apologies seen in real notes.
    static func isRefusalOrApology(_ text: String) -> Bool {
        if CleanupEngine.isRefusal(text) { return true }
        let l = text.lowercased()
        let markers = [
            "i'm sorry", "i am sorry", "i apologize", "i cannot", "i can't", "i'm unable", "i am unable",
            "as an ai", "unable to summarize", "unable to provide", "cannot provide a summary",
            "es tut mir leid", "entschuldigung, aber", "ich kann keine", "ich kann nicht", "ich bin nicht in der lage",
            "leider kann ich", "als ki", "the transcript is unclear", "the transcript does not contain",
            "das transkript enthält keine", "please provide",
        ]
        return markers.contains(where: { l.contains($0) })
    }

    /// The "answering back" guard for the short-meeting sentence: a reply to the
    /// transcript (or a made-up story) brings mostly words the speakers never said.
    /// Stems, not exact words, so a summary's inflections still count as said.
    static func isMostlyInvented(_ text: String, language: SummaryLanguage, source: String,
                                 threshold: Double = 0.7) -> Bool {
        let out = Grounding.contentWords(text, language: language)
        guard out.count >= 4 else { return false }
        let src = Set(Grounding.contentWords(source, language: language))
        let novel = out.filter { !src.contains($0) }.count
        return Double(novel) / Double(out.count) >= threshold
    }

    /// Keep only the sentences that share content words with `source` (the merged
    /// notes): the overview call may not add a claim that no note supports.
    static func groundedSentences(_ text: String, language: SummaryLanguage, source: String) -> String? {
        let src = Set(Grounding.contentWords(source, language: language))
        var kept: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            guard let sentence = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            let words = Grounding.contentWords(sentence, language: language)
            let shared = words.filter { src.contains($0) }.count
            // At least half of a sentence's content words must come from the notes.
            if !words.isEmpty, Double(shared) / Double(words.count) >= 0.5 { kept.append(sentence) }
        }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    /// Whether free text is acceptable as (part of) the saved summary: not a
    /// refusal, in the meeting's language (when long enough to tell), and grounded
    /// in `source` by at least one shared content word.
    static func acceptsProse(_ text: String, language: SummaryLanguage, source: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isRefusalOrApology(t) else { return false }
        if let detected = LanguageDetector.dominantLanguageCode(t), t.split(separator: " ").count >= 8,
           SummaryLanguage.normalize(detected) != language.code {
            return false
        }
        let a = Set(Grounding.contentWords(t, language: language))
        let b = Set(Grounding.contentWords(source, language: language))
        return !a.intersection(b).isEmpty
    }
}

// MARK: - Merge

enum SummaryMerger {
    /// Two items say the same thing when most of the smaller one's content words
    /// are in the other.
    static func isDuplicate(_ a: String, _ b: String, language: SummaryLanguage) -> Bool {
        let wa = Set(Grounding.contentWords(a, language: language))
        let wb = Set(Grounding.contentWords(b, language: language))
        if wa.isEmpty || wb.isEmpty { return a.lowercased() == b.lowercased() }
        return Grounding.overlap(wa, wb) >= 0.6
    }

    /// Ground every chunk's items, then merge across chunks in chronological order,
    /// de-duplicating each category in code (the first mention wins; a later
    /// duplicate may fill in a missing owner/due date). Items whose cited line is
    /// not in their own chunk, or that share no content with it, are dropped.
    static func merge(_ results: [(chunk: [SummaryUnit], notes: ChunkNotes)],
                      language: SummaryLanguage, speakers: Bool) -> MergedNotes {
        var merged = MergedNotes()
        func add(_ item: SummaryItem, to list: inout [SummaryItem]) {
            if let i = list.firstIndex(where: { isDuplicate($0.text, item.text, language: language) }) {
                if list[i].owner == nil { list[i].owner = item.owner }
                if list[i].due == nil { list[i].due = item.due }
                return
            }
            list.append(item)
        }
        for (chunk, notes) in results {
            func grounded(_ n: ChunkNotes.Note, _ kind: SummaryItemKind) -> SummaryItem? {
                let text = clean(n.text)
                guard !Grounding.isFiller(text), !SummaryFailure.isRefusalOrApology(text),
                      SummaryItemFilter.isUsable(text, kind: kind, language: language),
                      Grounding.isGrounded(text, line: n.line, in: chunk, language: language),
                      let u = chunk.first(where: { $0.index == n.line }) else { return nil }
                return SummaryItem(text: text, unit: u.index, segment: u.segment, start: u.start)
            }
            for n in notes.topics { if let i = grounded(n, .topic) { add(i, to: &merged.topics) } }
            for n in notes.decisions { if let i = grounded(n, .decision) { add(i, to: &merged.decisions) } }
            for n in notes.openQuestions { if let i = grounded(n, .question) { add(i, to: &merged.openQuestions) } }
            for n in notes.keyFacts { if let i = grounded(n, .fact) { add(i, to: &merged.keyFacts) } }
            for a in notes.actionItems {
                guard var item = grounded(.init(line: a.line, text: a.task), .action) else { continue }
                item.owner = Grounding.resolveOwner(a.owner, line: a.line, in: chunk, speakers: speakers)
                let due = clean(a.due)
                item.due = due.isEmpty || Grounding.isFiller(due) ? nil : due
                add(item, to: &merged.actionItems)
            }
        }
        // One statement belongs to one section: a decision is not also repeated as
        // an action item or an open question.
        func notIn(_ others: [SummaryItem]) -> (SummaryItem) -> Bool {
            { item in !others.contains { isDuplicate($0.text, item.text, language: language) } }
        }
        merged.actionItems = merged.actionItems.filter(notIn(merged.decisions))
        merged.openQuestions = merged.openQuestions.filter(notIn(merged.decisions + merged.actionItems))
        return merged
    }

    /// Trim bullets, quotes and a trailing line citation the model sometimes copies.
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"\s*\[\d+\]\s*$"#, options: .regularExpression) { t.removeSubrange(r) }
        while let f = t.first, "-*•–\"“„".contains(f) { t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }
        if let r = t.range(of: #"^\[\d+\]\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        while let l = t.last, "\"”".contains(l) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Rendering

enum SummaryRenderer {
    /// Below this many transcript words the note is one or two sentences, no sections.
    static let shortMeetingWords = 150

    static func wordCount(_ text: String, language: SummaryLanguage) -> Int {
        if language.isCJK {
            // ~2 characters per word is the usual rule of thumb for CJK.
            return text.filter { $0.isLetter || $0.isNumber }.count / 2
        }
        return text.split(whereSeparator: \.isWhitespace).count
    }

    static func isShort(words: Int) -> Bool { words < shortMeetingWords }

    /// Per-section caps that grow with the meeting, so a two-hour meeting gets a
    /// longer note than a ten-minute one instead of the same 50 words.
    static func caps(words: Int) -> (topics: Int, decisions: Int, actions: Int, questions: Int) {
        func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, v)) }
        return (topics: clamp(words / 350, 3, 16),
                decisions: clamp(words / 600, 3, 12),
                actions: clamp(words / 600, 3, 12),
                questions: clamp(words / 1200, 2, 8))
    }

    /// Keep at most `cap` items, evenly spread over the meeting (chronological),
    /// so the note covers the whole meeting rather than only its start.
    static func spread(_ items: [SummaryItem], cap: Int) -> [SummaryItem] {
        guard items.count > cap, cap > 0 else { return items }
        let step = Double(items.count) / Double(cap)
        return (0..<cap).map { items[min(items.count - 1, Int((Double($0) * step).rounded(.down)))] }
    }

    /// The note: overview paragraph first (no heading, so it reads as the summary's
    /// lead and `ActionItemSource.overviewLines` still finds it), then the bold
    /// sections in a fixed order. Empty sections are omitted entirely.
    static func render(overview: String?, notes: MergedNotes, language: SummaryLanguage,
                       words: Int) -> String? {
        let t = language.titles
        let cap = caps(words: words)
        var blocks: [String] = []
        if let o = overview?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty { blocks.append(o) }
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            blocks.append("**\(title):**\n" + lines.map { "- " + $0 }.joined(separator: "\n"))
        }
        section(t.decisions, spread(notes.decisions, cap: cap.decisions).map(\.text))
        section(t.actionItems, spread(notes.actionItems, cap: cap.actions).map { item in
            var s = item.text
            if let owner = item.owner, !owner.isEmpty { s = "\(owner): " + s }
            if let due = item.due, !due.isEmpty { s += " (\(due))" }
            return s
        })
        section(t.openQuestions, spread(notes.openQuestions, cap: cap.questions).map(\.text))
        section(t.topics, spread(notes.topics, cap: cap.topics).map { item in
            if let s = item.start { return "[\(MeetingTranscriptRenderer.timecode(s))] \(item.text)" }
            return item.text
        })
        // Only an overview with nothing else is fine; nothing at all is a failure.
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// The overview's input: the merged items as plain bullets, bounded.
    static func overviewInput(_ notes: MergedNotes, maxChars: Int = 2400) -> String {
        var lines: [String] = []
        lines += notes.topics.map { "- " + $0.text }
        lines += notes.decisions.map { "- " + $0.text }
        lines += notes.keyFacts.map { "- " + $0.text }
        lines += notes.actionItems.map { "- " + $0.text }
        lines += notes.openQuestions.map { "- " + $0.text }
        var out = ""
        for l in lines {
            if out.count + l.count + 1 > maxChars { break }
            out += (out.isEmpty ? "" : "\n") + l
        }
        return out
    }

    /// Sentences the overview should have for this meeting length (2-4).
    static func overviewSentences(words: Int) -> Int { words < 1500 ? 2 : (words < 6000 ? 3 : 4) }
}

// MARK: - Prompts

enum SummaryPrompts {
    static func extraction(_ language: SummaryLanguage) -> String {
        if language.code == "de" {
            return """
            Du liest einen Ausschnitt aus dem Transkript einer Besprechung. Jede Zeile beginnt mit ihrer Nummer [n]. \
            Das Transkript stammt aus einer Spracherkennung und enthält Fehler. \
            Notiere auf Deutsch, knapp und sachlich, nur was im Ausschnitt tatsächlich gesagt wird: \
            Themen, Entscheidungen, Aufgaben (wer, was, bis wann – nur wenn gesagt), offene Fragen \
            und wichtige Fakten (Namen, Zahlen, Termine). Gib zu jedem Eintrag die Nummer der Zeile an, \
            aus der er stammt. Übersetze nicht. Erfinde keine Namen: Ist kein Name genannt, \
            nimm die Sprecherbezeichnung der Zeile als Verantwortlichen. Unverständliche Stellen \
            überspringst du, statt zu raten. Gibt es zu einer Kategorie nichts, lass die Liste leer.
            """
        }
        let name = language.englishName
        return """
        You read an excerpt of a meeting transcript. Every line starts with its number [n]. \
        The transcript comes from speech recognition and contains errors. \
        Write in \(name), briefly and factually, only what is actually said in the excerpt: \
        topics, decisions, action items (who, what, by when — only if said), open questions, \
        and key facts (names, numbers, dates). Give each entry the number of the line it comes from. \
        Do not translate. Never invent names: when no name is said, use the line's speaker label \
        as the owner. Skip unintelligible passages instead of guessing. \
        If a category has nothing, leave its list empty.
        """
    }

    static func overview(_ language: SummaryLanguage, sentences: Int) -> String {
        if language.code == "de" {
            return """
            Du schreibst den Überblick einer Besprechungsnotiz auf Deutsch: genau \(sentences) kurze Sätze \
            als Fließtext, nur aus den folgenden Stichpunkten. Nichts hinzufügen, keine Überschrift, \
            keine Aufzählung, keine Entschuldigung, keine Rückfragen.
            """
        }
        return """
        You write the overview of a meeting note in \(language.englishName): exactly \(sentences) short \
        sentences of prose, using only the following notes. Add nothing, no heading, no list, \
        no apology, no questions.
        """
    }

    static func shortMeeting(_ language: SummaryLanguage) -> String {
        if language.code == "de" {
            return """
            Fasse dieses kurze Gesprächstranskript in ein oder zwei Sätzen auf Deutsch zusammen. \
            Nur was gesagt wird; nichts hinzufügen, nicht antworten, keine Überschrift. \
            Das Transkript stammt aus einer Spracherkennung und enthält Fehler.
            """
        }
        return """
        Summarize this short conversation transcript in one or two sentences in \(language.englishName). \
        Only what is said; add nothing, do not reply to it, no heading. \
        The transcript comes from speech recognition and contains errors.
        """
    }
}

// MARK: - Model seam

enum SummaryModelError: Error, Equatable {
    /// The input did not fit the context window: split and retry.
    case contextOverflow
    /// Guardrail / refusal: not retried.
    case refused
    case unavailable
    case other(String)
}

/// The on-device model, behind a seam so the pipeline is tested with a fake.
protocol MeetingSummaryModel: Sendable {
    var isAvailable: Bool { get }
    /// Structured extraction of one chunk (guided generation).
    func extract(instructions: String, prompt: String) async throws -> ChunkNotes
    /// One short free-text generation.
    func write(instructions: String, prompt: String, maxTokens: Int) async throws -> String
    /// Tokens `text` costs, or nil when the OS can't count them.
    func tokenCount(_ text: String) async -> Int?
}

// MARK: - Pipeline

struct MeetingSummaryResult: Sendable {
    /// The markdown to save, or nil: nothing usable came back (the note keeps its
    /// transcript, the summary stays empty and Regenerate is offered).
    var markdown: String?
    var language: SummaryLanguage
    var merged: MergedNotes
    var chunks: Int
    var failedChunks: Int
    /// The merged items as plain text, for the downstream graph extractor.
    var condensed: String
}

struct MeetingSummaryPipeline: Sendable {
    let model: any MeetingSummaryModel
    /// Characters of numbered transcript per extraction call. Measured on real
    /// meetings: German transcript text runs 3.4-3.8 chars/token on the on-device
    /// tokenizer; the 4096-token window is shared with the instructions (~170), the
    /// guided-generation schema (~500) and the output cap (900). 3000 chars (~900
    /// tokens) stays far inside that and keeps chunks small enough that the small
    /// model still extracts from all of it rather than from its first lines.
    var chunkBudgetChars = 3000
    /// Token ceiling for one chunk's prompt, checked when the OS can count tokens.
    var chunkBudgetTokens = 1800
    var extractMaxTokens = 900
    /// Wall-clock bound for one model call, so a wedged call can't keep "Writing
    /// the summary…" up forever; the chunk counts as failed and the rest go on.
    var perCallSeconds: Double = 90
    /// Whole-run bound; once exceeded, the remaining chunks are skipped and what
    /// was gathered so far is still used.
    var totalSeconds: Double = 25 * 60

    func run(transcript: String, segments: [MeetingSegment]?, localeHint: String? = nil) async -> MeetingSummaryResult {
        let language = SummaryLanguage.detect(transcript: transcript, localeHint: localeHint)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = MeetingSummaryResult(markdown: nil, language: language, merged: MergedNotes(),
                                          chunks: 0, failedChunks: 0, condensed: "")
        guard model.isAvailable, !trimmed.isEmpty else { return result }
        let words = SummaryRenderer.wordCount(trimmed, language: language)

        if SummaryRenderer.isShort(words: words) {
            result.chunks = 1
            let text = SummaryUnits.build(transcript: trimmed, segments: segments).map(\.text).joined(separator: " ")
            let out = try? await bounded {
                try await model.write(instructions: SummaryPrompts.shortMeeting(language),
                                      prompt: text, maxTokens: 160)
            }
            if let out, SummaryFailure.acceptsProse(out, language: language, source: text),
               !SummaryFailure.isMostlyInvented(out, language: language, source: text) {
                result.markdown = out.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                result.failedChunks = 1
            }
            result.condensed = text
            return result
        }

        var units = SummaryUnits.build(transcript: trimmed, segments: segments)
        units = SummaryUnits.dropEchoes(units, language: language)
        let speakers = SummaryUnits.showsSpeakers(units)
        let chunks = SummaryChunker.chunk(units, budgetChars: chunkBudgetChars, speakers: speakers)
        result.chunks = chunks.count
        let deadline = Date().addingTimeInterval(totalSeconds)
        var gathered: [(chunk: [SummaryUnit], notes: ChunkNotes)] = []
        for chunk in chunks {
            guard Date() < deadline else { result.failedChunks += 1; continue }
            let pieces = await extractAdaptive(chunk, language: language, speakers: speakers, depth: 0)
            if pieces.isEmpty { result.failedChunks += 1 }
            gathered += pieces
        }
        let merged = SummaryMerger.merge(gathered, language: language, speakers: speakers)
        result.merged = merged
        result.condensed = SummaryRenderer.overviewInput(merged, maxChars: MeetingSummarizer.singlePassCharBudget)
        guard !merged.isEmpty else { return result }

        var overview: String?
        let input = SummaryRenderer.overviewInput(merged)
        if Date() < deadline, !input.isEmpty {
            let sentences = SummaryRenderer.overviewSentences(words: words)
            let out = try? await bounded {
                try await model.write(instructions: SummaryPrompts.overview(language, sentences: sentences),
                                      prompt: input, maxTokens: 300)
            }
            if let out, SummaryFailure.acceptsProse(out, language: language, source: input) {
                overview = SummaryFailure.groundedSentences(out, language: language, source: input)
            }
        }
        result.markdown = SummaryRenderer.render(overview: overview, notes: merged, language: language, words: words)
        return result
    }

    /// Extract one chunk; when it doesn't fit (counted tokens over budget, or the
    /// model reports a context overflow) split it in half and try each half, at
    /// most twice deep. Returns the successful pieces only.
    func extractAdaptive(_ chunk: [SummaryUnit], language: SummaryLanguage, speakers: Bool,
                         depth: Int) async -> [(chunk: [SummaryUnit], notes: ChunkNotes)] {
        let prompt = SummaryChunker.render(chunk, speakers: speakers)
        let instructions = SummaryPrompts.extraction(language)
        var overflow = false
        if let tokens = await model.tokenCount(prompt), tokens > chunkBudgetTokens { overflow = true }
        if !overflow {
            do {
                let notes = try await bounded { try await model.extract(instructions: instructions, prompt: prompt) }
                return [(chunk, notes)]
            } catch SummaryModelError.contextOverflow {
                overflow = true
            } catch {
                return []
            }
        }
        guard overflow, chunk.count > 1, depth < 2 else { return [] }
        let mid = chunk.count / 2
        let first = await extractAdaptive(Array(chunk[..<mid]), language: language, speakers: speakers, depth: depth + 1)
        let second = await extractAdaptive(Array(chunk[mid...]), language: language, speakers: speakers, depth: depth + 1)
        return first + second
    }

    private struct Timeout: Error {}

    /// Run one model call under `perCallSeconds`. A timeout abandons the call (see
    /// `TimeBox`) and throws, so the caller treats it as a failed chunk.
    private func bounded<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let outcome: Result<T, Error>? = await TimeBox.run(seconds: perCallSeconds) {
            do { return .success(try await op()) } catch { return .failure(error) }
        }
        guard let outcome else { throw Timeout() }
        return try outcome.get()
    }
}
