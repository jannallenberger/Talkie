import Foundation

/// The one activation gesture family, as a pure state machine.
///
/// Talkie has a single, zero-configuration gesture: **hold to talk, tap-tap to
/// lock, tap to stop.** There is no Hold/Toggle mode setting — this machine gives
/// every user both push-to-talk and hands-free lock at once:
///
///   - **Hold**: press and hold past `tapThreshold`, speak, release → dictation
///     runs while held and ends the instant you let go (push-to-talk, zero added
///     stop latency — a release after a real hold ends immediately).
///   - **Tap-tap to lock**: a quick tap (release before `tapThreshold`) followed
///     by a second press within `doubleTapWindow` **locks** recording hands-free;
///     it keeps going with no key held.
///   - **Tap to stop**: while locked, the next press stops and inserts.
///   - **Lone quick tap**: a single quick tap that isn't followed by a second one
///     ends the (very short) session when the defer timer fires — it inserts
///     whatever was captured and never latches recording on.
///
/// ## Why a pure machine
/// `HotKeyMonitor.handle()` runs on the CGEventTap thread; keeping the decision
/// logic here — a `Sendable` value type with **no timers, no clocks, no I/O** —
/// means it can be exhaustively unit-tested as a function of its inputs, and the
/// monitor just feeds it timestamped edges under its existing lock. The machine
/// never reads the wall clock: every input carries the timestamp, so tests drive
/// time explicitly and the tap thread passes the event's own timestamp.
///
/// ## First-phoneme priority
/// A `keyDown` while idle emits `.begin` *immediately* — the machine never waits
/// to see whether this press becomes a hold or the first half of a tap-tap. The
/// short-tap ambiguity is resolved on the *release* side (defer the end), so the
/// microphone is always armed from the very first instant of the very first press.
///
/// ## The deferred end (and the one place latency is added)
/// Only a release that happened *before* `tapThreshold` is ambiguous — it might be
/// the first tap of a tap-tap, or a lone tap. Rather than guess, the machine asks
/// the caller to arm a timer (`.deferEnd`) and reports the pending end only if no
/// second press arrives inside `doubleTapWindow`. So a sub-`tapThreshold` tap that
/// ends up being lone inserts `doubleTapWindow` later than the release. **Holds pay
/// no such tax** — a release after `tapThreshold` ends synchronously. This is the
/// only latency the gesture adds, and it applies exclusively to sub-threshold taps.
///
/// ## Input-source-agnostic
/// The machine consumes abstract `keyDown`/`keyUp`/`timerFired` edges with
/// timestamps; it knows nothing about keycodes, modifiers, or mouse buttons. B7
/// (mouse-button activation) reuses this exact machine by feeding it edges from a
/// different source — so nothing here may mention a specific input device.
struct ActivationGesture: Sendable, Equatable {
    /// A key/button press must be held at least this long to count as a "hold".
    /// A release before this is a "tap" (candidate for tap-tap lock). 350 ms is
    /// comfortably above an intentional quick tap yet well under a deliberate hold,
    /// so first-phoneme audio is never clipped waiting to classify the gesture.
    static let tapThreshold: TimeInterval = 0.35

    /// After a quick tap, a second press within this window locks hands-free. Equal
    /// to `tapThreshold` by design: the two windows describe the same human "quick"
    /// tempo, and keeping them identical means there's a single mental model
    /// ("quick") rather than two thresholds to reason about.
    static let doubleTapWindow: TimeInterval = 0.35

    /// What the machine asks the caller to do after consuming an edge.
    enum Action: Sendable, Equatable {
        /// Do nothing.
        case none
        /// Begin a dictation session now (audio should arm immediately).
        case begin
        /// End the current dictation session now (stop + insert).
        case end
        /// Lock the session hands-free (recording continues with no key held).
        case lock
        /// Arm a one-shot timer to fire `timerFired(at:)` at `fireAt`. Used to
        /// resolve whether an ambiguous quick tap becomes a lone tap (→ `.end`) or
        /// the first half of a tap-tap (→ `.lock`). The caller owns the timer; the
        /// machine only decides the deadline. A superseding edge (a second press)
        /// makes the eventual `timerFired` a no-op, so a late timer is always safe.
        case deferEnd(fireAt: TimeInterval)
    }

    /// The recording lifecycle, as the machine sees it.
    private enum Phase: Sendable, Equatable {
        /// No session.
        case idle
        /// A press is down and dictation is running (push-to-talk hold in progress).
        /// `downAt` is when the press started, to classify the release as tap vs hold.
        case held(downAt: TimeInterval)
        /// A quick tap was released and we're waiting to see if a second press
        /// arrives to lock. `deadline` is when the deferred `.end` should fire.
        /// Dictation is still running (we began on the tap's key-down).
        case awaitingSecondTap(deadline: TimeInterval)
        /// Recording is locked hands-free. No key is held; the next press stops it.
        case locked
    }

