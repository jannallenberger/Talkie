import XCTest
@testable import Talkie

/// Pure-logic tests for the meeting-detection state machine — the debounce/session
/// behavior of `ActiveMeetingDetector.decide` and the offer-worthiness gate in
/// `bestCandidate`, exercised without any Core Audio I/O.
final class MeetingDetectorTests: XCTestCase {
    private typealias Detector = ActiveMeetingDetector
    private typealias State = ActiveMeetingDetector.DetectorState
    private typealias Candidate = ActiveMeetingDetector.DetectionCandidate

    private let cfg = Detector.Config(enabled: true, allowlist: [], offerForAnyMicApp: false)
    private let zoom = Candidate(bundleID: "us.zoom.xos", appName: "Zoom", tier: .meetingApp, confidence: 0.85)
    private let teams = Candidate(bundleID: "com.microsoft.teams2", appName: "Teams", tier: .meetingApp, confidence: 0.85)

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
        let muted = Detector.Config(enabled: true, allowlist: [], offerForAnyMicApp: false,
                                    muted: ["us.zoom.xos"])
        var s = State()
        (s, _) = Detector.decide(state: s, candidate: zoom, now: 100, config: muted)
        let (_, offer) = Detector.decide(state: s, candidate: zoom, now: 101.5, config: muted)
        XCTAssertNil(offer)
    }

    // MARK: bestCandidate — offer-worthiness gate

    func testBestCandidatePrefersStrongerSignalAndGatesUnknown() {
        let allow: [String: MeetingApp] = [
            "us.zoom.xos": MeetingApp(bundleID: "us.zoom.xos", displayName: "Zoom", tier: .meetingApp),
            "com.google.Chrome": MeetingApp(bundleID: "com.google.Chrome", displayName: "Chrome", tier: .browser),
        ]

        XCTAssertNil(Detector.bestCandidate([], allowlist: allow, offerForAnyMicApp: false))

        // Zoom + Chrome both mic-hot → the stronger (meeting app) wins.
        let both = [ActiveInputProcess(pid: 1, bundleID: "com.google.Chrome"),
                    ActiveInputProcess(pid: 2, bundleID: "us.zoom.xos")]
        XCTAssertEqual(Detector.bestCandidate(both, allowlist: allow, offerForAnyMicApp: false)?.bundleID,
                       "us.zoom.xos")

        // An unknown app is not offer-worthy unless explicitly opted in.
        let unknown = [ActiveInputProcess(pid: 9, bundleID: "com.unknown.app")]
        XCTAssertNil(Detector.bestCandidate(unknown, allowlist: allow, offerForAnyMicApp: false))
        let optedIn = Detector.bestCandidate(unknown, allowlist: allow, offerForAnyMicApp: true)
        XCTAssertNotNil(optedIn)
        XCTAssertNil(optedIn?.tier)
        XCTAssertEqual(optedIn?.confidence, Detector.Confidence.micHotOnly)
    }
}
