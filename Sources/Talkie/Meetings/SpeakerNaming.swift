import Foundation
import NaturalLanguage

// Speaker names (W2): turn "Speaker 2" into "Anna" — but only when it is clear.
//
// Names are stored per meeting as `label -> SpeakerName` (`Meeting.speakerNames`);
// the transcript, segments and summary keep their raw labels and the name is applied
// at presentation time (`SpeakerNames.apply…`), so an older build, a transcript edit
// or a cleared name never leaves a half-renamed meeting behind.
//
// Three sources, in precedence order manual > voice > conversation:
//   • manual        — the user typed it in the speaker popover.
//   • voice         — a voice the user explicitly asked Talkie to recognise
//                     (`KnownVoiceStore`) matched this speaker strictly.
//   • conversation  — strict, agreeing evidence from what was said
//                     (`ConversationNaming`). No biometrics.
// "Me" is never renamed.

/// One speaker's name in one meeting, with where it came from.
struct SpeakerName: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable, Comparable {
        case conversation, voice, manual
        /// Higher wins.
        var rank: Int { switch self { case .conversation: 0; case .voice: 1; case .manual: 2 } }
        static func < (a: Source, b: Source) -> Bool { a.rank < b.rank }
    }
    var name: String
    var source: Source
}

enum SpeakerNames {
    /// A label that may carry a name: anything but "Me" (and not empty).
    static func isNameable(_ label: String) -> Bool {
        label != SpeakerLabels.me && !label.isEmpty
    }

    /// Comparison key for a name: case-, diacritic- and whitespace-insensitive.
    static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func clean(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Precedence + one-to-one

    /// The automatic names for a meeting combined with what it already has. Manual
    /// entries always survive; otherwise voice beats conversation for the same label.
    /// Then one name per person: when two labels end up with the same name, the
    /// higher-precedence one keeps it and the other loses its name (stays "Speaker N").
    /// "Me" never gets a name.
    static func merge(existing: [String: SpeakerName]?, voice: [String: String],
                      conversation: [String: String]) -> [String: SpeakerName] {
        var byLabel: [String: SpeakerName] = [:]
        func offer(_ label: String, _ name: String, _ source: SpeakerName.Source) {
            let n = clean(name)
            guard isNameable(label), !n.isEmpty else { return }
            if let have = byLabel[label], have.source >= source { return }
            byLabel[label] = SpeakerName(name: n, source: source)
        }
        for (l, n) in conversation { offer(l, n, .conversation) }
        for (l, n) in voice { offer(l, n, .voice) }
        for (l, n) in existing ?? [:] { offer(l, n.name, n.source) }
        return oneToOne(byLabel)
    }

    /// Set (or, with an empty/nil name, clear) the user's own name for `label`. A
    /// manual name takes the name away from any other label that had it automatically;
    /// another label's MANUAL entry with the same name is left alone (the user's call).
    static func settingManual(_ name: String?, for label: String,
                              in names: [String: SpeakerName]?) -> [String: SpeakerName] {
        var out = names ?? [:]
        guard isNameable(label) else { return out }
        let n = clean(name ?? "")
        if n.isEmpty {
            out[label] = nil
            return out
        }
        out[label] = SpeakerName(name: n, source: .manual)
        let k = key(n)
        for (l, v) in out where l != label && v.source != .manual && key(v.name) == k { out[l] = nil }
        return out
    }

    /// Drop lower-precedence duplicates of the same name. Ties between two equal
    /// automatic sources drop BOTH (no guessing); manual ties are kept (user's choice).
    static func oneToOne(_ names: [String: SpeakerName]) -> [String: SpeakerName] {
        var groups: [String: [String]] = [:]
        for (l, v) in names { groups[key(v.name), default: []].append(l) }
        var out = names
        for (_, labels) in groups where labels.count > 1 {
            let best = labels.map { names[$0]!.source }.max()!
            let winners = labels.filter { names[$0]!.source == best }
            for l in labels where names[l]!.source < best { out[l] = nil }
            if best != .manual, winners.count > 1 { for l in winners { out[l] = nil } }
        }
        return out
    }

    // MARK: Presentation

    /// The name to show for a stored label, or nil when it has none.
    static func name(for label: String, in names: [String: SpeakerName]?) -> String? {
        guard isNameable(label), let n = names?[label]?.name, !n.isEmpty else { return nil }
        return n
    }

    /// `[mm:ss] Speaker 2: …` -> `[mm:ss] Anna: …` for every named label, at line starts
    /// only (the text people said is never touched). Used for exports, copy and MCP.
    static func applyToTranscript(_ transcript: String, names: [String: SpeakerName]?) -> String {
        guard let names, !names.isEmpty else { return transcript }
        var out: [Substring] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(Substring(renameLinePrefix(String(line), names: names)))
        }
        return out.joined(separator: "\n")
    }

