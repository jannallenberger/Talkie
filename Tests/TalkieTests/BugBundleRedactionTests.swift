import XCTest
@testable import Talkie

/// Proves the K8 bug bundle can NEVER leak the user's learned corrections,
/// dictated words, or name. The redaction pass is the whole privacy feature, so
/// these tests are adversarial: they feed in log lines in `LearningEngine`'s
/// ACTUAL emitted formats (from `LearningEngine.swift:88,107` and the baseline/
/// watch lines) plus planted secrets, and assert the secret never survives into
/// the bundle. Pure-logic only — no disk, no `Bundle.main`.
final class BugBundleRedactionTests: XCTestCase {

    // A distinctive token planted inside "private" content; if it ever appears in
    // redacted output, redaction failed. Chosen to be implausible in a real log.
    private let secret = "ZZQSECRETZZQ"

    // MARK: - LearningEngine's real "learned" formats are always dropped

    func testLearnedLineIsRedacted() {
        // Exact shape of LearningEngine.swift:107.
        let line = "learn: ✓ LEARNED 'higgs \(secret)' → 'Higgsfield'"
        XCTAssertFalse(BugBundle.isSafe(line),
                       "A 'LEARNED' correction line embeds the user's spoken words and must be dropped")
        XCTAssertTrue(BugBundle.redact([line]).isEmpty,
                      "redact must remove the learned correction entirely")
    }

    func testLearnedOnSendLineIsRedacted() {
        // Exact shape of LearningEngine.swift:88.
        let line = "learn: ✓ LEARNED on send 'cloud \(secret)' → 'claude.md'"
        XCTAssertFalse(BugBundle.isSafe(line),
                       "The send-path learned line also carries dictated words")
    }

    func testLearnBaselineLineWithAppNameIsRedacted() {
        // LearningEngine baseline lines interpolate the front app name + role and
        // can echo field content; the whole `learn:` family is untrusted.
        let line = "learn: ✓ baseline acquired (app=\(secret), role=AXTextArea, 42 chars)"
        XCTAssertFalse(BugBundle.isSafe(line),
                       "learn: lines interpolate app/field content and must be dropped wholesale")
    }

    func testWatchingLineIsRedacted() {
        let line = "learn: watching after insert (12 chars), app=\(secret)"
        XCTAssertFalse(BugBundle.isSafe(line))
    }

    // MARK: - Quote / arrow shapes are dropped wherever they appear

    func testAnyCorrectionArrowIsRedacted() {
        XCTAssertFalse(BugBundle.isSafe("something \(secret) → else"),
                       "The from→to arrow shape is a correction signal anywhere")
        XCTAssertFalse(BugBundle.isSafe("ascii arrow \(secret) -> here"))
    }

    func testQuotedContentIsRedacted() {
        for quoted in ["'\(secret)'", "\"\(secret)\"", "\u{2018}\(secret)\u{2019}",
                       "\u{201C}\(secret)\u{201D}", "\u{300C}\(secret)\u{300D}"] {
            let line = "note: heard \(quoted) in field"
            XCTAssertFalse(BugBundle.isSafe(line),
                           "Quoted content \(quoted) could wrap user words and must be dropped")
        }
    }

    func testLoneQuoteIsRedacted() {
        // A half-logged / truncated line with a single dangling quote is still dropped.
        XCTAssertFalse(BugBundle.isSafe("truncated tail 'the user said \(secret)"),
                       "Even an unbalanced quote closes the truncated-line hole")
    }

    // MARK: - Genuinely diagnostic lines survive

    func testDiagnosticLinesAreKept() {
        let kept = [
            "lang: auto-detect chose de-DE (score 0.82 vs 0.41)",
            "session started; sample rate 16000 Hz",
            "cleanup: neutral style applied in 34 ms",
            "insert: paste path, 0 fallbacks",
        ]
        XCTAssertEqual(BugBundle.redact(kept), kept,
                       "Timing/diagnostic lines with no quoted payload must be preserved")
    }

    func testRedactionIsIdempotent() {
        let mixed = [
            "session started",
            "learn: ✓ LEARNED 'a' → 'b'",
            "sample rate 16000",
            "note: 'quoted'",
        ]
        let once = BugBundle.redact(mixed)
        let twice = BugBundle.redact(once)
        XCTAssertEqual(once, twice, "Redacting an already-redacted list is a no-op")
        XCTAssertEqual(once, ["session started", "sample rate 16000"],
                       "Only the clean diagnostic lines survive")
    }

    // MARK: - The assembled bundle never contains planted secrets

