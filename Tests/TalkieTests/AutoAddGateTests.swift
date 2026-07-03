import XCTest
@testable import Talkie

/// L2-b — the "added by Chirp" auto-add lane in LOG-ONLY / PREVIEW mode.
///
/// Two things are pinned here:
///   1. `AutoAddGate.shouldSuggest` — the pure predicate. The whole truth table:
///      LLM vs heuristic source × in-Claude/agent-terminal vs a plain surface × dup
///      vs new × context-awareness on/off (modeled as `frontApp == nil`). The gate
///      defaults to EXCLUDE and biases hard toward silence, so the tests lean on the
///      reject paths — a false positive drops noise into a hand-curated surface.
///   2. `AutoAddPreviewLog` — the LOG-ONLY sink: it records what the gate WOULD do,
///      caps at ~200, and honors true-delete (purge-by-dictation and clear-all), which
///      is what keeps a content-derived log from becoming an un-purgeable transcript
///      store. The log is constructor-injected with a temp file so a developer's real
///      calibration data is never touched.
///
/// Note: nothing here calls `ScratchpadStore.addLine` — the preview lane must never
/// write to the scratchpad, and the gate/log have no dependency on it.
@MainActor
final class AutoAddGateTests: XCTestCase {

    // MARK: - Fixtures

    /// A plain, non-task-executing surface (a chat app) with context awareness ON.
    private func chatApp(windowTitle: String? = "DM with Sarah") -> AutoAddGate.FrontApp {
        AutoAddGate.FrontApp(bundleID: "com.tinyspeck.slackmacgap", category: .chat, windowTitle: windowTitle)
    }

    /// The Claude desktop app.
    private func claudeApp() -> AutoAddGate.FrontApp {
        AutoAddGate.FrontApp(bundleID: "com.anthropic.claude", category: .other, windowTitle: "Claude")
    }

    /// A terminal running a coding agent (detected from the title).
    private func agentTerminal() -> AutoAddGate.FrontApp {
        AutoAddGate.FrontApp(bundleID: "com.googlecode.iterm2", category: .terminal, windowTitle: "~ zsh · claude")
    }

    /// A plain coding editor (a task-executing surface by category alone).
    private func editorApp() -> AutoAddGate.FrontApp {
        AutoAddGate.FrontApp(bundleID: "com.microsoft.VSCode", category: .coding, windowTitle: "main.swift — repo")
    }

    /// A strong LLM-style commitment clause.
    private let llmCommitment = "Send the design deck to Sarah on Friday"
    /// A heuristic clause that passes the stricter future check.
    private let strictHeuristic = "I need to email the vendor about the invoice"
    /// A heuristic clause that only trips a loose cue (a past-tense recollection) and
    /// must NOT pass the stricter check.
    private let looseHeuristic = "we had to follow up last week but it slipped"

    // MARK: - 1a. Source condition (LLM always trusted; heuristic must be strict)

    func testLLMCommitmentIntoPlainAppSuggests() {
        let d = AutoAddGate.shouldSuggest(
            commitmentText: llmCommitment, source: .llmExtractor,
            frontApp: chatApp(), existingLines: [])
        XCTAssertTrue(d.suggest)
        XCTAssertTrue(d.reasons.contains("pass:source-llm"))
    }

    func testStrictHeuristicIntoPlainAppSuggests() {
        let d = AutoAddGate.shouldSuggest(
            commitmentText: strictHeuristic, source: .heuristic,
            frontApp: chatApp(), existingLines: [])
        XCTAssertTrue(d.suggest)
        XCTAssertTrue(d.reasons.contains("pass:source-heuristic-strict-future"))
    }

    func testLooseHeuristicRejectedOnSource() {
        let d = AutoAddGate.shouldSuggest(
            commitmentText: looseHeuristic, source: .heuristic,
            frontApp: chatApp(), existingLines: [])
        XCTAssertFalse(d.suggest)
        XCTAssertTrue(d.reasons.contains("reject:heuristic-not-strict-future"))
    }

    func testQuestionIsNotAStrictCommitment() {
        // A future marker inside a question must not count as a commitment.
        XCTAssertFalse(AutoAddGate.passesStrictFutureCommitment("should I email the vendor?"))
    }

    func testPastTenseIsNotAStrictCommitment() {
        XCTAssertFalse(AutoAddGate.passesStrictFutureCommitment("I was going to email the vendor"))
        XCTAssertFalse(AutoAddGate.passesStrictFutureCommitment("we had to email the vendor"))
    }

    func testFirstAndSecondPersonFutureBothPass() {
        XCTAssertTrue(AutoAddGate.passesStrictFutureCommitment("I'll ship the build tonight"))
        XCTAssertTrue(AutoAddGate.passesStrictFutureCommitment("you should review the PR"))
        XCTAssertTrue(AutoAddGate.passesStrictFutureCommitment("let's schedule the retro"))
    }

    // MARK: - 1b. App condition (task-executing surfaces excluded; unknown fails closed)

