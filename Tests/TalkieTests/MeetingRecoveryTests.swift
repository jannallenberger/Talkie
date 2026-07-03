import XCTest
@testable import Talkie

/// Pure-logic tests for crash-safe recording recovery (C7): the structured partial's
/// encode/decode round-trip, the legacy-plaintext fallback shim, and the recovery
/// mapping (true start time, honest duration floor, far-end → participants, and typed
/// notes preserved under "## Your notes"). All exercised without any Core Audio,
/// model, or real recording — the `kill -9` end-to-end path is the maker's manual
/// check (see the PR's "Manual exercise" section).
final class MeetingRecoveryTests: XCTestCase {

    private typealias Partial = MeetingRecorder.RecordingPartial

    // MARK: encode / decode round-trip

    func testPartialEncodeDecodeRoundTrips() {
        let partial = Partial(
            startedAt: 1_700_000_000,
            farEnd: true,
            notes: "buy milk\n- ship the build",
            transcript: "[00:03] Me: hello\n[00:05] Them: hi there"
        )
        let data = MeetingRecorder.encodePartial(partial)
        XCTAssertNotNil(data, "a well-formed partial must encode")
        let decoded = MeetingRecorder.decodePartial(data!)
        XCTAssertEqual(decoded, partial, "JSON round-trip must preserve every field verbatim")
    }

    func testEncodeIsDeterministicForDirtyCheck() {
        // The tick() dirty-check compares encoded BYTES, so equal partials must encode
        // to identical bytes (sorted keys) — otherwise a 2-hour meeting would re-write
        // an "identical" partial every second on key-order churn.
        let a = Partial(startedAt: 42, farEnd: false, notes: "n", transcript: "t")
        let b = Partial(startedAt: 42, farEnd: false, notes: "n", transcript: "t")
        XCTAssertEqual(
            MeetingRecorder.encodePartial(a),
            MeetingRecorder.encodePartial(b),
            "equal partials must encode to identical bytes for the byte-diff dirty check"
        )
    }

    func testDecodeRejectsGarbageThatIsNotJSONOrLegacyText() {
        // Empty bytes carry neither JSON nor recoverable text → nil (nothing to recover).
        XCTAssertNil(MeetingRecorder.decodePartial(Data()),
                     "empty bytes must not decode to a recoverable partial")
        // Whitespace-only "text" is not recoverable either.
        XCTAssertNil(MeetingRecorder.decodePartial(Data("   \n\t ".utf8)),
                     "whitespace-only content must not recover a meeting")
    }

    // MARK: legacy plaintext fallback

    func testLegacyPlaintextSoloRecoversMicOnly() {
        // A pre-C7 solo partial was a plain joined transcript with no "] Them:" labels.
        let raw = "okay so the plan is to ship on friday and then review"
        let partial = MeetingRecorder.decodePartial(Data(raw.utf8))
        XCTAssertNotNil(partial, "legacy plaintext must still recover")
        XCTAssertEqual(partial?.version, 0, "legacy partials are tagged version 0")
        XCTAssertEqual(partial?.startedAt, 0, "legacy partial carries no start → 0 (use file mtime)")
        XCTAssertEqual(partial?.farEnd, false, "no '] Them:' label → mic-only")
        XCTAssertEqual(partial?.notes, "", "legacy partials had no notes")
        XCTAssertEqual(partial?.transcript, raw)
    }

    func testLegacyPlaintextTwoSpeakerInfersFarEnd() {
        let raw = "[00:00] Me: hi\n[00:04] Them: hello there"
        let partial = MeetingRecorder.decodePartial(Data(raw.utf8))
        XCTAssertEqual(partial?.farEnd, true, "a '] Them:' label must recover as two participants")
    }

    // MARK: recovery mapping — true start time

    func testRecoveryUsesTrueStartTimeFromPartial() throws {
        let started = 1_700_000_000.0
        let modified = Date(timeIntervalSince1970: started + 63) // ~1 min later
        let partial = Partial(startedAt: started, farEnd: false, notes: "", transcript: "hello world")
        let plan = try XCTUnwrap(MeetingRecorder.recoveryPlan(from: partial, modified: modified))
        XCTAssertEqual(plan.start.timeIntervalSince1970, started, accuracy: 0.001,
                       "recovery must stamp the TRUE recorded start, not 'now'")
    }

    func testRecoveryDurationIsHonestFloorFromModificationDate() throws {
        let started = 1_700_000_000.0
        let modified = Date(timeIntervalSince1970: started + 90)
        let partial = Partial(startedAt: started, farEnd: false, notes: "", transcript: "hello")
        let plan = try XCTUnwrap(MeetingRecorder.recoveryPlan(from: partial, modified: modified))
        XCTAssertEqual(plan.duration, 90, accuracy: 0.001,
                       "duration floor = last-flush time − start (the recording ran at least that long)")
    }

    func testRecoveryDurationNeverNegative() {
        // Clock skew: the file's mtime is BEFORE the embedded start → clamp to 0, never
        // a negative duration.
        let started = 1_700_000_100.0
        let modified = Date(timeIntervalSince1970: started - 30)
        let partial = Partial(startedAt: started, farEnd: false, notes: "", transcript: "hi")
        let plan = MeetingRecorder.recoveryPlan(from: partial, modified: modified)
        XCTAssertEqual(plan?.duration, 0, "a backwards mtime must floor the duration at 0, not go negative")
    }

