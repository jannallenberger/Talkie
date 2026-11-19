import XCTest
@testable import Talkie

/// W2 speaker names: evidence rules (German + English), the name gate, the assignment
/// rule (agreement, conflicts, one-to-one), precedence, presentation and legacy decode.
/// All names here are invented.
final class SpeakerNamingTests: XCTestCase {

    /// Deterministic tagger: a word is a personal name iff it is in `names`.
    struct FakeTagger: PersonNameTagging {
        let names: Set<String>
        func isPersonalName(_ range: Range<String.Index>, in sentence: String) -> Bool {
            let words = sentence[range].split(separator: " ").map(String.init)
            return !words.isEmpty && words.allSatisfy(names.contains)
        }
    }
    let tagger = FakeTagger(names: ["Anna", "Berg", "Tom", "Sarah", "Priya", "Ole", "Mia", "Kai", "Lena", "Jonas"])

    private func seg(_ speaker: String, _ start: Double, _ text: String, end: Double? = nil) -> MeetingSegment {
        MeetingSegment(speaker: speaker, start: start, end: end ?? start + 2, text: text)
    }

    private func run(_ segs: [MeetingSegment], attendees: [String] = []) -> ConversationNaming.Report {
        ConversationNaming.run(segments: segs, attendees: attendees, tagger: tagger)
    }

    // MARK: Cue extraction — self-introductions

    func testGermanSelfIntroductionCues() {
        for s in ["Hallo, ich bin Anna.", "Mein Name ist Anna.", "Ich heiße Anna.", "Hier ist Anna.",
                  "Hier spricht Anna.", "Anna hier.", "Hallo, Anna hier, ich bin dabei.", "Hier ist die Anna."] {
            XCTAssertEqual(Cue.selfIntroductions(in: s).map(\.name).first, "Anna", s)
        }
    }

    func testEnglishSelfIntroductionCues() {
        for s in ["Hi, this is Anna.", "I'm Anna.", "I am Anna, from the other team.", "My name is Anna.",
                  "My name's Anna.", "Anna here.", "Hey, Anna here."] {
            XCTAssertEqual(Cue.selfIntroductions(in: s).map(\.name).first, "Anna", s)
        }
        XCTAssertEqual(Cue.selfIntroductions(in: "My name is Anna Berg.").first?.name, "Anna Berg")
        XCTAssertTrue(Cue.selfIntroductions(in: "I'm sure that works.").isEmpty, "lower-case is never a candidate")
    }

    func testAddressCuesNeedAQuestionOrSecondPerson() {
        XCTAssertEqual(Cue.addresses(in: "Anna, was meinst du?").first?.name, "Anna")
        XCTAssertEqual(Cue.addresses(in: "Was meinst du, Anna?").first?.name, "Anna")
        XCTAssertEqual(Cue.addresses(in: "Anna, what do you think?").first?.name, "Anna")
        XCTAssertEqual(Cue.addresses(in: "What do you think, Anna?").first?.name, "Anna")
        XCTAssertTrue(Cue.addresses(in: "Anna, das Budget steht.").isEmpty, "no question, no 'you': not an address")
    }

    func testSignOffCues() {
        XCTAssertEqual(Cue.signOffs(in: "Danke, Anna.").first?.name, "Anna")
        XCTAssertEqual(Cue.signOffs(in: "Tschüss Anna!").first?.name, "Anna")
        XCTAssertEqual(Cue.signOffs(in: "Thanks Anna.").first?.name, "Anna")
        XCTAssertEqual(Cue.signOffs(in: "Bye, Anna!").first?.name, "Anna")
    }

    // MARK: Name gate

    func testGermanRoleNounsAreRejectedEvenThoughCapitalised() {
        let gate = NameGate(attendees: [], tagger: FakeTagger(names: ["Entwickler", "Projektleiterin"]))
        for s in ["Ich bin Entwickler.", "Ich bin Projektleiterin."] {
            let m = Cue.selfIntroductions(in: s)[0]
            XCTAssertEqual(gate.check(m.name, range: m.range, in: s), .failure(.init(.roleOrCommonWord)), s)
        }
        let r = run([seg("Speaker 1", 0, "Ich bin Entwickler."), seg("Speaker 1", 30, "Ich bin Entwickler, wie gesagt.")])
        XCTAssertTrue(r.names.isEmpty)
        XCTAssertEqual(r.gateRejected[.roleOrCommonWord], 2)
    }