    private static func renameLinePrefix(_ line: String, names: [String: SpeakerName]) -> String {
        var rest = Substring(line)
        var head = ""
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let stamp = rest[rest.index(after: rest.startIndex)..<close]
            if !stamp.isEmpty, stamp.allSatisfy({ $0.isNumber || $0 == ":" }) {
                head = String(rest[...close])
                rest = rest[rest.index(after: close)...]
                while rest.first == " " { head.append(" "); rest = rest.dropFirst() }
            }
        }
        guard let colon = rest.firstIndex(of: ":") else { return line }
        let label = String(rest[..<colon])
        guard let name = name(for: label, in: names) else { return line }
        return head + name + String(rest[colon...])
    }

    /// The summary with names: every "Speaker N" (whole token) is replaced, and a
    /// named "Them" only where it is an action-item owner (`- Them: …`), since "Them"
    /// is also an ordinary English word.
    static func applyToSummary(_ summary: String, names: [String: SpeakerName]?) -> String {
        guard let names, !names.isEmpty, !summary.isEmpty else { return summary }
        var text = summary
        for (label, v) in names where isNameable(label) && !v.name.isEmpty {
            let escapedName = NSRegularExpression.escapedTemplate(for: v.name)
            if SpeakerPresentation.speakerNumber(label) != nil {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: label) + "(?![\\p{L}\\p{N}])"
                text = replace(pattern, in: text, with: escapedName, options: [])
            } else {
                let pattern = "^(\\s*[-*]\\s+)" + NSRegularExpression.escapedPattern(for: label) + ":"
                text = replace(pattern, in: text, with: "$1" + escapedName + ":", options: [.anchorsMatchLines])
            }
        }
        return text
    }

    /// Participants with names applied (order kept, duplicates removed).
    static func applyToParticipants(_ participants: [String], names: [String: SpeakerName]?) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for p in participants {
            let shown = name(for: p, in: names) ?? p
            if seen.insert(shown).inserted { out.append(shown) }
        }
        return out
    }

    private static func replace(_ pattern: String, in text: String, with template: String,
                                options: NSRegularExpression.Options) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

extension Meeting {
    /// The transcript as people should read it outside the app's turn view: speaker
    /// line prefixes replaced by their names. The stored `transcript` is unchanged.
    var namedTranscript: String { SpeakerNames.applyToTranscript(transcript, names: speakerNames) }
    var namedSummary: String { SpeakerNames.applyToSummary(summary, names: speakerNames) }
    var namedParticipants: [String] { SpeakerNames.applyToParticipants(participants, names: speakerNames) }
}

// MARK: - Name gate

/// Whether a capitalised word in context is a person's name. Injected so tests are
/// deterministic; the app uses Apple's on-device NaturalLanguage name tagger.
protocol PersonNameTagging: Sendable {
    /// True when every word of `range` in `sentence` is tagged as a personal name.
    func isPersonalName(_ range: Range<String.Index>, in sentence: String) -> Bool
}

struct NLPersonNameTagger: PersonNameTagging {
    func isPersonalName(_ range: Range<String.Index>, in sentence: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sentence
        var sawWord = false, allNames = true
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            sawWord = true
            if tag != .personalName { allNames = false; return false }
            return true
        }
        return sawWord && allNames
    }
}

/// Accepts a candidate only when it is a genuine personal name: it matches a calendar
/// attendee of this meeting (first, last or full name, tolerant of a small recognition
/// error) OR the name tagger marks it as a personal name in its sentence. German
/// capitalises every noun ("ich bin Entwickler"), so capitalisation alone proves
/// nothing; a fixed list of role words and function words is rejected before either
/// check as a second line of defence.
struct NameGate: Sendable {
    struct Accepted: Equatable, Sendable {
        /// The name to show: the attendee's spelling when it matched one.
        let display: String
        let attendeeMatch: Bool
    }
    enum Rejection: String, Sendable, CaseIterable {
        /// A role, title, team, weekday or function word ("Entwickler", "Marketing").
        case roleOrCommonWord
        /// Neither an attendee nor tagged as a personal name.
        case notAName
    }

