import XCTest
@testable import Talkie

/// Setup by the AI agent over MCP (`update_settings`) and agent-written meeting
/// summaries (`set_meeting_summary`): what is accepted, what changes, and that the
/// Undo pill puts everything back.
@MainActor
final class AgentSetupTests: XCTestCase {

    // MARK: Validation

    func testPlanKeepsOnlySupportedValues() {
        let plan = AgentSetup.plan(AgentSettingsChange(
            userName: "  Jann  ", assistantName: "Kiwi", appLanguage: "DE",
            spokenLanguages: ["de_DE", "English (US)", "klingon", "de-DE"],
            accent: "Ember", backdrop: "aurora", appearance: "dark"))
        XCTAssertEqual(plan.userName, "Jann")
        XCTAssertEqual(plan.assistantName, "Kiwi")
        XCTAssertEqual(plan.appLanguage, "de")
        XCTAssertEqual(plan.spokenLanguages, ["de-DE", "en-US"], "unknown dropped, duplicates folded, order kept")
        XCTAssertEqual(plan.accent, .ember)
        XCTAssertNil(plan.backdrop, "an unknown backdrop is dropped, not guessed")
        XCTAssertEqual(plan.appearance, .dark)
    }

    func testRejectsOverlongOrMultilineNamesAndEmptyLanguageLists() {
        let plan = AgentSetup.plan(AgentSettingsChange(
            userName: String(repeating: "a", count: 41), assistantName: "Two\nlines",
            spokenLanguages: ["xx-XX"]))
        XCTAssertNil(plan.userName)
        XCTAssertNil(plan.assistantName)
        XCTAssertNil(plan.spokenLanguages, "never leaves the user with no language")
        XCTAssertTrue(plan.isEmpty)
    }

    func testAppLanguageNormalisation() {
        XCTAssertEqual(AppLanguage.normalized("pt"), "pt-BR")
        XCTAssertEqual(AppLanguage.normalized("zh_Hans"), "zh-Hans")
        XCTAssertEqual(AppLanguage.normalized("System"), AppLanguage.system)
        XCTAssertNil(AppLanguage.normalized("tlh"))
    }

    func testChangesSkipWhatIsAlreadySet() {
        let current = AgentSettingsPlan(userName: "Jann", assistantName: "", appLanguage: "system",
                                        spokenLanguages: ["en-US"], accent: .ember, backdrop: .ember, appearance: .system)
        let wanted = AgentSettingsPlan(userName: "Jann", spokenLanguages: ["en-US", "de-DE"], accent: .ember)
        let delta = AgentSetup.changes(wanted, from: current)
        XCTAssertNil(delta.userName)
        XCTAssertNil(delta.accent)
        XCTAssertEqual(delta.spokenLanguages, ["en-US", "de-DE"])
        XCTAssertTrue(AgentSetup.changes(current, from: current).isEmpty)
    }

    func testUndoPlanRestoresTheAccentABackdropBrought() {
        let before = AgentSettingsPlan(userName: "A", accent: .plum, backdrop: .dusk)
        let undo = AgentSetup.undoPlan(for: AgentSettingsPlan(backdrop: .lagoon), before: before)
        XCTAssertEqual(undo.backdrop, .dusk)
        XCTAssertEqual(undo.accent, .plum)
        XCTAssertNil(undo.userName)
    }

    // MARK: Agent summary keeps the user's notes

    func testAgentSummaryKeepsTheNotesSection() throws {
        let notes = [MeetingNote(text: "Call Ana about the launch")]
        let composed = try XCTUnwrap(Meeting.agentSummaryForTesting("## Overview\nWe agreed on Friday.", notes: notes))
        XCTAssertTrue(composed.hasPrefix("## Overview"))
        XCTAssertTrue(composed.contains("Call Ana about the launch"), "the user's note must survive")
        XCTAssertNil(MeetingStore.agentSummary("   ", notes: notes, transcript: ""))
        XCTAssertEqual(MeetingStore.agentSummary("Just this.", notes: [], transcript: ""), "Just this.")
    }

    // MARK: Through the inbox

    private var tmp: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("talkie-agent-setup-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        suiteName = "talkie.agent-setup.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        defaults.removePersistentDomain(forName: suiteName)
        ThemeState.adopt(TalkieLook())
        super.tearDown()
    }

