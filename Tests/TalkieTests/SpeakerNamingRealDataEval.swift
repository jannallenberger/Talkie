import XCTest
@testable import Talkie

/// OPT-IN, COUNT-ONLY measurement of conversation naming on the owner's real meetings.
/// Skips unless BOTH are set:
///
///   TALKIE_NAMES_EVAL_MEETINGS=/path/to/meetings.json   (opened read-only)
///   TALKIE_NAMES_EVAL_OUT=/some/dir/outside/the/repo
///
/// Writes one `counts.json` there and prints the same counts. Never a name, a
/// transcript line or any other content. Calendar attendees are not stored with
/// meetings, so this measures the tagger path only (the attendee path can only add).
final class SpeakerNamingRealDataEval: XCTestCase {
    func testConversationNamingCountsOnRealMeetings() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TALKIE_NAMES_EVAL_MEETINGS"], !path.isEmpty,
              let outPath = env["TALKIE_NAMES_EVAL_OUT"], !outPath.isEmpty else {
            throw XCTSkip("set TALKIE_NAMES_EVAL_MEETINGS and TALKIE_NAMES_EVAL_OUT to run")
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        let meetings = try JSONDecoder().decode([Meeting].self, from: data)

        var c: [String: Int] = [:]
        func add(_ k: String, _ n: Int = 1) { c[k, default: 0] += n }
        for m in meetings {
            add("meetings")
            guard let segs = m.segments, !segs.isEmpty else { continue }
            add("meetingsWithSegments")
            if m.diarization == .applied { add("meetingsDiarizedApplied") }
            let labels = Set(segs.map(\.speaker)).filter(SpeakerNames.isNameable)
            // Production only names labels the diarizer resolved to one person: every
            // "Speaker N", and "Them" when the pass ran and kept Me/Them (one far person).
            let eligible = labels.filter {
                SpeakerPresentation.speakerNumber($0) != nil
                    || ($0 == SpeakerLabels.them && m.diarization == .unchanged)
            }
            add("nonMeLabels", labels.count)
            add("eligibleSpeakers", eligible.count)
            var cues = 0
            for t in ConversationNaming.turns(segs) {
                let ss = Cue.sentences(t.text)
                cues += ss.reduce(0) { $0 + Cue.selfIntroductions(in: $1).count }
                if let last = ss.last { cues += Cue.addresses(in: last).count + Cue.signOffs(in: last).count }
            }
            add("cueMatches", cues)
            let r = ConversationNaming.run(segments: segs, attendees: [])
            add("namedAnyLabel", r.names.count)
            add("namedEligible", r.names.keys.filter(eligible.contains).count)
            if !r.names.keys.filter(eligible.contains).isEmpty { add("meetingsWithANamedSpeaker") }
            for (k, n) in r.evidence { add("evidence.\(k.rawValue)", n) }
            for (k, n) in r.gateRejected { add("gateRejected.\(k.rawValue)", n) }
            add("noReply", r.noReply)
            add("speakerConflicts", r.speakerConflicts)
            add("nameConflicts", r.nameConflicts)
            add("insufficient", r.insufficient)
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let json = try JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: out.appendingPathComponent("counts.json"))
        for k in c.keys.sorted() { print("[names-eval] \(k) = \(c[k]!)") }
    }
}