    func testCommitmentIntoClaudeDesktopRejected() {
        let d = AutoAddGate.shouldSuggest(
            commitmentText: llmCommitment, source: .llmExtractor,
            frontApp: claudeApp(), existingLines: [])
        XCTAssertFalse(d.suggest)
        XCTAssertTrue(d.reasons.contains(where: { $0.hasPrefix("reject:task-executing-surface") }))
    }

    func testCommitmentIntoAgentTerminalRejected() {
        let d = AutoAddGate.shouldSuggest(
            commitmentText: llmCommitment, source: .llmExtractor,
            frontApp: agentTerminal(), existingLines: [])
        XCTAssertFalse(d.suggest)
        XCTAssertTrue(d.reasons.contains(where: { $0.hasPrefix("reject:task-executing-surface") }))
    }

    func testCommitmentIntoEditorRejected() {
        let d = AutoAddGate.shouldSuggest(
            commitmentText: llmCommitment, source: .llmExtractor,
            frontApp: editorApp(), existingLines: [])
        XCTAssertFalse(d.suggest)
        XCTAssertTrue(d.reasons.contains(where: { $0.hasPrefix("reject:task-executing-surface") }))
    }

    func testContextAwarenessOffFailsClosedButIsStillLoggable() {
        // frontApp == nil models context awareness OFF. Even a perfect LLM commitment
        // is rejected — but the decision (and its reason) is returned so the caller can
        // log the fail-closed attempt.
        let d = AutoAddGate.shouldSuggest(
            commitmentText: llmCommitment, source: .llmExtractor,
            frontApp: nil, existingLines: [])
        XCTAssertFalse(d.suggest)
        XCTAssertTrue(d.reasons.contains("reject:front-app-unknown-fail-closed"))
    }

    // MARK: - 1c. Duplicate condition

    func testExactDuplicateRejected() {
        let d = AutoAddGate.shouldSuggest(
            commitmentText: llmCommitment, source: .llmExtractor,
            frontApp: chatApp(), existingLines: [llmCommitment])
        XCTAssertFalse(d.suggest)
        XCTAssertTrue(d.reasons.contains("reject:near-duplicate"))
    }

    func testNormalizedDuplicateRejected() {
        // Same commitment, different casing / trailing punctuation / a task marker.
        let existing = ["- send the DESIGN deck to sarah on friday."]
        let d = AutoAddGate.shouldSuggest(
            commitmentText: llmCommitment, source: .llmExtractor,
            frontApp: chatApp(), existingLines: existing)
        XCTAssertFalse(d.suggest)
        XCTAssertTrue(d.reasons.contains("reject:near-duplicate"))
    }

    func testNonDuplicatePasses() {
        let d = AutoAddGate.shouldSuggest(
            commitmentText: llmCommitment, source: .llmExtractor,
            frontApp: chatApp(), existingLines: ["buy milk", "call the dentist"])
        XCTAssertTrue(d.suggest)
        XCTAssertTrue(d.reasons.contains("pass:not-duplicate"))
    }

    func testNormalizeStripsMarkersAndPunctuation() {
        XCTAssertEqual(AutoAddGate.normalizedForDuplicate("- Buy Milk."),
                       AutoAddGate.normalizedForDuplicate("[] buy milk"))
        XCTAssertEqual(AutoAddGate.normalizedForDuplicate("  Follow   up  with Sam!  "),
                       "follow up with sam")
    }

    // MARK: - 1d. Empty / degenerate input

    func testEmptyCommitmentRejected() {
        let d = AutoAddGate.shouldSuggest(
            commitmentText: "  ", source: .llmExtractor,
            frontApp: chatApp(), existingLines: [])
        XCTAssertFalse(d.suggest)
        XCTAssertTrue(d.reasons.contains("reject:empty-or-too-short"))
    }

    // MARK: - 1e. Full truth-table sweep (all four axes)

    func testTruthTableAllAxes() {
        // suggest is TRUE iff: (LLM OR strict-heuristic) AND (known non-executing app)
        // AND (not a duplicate).
        struct Case {
            let text: String
            let source: AutoAddGate.CommitmentSource
            let app: AutoAddGate.FrontApp?
            let existing: [String]
            let expected: Bool
        }
        let plain = chatApp()
        let cases: [Case] = [
            // LLM × plain × new  → suggest
            Case(text: llmCommitment, source: .llmExtractor, app: plain, existing: [], expected: true),
            // LLM × plain × dup  → no
            Case(text: llmCommitment, source: .llmExtractor, app: plain, existing: [llmCommitment], expected: false),
            // LLM × claude × new → no (executing surface)
            Case(text: llmCommitment, source: .llmExtractor, app: claudeApp(), existing: [], expected: false),
            // LLM × nil × new    → no (context awareness off)
            Case(text: llmCommitment, source: .llmExtractor, app: nil, existing: [], expected: false),
            // strict heuristic × plain × new → suggest
            Case(text: strictHeuristic, source: .heuristic, app: plain, existing: [], expected: true),
            // strict heuristic × agent terminal × new → no
            Case(text: strictHeuristic, source: .heuristic, app: agentTerminal(), existing: [], expected: false),
            // loose heuristic × plain × new → no (source fails strict check)
            Case(text: looseHeuristic, source: .heuristic, app: plain, existing: [], expected: false),
            // loose heuristic × claude × new → no (both fail)
            Case(text: looseHeuristic, source: .heuristic, app: claudeApp(), existing: [], expected: false),
        ]
        for c in cases {
            let d = AutoAddGate.shouldSuggest(
                commitmentText: c.text, source: c.source,
                frontApp: c.app, existingLines: c.existing)
            XCTAssertEqual(d.suggest, c.expected,
                           "text=\(c.text) source=\(c.source) app=\(String(describing: c.app?.bundleID)) existing=\(c.existing) reasons=\(d.reasons)")
        }
    }