    /// The real on-device tagger: compound German role nouns (not in the fixed list) are
    /// not personal names; a plain first name is.
    func testRealTaggerRejectsCompoundRoleNouns() throws {
        let gate = NameGate(attendees: [])
        for s in ["Ich bin Abteilungsleiter.", "Ich bin Bauingenieur.", "Ich bin Softwareentwickler.",
                  "Ich bin Vertriebsleiterin.", "This is Accounting."] {
            let m = Cue.selfIntroductions(in: s)[0]
            XCTAssertEqual(gate.check(m.name, range: m.range, in: s), .failure(.init(.notAName)), s)
        }
        // The positive case needs the system's name-recognition model, which is not
        // installed on every machine (CI runners tag nothing). Probe with a different,
        // unambiguous first name; when even that is not tagged, the model is absent and
        // the positive assertion would only test the machine, not the gate.
        let probe = "Ich bin Michael."
        let pm = Cue.selfIntroductions(in: probe)[0]
        guard case .success = gate.check(pm.name, range: pm.range, in: probe) else {
            throw XCTSkip("on-device name tagger recognises no names on this machine")
        }
        let s = "Ich bin Kai."
        let m = Cue.selfIntroductions(in: s)[0]
        XCTAssertEqual(gate.check(m.name, range: m.range, in: s), .success(.init(display: "Kai", attendeeMatch: false)))
    }

    func testUntaggedNonAttendeeIsRejected() {
        let s = "Ich bin Montagmorgen."
        let m = Cue.selfIntroductions(in: s)[0]
        XCTAssertEqual(NameGate(attendees: [], tagger: tagger).check(m.name, range: m.range, in: s),
                       .failure(.init(.notAName)))
    }

    func testEnglishCommonWordsAreRejected() {
        let r = run([seg("Speaker 1", 0, "This is Marketing."), seg("Speaker 1", 9, "I'm Ready.")])
        XCTAssertEqual(r.gateRejected[.roleOrCommonWord], 2)
        XCTAssertTrue(r.names.isEmpty)
    }

    func testAttendeeFuzzyMatch() {
        let gate = NameGate(attendees: ["Annika Bergström", "Lars Svensson"], tagger: FakeTagger(names: []))
        XCTAssertEqual(gate.attendeeMatch("Annika"), "Annika")
        XCTAssertEqual(gate.attendeeMatch("Anika"), "Annika", "one recognition error tolerated")
        XCTAssertEqual(gate.attendeeMatch("Bergstrom"), "Bergström", "diacritics ignored")
        XCTAssertEqual(gate.attendeeMatch("Lars Svenson"), "Lars Svensson")
        XCTAssertEqual(gate.attendeeMatch("Lahrs"), "Lars")
        XCTAssertNil(gate.attendeeMatch("Laura"))
        XCTAssertNil(gate.attendeeMatch("Ole"))
        // Short names need an exact match: "Kai" is not "Kay".
        XCTAssertNil(NameGate(attendees: ["Kay Wu"], tagger: tagger).attendeeMatch("Kai"))
        // Two different attendees within tolerance: ambiguous, no match.
        XCTAssertNil(NameGate(attendees: ["Jana A", "Jona B"], tagger: tagger).attendeeMatch("Jena"))
    }

    func testAttendeeMatchAcceptsAWordTheTaggerMisses() {
        let s = "Ich bin Ole."
        let m = Cue.selfIntroductions(in: s)[0]
        let gate = NameGate(attendees: ["Ole Hansen"], tagger: FakeTagger(names: []))
        XCTAssertEqual(gate.check(m.name, range: m.range, in: s), .success(.init(display: "Ole", attendeeMatch: true)))
    }

    func testSurnameFailureFallsBackToFirstName() {
        let r = run([seg("Speaker 1", 0, "Ich bin Anna Projektleiterin."), seg("Speaker 2", 3, "Hallo."),
                     seg("Speaker 2", 30, "Anna, was meinst du?"), seg("Speaker 1", 32, "Gute Frage.")])
        XCTAssertEqual(r.names, ["Speaker 1": "Anna"])
    }

    // MARK: Assignment

    func testSingleSelfIntroductionWithoutAttendeeIsNotEnough() {
        let r = run([seg("Speaker 1", 0, "Hi, I'm Anna."), seg("Speaker 2", 3, "Hello.")])
        XCTAssertTrue(r.names.isEmpty)
        XCTAssertEqual(r.insufficient, 1)
    }

    func testSingleSelfIntroductionMatchingAnAttendeeIsEnough() {
        let r = run([seg("Speaker 1", 0, "Hallo, ich bin Anna."), seg("Speaker 2", 3, "Hallo.")],
                    attendees: ["Anna Berg"])
        XCTAssertEqual(r.names, ["Speaker 1": "Anna"])
    }

    func testIntroductionPlusAnsweredAddressAgreeGerman() {
        let r = run([
            seg("Speaker 1", 0, "Hallo zusammen, ich bin Lena."),
            seg("Speaker 2", 5, "Hallo."),
            seg("Speaker 2", 40, "Gut. Lena, was meinst du?"),
            seg("Speaker 1", 42, "Ich finde das gut."),
        ])
        XCTAssertEqual(r.names, ["Speaker 1": "Lena"])
        XCTAssertEqual(r.evidence[.selfIntroduction], 1)
        XCTAssertEqual(r.evidence[.addressedReply], 1)
    }

