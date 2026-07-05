import Foundation

/// The one activation gesture family, as a pure state machine.
///
/// Talkie has a single, zero-configuration gesture: **hold to talk, keep holding to
/// latch hands-free, tap to stop.** There is no Hold/Toggle mode setting — this one
/// machine gives every user both push-to-talk and hands-free at once:
///
///   - **Hold to talk**: press and hold, speak, release *before* `latchThreshold` →
///     dictation runs while held and ends the instant you let go (push-to-talk, zero
///     added stop latency).
///   - **Hold to latch**: keep holding past `latchThreshold` and recording LATCHES
///     hands-free — let the key go and it keeps listening with nothing held. A small
///     lock indicator confirms it.
///   - **Tap to stop**: while latched, the next press stops and inserts.
///
/// This replaces the old *tap-tap-to-lock* gesture: latching now happens by simply
/// holding a beat longer, so there's no double-tap tempo to learn or mistime.
///
/// ## Why a pure machine
/// `HotKeyMonitor.handle()` runs on the CGEventTap thread; keeping the decision logic
/// here — a `Sendable` value type with **no timers, no clocks, no I/O** — means it can
/// be exhaustively unit-tested as a function of its inputs, and the monitor just feeds
/// it timestamped edges under its existing lock. The machine never reads the wall
/// clock: every input carries the timestamp, so tests drive time explicitly and the
/// tap thread passes the event's own timestamp.
///
/// ## First-phoneme priority
/// A `keyDown` while idle emits `.beginArmingLatch` *immediately* — the machine never
/// waits to classify the press, so the microphone is armed from the very first instant
/// of the very first press. The single timer it asks the caller to arm is the LATCH
/// deadline: if the key is still down when it fires, recording latches; a release
/// before then just ends the (held) push-to-talk session synchronously.
///
/// ## No added latency
/// A release is never ambiguous here: before the latch it always ends, after the latch
/// it always keeps recording. So — unlike the old tap-tap machine — there is no
/// deferred-end tax on any press; every stop is synchronous.
///
/// ## Input-source-agnostic
/// The machine consumes abstract `keyDown`/`keyUp`/`timerFired` edges with timestamps;
/// it knows nothing about keycodes, modifiers, or mouse buttons. B7 (mouse-button
/// activation) reuses this exact machine by feeding it edges from a different source —
/// so nothing here may mention a specific input device.
struct ActivationGesture: Sendable, Equatable {
    /// Hold at least this long and recording LATCHES hands-free (releasing the key
    /// keeps it going). A release before this is a plain push-to-talk hold that ends
    /// on release. ~0.5 s is a comfortable "hold a beat longer" that a quick tap never
    /// reaches, yet short enough that latching feels immediate.
    static let latchThreshold: TimeInterval = 0.5

    /// What the machine asks the caller to do after consuming an edge.
    enum Action: Sendable, Equatable {
        /// Do nothing.
        case none
        /// Begin a dictation session now (audio should arm immediately) AND arm a
        /// one-shot timer to fire `timerFired(at:)` at `fireAt` — the latch deadline.
        /// If the key is still held when it fires, recording latches hands-free.
        case beginArmingLatch(fireAt: TimeInterval)
        /// End the current dictation session now (stop + insert).
        case end
        /// Latch the session hands-free (recording continues with no key held).
        case lock
    }

    /// The recording lifecycle, as the machine sees it.
    private enum Phase: Sendable, Equatable {
        /// No session.
        case idle
        /// A press is down and dictation is running (push-to-talk hold in progress).
        /// `latchAt` is when it latches if the key is still down.
        case held(latchAt: TimeInterval)
        /// Latched while the key is STILL down (held past the threshold). The next
        /// key-up drops to `.locked` and keeps recording; it does not end.
        case lockedHeld
        /// Recording is latched hands-free. No key is held; the next press stops it.
        case locked
    }

    private var phase: Phase = .idle

    init() {}

    /// True while a session is active in any form (held, latched-held, or locked).
    var isActive: Bool { phase != .idle }

    /// True whenever recording is LATCHED (key still down after the latch, or fully
    /// released) — the phase that shows the lock indicator and must be exempt from the
    /// reconcile force-release (a latched session must not end on a "key is up" tick).
    var isLocked: Bool {
        switch phase {
        case .lockedHeld, .locked: return true
        case .idle, .held: return false
        }
    }

    /// True only while a plain push-to-talk hold is in progress — the ONLY phase the
    /// reconcile tick may force-end (a latched session has no held key to reconcile
    /// against, so a "modifier is up" reconcile must NOT end it).
    var isHeld: Bool {
        if case .held = phase { return true }
        return false
    }

    // MARK: Inputs

    /// The key/button went down at time `t`.
    mutating func keyDown(at t: TimeInterval) -> Action {
        switch phase {
        case .idle:
            // First-phoneme priority: arm immediately; the latch is decided by the
            // timer if the key is still held at the deadline.
            let latchAt = t + Self.latchThreshold
            phase = .held(latchAt: latchAt)
            return .beginArmingLatch(fireAt: latchAt)
        case .held, .lockedHeld:
            // A second down without an intervening up shouldn't happen from a clean
            // edge source, but if a key-up was dropped we're already recording —
            // ignore it and stay put so we don't double-begin.
            return .none
        case .locked:
            // Latched → the next press stops and inserts.
            phase = .idle
            return .end
        }
    }

    /// The key/button went up at time `t`.
    mutating func keyUp(at t: TimeInterval) -> Action {
        switch phase {
        case .idle, .locked:
            // Stray release with no held key (e.g. the up half of the tap that stopped
            // a locked session) — nothing to do.
            return .none
        case .held:
            // Released before the latch fired: a plain push-to-talk hold — end the
            // instant the key is released, zero added stop latency. (Had it latched,
            // we'd be in `.lockedHeld`, handled below.)
            phase = .idle
            return .end
        case .lockedHeld:
            // Released after latching: keep recording hands-free with nothing held.
            phase = .locked
            return .none
        }
    }

    /// The latch timer fired at time `t`. Latches the session **only** if the key is
    /// still held (we're in `.held`) and the deadline we armed has actually arrived. A
    /// release (→ `.idle`) or any other state change makes this a safe no-op, so a
    /// stale/duplicate timer can never latch an ended session.
    mutating func timerFired(at t: TimeInterval) -> Action {
        guard case .held(let latchAt) = phase else { return .none }
        // Only honor the timer whose deadline we're actually waiting on.
        guard t >= latchAt else { return .none }
        // Still held at the latch deadline → latch hands-free.
        phase = .lockedHeld
        return .lock
    }

    /// Force the machine back to idle without emitting an action. Used when the binding
    /// is torn down (key rebind, stop) and the caller is separately synthesizing
    /// whatever end/cleanup it needs — the machine must not also emit a second `.end`.
    /// Returns whether a session was active (so the caller can decide whether to fire
    /// its own deactivate).
    @discardableResult
    mutating func reset() -> Bool {
        let wasActive = phase != .idle
        phase = .idle
        return wasActive
    }
}
