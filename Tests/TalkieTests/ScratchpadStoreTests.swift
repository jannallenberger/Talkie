import XCTest
@testable import Talkie

/// L2-a: `ScratchpadStore` backs the dashboard hero card (notes + checkbox tasks)
/// and is the landing spot for transcripts that couldn't be pasted.
///
/// Like the other store tests, this reads/writes the fixed `scratchpad.json` under
/// Application Support, so persistence tests snapshot whatever is on disk in
/// `setUp` and restore it in `tearDown` — a developer running the suite never loses
/// their real scratchpad. Prefix parsing is a pure static and is exercised directly.
@MainActor
final class ScratchpadStoreTests: XCTestCase {
    private var fileURL: URL { AppPaths.supportDirectory().appendingPathComponent("scratchpad.json") }
    private var saved: Data?

    override func setUp() {
        super.setUp()
        saved = try? Data(contentsOf: fileURL)
        try? FileManager.default.removeItem(at: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        if let d = saved { try? d.write(to: fileURL) }
        super.tearDown()
    }

    // MARK: Prefix parsing (pure)

    func testParsePlainNote() {
        let p = ScratchpadStore.parse("just a note")
        XCTAssertEqual(p, ScratchpadStore.Parsed(text: "just a note", isTask: false, done: false))
    }

    func testParseDashBulletBecomesTask() {
        let p = ScratchpadStore.parse("- buy milk")
        XCTAssertEqual(p, ScratchpadStore.Parsed(text: "buy milk", isTask: true, done: false))
    }

    func testParseEmptyCheckboxBecomesUncheckedTask() {
        XCTAssertEqual(ScratchpadStore.parse("[] ship it"),
                       ScratchpadStore.Parsed(text: "ship it", isTask: true, done: false))
        XCTAssertEqual(ScratchpadStore.parse("[ ] ship it"),
                       ScratchpadStore.Parsed(text: "ship it", isTask: true, done: false))
    }

    func testParseCheckedCheckboxBecomesDoneTask() {
        XCTAssertEqual(ScratchpadStore.parse("[x] already done"),
                       ScratchpadStore.Parsed(text: "already done", isTask: true, done: true))
        XCTAssertEqual(ScratchpadStore.parse("[X] already done"),
                       ScratchpadStore.Parsed(text: "already done", isTask: true, done: true))
    }

    func testParseLeadingWhitespaceTolerated() {
        XCTAssertEqual(ScratchpadStore.parse("   - indented task"),
                       ScratchpadStore.Parsed(text: "indented task", isTask: true, done: false))
    }

    func testParseDashWithoutSpaceIsNotATask() {
        // A bare hyphen (e.g. a range "3-5") must not become a checkbox.
        let p = ScratchpadStore.parse("-notabullet")
        XCTAssertFalse(p.isTask)
        XCTAssertEqual(p.text, "-notabullet")
    }

    // MARK: addLine parses prefixes

    func testAddLinePlainNote() {
        let store = ScratchpadStore()
        store.addLine("remember this")
        XCTAssertEqual(store.lines.count, 1)
        XCTAssertEqual(store.lines[0].text, "remember this")
        XCTAssertFalse(store.lines[0].isTask)
        XCTAssertFalse(store.lines[0].addedByAI, "addedByAI defaults false")
        XCTAssertNil(store.lines[0].sourceDictationID)
    }

    func testAddLineDashBecomesTask() {
        let store = ScratchpadStore()
        store.addLine("- do the thing")
        XCTAssertTrue(store.lines[0].isTask)
        XCTAssertEqual(store.lines[0].text, "do the thing")
        XCTAssertFalse(store.lines[0].done)
    }

    func testAddLineCarriesSourceAndAIFlag() {
        let store = ScratchpadStore()
        store.addLine("rescued transcript", sourceDictationID: "abc-123", addedByAI: true)
        XCTAssertEqual(store.lines[0].sourceDictationID, "abc-123")
        XCTAssertTrue(store.lines[0].addedByAI)
    }

    // MARK: toggle + update

    func testToggleDoneFlipsTaskOnly() {
        let store = ScratchpadStore()
        store.addLine("- a task")
        store.addLine("a note")
        let taskID = store.lines[0].id
        let noteID = store.lines[1].id

        store.toggleDone(id: taskID)
        XCTAssertTrue(store.lines[0].done)
        store.toggleDone(id: taskID)
        XCTAssertFalse(store.lines[0].done)

        // Toggling a note is a no-op (it isn't a task).
        store.toggleDone(id: noteID)
        XCTAssertFalse(store.lines[1].done)
    }

    func testUpdatePromotesNoteToTaskInPlace() {
        let store = ScratchpadStore()
        store.addLine("plain")
        let id = store.lines[0].id
        store.update(id: id, text: "- now a task")
        XCTAssertTrue(store.lines[0].isTask)
        XCTAssertEqual(store.lines[0].text, "now a task")
    }

    func testUpdateDoesNotDemoteTaskWhenMarkerRemoved() {
        let store = ScratchpadStore()
        store.addLine("- task")
        let id = store.lines[0].id
        store.toggleDone(id: id)
        // Editing the text without the marker keeps it a (done) task.
        store.update(id: id, text: "task edited")
        XCTAssertTrue(store.lines[0].isTask)
        XCTAssertTrue(store.lines[0].done)
        XCTAssertEqual(store.lines[0].text, "task edited")
    }

    func testDeleteRemovesLine() {
        let store = ScratchpadStore()
        store.addLine("one")
        store.addLine("two")
        let id = store.lines[0].id
        store.delete(id: id)
        XCTAssertEqual(store.lines.count, 1)
        XCTAssertEqual(store.lines[0].text, "two")
    }

    // MARK: purge-by-source vs typed-line survival

    func testPurgeBySourceRemovesOnlyThatDictationsLines() {
        let store = ScratchpadStore()
        store.addLine("typed by hand")                                   // sourceID nil
        store.addLine("from dictation A", sourceDictationID: "A")
        store.addLine("also from A", sourceDictationID: "A")
        store.addLine("from dictation B", sourceDictationID: "B")

        store.purge(sourceID: "A")
        let remaining = store.lines.map(\.text)
        XCTAssertEqual(remaining, ["typed by hand", "from dictation B"])
    }

    func testPurgeAllDictationSourcedKeepsTypedLines() {
        let store = ScratchpadStore()
        store.addLine("my own note")                                     // survives
        store.addLine("- my own task")                                   // survives
        store.addLine("rescued 1", sourceDictationID: "A")
        store.addLine("rescued 2", sourceDictationID: "B")

        store.purgeAllDictationSourced()
        let remaining = store.lines.map(\.text)
        XCTAssertEqual(remaining, ["my own note", "my own task"],
                       "typed lines (sourceDictationID == nil) survive Clear-everything")
        XCTAssertTrue(store.lines.allSatisfy { $0.sourceDictationID == nil })
    }

    // MARK: Persistence round-trip

    func testTogglePersistsAcrossReload() {
        do {
            let store = ScratchpadStore()
            store.addLine("- persistent task")
            store.toggleDone(id: store.lines[0].id)
            store.addLine("a note too")
        }
        let reloaded = ScratchpadStore()
        XCTAssertEqual(reloaded.lines.count, 2)
        XCTAssertTrue(reloaded.lines[0].isTask)
        XCTAssertTrue(reloaded.lines[0].done, "the checked state survives a reload")
        XCTAssertEqual(reloaded.lines[0].text, "persistent task")
        XCTAssertEqual(reloaded.lines[1].text, "a note too")
    }

    func testCorruptFileLoadsEmpty() {
        try? Data("}{ not json at all".utf8).write(to: fileURL, options: .atomic)
        let store = ScratchpadStore()
        XCTAssertTrue(store.lines.isEmpty, "a corrupt file must decode to an empty store")
        // And the store is still usable afterward.
        store.addLine("recovered")
        XCTAssertEqual(store.lines.count, 1)
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let store = ScratchpadStore()
        XCTAssertTrue(store.lines.isEmpty)
    }
}
