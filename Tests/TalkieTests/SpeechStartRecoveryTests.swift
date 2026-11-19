import XCTest
@testable import Talkie

/// The wake/stale-connection recovery: pure decisions plus the retry and bounded-start
/// runners against fake attempts (no real Speech service, no real defaults).
final class SpeechStartRecoveryTests: XCTestCase {
    private func cocoa(_ code: Int) -> NSError { NSError(domain: NSCocoaErrorDomain, code: code) }

    // MARK: classification

    func testStaleConnectionCodes() {
        XCTAssertTrue(SpeechStartRecovery.isStaleConnection(cocoa(4099)))
        XCTAssertTrue(SpeechStartRecovery.isStaleConnection(cocoa(4097)))
        XCTAssertTrue(SpeechStartRecovery.isStaleConnection(NSError(domain: "com.apple.coreaudio.avfaudio", code: -10877)))
        XCTAssertTrue(SpeechStartRecovery.isStaleConnection(TalkieEngineError.startTimedOut))
    }

    func testUnderlyingErrorIsFollowed() {
        let wrapped = NSError(domain: "SFSpeechErrorDomain", code: 1,
                              userInfo: [NSUnderlyingErrorKey: cocoa(4099)])
        XCTAssertTrue(SpeechStartRecovery.isStaleConnection(wrapped))
    }

    func testOtherErrorsAreNotStale() {
        XCTAssertFalse(SpeechStartRecovery.isStaleConnection(cocoa(260)))
        XCTAssertFalse(SpeechStartRecovery.isStaleConnection(TalkieEngineError.noInputDevice))
        XCTAssertFalse(SpeechStartRecovery.isStaleConnection(TalkieEngineError.noSupportedLocale))
        XCTAssertFalse(SpeechStartRecovery.isStaleConnection(CancellationError()))
    }

    // MARK: policy

    func testRetryPolicyRetriesOnceThenGivesUp() {
        XCTAssertEqual(SpeechStartRecovery.decide(afterFailedAttempt: 0, error: cocoa(4099)), .retry)
        XCTAssertEqual(SpeechStartRecovery.decide(afterFailedAttempt: 1, error: cocoa(4099)), .giveUp)
        XCTAssertEqual(SpeechStartRecovery.decide(afterFailedAttempt: 0, error: cocoa(260)), .giveUp)
    }

    func testRebuildPlanTouchesMicOnlyForAudioUnitErrors() {
        XCTAssertEqual(SpeechStartRecovery.rebuildPlan(for: cocoa(4099)),
                       .init(speech: true, mic: false))
        XCTAssertEqual(SpeechStartRecovery.rebuildPlan(for: NSError(domain: "x", code: -10877)),
                       .init(speech: true, mic: true))
    }

    func testTimeoutAppliesOnlyOnceModelInstalled() {
        XCTAssertNil(SpeechStartRecovery.attemptTimeout(modelKnownInstalled: false))
        XCTAssertEqual(SpeechStartRecovery.attemptTimeout(modelKnownInstalled: true),
                       SpeechStartRecovery.attemptTimeoutSeconds)
    }

    func testFinalErrorIsPlainSentence() {
        let e = SpeechStartRecovery.userFacing(cocoa(4099))
        guard case TalkieEngineError.speechServiceUnavailable = e else { return XCTFail("\(e)") }
        XCTAssertFalse((e as NSError).localizedDescription.contains("4099"))
        // A non-stale error passes through untouched.
        XCTAssertEqual((SpeechStartRecovery.userFacing(cocoa(260)) as NSError).code, 260)
    }

    // MARK: retry runner (first start throws 4099, second succeeds)

    func testFirstStartFailsSecondSucceeds() async throws {
        var attempts = 0
        var rebuilds = 0
        let value: Int = try await SpeechStartRecovery.run(
            attempt: { n in
                attempts += 1
                if n == 0 { throw self.cocoa(4099) }
                return 42
            },
            rebuild: { _ in rebuilds += 1 })
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(rebuilds, 1)
    }