    // MARK: - 2. AutoAddPreviewLog (LOG-ONLY sink)

    private func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("talkie-l2b-test-\(UUID().uuidString).json")
    }

    private func makeDecision(_ suggest: Bool) -> AutoAddGate.Decision {
        AutoAddGate.Decision(suggest: suggest, reasons: suggest ? ["pass:x"] : ["reject:x"])
    }

    func testPreviewLogRecordsWhatGateWouldDo() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = AutoAddPreviewLog(fileURL: url)

        log.record(commitmentText: "email vendor", frontAppBundleID: "com.tinyspeck.slackmacgap",
                   source: .heuristic, decision: makeDecision(true), sourceDictationID: "d1")
        XCTAssertEqual(log.records.count, 1)
        let r = try XCTUnwrap(log.records.first)
        XCTAssertEqual(r.commitmentText, "email vendor")
        XCTAssertEqual(r.source, "heuristic")
        XCTAssertTrue(r.wouldSuggest)
        XCTAssertEqual(r.sourceDictationID, "d1")
    }

    func testPreviewLogPersistsAndReloads() {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let log = AutoAddPreviewLog(fileURL: url)
            log.record(commitmentText: "call the dentist", frontAppBundleID: nil,
                       source: .llmExtractor, decision: makeDecision(false), sourceDictationID: "d9")
        }
        // A fresh store over the same file sees the persisted record.
        let reloaded = AutoAddPreviewLog(fileURL: url)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records.first?.commitmentText, "call the dentist")
        XCTAssertEqual(reloaded.records.first?.frontAppBundleID, nil)
    }

    func testPreviewLogRollingCap() {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = AutoAddPreviewLog(fileURL: url)
        let over = AutoAddPreviewLog.maxRecords + 25
        for i in 0..<over {
            log.record(commitmentText: "c\(i)", frontAppBundleID: nil,
                       source: .heuristic, decision: makeDecision(false), sourceDictationID: "d\(i)")
        }
        XCTAssertEqual(log.records.count, AutoAddPreviewLog.maxRecords)
        // Oldest dropped: the first surviving record is c25, the last is the newest.
        XCTAssertEqual(log.records.first?.commitmentText, "c25")
        XCTAssertEqual(log.records.last?.commitmentText, "c\(over - 1)")
    }

    func testPreviewLogPurgeBySourceRemovesOnlyThatDictation() {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = AutoAddPreviewLog(fileURL: url)
        log.record(commitmentText: "a", frontAppBundleID: nil, source: .heuristic,
                   decision: makeDecision(true), sourceDictationID: "keep")
        log.record(commitmentText: "b", frontAppBundleID: nil, source: .heuristic,
                   decision: makeDecision(true), sourceDictationID: "gone")
        log.record(commitmentText: "c", frontAppBundleID: nil, source: .heuristic,
                   decision: makeDecision(true), sourceDictationID: "keep")

        log.purge(sourceID: "gone")
        XCTAssertEqual(log.records.map(\.commitmentText), ["a", "c"])
        XCTAssertFalse(log.records.contains(where: { $0.sourceDictationID == "gone" }))
    }

    func testPreviewLogPurgeAllDictationSourcedClearsIDLinkedRecords() {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = AutoAddPreviewLog(fileURL: url)
        log.record(commitmentText: "a", frontAppBundleID: nil, source: .heuristic,
                   decision: makeDecision(true), sourceDictationID: "d1")
        log.record(commitmentText: "b", frontAppBundleID: nil, source: .heuristic,
                   decision: makeDecision(true), sourceDictationID: "d2")

        log.purgeAllDictationSourced()
        XCTAssertTrue(log.records.isEmpty)
    }

    func testPreviewLogResetWipesEverything() {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = AutoAddPreviewLog(fileURL: url)
        log.record(commitmentText: "a", frontAppBundleID: nil, source: .heuristic,
                   decision: makeDecision(true), sourceDictationID: "d1")
        log.reset()
        XCTAssertTrue(log.records.isEmpty)

        // And the wipe persisted.
        let reloaded = AutoAddPreviewLog(fileURL: url)
        XCTAssertTrue(reloaded.records.isEmpty)
    }

    func testCorruptFileDecodesToEmpty() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json at all".utf8).write(to: url)
        let log = AutoAddPreviewLog(fileURL: url)
        XCTAssertTrue(log.records.isEmpty)
    }
}