    func testTwoAnsweredAddressesAgreeEnglish() {
        let r = run([
            seg("Speaker 1", 0, "Let's start. What do you think, Tom?"),
            seg("Speaker 2", 2, "Sounds good."),
            seg("Speaker 1", 60, "Tom, can you take that?"),
            seg("Speaker 2", 62, "Sure."),
        ])
        XCTAssertEqual(r.names, ["Speaker 2": "Tom"])
    }

    func testAddressAnsweredTooLateDoesNotCount() {
        let r = run([
            seg("Speaker 1", 0, "Tom, what do you think?", end: 2),
            seg("Speaker 2", 2 + ConversationNaming.replyWindow + 1, "Sounds good."),
            seg("Speaker 1", 60, "Tom, can you take that?", end: 62),
            seg("Speaker 2", 70, "Sure."),
        ])
        XCTAssertTrue(r.names.isEmpty)
        XCTAssertEqual(r.noReply, 2)
    }

    func testAddressOnlyInTheLastSentenceOfTheTurn() {
        // "Tom, do you …" mid-turn, then the same speaker goes on: not a hand-over.
        let r = run([
            seg("Speaker 1", 0, "Tom, do you remember? Anyway, we shipped it."),
            seg("Speaker 2", 2, "Yes."),
            seg("Speaker 1", 60, "Tom, do you remember? So that was it."),
            seg("Speaker 2", 62, "Yes."),
        ])
        XCTAssertTrue(r.names.isEmpty)
    }

    func testSignOffsAloneAreWeak() {
        let r = run([
            seg("Speaker 1", 0, "Danke, Mia."), seg("Speaker 2", 2, "Gerne."),
            seg("Speaker 1", 30, "Tschüss Mia!"), seg("Speaker 2", 32, "Tschüss."),
        ])
        XCTAssertTrue(r.names.isEmpty, "two weak pieces are not enough")
        XCTAssertEqual(r.insufficient, 1)
    }

    func testSignOffCanBeTheSecondPiece() {
        let r = run([
            seg("Speaker 2", 0, "Hi, I'm Mia."), seg("Speaker 1", 3, "Welcome."),
            seg("Speaker 1", 300, "Thanks Mia."), seg("Speaker 2", 302, "Bye."),
        ])
        XCTAssertEqual(r.names, ["Speaker 2": "Mia"])
    }

    func testSpeakerWithTwoDifferentNamesIsAConflict() {
        let r = run([
            seg("Speaker 1", 0, "Ich bin Anna."), seg("Speaker 2", 2, "Hallo."),
            seg("Speaker 2", 30, "Kai, was meinst du?"), seg("Speaker 1", 31, "Gut."),
            seg("Speaker 2", 60, "Kai, und du?"), seg("Speaker 1", 61, "Ja."),
        ], attendees: ["Anna Berg"])
        XCTAssertTrue(r.names.isEmpty)
        XCTAssertEqual(r.speakerConflicts, 1)
    }

    func testNamePointingAtTwoSpeakersIsAConflict() {
        let r = run([
            seg("Speaker 1", 0, "Ich bin Anna."), seg("Speaker 2", 2, "Ich bin Anna."),
        ], attendees: ["Anna Berg"])
        XCTAssertTrue(r.names.isEmpty)
        XCTAssertEqual(r.nameConflicts, 2)
    }

    func testMeIsNeverNamedAndReservesItsName() {
        let r = run([
            seg("Me", 0, "Hallo, ich bin Jonas."), seg("Speaker 1", 2, "Hallo Jonas."),
            seg("Speaker 1", 30, "Jonas, was meinst du?"), seg("Speaker 2", 31, "Weiß nicht."),
        ], attendees: ["Jonas Weber"])
        XCTAssertNil(r.names["Me"])
        XCTAssertNil(r.names["Speaker 2"], "the name already points at Me")
    }

    func testAddressingYourselfIsIgnoredAsReplyMustBeSomeoneElse() {
        let r = run([seg("Speaker 1", 0, "Anna, what do you think?"), seg("Speaker 1", 2, "I think yes.")])
        XCTAssertTrue(r.names.isEmpty)
    }

    func testAttendeeSpellingWins() {
        let r = run([
            seg("Speaker 1", 0, "I'm Anika."), seg("Speaker 2", 2, "Hello."),
        ], attendees: ["Annika Bergström"])
        XCTAssertEqual(r.names, ["Speaker 1": "Annika"])
    }

    // MARK: Precedence and one-to-one