    func testBothStartsFailThrowsUserFacingAfterExactlyOneRetry() async {
        var attempts = 0
        do {
            let _: Int = try await SpeechStartRecovery.run(
                attempt: { _ in attempts += 1; throw self.cocoa(4099) },
                rebuild: { _ in })
            XCTFail("must throw")
        } catch TalkieEngineError.speechServiceUnavailable {
            XCTAssertEqual(attempts, 2, "one initial try + exactly one retry")
        } catch { XCTFail("\(error)") }
    }

    func testNonStaleFailureIsNotRetried() async {
        var attempts = 0
        do {
            let _: Int = try await SpeechStartRecovery.run(
                attempt: { _ in attempts += 1; throw TalkieEngineError.noInputDevice },
                rebuild: { _ in XCTFail("no rebuild for a non-stale error") })
            XCTFail("must throw")
        } catch { XCTAssertEqual(attempts, 1) }
    }

    // MARK: bounded start (start never returns)

    func testBoundedReturnsFastResult() async throws {
        let v = try await SpeechStartRecovery.bounded(seconds: 2) { 7 }
        XCTAssertEqual(v, 7)
    }

    func testBoundedThrowsTimedOutWhenOperationNeverReturns() async {
        let began = Date()
        do {
            // Ignores cancellation, like Apple's non-cooperative await.
            _ = try await SpeechStartRecovery.bounded(seconds: 0.2) { () async throws -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
            XCTFail("must time out")
        } catch TalkieEngineError.startTimedOut {
            XCTAssertLessThan(Date().timeIntervalSince(began), 2, "must return promptly, not wait for the hung op")
        } catch { XCTFail("\(error)") }
    }

    func testHungStartIsRetriedThenSucceeds() async throws {
        var rebuilds = 0
        let v: Int = try await SpeechStartRecovery.run(
            attempt: { n in
                try await SpeechStartRecovery.bounded(seconds: 0.2) { () async throws -> Int in
                    if n == 0 { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
                    return 5
                }
            },
            rebuild: { _ in rebuilds += 1 })
        XCTAssertEqual(v, 5)
        XCTAssertEqual(rebuilds, 1)
    }

    func testHungTwiceFailsBoundedWithUserFacingError() async {
        let began = Date()
        do {
            let _: Int = try await SpeechStartRecovery.run(
                attempt: { _ in
                    try await SpeechStartRecovery.bounded(seconds: 0.15) { () async throws -> Int in
                        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                        return 0
                    }
                },
                rebuild: { _ in })
            XCTFail("must throw")
        } catch TalkieEngineError.speechServiceUnavailable {
            XCTAssertLessThan(Date().timeIntervalSince(began), 3)
        } catch { XCTFail("\(error)") }
    }

    // MARK: wake plan

    private let idle = WakeRecovery.Activity(dictating: false, processing: false, meetingBusy: false)

    func testIdleSleepReleasesPrewarmedMic() {
        XCTAssertEqual(WakeRecovery.actions(for: .willSleep, activity: idle), [.releasePrewarmedMic])
    }

    func testIdleWakeRebuildsSpeechThenMic() {
        XCTAssertEqual(WakeRecovery.actions(for: .didWake, activity: idle),
                       [.resetSpeechService, .rewarmSpeechModels, .reprewarmMic])
    }

    func testScreensWakeOnlyReprewarms() {
        XCTAssertEqual(WakeRecovery.actions(for: .screensDidWake, activity: idle), [.reprewarmMic])
    }

    func testActiveSessionsAreNeverTornDown() {
        for activity in [WakeRecovery.Activity(dictating: true, processing: false, meetingBusy: false),
                         .init(dictating: false, processing: true, meetingBusy: false),
                         .init(dictating: false, processing: false, meetingBusy: true)] {
            for event in [PowerEvent.willSleep, .didWake, .screensDidWake] {
                XCTAssertEqual(WakeRecovery.actions(for: event, activity: activity), [])
            }
        }
    }
}
