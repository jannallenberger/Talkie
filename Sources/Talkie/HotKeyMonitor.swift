import AppKit
import CoreGraphics

/// Watches a single global activation key (a modifier, or Fn) and reports
/// press/release. Implemented with a listen-only `CGEventTap` so it needs only
/// the Input Monitoring permission (never swallows the key, so the modifier
/// still works normally in other apps). The tap is created synchronously on the
/// caller's thread; its run-loop source runs on a dedicated thread so a busy
/// main thread can't trip the system's tap-timeout. All shared state is guarded
/// by a lock because `handle()` runs on the tap thread while start/stop/update
/// run on the main thread.
final class HotKeyMonitor: @unchecked Sendable {
    struct Config: Sendable, Equatable {
        var key: ActivationKey
    }

    private let onActivate: @Sendable () -> Void
    private let onDeactivate: @Sendable () -> Void
    /// Fired when a tap-tap locks recording hands-free. Recording is already
    /// running (it began on the first tap's key-down), so this only tells the app
    /// to switch to the locked/hands-free presentation — it must NOT start a second
    /// session.
    private let onLock: @Sendable () -> Void
    /// Fired on a global "paste my last transcript" chord — ⌘ + (Control or Option,
    /// whichever the activation key does NOT use) + V, so it can't double as a
    /// dictation trigger. Detected on the same listen-only tap, so the chord is never
    /// swallowed (it still reaches the focused app, which is harmless — text fields
    /// don't bind these chords).
    private let onPasteLast: @Sendable () -> Void

    /// `kVK_ANSI_V` — the key code for the paste-last chord (⌥⌘ + V).
    private static let pasteLastKeyCode: Int64 = 9

    private let lock = NSLock()
    // --- all guarded by `lock` ---
    private var config: Config
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var threadRunLoop: CFRunLoop?
    private var isStarted = false
    /// The one activation gesture family (hold / tap-tap-lock / tap-stop), driven
    /// entirely by the timestamped edges `handle()` feeds it. All access is under
    /// `lock` because `handle()` runs on the tap thread while the deferred-end timer
    /// and the health/reconcile timer run on other queues.
    private var gesture = ActivationGesture()
    /// The one-shot timer that resolves an ambiguous quick tap: if it fires before a
    /// second press arrives, the tap was lone → end. Rearmed on each new quick tap,
    /// cancelled when a second press locks. Guarded by `lock`.
    private var deferTimer: DispatchSourceTimer?
    // -----------------------------

    private var healthTimer: DispatchSourceTimer?

    init(
        config: Config,
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onLock: @escaping @Sendable () -> Void = {},
        onPasteLast: @escaping @Sendable () -> Void = {}
    ) {
        self.config = config
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onLock = onLock
        self.onPasteLast = onPasteLast
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    /// Installs the tap. Returns false if Input Monitoring isn't granted yet
    /// (the tap cannot be created); call again after the user grants it.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        if isStarted {
            lock.unlock()
            return true
        }
        lock.unlock()

        guard CGPreflightListenEventAccess() else { return false }

