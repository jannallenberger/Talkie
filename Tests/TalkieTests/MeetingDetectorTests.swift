import XCTest
@testable import Talkie

/// Pure-logic tests for the meeting-detection state machine — the debounce/session
/// behavior of `ActiveMeetingDetector.decide`, the candidate selection in
/// `bestCandidate`, and the adaptive auto-mute in `markSessionDismissed` — exercised
/// without any Core Audio I/O.
final class MeetingDetectorTests: XCTestCase {
    private typealias Detector = ActiveMeetingDetector
    private typealias State = ActiveMeetingDetector.DetectorState
    private typealias Candidate = ActiveMeetingDetector.DetectionCandidate

    private let cfg = Detector.Config(enabled: true, allowlist: [])
    private let zoom = Candidate(bundleID: "us.zoom.xos", appName: "Zoom", tier: .meetingApp, confidence: 0.85)
    private let teams = Candidate(bundleID: "com.microsoft.teams2", appName: "Teams", tier: .meetingApp, confidence: 0.85)

    private static let allow: [String: MeetingApp] = [
        "us.zoom.xos": MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", tier: .meetingApp),
        "com.google.Chrome": MeetingApp(bundleID: "com.google.Chrome", displayName: "Chrome", tier: .browser),
    ]

    // MARK: decide — start / offered-once

    func testOffersOnlyAfterTwoSustainedPolls() {
        let (s, offer1) = Detector.decide(state: State(), candidate: zoom, now: 100, config: cfg)
        XCTAssertNil(offer1, "one poll shouldn't offer (start-confirm = 2)")

        let (s2, offer2) = Detector.decide(state: s, candidate: zoom, now: 101.5, config: cfg)
        XCTAssertEqual(offer2?.bundleID, "us.zoom.xos", "second sustained poll should offer")

        let (_, offer3) = Detector.decide(state: s2, candidate: zoom, now: 103, config: cfg)
        XCTAssertNil(offer3, "the same session must not re-offer")
    }

    func testDismissedSessionNeverReoffers() {
        var s = State()
        (s, _) = Detector.decide(state: s, candidate: zoom, now: 100, config: cfg)
        (s, _) = Detector.decide(state: s, candidate: zoom, now: 101.5, config: cfg)  // offered
        s.dismissed = true
        let (_, offer) = Detector.decide(state: s, candidate: zoom, now: 103, config: cfg)
        XCTAssertNil(offer)
    }

    // MARK: decide — end debounce + new session

    func testEndDebounceKeepsThenResetsSession() {
        var s = State()
        (s, _) = Detector.decide(state: s, candidate: zoom, now: 100, config: cfg)
        (s, _) = Detector.decide(state: s, candidate: zoom, now: 101.5, config: cfg)  // lastSeen = 101.5

        // Within the 20 s window the session survives (mute / hold / share swap).
        let (within, _) = Detector.decide(state: s, candidate: nil, now: 110, config: cfg)
        XCTAssertEqual(within.sessionBundleID, "us.zoom.xos")

        // Past the window the session resets.
        let (reset, _) = Detector.decide(state: within, candidate: nil, now: 130, config: cfg)
        XCTAssertNil(reset.sessionBundleID)

        // A fresh call then re-offers after the start-confirm again.
        let (r1, o1) = Detector.decide(state: reset, candidate: zoom, now: 131, config: cfg)
        XCTAssertNil(o1)
        let (_, o2) = Detector.decide(state: r1, candidate: zoom, now: 132.5, config: cfg)
        XCTAssertNotNil(o2)
    }

    func testDifferentAppStartsNewSessionAndReoffers() {
        var s = State()
        (s, _) = Detector.decide(state: s, candidate: zoom, now: 100, config: cfg)
        (s, _) = Detector.decide(state: s, candidate: zoom, now: 101.5, config: cfg)  // offered Zoom

        // Teams becomes mic-hot → a brand-new session, which offers after 2 polls.
        let (t1, to1) = Detector.decide(state: s, candidate: teams, now: 200, config: cfg)
        XCTAssertNil(to1)
        let (_, to2) = Detector.decide(state: t1, candidate: teams, now: 201.5, config: cfg)
        XCTAssertEqual(to2?.bundleID, "com.microsoft.teams2")
    }

    func testMutedAppNeverOffers() {
        let muted = Detector.Config(enabled: true, allowlist: [], muted: ["us.zoom.xos"])
        var s = State()
        (s, _) = Detector.decide(state: s, candidate: zoom, now: 100, config: muted)
        let (_, offer) = Detector.decide(state: s, candidate: zoom, now: 101.5, config: muted)
        XCTAssertNil(offer)
    }

    // MARK: bestCandidate — selection + unknown apps always eligible

    func testBestCandidatePrefersStrongerSignal() {
        XCTAssertNil(Detector.bestCandidate([], allowlist: Self.allow),
                     "nothing on the mic → no candidate")

        // Zoom + Chrome both mic-hot → the stronger (meeting app) wins.
        let both = [ActiveInputProcess(pid: 1, bundleID: "com.google.Chrome"),
                    ActiveInputProcess(pid: 2, bundleID: "us.zoom.xos")]
        XCTAssertEqual(Detector.bestCandidate(both, allowlist: Self.allow)?.bundleID,
                       "us.zoom.xos")
    }

