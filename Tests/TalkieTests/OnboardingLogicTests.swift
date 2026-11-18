import XCTest
@testable import Talkie

final class OnboardingLogicTests: XCTestCase {

    // MARK: Permission row state machine (fix 1)

    func testGrantedRowShowsNoButton() {
        XCTAssertEqual(PermissionRowAction.decide(granted: true, canShowSystemPrompt: true), .granted)
        XCTAssertEqual(PermissionRowAction.decide(granted: true, canShowSystemPrompt: false), .granted)
    }

    func testUndecidedRowStillAsksTheSystem() {
        XCTAssertEqual(PermissionRowAction.decide(granted: false, canShowSystemPrompt: true), .request)
    }

    func testDeniedOrAlreadyPromptedRowOpensSystemSettings() {
        XCTAssertEqual(PermissionRowAction.decide(granted: false, canShowSystemPrompt: false), .openSettings)
    }

    @MainActor
    func testModelReportsEveryKindAndOnlyGrantedOnesAreDone() {
        let model = PermissionsModel()
        // A fresh model has nothing granted; every kind resolves to a button (never
        // to a dead end), and a granted state flips it to the check.
        for kind in PermissionKind.allCases {
            XCTAssertNotEqual(model.rowAction(kind), .granted)
        }
        model.microphone = true
        XCTAssertEqual(model.rowAction(.microphone), .granted)
    }

    // MARK: Hotkey tap retry (fix 5)

    func testRetriesOnlyWhenTheGrantIsFirstObserved() {
        XCTAssertTrue(HotKeyTapRetry.shouldRetry(wasGranted: false, isGranted: true))
        XCTAssertFalse(HotKeyTapRetry.shouldRetry(wasGranted: true, isGranted: true))
        XCTAssertFalse(HotKeyTapRetry.shouldRetry(wasGranted: false, isGranted: false))
        XCTAssertFalse(HotKeyTapRetry.shouldRetry(wasGranted: true, isGranted: false))
    }

    func testRelaunchHintWhenGrantedButTapWontInstall() {
        XCTAssertTrue(HotKeyTapRetry.needsRelaunch(granted: true, tapInstalled: false))
        XCTAssertFalse(HotKeyTapRetry.needsRelaunch(granted: true, tapInstalled: true))
        XCTAssertFalse(HotKeyTapRetry.needsRelaunch(granted: false, tapInstalled: false))
    }

    // MARK: Title count (fix 3)

    func testHeadingCountsTheRowsStillMissing() {
        XCTAssertEqual(OnboardingPermissionsCopy.headingKey(missing: 3), "Three permissions")
        XCTAssertEqual(OnboardingPermissionsCopy.headingKey(missing: 2), "Two more permissions")
        XCTAssertEqual(OnboardingPermissionsCopy.headingKey(missing: 1), "One more permission")
        XCTAssertEqual(OnboardingPermissionsCopy.headingKey(missing: 0), "Permissions are set")
    }

    func testBodyDoesNotNameACount() {
        for missing in 0...3 {
            let body = OnboardingPermissionsCopy.bodyKey(missing: missing).lowercased()
            XCTAssertFalse(body.contains("these two"))
            XCTAssertFalse(body.contains("two more"))
        }
    }

    // MARK: Final button (fix 7)

    func testStartDictatingOnlyWithAllThreeGrants() {
        let all = OnboardingReadiness(microphone: true, inputMonitoring: true, accessibility: true)
        XCTAssertTrue(all.canDictate)
        XCTAssertEqual(all.finishTitleKey, "Start dictating")
        XCTAssertTrue(all.missing.isEmpty)
    }

    func testAnyMissingGrantChangesTheLabelAndIsListed() {
        let cases: [(OnboardingReadiness, [PermissionKind])] = [
            (.init(microphone: false, inputMonitoring: true, accessibility: true), [.microphone]),
            (.init(microphone: true, inputMonitoring: false, accessibility: true), [.inputMonitoring]),
            (.init(microphone: true, inputMonitoring: true, accessibility: false), [.accessibility]),
            (.init(microphone: false, inputMonitoring: false, accessibility: false),
             [.microphone, .inputMonitoring, .accessibility]),
        ]
        for (readiness, expected) in cases {
            XCTAssertFalse(readiness.canDictate)
            XCTAssertEqual(readiness.finishTitleKey, "Finish without the dictation key")
            XCTAssertEqual(readiness.missing, expected)
        }
    }

    // MARK: Speech model state (fix 2)

    func testOfflineDareOnlyOnceTheModelIsInstalled() {
        XCTAssertTrue(SpeechModelPhase.installed.offersOfflineDare)
        for phase: SpeechModelPhase in [.unknown, .downloading(fraction: nil), .downloading(fraction: 0.4), .failed] {
            XCTAssertFalse(phase.offersOfflineDare, "\(phase)")
        }
    }

    func testDownloadNoticeShowsOnlyWhileDownloading() {
        XCTAssertTrue(SpeechModelPhase.downloading(fraction: nil).showsDownloadNotice)
        XCTAssertTrue(SpeechModelPhase.downloading(fraction: 0.5).showsDownloadNotice)
        XCTAssertFalse(SpeechModelPhase.installed.showsDownloadNotice)
        XCTAssertFalse(SpeechModelPhase.unknown.showsDownloadNotice)
    }

    func testProgressFractionIsClampedOrIndeterminate() {
        XCTAssertNil(SpeechModelPhase.downloading(fraction: nil).progressFraction)
        XCTAssertNil(SpeechModelPhase.downloading(fraction: .nan).progressFraction)
        XCTAssertEqual(SpeechModelPhase.downloading(fraction: 1.7).progressFraction, 1)
        XCTAssertEqual(SpeechModelPhase.downloading(fraction: -0.2).progressFraction, 0)
        XCTAssertEqual(SpeechModelPhase.downloading(fraction: 0.25).progressFraction, 0.25)
        XCTAssertNil(SpeechModelPhase.installed.progressFraction)
    }

    // MARK: Localisation (fix 4)

    /// Every key the onboarding logic can emit exists in all ten catalogs.
    func testOnboardingKeysExistInEveryCatalog() throws {
        var keys: [String] = PermissionKind.allCases.map(\.nameKey)
        for missing in 0...3 {
            keys.append(OnboardingPermissionsCopy.headingKey(missing: missing))
            keys.append(OnboardingPermissionsCopy.bodyKey(missing: missing))
        }
        keys.append(OnboardingReadiness(microphone: true, inputMonitoring: true, accessibility: true).finishTitleKey)
        keys.append(OnboardingReadiness(microphone: false, inputMonitoring: false, accessibility: false).finishTitleKey)
        keys += ["On-device", "No cloud", "No account", "Open System Settings", "Review permissions",
                 "Still off: %@", "Downloading the speech model (one time)…",
                 "Replay introduction", "Introduction"]

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let langs = ["de", "en", "es", "fr", "it", "ja", "ko", "nl", "pt-BR", "zh-Hans"]
        for lang in langs {
            let url = root.appendingPathComponent("Resources/Localizations/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in keys {
                XCTAssertNotNil(table[key], "\(lang) is missing \"\(key)\"")
            }
        }
    }
}