        // Create the tap synchronously so `isStarted`/`tap` are set before we
        // return — no window where a second start() spawns a duplicate thread.
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotKeyEventCallback,
            userInfo: refcon
        ) else {
            return false
        }

        lock.lock()
        self.tap = tap
        self.isStarted = true
        lock.unlock()

        let thread = Thread { [weak self] in
            guard let self else { return }
            // Read the tap from `self` rather than capturing the CFMachPort into
            // this @Sendable closure (keeps Swift 6 concurrency happy).
            self.lock.lock()
            let tap = self.tap
            self.lock.unlock()
            guard let tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.lock.lock()
            self.runLoopSource = source
            self.threadRunLoop = CFRunLoopGetCurrent()
            self.lock.unlock()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.coralate.talkie.hotkey"
        thread.start()

        startHealthTimer()
        return true
    }

    func stop() {
        healthTimer?.cancel()
        healthTimer = nil

        lock.lock()
        let tap = self.tap
        let runLoop = self.threadRunLoop
        self.tap = nil
        self.runLoopSource = nil
        self.threadRunLoop = nil
        self.isStarted = false
        self.deferTimer?.cancel()
        self.deferTimer = nil
        self.gesture.reset()
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    /// Swap the bound key. Only tears down an in-flight activation when the binding
    /// actually changed — rebinding during an unrelated hold (or a locked session)
    /// must force-end it, since the edges for the *new* key can't cleanly finish a
    /// session that began under the old one. The gesture machine is reset and, if a
    /// session was active, we synthesize the deactivate here (the machine's `reset`
    /// deliberately emits no action so it can't double-fire).
    func update(config newConfig: Config) {
        lock.lock()
        let changed = newConfig != self.config
        self.config = newConfig
        var wasActive = false
        if changed {
            deferTimer?.cancel()
            deferTimer = nil
            wasActive = gesture.reset()
        }
        lock.unlock()

        if changed && wasActive {
            onDeactivate()
        }
    }

    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let tap = self.tap
            let started = self.isStarted
            self.lock.unlock()
            guard started, let tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            self.reconcileLiveState()
        }
        timer.resume()
        healthTimer = timer
    }

    // MARK: Event handling (called from the tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reconcileLiveState()
            return
        }

        // A global ⌘+(Control|Option)+V chord re-pastes the last transcript. The
        // second modifier is whichever one the activation key does NOT use, so the
        // chord can never also arm dictation. Detected here on the shared listen-only
        // tap; ignored on auto-repeat so a held chord fires once.
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               event.getIntegerValueField(.keyboardEventKeycode) == Self.pasteLastKeyCode {
                lock.lock()
                let secondary = config.key.pasteShortcut.secondary
                lock.unlock()
                let f = event.flags
                let cmd = f.contains(.maskCommand)
                let opt = f.contains(.maskAlternate)
                let ctrl = f.contains(.maskControl)
                let shift = f.contains(.maskShift)
                let match: Bool
                switch secondary {
                case .control: match = cmd && ctrl && !opt && !shift
                case .option:  match = cmd && opt && !ctrl && !shift
                }
                if match { onPasteLast() }
            }
            return
        }

        guard type == .flagsChanged else { return } // all supported keys are modifiers/Fn

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        // One monotonic seconds clock for edges AND the deferred-end timer, so the
        // pure machine can compare an edge's timestamp against the timer's fire
        // timestamp. (The event's own timestamp is in different units; using uptime
        // for both keeps them commensurable.)
        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        let cfg = config
        guard keyCode == cfg.key.keyCode else { lock.unlock(); return }
        let down = cfg.key.isDown(in: flags)
        // Feed the timestamped edge to the pure gesture machine and act on what it
        // decides — all still under `lock` (the tap thread must not race the timers).
        let action = down ? gesture.keyDown(at: now) : gesture.keyUp(at: now)
        let fire = applyLocked(action)
        lock.unlock()

        fire?()
    }

    /// Translate a gesture `Action` into the callback to fire (or nil), performing
    /// any timer bookkeeping. **Must be called with `lock` held** — it touches
    /// `deferTimer`. Returns the callback to invoke *after* unlocking (so we never
    /// run app code while holding the tap-thread lock).
    private func applyLocked(_ action: ActivationGesture.Action) -> (@Sendable () -> Void)? {
        switch action {
        case .none:
            return nil
        case .begin:
            cancelDeferTimerLocked()
            return onActivate
        case .end:
            cancelDeferTimerLocked()
            return onDeactivate
        case .lock:
            // A second tap locked: the pending lone-tap timer is now superseded.
            cancelDeferTimerLocked()
            return onLock
        case .deferEnd(let fireAt):
            armDeferTimerLocked(fireAt: fireAt)
            return nil
        }
    }

    /// Arm (or re-arm) the one-shot deferred-end timer to fire at uptime `fireAt`.
    /// When it fires it feeds `timerFired` back into the machine on the same lock;
    /// if the machine still wants to end (no second tap came) we fire `onDeactivate`.
    /// Must be called with `lock` held.
    private func armDeferTimerLocked(fireAt: TimeInterval) {
        deferTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        let delay = max(0, fireAt - ProcessInfo.processInfo.systemUptime)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let fireNow = ProcessInfo.processInfo.systemUptime
            self.lock.lock()
            let action = self.gesture.timerFired(at: fireNow)
            let fire = self.applyLocked(action)
            // This timer has done its job; drop the reference so a later cancel is
            // a no-op and we don't hold a spent source.
            if self.deferTimer === timer { self.deferTimer = nil }
            self.lock.unlock()
            fire?()
        }
        deferTimer = timer
        timer.resume()
    }

    /// Cancel any pending deferred-end timer. Must be called with `lock` held.
    private func cancelDeferTimerLocked() {
        deferTimer?.cancel()
        deferTimer = nil
    }

    /// If we think a key is physically *held* but the live modifier state says it
    /// isn't (a key-up event was dropped), synthesize the release so a hold can't
    /// latch on forever. ONLY the held phase is eligible: a locked hands-free
    /// session has no key down (ending it here would kill the lock), and an
    /// awaiting-second-tap window also has the key already up (ending it would
    /// pre-empt a legitimate tap-tap). So we gate strictly on `gesture.isHeld`.
    private func reconcileLiveState() {
        lock.lock()
        let cfg = config
        let held = gesture.isHeld
        lock.unlock()
        guard held else { return }

        let live = CGEventSource.flagsState(.combinedSessionState)
        guard !cfg.key.isDown(in: live) else { return }

        var fire: (@Sendable () -> Void)?
        lock.lock()
        // Re-check under the lock — the phase may have changed between the two
        // critical sections. Only a still-held session is force-released, and the
        // machine's `reset` emits no action so we own the single `onDeactivate`.
        if gesture.isHeld {
            cancelDeferTimerLocked()
            gesture.reset()
            fire = onDeactivate
        }
        lock.unlock()
        fire?()
    }
}

// MARK: - Key code / flag mapping

private extension ActivationKey {
    /// Hardware key code reported on `.flagsChanged`.
    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61   // 0x3D
        case .leftOption: return 58    // 0x3A
        case .rightControl: return 62  // 0x3E
        }
    }

    /// Device-dependent flag bit that distinguishes left vs right of a modifier
    /// pair (the merged `.maskAlternate` / `.maskControl` can't tell sides apart).
    func isDown(in flags: CGEventFlags) -> Bool {
        switch self {
        case .rightOption: return flags.rawValue & 0x40 != 0   // NX_DEVICERALTKEYMASK
        case .leftOption: return flags.rawValue & 0x20 != 0    // NX_DEVICELALTKEYMASK
        case .rightControl: return flags.rawValue & 0x2000 != 0 // NX_DEVICERCTLKEYMASK
        }
    }
}

// MARK: - C callback trampoline

private func hotKeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handle(type: type, event: event)
    }
    // Listen-only tap: the return value is ignored, but hand the event back.
    return Unmanaged.passUnretained(event)
}
