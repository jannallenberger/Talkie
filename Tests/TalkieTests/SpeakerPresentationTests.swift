import XCTest
@testable import Talkie

final class SpeakerPresentationTests: XCTestCase {
    private func seg(_ speaker: String, _ text: String = "x") -> MeetingSegment {
        MeetingSegment(speaker: speaker, start: 0, end: 1, text: text)
    }

    func testMeIsAlwaysSlotZero() {
        let a = SpeakerPresentation.colorIndices(for: ["Speaker 1", "Me", "Speaker 2"])
        let b = SpeakerPresentation.colorIndices(for: ["Me", "Them"])
        XCTAssertEqual(a["Me"], 0)
        XCTAssertEqual(b["Me"], 0)
    }

    func testOthersGetDistinctStableSlotsByFirstAppearance() {
        let labels = ["Speaker 2", "Me", "Speaker 1", "Speaker 2", "Me", "Speaker 1"]
        let m = SpeakerPresentation.colorIndices(for: labels)
        XCTAssertEqual(m["Speaker 2"], 1)
        XCTAssertEqual(m["Speaker 1"], 2)
        XCTAssertEqual(m, SpeakerPresentation.colorIndices(for: labels))
    }

    func testSlotsWrapAndNeverUseMeSlot() {
        let labels = (1...12).map { "Speaker \($0)" }
        let m = SpeakerPresentation.colorIndices(for: labels)
        for v in m.values { XCTAssertTrue((1..<SpeakerPresentation.paletteSize).contains(v)) }
    }

    func testShowsLabelsNeedsTwoDistinctSpeakers() {
        XCTAssertFalse(SpeakerPresentation.showsLabels(nil))
        XCTAssertFalse(SpeakerPresentation.showsLabels([seg("Me"), seg("Me")]))
        XCTAssertTrue(SpeakerPresentation.showsLabels([seg("Me"), seg("Them")]))
    }

    func testTurnsMergeConsecutiveSameSpeaker() {
        let segs = [seg("Me", "a"), seg("Me", "b"), seg("Speaker 1", "c"), seg("Me", "d")]
        XCTAssertEqual(SpeakerPresentation.turnStarts(segs), [true, false, true, true])
        let t = SpeakerPresentation.turns(segs)
        XCTAssertEqual(t.map(\.speaker), ["Me", "Speaker 1", "Me"])
        XCTAssertEqual(t.first?.text, "a b")
    }

    func testDisplayNameKeepsStoredLabelsParseable() {
        XCTAssertEqual(SpeakerPresentation.speakerNumber("Speaker 3"), 3)
        XCTAssertNil(SpeakerPresentation.speakerNumber("Them"))
        XCTAssertNil(SpeakerPresentation.speakerNumber("Speaker X"))
        XCTAssertEqual(SpeakerPresentation.displayName(for: "Imported"), "Imported")
    }

    func testNewKeysPresentInAllCatalogs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let keys = ["Me", "Them", "Speaker %d", "Identifying speakers…",
                    "Captures you and the other participants on the call (Zoom, Meet, Teams) — and tells each person apart automatically."]
        for l in MicrocopyLocalizationTests.locales {
            let url = root.appendingPathComponent("Resources/Localizations/\(l).lproj/Localizable.strings")
            let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], l)
            for k in keys { XCTAssertFalse((dict[k] ?? "").isEmpty, "\(l): \(k)") }
            XCTAssertTrue(dict["Speaker %d"]!.contains("%d"), l)
        }
    }
}
