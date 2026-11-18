import XCTest
@testable import Talkie

/// The Meetings Export menu's audio items: 0 files → none (the view shows one
/// disabled "No audio was kept" item), 1 file → a single "Audio" item, 2 lanes →
/// your side + other side, never a mix.
final class MeetingAudioExportTests: XCTestCase {
    private let base = "2026-11-18-1400-standup"

    func testNoAudioKeptOffersNothing() {
        XCTAssertTrue(MeetingAudioExport.items(audioFiles: nil, baseName: base).isEmpty)
        XCTAssertTrue(MeetingAudioExport.items(audioFiles: [:], baseName: base).isEmpty)
        XCTAssertTrue(MeetingAudioExport.items(audioFiles: ["Me": ""], baseName: base).isEmpty)
    }

    func testMissingFilesAreFilteredOut() {
        let files = ["Me": "\(base)-me.m4a", "Them": "\(base)-them.m4a"]
        XCTAssertTrue(MeetingAudioExport.items(audioFiles: files, baseName: base,
                                               fileExists: { _ in false }).isEmpty)
        let onlyMe = MeetingAudioExport.items(audioFiles: files, baseName: base,
                                              fileExists: { $0.hasSuffix("-me.m4a") })
        XCTAssertEqual(onlyMe.map(\.side), [.single])
        XCTAssertEqual(onlyMe.first?.fileName, "\(base)-me.m4a")
    }

    func testMicOnlyRecordingIsOneSingleItem() {
        let items = MeetingAudioExport.items(audioFiles: ["Me": "\(base)-me.m4a"], baseName: base)
        XCTAssertEqual(items, [.init(side: .single, fileName: "\(base)-me.m4a",
                                     defaultName: "\(base).m4a")])
        XCTAssertEqual(items.first?.fileExtension, "m4a")
    }

    func testImportKeepsItsOwnExtension() {
        let items = MeetingAudioExport.items(audioFiles: ["Imported": "\(base).mp3"], baseName: base)
        XCTAssertEqual(items.map(\.side), [.single])
        XCTAssertEqual(items.first?.defaultName, "\(base).mp3")
        XCTAssertEqual(items.first?.fileExtension, "mp3")
    }

    func testTwoLanesAreYourSideThenOtherSide() {
        let items = MeetingAudioExport.items(
            audioFiles: ["Them": "\(base)-them.m4a", "Me": "\(base)-me.m4a"], baseName: base)
        XCTAssertEqual(items, [
            .init(side: .yourSide, fileName: "\(base)-me.m4a", defaultName: "\(base)-me.m4a"),
            .init(side: .otherSide, fileName: "\(base)-them.m4a", defaultName: "\(base)-them.m4a"),
        ])
    }

    func testTitlesNameTheSideAndFormat() {
        let items = MeetingAudioExport.items(
            audioFiles: ["Me": "a-me.m4a", "Them": "a-them.m4a"], baseName: "a")
        XCTAssertEqual(items.map(\.title),
                       ["Audio — your side (.m4a)", "Audio — other side (.m4a)"])
        let single = MeetingAudioExport.items(audioFiles: ["Imported": "x.wav"], baseName: "a")
        XCTAssertEqual(single.first?.title, "Audio (.wav)")
    }
}