    private var phase: Phase = .idle

    init() {}

    /// True while a session is active in any form (held, awaiting-second-tap, or
    /// locked) — i.e. audio is or should be flowing. Used only by callers that want
    /// to reflect "is something recording" without knowing the phase.
    var isActive: Bool { phase != .idle }

    /// True only while recording is locked hands-free — the phase that must show the
    /// lock indicator and must be exempt from the reconcile force-release (a locked
    /// session has no key held, so a "modifier is up" reconcile must NOT end it).
    var isLocked: Bool { phase == .locked }

    /// True while a plain push-to-talk hold is in progress — the ONLY phase the
    /// reconcile tick may force-end. `awaitingSecondTap` is deliberately excluded:
    /// the key is already up there (that's what started the wait), so a reconcile
    /// firing on "key is up" must not pre-empt the legitimate tap-tap window.
    var isHeld: Bool {
        if case .held = phase { return true }
        return false
    }

    // MARK: Inputs

    /// The key/button went down at time `t`.
    mutating func keyDown(at t: TimeInterval) -> Action {
        switch phase {
        case .idle:
            // First-phoneme priority: arm immediately, classify on release.
            phase = .held(downAt: t)
            return .begin
        case .held:
            // A second down without an intervening up shouldn't happen from a clean
            // edge source (you can't press an already-pressed key), but if a key-up
            // was dropped we're conservatively already recording — ignore it and
            // stay held so we don't double-begin.
            return .none
        case .awaitingSecondTap:
            // The second tap of a tap-tap: lock hands-free. Recording has been
            // running since the first tap's key-down, so there's nothing to begin —
            // we only transition state. The pending deferred end is superseded (its
            // timer, if it still fires, will no-op because we're no longer awaiting).
            phase = .locked
            return .lock
        case .locked:
            // Locked → the next press stops and inserts.
            phase = .idle
            return .end
        }
    }

    /// The key/button went up at time `t`.
    mutating func keyUp(at t: TimeInterval) -> Action {
        switch phase {
        case .idle:
            // Stray release with no session (e.g. the up half of the press that
            // stopped a locked session) — nothing to do.
            return .none
        case .held(let downAt):
            if t - downAt >= Self.tapThreshold {
                // A real hold: end the instant the key is released — zero added
                // stop latency for push-to-talk.
                phase = .idle
                return .end
            } else {
                // A quick tap: defer the end and wait for a possible second press to
                // lock. We stay recording meanwhile. The caller arms a timer for the
                // deadline; if it fires first we end (lone tap), if a second press
                // comes first we lock.
                let deadline = t + Self.doubleTapWindow
                phase = .awaitingSecondTap(deadline: deadline)
                return .deferEnd(fireAt: deadline)
            }
        case .awaitingSecondTap:
            // The release of the *second* tap. In the tap-tap flow the second press
            // (keyDown) already locked us; by the time its key-up arrives we're in
            // `.locked`, not here. Reaching this means a key-up arrived while still
            // awaiting (e.g. a duplicated up edge) — ignore it; the deferred timer
            // still governs the lone-tap end.
            return .none
        case .locked:
            // The key-up half of the press that will stop the locked session is
            // consumed by `keyDown` (which returned `.end` and went idle) — but if a
            // stray up arrives while locked, ignore it; a locked session has no held
            // key to release.
            return .none
        }
    }

    /// The deferred-end timer fired at time `t`. Ends the session **only** if we're
    /// still awaiting a second tap and the timer that fired is the one we armed
    /// (its deadline matches). A second press that locked (or any state change)
    /// makes this a safe no-op, so a stale/duplicate timer can never end a locked or
    /// idle session.
    mutating func timerFired(at t: TimeInterval) -> Action {
        guard case .awaitingSecondTap(let deadline) = phase else { return .none }
        // Only honor the timer whose deadline we're actually waiting on. Guards
        // against a superseded timer (rearmed for a later deadline) firing early.
        guard t >= deadline else { return .none }
        // The lone quick tap: no second press came, so end now (inserts whatever
        // the brief capture produced). Never latches recording on.
        phase = .idle
        return .end
    }

    /// Force the machine back to idle without emitting an action. Used when the
    /// binding is torn down (key rebind, stop) and the caller is separately
    /// synthesizing whatever end/cleanup it needs — the machine must not also emit
    /// a second `.end`. Returns whether a session was active (so the caller can
    /// decide whether to fire its own deactivate).
    @discardableResult
    mutating func reset() -> Bool {
        let wasActive = phase != .idle
        phase = .idle
        return wasActive
    }
}