    let attendees: [String]
    var tagger: any PersonNameTagging = NLPersonNameTagger()

    func check(_ candidate: String, range: Range<String.Index>, in sentence: String) -> Swift.Result<Accepted, RejectionError> {
        let words = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return .failure(.init(.notAName)) }
        if words.contains(where: { Self.stopWords.contains(SpeakerNames.key($0)) }) {
            return .failure(.init(.roleOrCommonWord))
        }
        if let a = attendeeMatch(candidate) { return .success(Accepted(display: a, attendeeMatch: true)) }
        if tagger.isPersonalName(range, in: sentence) {
            return .success(Accepted(display: SpeakerNames.clean(candidate), attendeeMatch: false))
        }
        return .failure(.init(.notAName))
    }

    struct RejectionError: Error, Equatable { let reason: Rejection; init(_ r: Rejection) { reason = r } }

    /// The attendee spelling `candidate` stands for, or nil. A full-name candidate must
    /// match a full name; a one-word candidate may match any one word of an attendee's
    /// name. Two DIFFERENT spellings matching (two attendees "Jan" and "Jana" for "Jann")
    /// is ambiguous: nil.
    func attendeeMatch(_ candidate: String) -> String? {
        let c = SpeakerNames.key(candidate)
        let cWords = c.split(separator: " ").map(String.init)
        var hits = Set<String>(), display: [String: String] = [:]
        for attendee in attendees {
            let full = SpeakerNames.clean(attendee)
            let parts = full.split(separator: " ").map(String.init)
            if cWords.count > 1 {
                if Self.close(c, SpeakerNames.key(full)) { hits.insert(SpeakerNames.key(full)); display[SpeakerNames.key(full)] = full }
            } else {
                for p in parts where p.count >= 2 && Self.close(c, SpeakerNames.key(p)) {
                    hits.insert(SpeakerNames.key(p)); display[SpeakerNames.key(p)] = p
                }
            }
        }
        guard hits.count == 1, let k = hits.first else { return nil }
        return display[k]
    }

    /// Edit distance allowed: none up to 3 letters, 1 up to 7, 2 beyond.
    static func close(_ a: String, _ b: String) -> Bool {
        let n = min(a.count, b.count)
        let allowed = n <= 3 ? 0 : (n <= 7 ? 1 : 2)
        return levenshtein(a, b, limit: allowed) <= allowed
    }

    static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }

    /// Words that are never a name, folded (lower-case, no diacritics). German role
    /// nouns are the reason this exists: "ich bin Entwickler" is grammatical and
    /// capitalised. Also pronouns, greetings, days and months, which the recognizer
    /// capitalises at a sentence start.
    static let stopWords: Set<String> = [
        // pronouns / function words
        "ich", "du", "er", "sie", "es", "wir", "ihr", "mich", "dich", "uns", "euch", "hier", "da", "dran",
        "jetzt", "gerade", "auch", "noch", "nicht", "kein", "keine", "so", "ja", "nein", "gut", "okay", "ok",
        "genau", "also", "super", "perfekt", "klar", "prima", "stimmt", "richtig", "naja", "cool", "right",
        "alright", "well", "nice", "awesome", "perfect", "exactly", "correct", "true", "wait", "warte",
        "i", "you", "he", "she", "we", "they", "it", "me", "here", "there", "now", "just", "not", "sure",
        "good", "fine", "great", "back", "done", "ready", "sorry", "yes", "no", "yeah", "the", "a", "an",
        "der", "die", "das", "ein", "eine", "einer", "und", "aber", "mal", "wieder", "sehr", "neu",
        // greetings / meeting words
        "hallo", "hello", "hi", "hey", "moin", "servus", "tschuss", "danke", "thanks", "bye", "team",
        "meeting", "call", "besprechung", "termin", "speaker", "sprecher", "them", "talkie",
        // roles and titles (de)
        "entwickler", "entwicklerin", "projektleiter", "projektleiterin", "teamleiter", "teamleiterin",
        "geschaftsfuhrer", "geschaftsfuhrerin", "chef", "chefin", "kunde", "kundin", "berater", "beraterin",
        "designer", "designerin", "ingenieur", "ingenieurin", "student", "studentin", "praktikant",
        "praktikantin", "werkstudent", "werkstudentin", "leiter", "leiterin", "inhaber", "inhaberin",
        "vertrieb", "verkauf", "einkauf", "buchhaltung", "personal", "support", "kollege", "kollegin",
        "mitarbeiter", "mitarbeiterin", "grunder", "grunderin", "vorstand", "assistent", "assistentin",
        "programmierer", "programmiererin", "manager", "managerin", "lehrer", "lehrerin", "arzt", "arztin",
        "anwalt", "anwaltin", "herr", "frau", "doktor", "professor", "professorin",
        // roles and titles (en)
        "developer", "engineer", "manager", "designer", "founder", "cofounder", "ceo", "cto", "cfo", "coo",
        "lead", "director", "intern", "student", "customer", "client", "consultant", "sales", "marketing",
        "product", "engineering", "finance", "legal", "operations", "recruiter", "owner", "head", "vp",
        "mr", "mrs", "ms", "dr", "doctor", "sir", "madam", "everyone", "everybody", "guys", "folks",
        // days and months
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "januar", "februar", "marz", "april", "mai", "juni", "juli", "august", "september", "oktober",
        "november", "dezember", "january", "february", "march", "may", "june", "july", "october", "december",
    ]
}

