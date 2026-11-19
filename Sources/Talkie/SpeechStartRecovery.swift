import Foundation

/// Recovery for "the first dictation after a long sleep / idle never starts".
///
/// After the Mac sleeps for hours the system speech service (`localspeechrecognition`)
/// can be gone: the process-held connection is invalid (NSCocoaErrorDomain 4099), the
/// locale reservations are dropped ("unallocated locales"), and a prewarmed audio engine
/// can fail with CoreAudio -10877. Nothing in the app noticed, and the start path awaited
/// Apple's objects without a bound. Everything decidable lives here as pure functions
/// (unit-tested); `AppDelegate` only wires them to the real engine, mic and pill.
enum SpeechStartRecovery {
    /// One automatic rebuild-and-retry per key press, never more.
    static let maxRetries = 1

    /// Per-attempt bound on session setup (model check, analyzer start). A healthy start
    /// takes well under a second; this only exists so a wedged speech service can never
    /// leave the pill gray forever.
    static let attemptTimeoutSeconds: Double = 8

    /// The bound for a session setup. A first-run model download is legitimately slow and
    /// has its own visible progress, so the bound applies only once the model is known
    /// to be installed (then setup is a local call that cannot take minutes).
    static func attemptTimeout(modelKnownInstalled: Bool) -> Double? {
        modelKnownInstalled ? attemptTimeoutSeconds : nil
    }

    // MARK: Error classification

    /// `NSXPCConnectionInterrupted` / `NSXPCConnectionInvalid` / `NSXPCConnectionReplyInvalid`.
    private static let staleCocoaCodes: Set<Int> = [4097, 4099, 4101]
    /// `kAudioUnitErr_InvalidElement` — the input unit of a long-idle engine.
    private static let staleAudioUnitCode = -10877

