import Foundation

/// The pure decision core of the hands-free auto-stop watchdog (B5).
///
/// A locked hands-free dictation (B4 — tap-tap put it in locked mode) keeps
/// recording after the key is released, and today only a manual tap stops it. For a
/// user who literally cannot reach the keyboard that's a dead end. This watchdog
/// ends such a session after a *sustained* silence — but never abruptly: it first
/// arms, then shows a visible, cancelable countdown in the pill, and only stops if
/// the silence survives the whole window. Speaking again at any point cancels it and
/// the session continues.
///
/// Like `FarEndWatchdog` / `ActiveMeetingDetector`, this is a pure value type with no
/// clock of its own: every timestamp is *supplied* in seconds by the caller (the
/// `@MainActor` `SilenceWatchdogDriver` below, driven by the live `onLevel` closure,
/// the engine's volatile-result handler, and a coarse tick). That keeps the whole
/// two-phase state machine replayable in tests without any audio I/O — a synthetic
/// `(timestamp, level)` + `transcriptChanged` sequence is fed in and the emitted
/// `Event`s are asserted.
///
/// ## What counts as silence
/// Silence is BOTH conditions, sustained together:
/// - the mic level is below `silenceFloor` (the perceptual dB mapping's practical
///   floor — `AudioCapture.level(of:)` maps −55 dB → 0, so `0.05` ≈ −52 dB, i.e.
///   genuine room-quiet, not speech), AND
/// - no *volatile* transcript change has arrived.
///
/// The volatile-text condition is load-bearing for a **quiet speaker**: someone whose
/// voice barely clears the level floor is still clearly talking if the recognizer is
/// emitting new partial words, so a volatile-text change alone resets the silence
/// clock even when the level never rises. Eating that person's words would be the
/// worst failure of this feature.
///
/// ## Two phases (deliberately generous)
/// The killer risk is stopping during a *thinking pause*. Mitigation is baked into
/// the constants and the shape, not into a setting:
/// 1. **Arm.** After `armAfter` (4 s) of continuous silence the watchdog emits
///    `.countdownStarted(remaining:)` — the pill begins a visible countdown.
/// 2. **Count down.** For a further `countdownDuration` (3 s) any speech (a level
///    spike OR a volatile-text change) emits `.cancelled` and returns to waiting;
///    only if the silence survives the full countdown does it emit `.stop`.
///
/// So it takes ~`armAfter + countdownDuration` (≈7 s) of true, unbroken silence to
/// auto-stop, and the last 3 s of that are on-screen and cancelable. These constants
/// live here in code with no user-facing setting, per the B5 spec — do NOT tighten
/// them; a generous, visible, cancelable window is the entire safety story.
struct SilenceWatchdog: Sendable {
    /// Tunable thresholds. Defaults follow the B5 spec (4 s arm + 3 s countdown ≈ 7 s
    /// total true silence). Err long: a swallowed thinking pause is far worse than a
    /// few extra seconds before a genuinely-abandoned session wraps up.
    struct Thresholds: Sendable {
        /// Mic level (0…1, `AudioCapture`'s perceptual dB mapping) at or below which a
        /// buffer counts as silent. `0.05` ≈ −52 dB on that mapping — clearly below
        /// speech, above the noise floor of a live-but-quiet room.
        var silenceFloor: Float = 0.05
        /// Seconds of continuous silence before the visible countdown begins.
        var armAfter: TimeInterval = 4
        /// Seconds the on-screen countdown runs before auto-stop, if silence persists.
        var countdownDuration: TimeInterval = 3

        static let `default` = Thresholds()
    }

