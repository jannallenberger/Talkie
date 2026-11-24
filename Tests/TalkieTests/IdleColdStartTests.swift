import XCTest
@testable import Talkie

final class IdleColdStartTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let idle = IdleColdStart.Busy(activity: .init(dictating: false, processing: false, meetingBusy: false))

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func testWaitsForTheIdleThreshold() {
        XCTAssertFalse(IdleColdStart.shouldColdStart(now: at(14), lastSpeechUse: t0, lastColdStart: nil, busy: idle))
        XCTAssertTrue(IdleColdStart.shouldColdStart(now: at(15), lastSpeechUse: t0, lastColdStart: nil, busy: idle))
    }

    func testRepeatsOnlyEveryHalfHourWhileIdle() {
        // A cold start at 15 min; the next one not before 45.
        XCTAssertFalse(IdleColdStart.shouldColdStart(now: at(30), lastSpeechUse: t0, lastColdStart: at(15), busy: idle))
        XCTAssertFalse(IdleColdStart.shouldColdStart(now: at(44), lastSpeechUse: t0, lastColdStart: at(15), busy: idle))
        XCTAssertTrue(IdleColdStart.shouldColdStart(now: at(45), lastSpeechUse: t0, lastColdStart: at(15), busy: idle))
    }

    func testADictationAfterTheLastColdStartRestartsTheWait() {
        // Cold start at 15, dictated at 20: the next cold start waits 15 min from 20.
        XCTAssertFalse(IdleColdStart.shouldColdStart(now: at(34), lastSpeechUse: at(20), lastColdStart: at(15), busy: idle))
        XCTAssertTrue(IdleColdStart.shouldColdStart(now: at(35), lastSpeechUse: at(20), lastColdStart: at(15), busy: idle))
    }

    func testNeverWhileAnythingUsesSpeechOrTheMic() {
        let cases: [IdleColdStart.Busy] = [
            .init(activity: .init(dictating: true, processing: false, meetingBusy: false)),
            .init(activity: .init(dictating: false, processing: true, meetingBusy: false)),
            .init(activity: .init(dictating: false, processing: false, meetingBusy: true)),
            .init(activity: .init(dictating: false, processing: false, meetingBusy: false), importing: true),
            .init(activity: .init(dictating: false, processing: false, meetingBusy: false), nearPowerEvent: true),
        ]
        for busy in cases {
            XCTAssertFalse(IdleColdStart.shouldColdStart(now: at(120), lastSpeechUse: t0, lastColdStart: nil, busy: busy),
                           "\(busy)")
        }
    }

    func testOverrideThresholds() {
        XCTAssertTrue(IdleColdStart.shouldColdStart(now: at(2), lastSpeechUse: t0, lastColdStart: nil, busy: idle,
                                                    idleAfter: 90, repeatEvery: 180))
        XCTAssertFalse(IdleColdStart.shouldColdStart(now: at(4), lastSpeechUse: t0, lastColdStart: at(2), busy: idle,
                                                     idleAfter: 90, repeatEvery: 180))
    }

    func testTheColdStartIsTheWakeRebuildMicFirst() {
        XCTAssertEqual(IdleColdStart.actions.first, .releasePrewarmedMic)
        XCTAssertEqual(Set(IdleColdStart.actions),
                       Set(WakeRecovery.actions(for: .didWake, activity: idle.activity) + [.releasePrewarmedMic]))
    }
}

final class MemoryFeedPagingTests: XCTestCase {
    func testGrowsAPageAtATimeUpToTheTotal() {
        let page = MemoryFeedPaging.pageSize
        XCTAssertEqual(MemoryFeedPaging.nextLimit(current: page, total: 1025), 2 * page)
        XCTAssertEqual(MemoryFeedPaging.nextLimit(current: 1000, total: 1025), 1025)
        XCTAssertEqual(MemoryFeedPaging.nextLimit(current: 1025, total: 1025), 1025)
    }

    func testNeverBelowOnePage() {
        XCTAssertEqual(MemoryFeedPaging.nextLimit(current: 0, total: 10), MemoryFeedPaging.pageSize)
        XCTAssertGreaterThanOrEqual(MemoryFeedPaging.nextLimit(current: 3, total: 500), MemoryFeedPaging.pageSize)
    }
}
