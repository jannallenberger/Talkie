import XCTest
@testable import Talkie

/// A minimal thread-safe flag for the tests below (mirrors how the real
/// `onTimeout` unblocks a stuck operation by flipping shared state).
private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// `withAsyncTimeout` is the safety net that stops a wedged `SpeechAnalyzer`
/// finalize from hanging the dictation pipeline forever (the "stuck in Polishing…"
/// bug). The key property it must have — and the one an earlier structured-only
/// version LACKED — is that on timeout it runs `onTimeout` to break the hang and
/// then RETURNS, rather than the task group blocking forever on the stuck child.
final class AsyncTimeoutTests: XCTestCase {
    /// A fast operation reports `true`, and `onTimeout` never runs.
    func testFastOperationReportsFinished() async {
        let timedOut = Flag()
        let finished = await withAsyncTimeout(
            seconds: 2,
            operation: { try? await Task.sleep(nanoseconds: 10_000_000) }, // 10ms
            onTimeout: { await timedOut.set() }
        )
        XCTAssertTrue(finished, "An op that finishes inside the budget must report true.")
        let ranOnTimeout = await timedOut.isSet
        XCTAssertFalse(ranOnTimeout, "onTimeout must NOT run when the op finished in time.")
    }

    /// A cooperative slow op (a long, cancellation-aware sleep) is ended by the
    /// group's cancellation at the deadline and reports `false`.
    func testCooperativeSlowOpTimesOut() async {
        let finished = await withAsyncTimeout(
            seconds: 0.2,
            operation: { try? await Task.sleep(nanoseconds: 5_000_000_000) }, // 5s
            onTimeout: {}
        )
        XCTAssertFalse(finished, "An op slower than the budget must report false.")
    }

    /// THE core guarantee: an operation that ignores cooperative cancellation (it
    /// exits only when `onTimeout` flips its flag — exactly like Apple's finalize,
    /// which only `cancelAndFinishNow` breaks) still makes `withAsyncTimeout` RETURN
    /// `false` shortly after the deadline, instead of hanging forever.
    func testNonCooperativeHangIsBrokenByOnTimeout() async {
        let release = Flag()
        let start = Date()
        let finished = await withAsyncTimeout(
            seconds: 0.3,
            operation: {
                // Exits ONLY via the flag (not via Task cancellation). Yields so the
                // executor stays free for the timer + onTimeout to run.
                while await !release.isSet { await Task.yield() }
            },
            onTimeout: { await release.set() }
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(finished, "A hanging op must report false once onTimeout breaks it.")
        XCTAssertLessThan(elapsed, 3.0, "Must return shortly after the 0.3s deadline, not hang.")
    }
}
