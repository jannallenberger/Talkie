import Foundation

/// The activation gesture, as a pure state machine: **hold to talk, let go to
/// transcribe.** Pressing the key starts dictation at once; releasing it always ends
/// the session and inserts the text, however long the key was held. There is no
/// hands-free latch: a release never leaves Talkie listening.
///
/// ## Why a pure machine
/// `HotKeyMonitor.handle()` runs on the CGEventTap thread; keeping the decision logic
/// here — a `Sendable` value type with **no timers, no clocks, no I/O** — means it can
/// be unit-tested as a function of its inputs, and the monitor just feeds it edges
/// under its existing lock.
///
/// ## First-phoneme priority
/// A `keyDown` while idle emits `.begin` immediately, so the microphone is armed from
/// the very first instant of the press.
///
/// ## Input-source-agnostic
/// The machine consumes abstract `keyDown`/`keyUp` edges; it knows nothing about
/// keycodes, modifiers, or mouse buttons, so mouse-button activation reuses it.
struct ActivationGesture: Sendable, Equatable {
    /// A session shorter than this that produced no text counts as a "lone quick tap"
    /// — used only to decide whether to show the one-time "hold to talk" hint.
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

    private var held = false

    init() {}

    /// True while the key is down and a session is running.
    var isActive: Bool { held }

    /// True while a hold is in progress — the phase the reconcile tick may force-end
    /// when a key-up was dropped.
    var isHeld: Bool { held }

    // MARK: Inputs

    /// The key/button went down at time `t`.
    mutating func keyDown(at t: TimeInterval) -> Action {
        // A second down without an intervening up (a dropped key-up) must not
        // double-begin: we're already recording.
        guard !held else { return .none }
        held = true
        return .begin
    }

    /// The key/button went up at time `t`. Always ends a running session.
    mutating func keyUp(at t: TimeInterval) -> Action {
        guard held else { return .none }
        held = false
        return .end
    }

    /// Force the machine back to idle without emitting an action. Used when the binding
    /// is torn down (key rebind, stop) and the caller is separately synthesizing
    /// whatever end/cleanup it needs. Returns whether a session was active.
    @discardableResult
    mutating func reset() -> Bool {
        let wasActive = held
        held = false
        return wasActive
    }
}