    /// What the watchdog tells the driver to do, as a result of the latest observation
    /// or tick. `nil` (no event) is by far the common case — most ticks change nothing.
    enum Event: Equatable, Sendable {
        /// Silence has lasted `armAfter`; begin the visible pill countdown. `remaining`
        /// is the countdown length so the driver can size the ring animation.
        case countdownStarted(remaining: TimeInterval)
        /// Speech resumed during the countdown; abandon it and restore the plain
        /// locked pill. The session continues.
        case cancelled
        /// The countdown elapsed with unbroken silence; stop the dictation now (the
        /// driver yields `.end`, exactly as a manual tap would).
        case stop
    }

    /// The internal phase. Value-typed so the whole machine is a `struct` that tests
    /// can copy and replay.
    private enum Phase: Equatable {
        /// Not currently in the visible countdown. Silence is measured as
        /// `now - lastActivityAt`; `lastActivityAt == nil` only before any activity has
        /// ever been seen (in which case there is nothing to measure against yet).
        case waiting(lastActivityAt: TimeInterval?)
        /// The visible countdown is running, started at `startedAt`; it stops at
        /// `startedAt + countdownDuration` unless activity cancels it first.
        case countingDown(startedAt: TimeInterval)
    }

    var thresholds: Thresholds = .default
    private var phase: Phase = .waiting(lastActivityAt: nil)

    init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    /// Whether the visible countdown is currently running. The driver reads this to
    /// know if a fresh `.cancelled` needs to restore the pill.
    var isCountingDown: Bool {
        if case .countingDown = phase { return true }
        return false
    }

    /// Fold in one audio-level sample taken at `now`. A level above the floor is
    /// activity (resets the silence clock / cancels a countdown); a level at or below
    /// the floor advances the silence measurement. Returns any resulting `Event`.
    mutating func observe(level: Float, at now: TimeInterval) -> Event? {
        if level > thresholds.silenceFloor {
            return registerActivity(at: now)
        }
        return advanceSilence(to: now)
    }

    /// Fold in a volatile-transcript change at `now` — the *quiet-speaker* signal.
    /// Always counts as activity regardless of level: new partial words mean the user
    /// is speaking even if their voice never clears the level floor.
    mutating func transcriptChanged(at now: TimeInterval) -> Event? {
        return registerActivity(at: now)
    }

    /// A bare clock tick with no new sample (the driver polls a few times a second).
    /// Advances the silence measurement / countdown against `now` from the last known
    /// activity time. This is what actually fires `.countdownStarted` and `.stop` when
    /// nothing at all is arriving — the truly-silent case.
    mutating func tick(now: TimeInterval) -> Event? {
        return advanceSilence(to: now)
    }

    // MARK: - Core transitions

    /// Any activity (level spike or volatile change) at `now`. Cancels a running
    /// countdown (emitting `.cancelled`) or just resets the silence clock. Either way
    /// the silence measurement now restarts from `now`.
    private mutating func registerActivity(at now: TimeInterval) -> Event? {
        switch phase {
        case .countingDown:
            phase = .waiting(lastActivityAt: now)
            return .cancelled
        case .waiting:
            phase = .waiting(lastActivityAt: now)
            return nil
        }
    }

    /// Advance the silence measurement to `now` with no new activity. Measures silence
    /// from the last activity, arms the countdown once `armAfter` has elapsed, and
    /// stops once the countdown window elapses.
    private mutating func advanceSilence(to now: TimeInterval) -> Event? {
        switch phase {
        case .waiting(let lastActivityAt):
            guard let since = lastActivityAt else {
                // No activity has been seen yet, so this quiet observation is our first
                // reference point — start measuring silence from here. (In a real locked
                // session speech precedes the lock, so the clock normally starts from the
                // last spoken word; this branch just covers a session that is quiet from
                // its first sample so it can still eventually arm.)
                phase = .waiting(lastActivityAt: now)
                return nil
            }
            // Defensive against a non-monotonic/rewound clock: never let elapsed go
            // negative (which would postpone arming); treat as still-just-started.
            let silentFor = max(0, now - since)
            guard silentFor >= thresholds.armAfter else { return nil }
            phase = .countingDown(startedAt: now)
            return .countdownStarted(remaining: thresholds.countdownDuration)

        case .countingDown(let startedAt):
            let elapsed = max(0, now - startedAt)
            guard elapsed >= thresholds.countdownDuration else { return nil }
            // Countdown survived the full window in silence → stop. Reset to a pristine
            // waiting state so a reused instance is inert until fed activity again (the
            // driver tears down anyway).
            phase = .waiting(lastActivityAt: nil)
            return .stop
        }
    }
}