    private func write(_ dict: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        try! data.write(to: tmp.appendingPathComponent("inbox/\(UUID().uuidString).json"))
    }

    func testSettingsSuggestionAppliesAndUndoPutsItBack() throws {
        let settings = AppSettings()
        let savedName = settings.userName, savedLangs = settings.spokenLanguages, savedBird = settings.parrotName
        defer { settings.userName = savedName; settings.spokenLanguages = savedLangs; settings.parrotName = savedBird }
        settings.userName = "Old"
        settings.spokenLanguages = ["en-US"]
        let appearance = AppearanceStore(defaults: defaults)
        var shown: [(String, () -> Void)] = []
        var reverted = 0
        let inbox = DictionaryInbox(
            dictionary: DictionaryStore(), nicheVocab: NicheVocabStore(directory: tmp.appendingPathComponent("niche")),
            settings: settings, appearance: appearance, defaults: defaults,
            directory: tmp.appendingPathComponent("inbox"),
            presentPill: { shown.append(($0, $1)) }, presentReverted: { reverted += 1 })

        write(["kind": "settings", "op": "updateSettings", "createdUnix": Date().timeIntervalSince1970, "version": 1,
               "settings": ["userName": "Jann", "spokenLanguages": ["en-US", "de-DE"], "backdrop": "lagoon"]])
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 1)
        XCTAssertEqual(settings.userName, "Jann")
        XCTAssertEqual(settings.spokenLanguages, ["en-US", "de-DE"])
        XCTAssertEqual(appearance.look.backdrop, .lagoon)
        XCTAssertEqual(appearance.look.accent, .green, "a backdrop brings its accent, as in Settings")
        let (message, undo) = try XCTUnwrap(shown.first)
        XCTAssertTrue(message.contains("your name"), message)

        undo()
        XCTAssertEqual(settings.userName, "Old")
        XCTAssertEqual(settings.spokenLanguages, ["en-US"])
        XCTAssertEqual(appearance.look.backdrop, TalkieLook().backdrop)
        XCTAssertEqual(appearance.look.accent, TalkieLook().accent)
        XCTAssertEqual(reverted, 1)

        // The same values again change nothing: no second pill.
        write(["kind": "settings", "op": "updateSettings", "createdUnix": Date().timeIntervalSince1970, "version": 1,
               "settings": ["userName": "Old"]])
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 0)
    }

    func testSummarySuggestionAppliesAndUndoRestores() throws {
        let store = MeetingStore(supportDirectory: tmp, meetingsDirectory: tmp)
        var meeting = Meeting(title: "Weekly", startUnix: 1_700_000_000, durationSec: 60,
                              transcript: "[00:01] Me: hello", summary: "on-device summary",
                              fileName: "weekly.md")
        meeting.notes = [MeetingNote(text: "Bring the budget")]
        store.add(meeting)
        var undoFn: (() -> Void)?
        let inbox = DictionaryInbox(
            dictionary: DictionaryStore(), nicheVocab: NicheVocabStore(directory: tmp.appendingPathComponent("niche")),
            meetingStore: store, directory: tmp.appendingPathComponent("inbox"),
            presentPill: { _, undo in undoFn = undo }, presentReverted: {})

        write(["kind": "meeting", "op": "setMeetingSummary", "meetingID": String(meeting.id.uuidString.prefix(8)),
               "text": "## Overview\nShipped.", "createdUnix": Date().timeIntervalSince1970, "version": 1])
        XCTAssertEqual(inbox.drainSynchronouslyForTesting(), 1)
        let written = try XCTUnwrap(store.meetings.first?.summary)
        XCTAssertTrue(written.hasPrefix("## Overview\nShipped."))
        XCTAssertTrue(written.contains("Bring the budget"))
        try XCTUnwrap(undoFn)()
        XCTAssertEqual(store.meetings.first?.summary, "on-device summary")
    }
}

extension Meeting {
    /// The store's composition, from the meeting side, for readability above.
    static func agentSummaryForTesting(_ text: String, notes: [MeetingNote]) -> String? {
        MeetingStore.agentSummary(text, notes: notes, transcript: "")
    }
}