// MARK: - Evidence from the conversation

/// Pure conversation-based naming. Input: the meeting's segments (labels + times +
/// text) in transcript order, the calendar attendees, a name tagger. Output: the
/// labels it is sure about, plus counts of what it rejected (for measurement).
enum ConversationNaming {
    enum Kind: String, Sendable, CaseIterable {
        /// "ich bin Anna" / "my name is Anna" / "Anna hier" said by the speaker.
        case selfIntroduction
        /// "Anna, was meinst du?" — and the NEXT turn, by someone else, answers fast.
        case addressedReply
        /// "Danke, Anna" naming the next speaker. Weak: never enough on its own.
        case signOff
        var isWeak: Bool { self == .signOff }
    }

    struct Evidence: Equatable, Sendable {
        let label: String
        let name: String
        let key: String
        let kind: Kind
        /// The turn the evidence came from (independence: one per turn and kind).
        let turn: Int
        let attendeeMatch: Bool
    }

    struct Report: Equatable, Sendable {
        var names: [String: String] = [:]
        /// Evidence pieces accepted by the name gate, by kind.
        var evidence: [Kind: Int] = [:]
        /// Candidates the name gate rejected, by reason.
        var gateRejected: [NameGate.Rejection: Int] = [:]
        /// Address/sign-off cues with no quick answer by another speaker.
        var noReply = 0
        /// Labels dropped because evidence named them two different ways.
        var speakerConflicts = 0
        /// Names dropped because evidence pointed at two different speakers (or at Me).
        var nameConflicts = 0
        /// Labels with consistent evidence that was still not enough.
        var insufficient = 0
    }

    /// Seconds within which the next speaker must start for an address to count as
    /// answered. Lane clocks are only approximately aligned, so this also absorbs that.
    static let replyWindow = 4.0

    struct Turn: Equatable { let label: String; let start: Double; let end: Double; let text: String }

