import XCTest
@testable import Talkie

/// The "Speakers" row: which chips appear for which meeting.
final class SpeakerChipTests: XCTestCase {
    private func meeting(_ labels: [String], names: [String: SpeakerName]? = nil) -> Meeting {
        var m = Meeting(title: "T", startUnix: 0, durationSec: 60, transcript: "", summary: "", fileName: "f.md")
        m.segments = labels.enumerated().map { MeetingSegment(speaker: $0.element, start: Double($0.offset), end: Double($0.offset) + 1, text: "x") }
        m.speakerNames = names
        return m
    }

    func testTwoPartyMeetingOffersThem() {
        let chips = SpeakerChip.chips(for: meeting(["Them", "Me", "Them"]))
        XCTAssertEqual(chips.map(\.label), ["Me", "Them"])
        XCTAssertEqual(chips.map(\.nameable), [false, true])
    }

    func testDiarizedMultiSpeakerMeetingInOrder() {
        let chips = SpeakerChip.chips(for: meeting(["Speaker 10", "Me", "Speaker 2", "Speaker 1"]))
        XCTAssertEqual(chips.map(\.label), ["Me", "Speaker 1", "Speaker 2", "Speaker 10"])
    }

    func testNoRowWithoutSegmentsOrWithoutAnyoneToName() {
        var m = meeting([])
        m.segments = nil
        XCTAssertTrue(SpeakerChip.chips(for: m).isEmpty)
        XCTAssertTrue(SpeakerChip.chips(for: meeting([])).isEmpty)
        XCTAssertTrue(SpeakerChip.chips(for: meeting(["Me", "Me"])).isEmpty, "solo recording")
        XCTAssertTrue(SpeakerChip.chips(for: meeting(["Imported"])).isEmpty, "an import label is not a person")
    }

    func testNamedAndVoiceNamedSpeakers() {
        let chips = SpeakerChip.chips(for: meeting(["Me", "Speaker 1", "Speaker 2", "Speaker 3"], names: [
            "Speaker 1": SpeakerName(name: "Anna", source: .manual),
            "Speaker 2": SpeakerName(name: "Tom", source: .voice),
            "Me": SpeakerName(name: "X", source: .manual),
        ]))
        XCTAssertEqual(chips, [
            SpeakerChip(label: "Me", name: nil, nameable: false, voiceDerived: false),
            SpeakerChip(label: "Speaker 1", name: "Anna", nameable: true, voiceDerived: false),
            SpeakerChip(label: "Speaker 2", name: "Tom", nameable: true, voiceDerived: true),
            SpeakerChip(label: "Speaker 3", name: nil, nameable: true, voiceDerived: false),
        ])
    }

    @MainActor
    func testRenamingThemInATwoPartyMeetingAppliesToThePlainTranscript() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chips-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
            var m = meeting(["Me", "Them"])
            m.transcript = "[00:00] Me: hi\n[00:01] Them: hello"
            store.add(m)
            store.setSpeakerName("Tom", label: "Them", meetingID: m.id)
            XCTAssertEqual(store.meetings[0].namedTranscript, "[00:00] Me: hi\n[00:01] Tom: hello")
            XCTAssertEqual(SpeakerChip.chips(for: store.meetings[0]).last?.name, "Tom")
        }
    }
}