    /// Is this the signature of a dead speech-service connection or an invalidated audio
    /// unit — i.e. will a freshly built set of objects plausibly succeed? Looks through
    /// underlying errors, since Speech wraps the XPC error.
    static func isStaleConnection(_ error: Error) -> Bool {
        if let engineError = error as? TalkieEngineError {
            return engineError.isStaleConnection
        }
        if error is CancellationError { return false }
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 6 {
            if ns.domain == NSCocoaErrorDomain, staleCocoaCodes.contains(ns.code) { return true }
            if ns.code == staleAudioUnitCode { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    enum Decision: Equatable { case retry, giveUp }

    /// `attempt` is zero-based: 0 is the first try. Retry only stale-connection failures,
    /// and only up to `maxRetries` times.
    static func decide(afterFailedAttempt attempt: Int, error: Error) -> Decision {
        guard attempt < maxRetries, isStaleConnection(error) else { return .giveUp }
        return .retry
    }

    /// What a retry has to throw away before building fresh objects.
    struct RebuildPlan: Equatable {
        /// Cancel the analyzer/results reader, invalidate any in-flight start and
        /// re-reserve the locale assets.
        var speech: Bool
        /// Drop the (prewarmed) AVAudioEngine so the next start builds a clean one.
        var mic: Bool
    }

    static func rebuildPlan(for error: Error) -> RebuildPlan {
        let audio = hasAudioUnitCode(error)
        return RebuildPlan(speech: true, mic: audio)
    }

    private static func hasAudioUnitCode(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 6 {
            if ns.code == staleAudioUnitCode { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// The error the user finally sees: a stale-connection failure that survived the
    /// retry is reported as a plain "speech service not reachable" sentence instead of
    /// the raw framework error. Other errors pass through unchanged.
    static func userFacing(_ error: Error) -> Error {
        if let e = error as? TalkieEngineError, !e.isStaleConnection { return error }
        return isStaleConnection(error) ? TalkieEngineError.speechServiceUnavailable : error
    }

    // MARK: Retry runner

    /// Run `attempt`; on a stale-connection failure run `rebuild` and try once more.
    /// Runs on the caller's actor so main-actor-confined attempt closures (audio start)
    /// stay on the main actor. Throws the user-facing error when it gives up.
    static func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        attempt: (Int) async throws -> T,
        rebuild: (Error) async -> Void
    ) async throws -> T {
        var n = 0
        while true {
            do {
                return try await attempt(n)
            } catch {
                guard decide(afterFailedAttempt: n, error: error) == .retry else {
                    throw userFacing(error)
                }
                talkieDebugLog("speech start failed (attempt \(n + 1)): \(error) — rebuilding and retrying once")
                await rebuild(error)
                n += 1
            }
        }
    }

    // MARK: Bounded wait

    /// Run `operation`, but never wait longer than `seconds`: on timeout throw
    /// `TalkieEngineError.startTimedOut` and return, even if `operation` never comes
    /// back. Unlike `withAsyncTimeout` this does NOT wait for the operation to unwind
    /// (a structured group would block on Apple's non-cooperative await); the abandoned
    /// operation is unblocked afterwards by the rebuild step, and its late result is
    /// dropped. `seconds == nil` means unbounded.
    static func bounded<T: Sendable>(
        seconds: Double?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let seconds else { return try await operation() }
        let race = OneShotResult<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.bind(continuation)
            Task {
                do { race.resolve(.success(try await operation())) }
                catch { race.resolve(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                race.resolve(.failure(TalkieEngineError.startTimedOut))
            }
        }
    }

    /// Resolves a continuation with whichever outcome arrives first; later ones are ignored.
    private final class OneShotResult<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        func bind(_ c: CheckedContinuation<T, Error>) {
            lock.lock(); defer { lock.unlock() }
            continuation = c
        }

        func resolve(_ result: Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}

extension TalkieEngineError {
    /// Part of `SpeechStartRecovery.isStaleConnection` for our own error type.
    var isStaleConnection: Bool {
        switch self {
        case .startTimedOut: return true
        default: return false
        }
    }
}

/// Carries a non-Sendable-but-safe value (AVAudioFormat + stream continuation) out of a
/// `@Sendable` closure; the engine already hands these across actors today.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The outcome of a successful dictation start.
struct StartedDictation {
    let generation: Int
}

// MARK: - Sleep / wake

/// Power events the app reacts to while idle.
enum PowerEvent: Equatable, Sendable {
    case willSleep
    case didWake
    case screensDidWake
}

enum WakeAction: Equatable, Sendable {
    /// Drop the prewarmed (never-started) AVAudioEngine so sleep can't leave a dead unit.
    case releasePrewarmedMic
    /// Drop speech-service state and re-reserve locale assets (daemon may have restarted).
    case resetSpeechService
    /// Re-warm the speech models (also re-reserves their locales).
    case rewarmSpeechModels
    /// Prewarm the mic again — `AudioCapture.prewarm` itself refuses when a Bluetooth
    /// input is involved, so the idle-off-the-headset rule is preserved.
    case reprewarmMic
}

enum WakeRecovery {
    /// "Idle" means nothing is using the speech engine or mic right now. An active
    /// dictation, a polishing/inserting one or any meeting work is never torn down.
    struct Activity: Equatable, Sendable {
        var dictating: Bool
        var processing: Bool
        var meetingBusy: Bool
        var isIdle: Bool { !dictating && !processing && !meetingBusy }
    }

    static func actions(for event: PowerEvent, activity: Activity) -> [WakeAction] {
        guard activity.isIdle else { return [] }
        switch event {
        case .willSleep:
            return [.releasePrewarmedMic]
        case .didWake:
            return [.resetSpeechService, .rewarmSpeechModels, .reprewarmMic]
        case .screensDidWake:
            // The display waking alone doesn't restart the speech daemon; just make
            // sure the mic is prewarmed (a no-op when it already is).
            return [.reprewarmMic]
        }
    }

    /// Give audio devices a moment to reappear after wake before touching them.
    static let wakeSettleSeconds: Double = 2
}

// MARK: - Debug simulation

extension Dev {
    /// Count of upcoming speech session starts that should fail as if the system speech
    /// service were dead (NSCocoaErrorDomain 4099), for exercising the recovery by hand:
    ///     defaults write com.coralate.talkie SimulateStaleSpeechStarts -int 1
    /// `1` shows the silent retry succeeding; `2` shows the user-facing error notice.
    /// Honored only while `Dev.isEnabled` (Debug build or dev mode); a normal user's
    /// install ignores the key entirely.
    static let simulateStaleStartsKey = "SimulateStaleSpeechStarts"

    /// Consume one simulated failure, if any are pending.
    static func consumeSimulatedStaleStart() -> Bool {
        guard isEnabled else { return false }
        let remaining = UserDefaults.standard.integer(forKey: simulateStaleStartsKey)
        guard remaining > 0 else { return false }
        UserDefaults.standard.set(remaining - 1, forKey: simulateStaleStartsKey)
        return true
    }

    static var simulatedStaleError: NSError {
        NSError(domain: NSCocoaErrorDomain, code: 4099,
                userInfo: [NSDebugDescriptionErrorKey: "simulated stale speech connection"])
    }
}