    func testPrecedenceManualOverVoiceOverConversation() {
        let existing = ["Speaker 1": SpeakerName(name: "Ann", source: .manual)]
        let m = SpeakerNames.merge(existing: existing,
                                   voice: ["Speaker 1": "Anna", "Speaker 2": "Tom"],
                                   conversation: ["Speaker 1": "Annie", "Speaker 2": "Tim", "Speaker 3": "Kai"])
        XCTAssertEqual(m["Speaker 1"], SpeakerName(name: "Ann", source: .manual))
        XCTAssertEqual(m["Speaker 2"], SpeakerName(name: "Tom", source: .voice))
        XCTAssertEqual(m["Speaker 3"], SpeakerName(name: "Kai", source: .conversation))
    }

    func testOneSpeakerPerNameAcrossSources() {
        let m = SpeakerNames.merge(existing: nil, voice: ["Speaker 1": "Anna"], conversation: ["Speaker 2": "anna"])
        XCTAssertEqual(m, ["Speaker 1": SpeakerName(name: "Anna", source: .voice)])
        let tie = SpeakerNames.merge(existing: nil, voice: ["Speaker 1": "Anna", "Speaker 2": "Anna"], conversation: [:])
        XCTAssertTrue(tie.isEmpty, "two equal automatic claims name neither")
    }

    func testMeIsNeverNamedEvenManually() {
        XCTAssertTrue(SpeakerNames.merge(existing: nil, voice: ["Me": "X"], conversation: ["Me": "Y"]).isEmpty)
        XCTAssertNil(SpeakerNames.settingManual("Z", for: "Me", in: nil)["Me"])
    }

    func testManualNameTakesTheNameFromAnAutomaticLabelAndClears() {
        var n = SpeakerNames.merge(existing: nil, voice: [:], conversation: ["Speaker 2": "Anna"])
        n = SpeakerNames.settingManual("Anna", for: "Speaker 1", in: n)
        XCTAssertEqual(n, ["Speaker 1": SpeakerName(name: "Anna", source: .manual)])
        n = SpeakerNames.settingManual("  ", for: "Speaker 1", in: n)
        XCTAssertTrue(n.isEmpty)
    }

    // MARK: Presentation

    func testTranscriptPrefixesAreRenamedNotTheSpokenText() {
        let t = "[00:01] Me: Hi Speaker 2.\n[00:03] Speaker 2: Them: hello\n[00:05] Speaker 3: ok"
        let names = ["Speaker 2": SpeakerName(name: "Anna", source: .conversation)]
        XCTAssertEqual(SpeakerNames.applyToTranscript(t, names: names),
                       "[00:01] Me: Hi Speaker 2.\n[00:03] Anna: Them: hello\n[00:05] Speaker 3: ok")
    }

    func testSummaryOwnersAndSpeakerTokens() {
        let s = "**Action items:**\n- Speaker 2: send the deck\n- Them: book a room\n- Speaker 12: x\nAsk them later; Speaker 2 agreed."
        let names = ["Speaker 2": SpeakerName(name: "Anna", source: .manual),
                     "Them": SpeakerName(name: "Tom", source: .voice)]
        XCTAssertEqual(SpeakerNames.applyToSummary(s, names: names),
                       "**Action items:**\n- Anna: send the deck\n- Tom: book a room\n- Speaker 12: x\nAsk them later; Anna agreed.")
    }

    func testParticipants() {
        let names = ["Speaker 1": SpeakerName(name: "Anna", source: .manual)]
        XCTAssertEqual(SpeakerNames.applyToParticipants(["Me", "Speaker 1", "Speaker 2"], names: names),
                       ["Me", "Anna", "Speaker 2"])
    }

    // MARK: Persistence

    func testLegacyMeetingDecodesWithoutNames() throws {
        let json = #"[{"title":"T","startUnix":1,"durationSec":2,"transcript":"x","summary":"","fileName":"f.md"}]"#
        let m = try JSONDecoder().decode([Meeting].self, from: Data(json.utf8))
        XCTAssertNil(m[0].speakerNames)
        XCTAssertEqual(m[0].namedTranscript, "x")
    }

    func testNamesRoundTripAndUnknownSourceDropsOnlyTheNames() throws {
        var m = Meeting(title: "T", startUnix: 1, durationSec: 2, transcript: "x", summary: "", fileName: "f.md")
        m.speakerNames = ["Speaker 1": SpeakerName(name: "Anna", source: .voice)]
        let back = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.speakerNames, m.speakerNames)
        let future = #"{"title":"T","startUnix":1,"durationSec":2,"transcript":"x","summary":"","fileName":"f.md","speakerNames":{"Speaker 1":{"name":"A","source":"telepathy"}}}"#
        let decoded = try JSONDecoder().decode(Meeting.self, from: Data(future.utf8))
        XCTAssertNil(decoded.speakerNames)
        XCTAssertEqual(decoded.title, "T")
    }
}