/// The thin `@MainActor` driver around the pure `SilenceWatchdog`.
///
/// One is created per *locked* hands-free dictation session (never for a held /
/// push-to-talk session) and fed by the existing main-actor callbacks:
/// `AudioCapture.onLevel` (the same normalized 0…1 level the waveform uses, ~12×/sec)
/// and the engine's volatile-result handler (every partial). It also runs a coarse
/// self-tick so the *truly-silent* case — where no level or transcript update arrives
/// at all — still arms and stops on schedule.
///
/// It owns no policy: it forwards each observation to the pure core and translates the
/// returned `Event`s into three injected closures the hub supplies —
/// `onCountdownStarted` (show the pill ring), `onCancelled` (restore the plain locked
/// pill), and `onStop` (yield `.end` into the dictation event stream, ending exactly
/// as a manual tap would). Everything runs on the main actor, so there is no locking:
/// the callbacks and the timer all hop here already.
@MainActor
final class SilenceWatchdogDriver {
    private var watchdog: SilenceWatchdog
    private var timer: Timer?

    /// Poll interval for the self-tick. A few times a second is plenty: the arm/stop
    /// thresholds are whole seconds, so sub-second precision is irrelevant and a busy
    /// timer would be wasteful. Level/transcript callbacks drive cancellation far more
    /// responsively than this; the tick only exists for the no-input-at-all case.
    private let tickInterval: TimeInterval = 0.2

    private let onCountdownStarted: (TimeInterval) -> Void
    private let onCancelled: () -> Void
    private let onStop: () -> Void

    /// Monotonic seconds since this driver started, using a process-uptime clock so a
    /// wall-clock change (NTP, DST) can't skew the silence measurement.
    private let epoch = ProcessInfo.processInfo.systemUptime
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime - epoch }

    init(thresholds: SilenceWatchdog.Thresholds = .default,
         onCountdownStarted: @escaping (TimeInterval) -> Void,
         onCancelled: @escaping () -> Void,
         onStop: @escaping () -> Void) {
        self.watchdog = SilenceWatchdog(thresholds: thresholds)
        self.onCountdownStarted = onCountdownStarted
        self.onCancelled = onCancelled
        self.onStop = onStop
    }

    /// Begin watching. Safe to call once per session; the caller only builds a driver
    /// for a locked session, so merely constructing-and-starting is the arm.
    func start() {
        // Coarse repeating self-tick for the silent case. `.common` so it keeps firing
        // during menu tracking / event loops; weak self so it never keeps the driver
        // (or the session) alive past teardown.
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop watching and release the timer. Called on any session-end path (manual tap,
    /// auto-stop, capture failure) so a torn-down session leaves no live timer behind.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Feed a mic level sample (from `AudioCapture.onLevel`).
    func observe(level: Float) {
        emit(watchdog.observe(level: level, at: now))
    }

    /// Feed a volatile-transcript change (from the engine's partial-result handler) —
    /// the quiet-speaker activity signal.
    func transcriptChanged() {
        emit(watchdog.transcriptChanged(at: now))
    }

    private func tick() {
        emit(watchdog.tick(now: now))
    }

    private func emit(_ event: SilenceWatchdog.Event?) {
        switch event {
        case .countdownStarted(let remaining): onCountdownStarted(remaining)
        case .cancelled: onCancelled()
        case .stop:
            // One-shot: stop the timer before firing so a stop can't re-enter.
            stop()
            onStop()
        case .none:
            break
        }
    }
}