    func testBuiltBundleContainsNoLearnedOrDictatedContent() {
        let hostileLog = [
            "learn: ✓ LEARNED 'higgs \(secret)' → 'Higgsfield'",
            "learn: ✓ LEARNED on send 'cloud \(secret)' → 'claude.md'",
            "learn: ✓ baseline acquired (app=Secret\(secret)App, role=AXTextArea, 88 chars)",
            "note: user typed \u{201C}\(secret)\u{201D}",
            "lang: chose en-US (clean diagnostic)",
        ]
        let env = Self.sampleEnvironment()
        let bundle = BugBundle.build(environment: env, logTail: hostileLog)

        XCTAssertFalse(bundle.contains(secret),
                       "No planted learned/dictated token may survive into the bundle text")
        XCTAssertFalse(bundle.contains("LEARNED"),
                       "The LEARNED marker itself must never appear in the bundle")
        XCTAssertTrue(bundle.contains("clean diagnostic"),
                      "A genuinely safe diagnostic line should still make it in")
    }

    func testBuiltBundleNeverContainsUserNameOrParrotName() {
        // The name is never part of the Environment whitelist, so even with a
        // hostile log it cannot appear. This pins the whitelist contract.
        let bundle = BugBundle.build(environment: Self.sampleEnvironment(),
                                     logTail: ["learn: ✓ LEARNED 'x' → 'y'"])
        XCTAssertFalse(bundle.contains("Jann"),
                       "The user's name is not in the whitelist and must never appear")
        XCTAssertFalse(bundle.lowercased().contains("parrot"),
                       "The parrot name is not in the whitelist and must never appear")
    }

    // MARK: - Missing / empty log ("no debug log on this Mac")

    func testEmptyLogProducesFriendlyPlaceholder() {
        let bundle = BugBundle.build(environment: Self.sampleEnvironment(), logTail: [])
        XCTAssertTrue(bundle.contains("No debug log on this Mac"),
                      "A missing log must render an honest placeholder, not crash or blank")
        XCTAssertFalse(bundle.contains("```"),
                       "With no log there is no code block to render")
    }

    func testLogThatIsAllPrivateBecomesTheEmptyPlaceholder() {
        // If every line is private, the redacted tail is empty → same friendly path.
        let allPrivate = [
            "learn: ✓ LEARNED 'a \(secret)' → 'b'",
            "learn: watching after insert (3 chars), app=\(secret)",
        ]
        let bundle = BugBundle.build(environment: Self.sampleEnvironment(), logTail: allPrivate)
        XCTAssertFalse(bundle.contains(secret))
        XCTAssertTrue(bundle.contains("No debug log on this Mac"),
                      "A fully-redacted log collapses to the honest empty placeholder")
    }

    // MARK: - The whitelisted content IS present (bundle is actually useful)

    func testBundleIncludesWhitelistedEnvironment() {
        let bundle = BugBundle.build(environment: Self.sampleEnvironment(), logTail: [])
        XCTAssertTrue(bundle.contains("0.1.0"), "App version should be reported")
        XCTAssertTrue(bundle.contains("26.0.0"), "macOS version should be reported")
        XCTAssertTrue(bundle.contains("arm64"), "Architecture should be reported")
        XCTAssertTrue(bundle.contains("rightOption"), "Activation key should be reported")
        XCTAssertTrue(bundle.contains("granted"), "Permission states should be reported")
    }

    func testBuildIsDeterministic() {
        // Same inputs → identical bytes, so the preview equals the copied text.
        let env = Self.sampleEnvironment()
        let log = ["lang: chose en-US", "session started"]
        XCTAssertEqual(BugBundle.build(environment: env, logTail: log),
                       BugBundle.build(environment: env, logTail: log),
                       "The builder must be a pure function of its inputs")
    }

    // MARK: - cleanup summary is non-identifying

    func testCleanupSummaryNeverLeaksBundleIDs() {
        let styles = ["com.private.app": "professional", "editor.category": "prompt"]
        let summary = BugBundle.cleanupSummary(styles)
        XCTAssertFalse(summary.contains("com.private.app"),
                       "The cleanup summary must not name the user's configured apps")
        XCTAssertFalse(summary.contains("professional"))
        XCTAssertEqual(summary, "default + 2 app overrides")
        XCTAssertEqual(BugBundle.cleanupSummary([:]), "default only")
        XCTAssertEqual(BugBundle.cleanupSummary(["a": "b"]), "default + 1 app override")
    }

    // MARK: - Fixture

    private static func sampleEnvironment() -> BugBundle.Environment {
        BugBundle.Environment(
            appVersion: "0.1.0",
            appBuild: "1",
            osVersion: "26.0.0",
            architecture: "arm64",
            localeIdentifier: "en-US",
            spokenLanguages: ["en-US", "de-DE"],
            accessibilityGranted: true,
            inputMonitoringGranted: true,
            microphoneGranted: false,
            activationKey: "rightOption",
            cleanupSummary: "default only",
            historyRetentionDays: 7,
            autoDetectMeetings: true,
            contextAwareness: true,
            vibeCoding: false,
            learnFromEdits: true,
            optimisticInsertion: false,
            playSounds: true,
            launchAtLogin: false,
            showBirdBuddy: true
        )
    }
}