    func testLegacyPartialUsesFileModificationDateAsStart() throws {
        // startedAt == 0 (legacy) → start falls back to the file's mtime, and the
        // duration floor is then 0 (we don't know how long it ran).
        let modified = Date(timeIntervalSince1970: 1_699_999_000)
        let partial = Partial(version: 0, startedAt: 0, farEnd: false, notes: "", transcript: "legacy body")
        let plan = try XCTUnwrap(MeetingRecorder.recoveryPlan(from: partial, modified: modified))
        XCTAssertEqual(plan.start.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 0.001,
                       "a legacy partial with no start uses the file's mtime")
        XCTAssertEqual(plan.duration, 0, "with start = mtime, the floor is 0")
    }

    // MARK: recovery mapping — far-end → participants

    func testRecoveryParticipantsFromFarEndFlag() {
        let modified = Date(timeIntervalSince1970: 1_700_000_050)
        let solo = Partial(startedAt: 1_700_000_000, farEnd: false, notes: "", transcript: "hi")
        let both = Partial(startedAt: 1_700_000_000, farEnd: true, notes: "", transcript: "hi")
        XCTAssertEqual(MeetingRecorder.recoveryPlan(from: solo, modified: modified)?.participants, ["Me"],
                       "farEnd=false → mic-only participants")
        XCTAssertEqual(MeetingRecorder.recoveryPlan(from: both, modified: modified)?.participants, ["Me", "Them"],
                       "farEnd=true → both participants (from the flag, not a transcript sniff)")
    }

    // MARK: recovery mapping — typed notes preserved

    func testRecoveryPreservesTypedNotesUnderYourNotesHeading() {
        let modified = Date(timeIntervalSince1970: 1_700_000_060)
        let partial = Partial(
            startedAt: 1_700_000_000,
            farEnd: false,
            notes: "decision: go with plan B\naction: email the vendor",
            transcript: "[00:01] Me: let's decide"
        )
        let plan = MeetingRecorder.recoveryPlan(from: partial, modified: modified)
        let summary = plan?.summary ?? ""
        XCTAssertTrue(summary.contains("## Your notes"),
                      "typed notes must be preserved under a '## Your notes' heading")
        XCTAssertTrue(summary.contains("decision: go with plan B"),
                      "the raw note text must survive verbatim")
        XCTAssertTrue(summary.contains("action: email the vendor"))
        XCTAssertEqual(plan?.transcript, "[00:01] Me: let's decide",
                       "the transcript through the last flush is recovered too")
    }

    func testRecoveryWithNoNotesHasEmptySummary() {
        let modified = Date(timeIntervalSince1970: 1_700_000_060)
        let partial = Partial(startedAt: 1_700_000_000, farEnd: false, notes: "", transcript: "just a transcript")
        let plan = MeetingRecorder.recoveryPlan(from: partial, modified: modified)
        XCTAssertEqual(plan?.summary, "", "no notes → summary-less recovery (no launch-time model call)")
    }

    // MARK: recovery mapping — nothing to recover

    func testRecoveryReturnsNilWhenEmpty() {
        let modified = Date(timeIntervalSince1970: 1_700_000_060)
        let empty = Partial(startedAt: 1_700_000_000, farEnd: false, notes: "  ", transcript: "\n\t")
        XCTAssertNil(MeetingRecorder.recoveryPlan(from: empty, modified: modified),
                     "a partial with neither transcript nor notes recovers nothing")
    }

    func testNotesOnlyCrashStillRecovers() {
        // A crash before any transcript landed, but the user had typed notes → those
        // are real work and must still produce a recovered meeting.
        let modified = Date(timeIntervalSince1970: 1_700_000_060)
        let partial = Partial(startedAt: 1_700_000_000, farEnd: false,
                              notes: "the one thing I typed", transcript: "")
        let plan = MeetingRecorder.recoveryPlan(from: partial, modified: modified)
        XCTAssertNotNil(plan, "notes-only crash must still recover the notes")
        XCTAssertTrue((plan?.summary ?? "").contains("the one thing I typed"))
        XCTAssertEqual(plan?.transcript, "", "no transcript, but the note is preserved")
    }

    // MARK: recovery mapping — full Meeting assembly

    @MainActor
    func testMakeRecoveredMeetingAssemblesConsistentMeeting() throws {
        let started = 1_700_000_000.0
        let modified = Date(timeIntervalSince1970: started + 75)
        let partial = Partial(startedAt: started, farEnd: true, notes: "note text",
                              transcript: "[00:01] Me: hi\n[00:03] Them: hello")
        let meeting = try XCTUnwrap(MeetingRecorder.makeRecoveredMeeting(from: partial, modified: modified))
        XCTAssertEqual(meeting.startUnix, started, accuracy: 0.001, "true start time carried onto the Meeting")
        XCTAssertEqual(meeting.durationSec, 75, accuracy: 0.001, "honest duration floor carried on")
        XCTAssertEqual(meeting.participants, ["Me", "Them"])
        XCTAssertEqual(meeting.source, "talkie (recovered)")
        XCTAssertTrue(meeting.title.hasPrefix("Recovered meeting · "),
                      "recovered notes keep the 'Recovered meeting' title surface")
        XCTAssertTrue(meeting.summary.contains("note text"), "typed notes preserved in the summary")
        XCTAssertTrue(meeting.fileName.hasSuffix("-meeting.md"))
    }

    @MainActor
    func testMakeRecoveredMeetingReturnsNilWhenEmpty() {
        let modified = Date(timeIntervalSince1970: 1_700_000_060)
        let empty = Partial(startedAt: 1_700_000_000, farEnd: false, notes: "", transcript: "")
        XCTAssertNil(MeetingRecorder.makeRecoveredMeeting(from: empty, modified: modified),
                     "an empty partial assembles no Meeting")
    }
}