    /// Consecutive same-label segments merged, in time order (index tiebreak).
    static func turns(_ segments: [MeetingSegment]) -> [Turn] {
        let sorted = segments.enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)
        var out: [Turn] = []
        for s in sorted {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = out.last, last.label == s.speaker {
                out[out.count - 1] = Turn(label: last.label, start: last.start, end: max(last.end, s.end),
                                          text: last.text + " " + text)
            } else {
                out.append(Turn(label: s.speaker, start: s.start, end: max(s.start, s.end), text: text))
            }
        }
        return out
    }

    static func run(segments: [MeetingSegment], attendees: [String],
                    tagger: any PersonNameTagging = NLPersonNameTagger()) -> Report {
        var report = Report()
        let gate = NameGate(attendees: attendees, tagger: tagger)
        let ts = turns(segments)
        var evidence: [Evidence] = []

        // A two-word candidate ("Anna Berg") that fails is retried as its first word
        // ("ich bin Anna Projektleiterin" -> "Anna"); a rejection is counted once.
        func gated(_ m: Cue.Match) -> NameGate.Accepted? {
            switch gate.check(m.name, range: m.range, in: m.sentence) {
            case .success(let a): return a
            case .failure(let e):
                if let space = m.name.firstIndex(of: " ") {
                    let first = String(m.name[..<space])
                    let r = m.range.lowerBound..<m.sentence.index(m.range.lowerBound, offsetBy: first.count)
                    if case .success(let a) = gate.check(first, range: r, in: m.sentence) { return a }
                }
                report.gateRejected[e.reason, default: 0] += 1
                return nil
            }
        }
        func nextReply(after i: Int) -> Int? {
            guard i + 1 < ts.count else { return nil }
            let n = ts[i + 1]
            guard n.label != ts[i].label, n.start - ts[i].end <= replyWindow else { return nil }
            return i + 1
        }

        for (i, t) in ts.enumerated() {
            let sentences = Cue.sentences(t.text)
            for s in sentences {
                for m in Cue.selfIntroductions(in: s) {
                    guard let a = gated(m) else { continue }
                    evidence.append(Evidence(label: t.label, name: a.display, key: SpeakerNames.key(a.display),
                                             kind: .selfIntroduction, turn: i, attendeeMatch: a.attendeeMatch))
                }
            }
            // Hand-over cues only count in the turn's LAST sentence: the moment the
            // floor passes to the person addressed.
            guard let last = sentences.last else { continue }
            for (kind, matches) in [(Kind.addressedReply, Cue.addresses(in: last)), (.signOff, Cue.signOffs(in: last))] {
                for m in matches {
                    guard let a = gated(m) else { continue }
                    guard let r = nextReply(after: i) else { report.noReply += 1; continue }
                    evidence.append(Evidence(label: ts[r].label, name: a.display, key: SpeakerNames.key(a.display),
                                             kind: kind, turn: i, attendeeMatch: a.attendeeMatch))
                }
            }
        }
        for e in evidence { report.evidence[e.kind, default: 0] += 1 }
        let decided = decide(evidence)
        report.names = decided.names
        report.speakerConflicts = decided.speakerConflicts
        report.nameConflicts = decided.nameConflicts
        report.insufficient = decided.insufficient
        return report
    }

    /// The assignment rule, separate from extraction so it is tested on its own:
    /// a label gets a name only when (a) at least two independent pieces of evidence
    /// agree, at least one of them not weak, or (b) one self-introduction matches a
    /// calendar attendee; and nothing conflicts — the label was never given another
    /// name, and the name never pointed at another label (Me included). "Me" itself
    /// is never named. One name per speaker, one speaker per name.
    static func decide(_ evidence: [Evidence])
        -> (names: [String: String], speakerConflicts: Int, nameConflicts: Int, insufficient: Int) {
        var keysByLabel: [String: Set<String>] = [:], labelsByKey: [String: Set<String>] = [:]
        for e in evidence {
            keysByLabel[e.label, default: []].insert(e.key)
            labelsByKey[e.key, default: []].insert(e.label)
        }
        var names: [String: String] = [:]
        var speakerConflicts = 0, nameConflicts = 0, insufficient = 0
        for (label, keys) in keysByLabel.sorted(by: { $0.key < $1.key }) where SpeakerNames.isNameable(label) {
            guard keys.count == 1, let key = keys.first else { speakerConflicts += 1; continue }
            guard labelsByKey[key]?.count == 1 else { nameConflicts += 1; continue }
            let mine = evidence.filter { $0.label == label }
            var independent = Set<String>()
            for e in mine { independent.insert("\(e.turn)|\(e.kind.rawValue)") }
            let strong = mine.contains { !$0.kind.isWeak }
            let introMatchesAttendee = mine.contains { $0.kind == .selfIntroduction && $0.attendeeMatch }
            guard (independent.count >= 2 && strong) || introMatchesAttendee else { insufficient += 1; continue }
            // Show the attendee spelling when any piece matched one, else the most
            // frequent spelling (ties: alphabetical, for determinism).
            var counts: [String: Int] = [:]
            for e in mine { counts[e.name, default: 0] += 1 }
            let frequent: String = counts.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }[0].key
            let attendeeSpelling: String? = mine.first(where: { $0.attendeeMatch })?.name
            names[label] = attendeeSpelling ?? frequent
        }
        return (names, speakerConflicts, nameConflicts, insufficient)
    }
}

