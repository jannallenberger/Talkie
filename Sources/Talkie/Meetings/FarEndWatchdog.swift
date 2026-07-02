import Foundation

/// The pure decision core of the zero-PCM far-end tap watchdog (plan 01 §4.2a).
///
/// A Core Audio process tap can, on a long session, keep firing its IOProc while
/// delivering **all-zero PCM** — indistinguishable from legitimate silence, and only
/// a full teardown + rebuild of the tap *and* aggregate restores real audio (Apple
/// Developer Forums thread 825780). `SystemAudioCapture` tracks, on its realtime
/// thread, when it last saw a non-silent far-end buffer; this state machine turns
/// that timing (plus a mic-alive cross-check) into one of three actions — keep going,
/// rebuild the tap, or give up on the far end and honestly downgrade the UI to
/// "Recording (mic only)…".
///
/// It is a pure value type with no Foundation state and no clock of its own: every
/// time is *supplied* in seconds by the caller, exactly like `ActiveMeetingDetector`'s
/// `decide`, so a synthetic sequence can be replayed in tests without any audio I/O.
///
/// The two silence branches are deliberately asymmetric:
///
/// - **Never-received grace.** If no non-silent far-end buffer has *ever* arrived, we
///   allow one immediate rebuild after a short grace (a tap that was born dead) — but
///   ONLY when the mic proves the app is actually alive. Joining a call early, before
///   anyone speaks, is common; a genuinely quiet start (mic also silent) must never be
///   downgraded, so with the mic quiet this branch holds at `.ok` indefinitely. (This
///   is the CRITICAL correction to the naive "10 s grace → give up" design in the
///   plan sketch: the never-received path is mic-alive-gated too, not just the
///   mid-meeting path.)
/// - **Mid-meeting silence.** Once real far-end audio *has* been seen, a long
///   continuous silence (≥ `silenceRebuild`) **while the mic is still delivering
///   buffers** means the tap likely died — rebuild it. The mic-alive requirement is
///   what distinguishes "the call went quiet" (mute / hold / listening) from "the tap
///   died"; a real quiet stretch on a live call must not trip a rebuild.
///
/// Rebuilds are capped per meeting (`maxRebuilds`); once exhausted the watchdog gives
/// up (`.giveUp`) and the recorder degrades to mic-only. Rebuilds are also spaced
/// (`rebuildBackoff` after the last rebuild) so a tap that dies again immediately
/// can't burn the whole cap in a few seconds.
struct FarEndWatchdog: Sendable {
    /// Tunable thresholds. Defaults follow the C6 spec: ~10 s never-received grace,
    /// ≥90 s mid-meeting silence, at most 3 rebuilds per meeting. Err long on the
    /// silence window — a false rebuild on a genuinely quiet call is worse than a
    /// slightly delayed recovery of a truly dead tap.
    struct Thresholds: Sendable {
        /// Seconds after capture start before a never-received tap may be rebuilt.
        /// Short — a tap that never delivers a single non-silent buffer in this window
        /// (with the mic alive) was almost certainly born dead.
        var neverReceivedGrace: TimeInterval = 10
        /// Seconds of continuous far-end silence, *after* real audio was once seen,
        /// that triggers a rebuild — provided the mic is still delivering buffers.
        var silenceRebuild: TimeInterval = 90
        /// Max rebuilds per meeting before giving up on the far end entirely.
        var maxRebuilds: Int = 3
        /// Minimum seconds between rebuilds, so a tap that keeps dying immediately
        /// can't exhaust the cap in a burst (spaces the never-received retries too).
        var rebuildBackoff: TimeInterval = 20
        /// How recently (seconds) the mic must have delivered a buffer to count as
        /// "the app is alive". Comfortably larger than a mic buffer period; small
        /// enough that a truly dead mic path reads as not-alive within a poll or two.
        var micAliveWindow: TimeInterval = 5

        static let `default` = Thresholds()
    }

    /// A snapshot of everything the decision needs, gathered by `SystemAudioCapture`
    /// from its lock-guarded counters + the injected mic-alive probe. All times are
    /// seconds on one monotonic clock (the caller's), so they're directly comparable.
    struct Input: Sendable {
        /// Now, in the caller's monotonic seconds.
        var now: TimeInterval
        /// When far-end capture (the current tap) started.
        var startedAt: TimeInterval
        /// When the last non-silent far-end buffer arrived; nil if none ever has.
        var lastNonSilentAt: TimeInterval?
        /// True once any non-silent far-end buffer has arrived this meeting.
        var everReceivedNonSilent: Bool
        /// Rebuilds already performed this meeting.
        var rebuildCount: Int
        /// When the last rebuild happened; nil if none yet. Gates the backoff.
        var lastRebuildAt: TimeInterval?
        /// True iff the mic has delivered a buffer within `micAliveWindow` — the
        /// cross-check that the app/recording is genuinely alive (so far-end silence
        /// means a dead tap, not a quiet call).
        var micAliveRecently: Bool
    }

    /// What the caller should do this tick.
    enum Action: Equatable, Sendable {
        /// Healthy (or not-yet-decidable) — do nothing.
        case ok
        /// The tap looks dead — tear it down and rebuild tap + aggregate.
        case rebuild
        /// Rebuilds are exhausted — stop trying and downgrade to mic-only.
        case giveUp
    }

    var thresholds: Thresholds = .default

    /// Decide what to do, purely from the supplied `Input`. No clock, no I/O — the
    /// same shape as `ActiveMeetingDetector.decide`, so tests replay synthetic
    /// sequences. See the type doc for the two asymmetric silence branches.
    func decide(_ input: Input) -> Action {
        let t = thresholds

        if input.everReceivedNonSilent {
            // --- Mid-meeting death path ---
            // Silence is measured from the last real audio (or, defensively, from
            // start if the flag is set but the timestamp is somehow missing).
            let since = input.lastNonSilentAt ?? input.startedAt
            let silentFor = input.now - since
            guard silentFor >= t.silenceRebuild else { return .ok }
            // A genuinely quiet call (mic also quiet) is NOT a dead tap — hold.
            guard input.micAliveRecently else { return .ok }
            return rebuildOrGiveUp(input)
        } else {
            // --- Never-received path (tap possibly born dead) ---
            // Only actionable once the mic proves the app is alive: joining early,
            // before anyone speaks, must never be downgraded on a quiet start.
            guard input.micAliveRecently else { return .ok }
            let waited = input.now - input.startedAt
            guard waited >= t.neverReceivedGrace else { return .ok }
            return rebuildOrGiveUp(input)
        }
    }

    /// Shared tail for both silence branches: respect the per-meeting cap and the
    /// inter-rebuild backoff. Exhausted cap → `.giveUp`; within backoff → `.ok`
    /// (wait); otherwise `.rebuild`.
    private func rebuildOrGiveUp(_ input: Input) -> Action {
        guard input.rebuildCount < thresholds.maxRebuilds else { return .giveUp }
        if let last = input.lastRebuildAt, input.now - last < thresholds.rebuildBackoff {
            return .ok
        }
        return .rebuild
    }
}