    /// The behavior change at the heart of H9: an unknown, non-allowlisted mic-hot app
    /// is now offer-worthy by default (previously gated behind the deleted
    /// "offer for any mic app" toggle). It reports at the low `micHotOnly` floor with a
    /// nil tier.
    func testUnknownAppIsOfferWorthyByDefault() {
        let unknown = [ActiveInputProcess(pid: 9, bundleID: "com.unknown.app")]
        let candidate = Detector.bestCandidate(unknown, allowlist: Self.allow)
        XCTAssertNotNil(candidate, "an unknown mic-hot app now always qualifies")
        XCTAssertNil(candidate?.tier, "an unknown app has no tier")
        XCTAssertEqual(candidate?.confidence, Detector.Confidence.micHotOnly,
                       "an unknown app reports at the mic-hot-only confidence floor")
        XCTAssertEqual(candidate?.bundleID, "com.unknown.app")
    }

    // MARK: markSessionDismissed — adaptive auto-mute (exercises the actor)

    /// Two explicit dismissals of an *unknown* app mute it for good — the cap that
    /// makes always-offering-for-unknown-apps safe. `onMute` fires exactly once, on
    /// the second dismissal.
    func testUnknownAppMutesAfterTwoDismissals() async {
        let detector = Detector(config: Detector.Config(enabled: false, allowlist: []))
        let muted = MuteRecorder()
        await detector.start(onDetect: { _ in }, onMute: { muted.record($0) })

        await detector.markSessionDismissed("com.unknown.app", mute: true)
        var count = muted.count
        XCTAssertEqual(count, 0, "one dismissal must not mute an unknown app")

        await detector.markSessionDismissed("com.unknown.app", mute: true)
        count = muted.count
        XCTAssertEqual(count, 1, "the second dismissal mutes the unknown app")
        let ids = muted.ids
        XCTAssertEqual(ids, ["com.unknown.app"])

        // A third dismissal must not re-fire the mute (it's already muted).
        await detector.markSessionDismissed("com.unknown.app", mute: true)
        count = muted.count
        XCTAssertEqual(count, 1, "an already-muted app must not re-fire onMute")
    }

    /// Browser-tier behavior is unchanged: still muted after two dismissals.
    func testBrowserAppMutesAfterTwoDismissals() async {
        let detector = Detector(config: Detector.Config(enabled: false, allowlist: MeetingApp.builtInAllowlist))
        let muted = MuteRecorder()
        await detector.start(onDetect: { _ in }, onMute: { muted.record($0) })

        await detector.markSessionDismissed("com.google.Chrome", mute: true)
        var count = muted.count
        XCTAssertEqual(count, 0, "one dismissal must not mute a browser")

        await detector.markSessionDismissed("com.google.Chrome", mute: true)
        count = muted.count
        XCTAssertEqual(count, 1, "the second dismissal mutes the browser")
        let ids = muted.ids
        XCTAssertEqual(ids, ["com.google.Chrome"])
    }

    /// An explicit dedicated meeting app is NEVER auto-muted, no matter how many times
    /// it's dismissed — a mic-hot there almost always means a recordable call.
    func testMeetingAppNeverAutoMutes() async {
        let detector = Detector(config: Detector.Config(enabled: false, allowlist: MeetingApp.builtInAllowlist))
        let muted = MuteRecorder()
        await detector.start(onDetect: { _ in }, onMute: { muted.record($0) })

        for _ in 0..<5 {
            await detector.markSessionDismissed("us.zoom.xos", mute: true)
        }
        let count = muted.count
        XCTAssertEqual(count, 0, "a dedicated meeting app must never auto-mute")
    }

    /// A soft auto-hide (`mute: false`) never counts toward the mute threshold, even
    /// for an unknown app.
    func testSoftDismissDoesNotMute() async {
        let detector = Detector(config: Detector.Config(enabled: false, allowlist: []))
        let muted = MuteRecorder()
        await detector.start(onDetect: { _ in }, onMute: { muted.record($0) })

        await detector.markSessionDismissed("com.unknown.app", mute: false)
        await detector.markSessionDismissed("com.unknown.app", mute: false)
        let count = muted.count
        XCTAssertEqual(count, 0, "soft auto-hides never mute an app")
    }
}

/// Collects the bundle ids passed to a detector's `onMute` callback. The callback is
/// a *synchronous* `@Sendable (String) -> Void` fired from the detector actor, so this
/// can't be an actor (no `await` inside the callback). It follows the house
/// `@unchecked Sendable` + `NSLock` pattern instead: every access is guarded by the
/// lock, which is why the unchecked annotation is accurate.
private final class MuteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var ids: [String] { lock.withLock { storage } }
    var count: Int { lock.withLock { storage.count } }
    func record(_ id: String) { lock.withLock { storage.append(id) } }
}
