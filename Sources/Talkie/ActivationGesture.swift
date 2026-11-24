import Foundation

/// The activation gesture, as a pure state machine: **press to start, press again to
/// stop.** The key is an on/off switch. The first press starts dictation at once;
/// the next press ends the session and inserts the text. Releasing the key does
/// nothing, so nobody has to hold it while talking.
///
/// ## Why a pure machine
/// `HotKeyMonitor.handle()` runs on the CGEventTap thread; keeping the decision logic
/// here — a `Sendable` value type with **no timers, no clocks, no I/O** — means it can
/// be unit-tested as a function of its inputs, and the monitor just feeds it edges
/// under its existing lock.
///
/// ## Physical key state
/// The machine still tracks whether the key is physically down, so a second down
/// without an up in between (a dropped key-up, or a repeat that slipped through) is
/// ignored instead of switching the session off again.
///
/// ## Input-source-agnostic
/// The machine consumes abstract `keyDown`/`keyUp` edges; it knows nothing about
/// keycodes, modifiers, or mouse buttons, so mouse-button activation reuses it.
struct ActivationGesture: Sendable, Equatable {
    /// A session shorter than this that produced no text counts as an accidental
    /// double press — used only to decide whether to show the one-time gesture hint.
    static let quickTapThreshold: TimeInterval = 0.5

    /// What the machine asks the caller to do after consuming an edge.
    enum Action: Sendable, Equatable {
        /// Do nothing.
        case none
        /// Begin a dictation session now (audio should arm immediately).
        case begin
        /// End the current dictation session now (stop + insert).
        case end
    }

    private var recording = false
    private var keyIsDown = false

    init() {}

    /// True while a session is running (between the starting and the stopping press).
    var isActive: Bool { recording }

    /// True while the key is physically down. The reconcile tick clears it when a
    /// key-up was dropped (`releaseLost`); it never ends a session.
    var isHeld: Bool { keyIsDown }

    // MARK: Inputs

    /// The key/button went down at time `t`: starts a session, or stops the running one.
    mutating func keyDown(at t: TimeInterval) -> Action {
        guard !keyIsDown else { return .none }
        keyIsDown = true
        recording.toggle()
        return recording ? .begin : .end
    }

    /// The key/button went up at time `t`. Never starts or stops anything.
    mutating func keyUp(at t: TimeInterval) -> Action {
        keyIsDown = false
        return .none
    }

    /// A key-up was lost (the live state says the key is up although we saw no
    /// release). Forget the press so the next one is seen; the session keeps going.
    mutating func releaseLost() {
        keyIsDown = false
    }

    /// Force the machine back to idle without emitting an action. Used when the binding
    /// is torn down (key rebind, stop) and the caller is separately synthesizing
    /// whatever end/cleanup it needs. Returns whether a session was active.
    @discardableResult
    mutating func reset() -> Bool {
        let wasActive = recording
        recording = false
        keyIsDown = false
        return wasActive
    }

    /// The session ended from outside the key (silence auto-stop, a dead mic): the
    /// next press must start a new session, not "stop" the one that is already over.
    mutating func sessionEndedElsewhere() {
        recording = false
    }
}