/// The text cues, German and English. Each match carries the candidate, its range in
/// the sentence (for the tagger) and the sentence itself.
enum Cue {
    struct Match: Equatable {
        let name: String
        let range: Range<String.Index>
        let sentence: String
    }

    /// One capitalised word, optionally followed by a second (a surname).
    private static let nameGroup = #"(\p{Lu}[\p{Ll}\p{Lu}'’\-]+(?:[ ]\p{Lu}[\p{Ll}'’\-]+)?)"#
    private static let oneName = #"(\p{Lu}[\p{Ll}\p{Lu}'’\-]+)"#
    private static let end = #"(?=$|[\s,.!?;:])"#

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private static let introPatterns: [NSRegularExpression] = [
        // "ich bin Anna", "mein Name ist Anna Berg", "ich heiße Anna", "hier ist (die) Anna", "hier spricht Anna"
        re(#"(?i:\b(?:ich\s+bin|ich\s+hei(?:ß|ss)e|mein\s+name\s+ist|hier\s+ist|hier\s+spricht)\s+)(?:(?i:der|die)\s+)?"# + nameGroup + end),
        // "my name is Anna", "my name's Anna", "this is Anna", "I'm Anna", "I am Anna"
        re(#"(?i:\b(?:my\s+name\s+is|my\s+name['’]s|this\s+is|i['’]m|i\s+am)\s+)"# + nameGroup + end),
        // "Anna hier" / "Anna here" at the start of the sentence (after an optional greeting)
        re(#"^(?:(?i:hallo|hi|hey|hello|ja|yes|yeah|okay|ok|moin|servus|guten\s+morgen|guten\s+tag|good\s+morning)[,.!]?\s+)?"# + oneName + #"\s+(?i:hier|here)(?=$|[\s,.!?;:])"#),
    ]

    private static let secondPerson = re(#"(?i)\b(?:du|dich|dir|dein|deine|deiner|ihr|euch|sie|ihnen|you|your)\b"#)

    private static let addressPatterns: [NSRegularExpression] = [
        // "Anna, was meinst du?" / "Anna, what do you think?"  (sentence-initial vocative)
        re(#"^(?:(?i:und|also|ja|na|okay|ok|so|and|well)[,]?\s+)?"# + oneName + #"\s*,\s*\S"#),
        // "Was meinst du, Anna?" / "What do you think, Anna?"  (sentence-final vocative)
        re(#",\s*"# + oneName + #"\s*[?!.]*\s*$"#),
    ]

    private static let signOffPatterns: [NSRegularExpression] = [
        re(#"(?i:\b(?:danke(?:\s+dir|\s+schön)?|vielen\s+dank|tschüss|tschüs|ciao|bis\s+dann|bis\s+später|bis\s+bald|bis\s+morgen|thanks|thank\s+you|bye|see\s+you|cheers|take\s+care))[,]?\s+"# + oneName + end),
    ]

    /// Sentences of a turn (split after . ! ? keeping the mark).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in text {
            cur.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let s = cur.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    static func selfIntroductions(in sentence: String) -> [Match] {
        introPatterns.flatMap { matches($0, in: sentence) }
    }

    /// Vocatives, only in a sentence that is a question or speaks to "you".
    static func addresses(in sentence: String) -> [Match] {
        let ns = NSRange(sentence.startIndex..., in: sentence)
        guard sentence.contains("?") || secondPerson.firstMatch(in: sentence, range: ns) != nil else { return [] }
        return addressPatterns.flatMap { matches($0, in: sentence) }
    }

    static func signOffs(in sentence: String) -> [Match] {
        signOffPatterns.flatMap { matches($0, in: sentence) }
    }

    private static func matches(_ re: NSRegularExpression, in s: String) -> [Match] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let r = Range(m.range(at: 1), in: s) else { return nil }
            return Match(name: String(s[r]), range: r, sentence: s)
        }
    }
}
