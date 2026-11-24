import AppKit
import CoreGraphics

/// Watches a single global activation trigger — a modifier key (by side), a
/// function key F1-F20 or an extra mouse button — and reports press/release. Implemented with a
/// listen-only `CGEventTap` so it needs only the Input Monitoring permission
/// (never swallows the event, so the modifier — or the mouse button's native app
/// action, e.g. browser back — still works normally in other apps). The tap is
/// created synchronously on the caller's thread; its run-loop source runs on a
/// dedicated thread so a busy main thread can't trip the system's tap-timeout.
/// All shared state is guarded by a lock because `handle()` runs on the tap
/// thread while start/stop/update run on the main thread. Keyboard and mouse
/// triggers feed the identical `ActivationGesture` machine — only the event
/// source differs.
final class HotKeyMonitor: @unchecked Sendable {
    struct Config: Sendable, Equatable {
        var key: ActivationKey
        /// The "format while you dictate" command key, or nil when the feature is off.
        /// Only observed while a dictation is active; never the dictation key.
        var commandKey: ActivationKey? = nil
    }

    private let onActivate: @Sendable () -> Void
    private let onDeactivate: @Sendable () -> Void
    /// Fired on a global "paste my last transcript" chord — ⌘ + (Control or Option,
    /// whichever the activation key does NOT use) + V, so it can't double as a
    /// dictation trigger. Detected on the same listen-only tap, so the chord is never
    /// swallowed (it still reaches the focused app, which is harmless — text fields
    /// don't bind these chords).
    private let onPasteLast: @Sendable () -> Void
    /// "Format while you dictate": what the command key did during an active dictation
    /// (a clean span, a tap, or a cancelled hold). Decided by the pure
    /// `FormatKeyGesture` on this same listen-only tap — the key is never swallowed.
    private let onFormatKey: @Sendable (FormatKeyGesture.Output) -> Void

    /// `kVK_ANSI_V` — the key code for the paste-last chord (⌥⌘ + V).
    private static let pasteLastKeyCode: Int64 = 9

    private let lock = NSLock()
    // --- all guarded by `lock` ---
    private var config: Config
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var threadRunLoop: CFRunLoop?
    private var isStarted = false
    /// True while the settings key recorder is listening; `handle()` ignores all input.
    private var suspended = false
    /// The activation gesture (hold to talk, release to transcribe), driven by the
    /// edges `handle()` feeds it. All access is under `lock` because `handle()` runs
    /// on the tap thread while the health/reconcile timer runs on another queue.
    private var gesture = ActivationGesture()
    /// The command-key machine. Fed only while `gesture.isActive` (a dictation is
    /// running) and `config.commandKey` is set; reset otherwise. Guarded by `lock`.
    private var formatGesture = FormatKeyGesture()
    // -----------------------------

    private var healthTimer: DispatchSourceTimer?

    init(
        config: Config,
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onPasteLast: @escaping @Sendable () -> Void = {},
        onFormatKey: @escaping @Sendable (FormatKeyGesture.Output) -> Void = { _ in }
    ) {
        self.config = config
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onPasteLast = onPasteLast
        self.onFormatKey = onFormatKey
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
        // `otherMouseDown`/`otherMouseUp` carry the side buttons (button 4/5) so a
        // mouse-button `ActivationKey` can drive the same gesture machine; the tap
        // is still listen-only, so the button keeps performing its native app
        // action (e.g. browser back). Left/right mouse-downs are observed only so a
        // click during a held command key can cancel that command (the accident
        // guard of "format while you dictate"); they never drive the dictation key.
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)
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
        self.gesture.reset()
        self.formatGesture.reset()
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    /// Swap the bound key. Only tears down an in-flight activation when the binding
    /// actually changed — rebinding during an unrelated hold
    /// must force-end it, since the edges for the *new* key can't cleanly finish a
    /// session that began under the old one. The gesture machine is reset and, if a
    /// session was active, we synthesize the deactivate here (the machine's `reset`
    /// deliberately emits no action so it can't double-fire).
    func update(config newConfig: Config) {
        lock.lock()
        // Only a change of the DICTATION key tears down an in-flight session; a
        // command-key change just drops any half-done command hold.
        let changed = newConfig.key != self.config.key
        if newConfig.commandKey != self.config.commandKey { formatGesture.reset() }
        self.config = newConfig
        var wasActive = false
        if changed {
            wasActive = gesture.reset()
        }
        lock.unlock()

        if changed && wasActive {
            onDeactivate()
        }
    }

    /// Suspend/resume all trigger and paste-last handling (key recorder is listening).
    /// Suspending force-ends any in-flight hold exactly like a rebind does.
    func setSuspended(_ value: Bool) {
        lock.lock()
        suspended = value
        var wasActive = false
        if value {
            wasActive = gesture.reset()
            formatGesture.reset()
        }
        lock.unlock()
        if wasActive { onDeactivate() }
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

        // Suspended while the key recorder listens: no dictation or paste-last.
        lock.lock()
        let isSuspended = suspended
        lock.unlock()
        if isSuspended { return }

        // Left/right clicks are observed for one thing only: a click during a held
        // format key cancels that command. Unless a dictation is active AND a hold is
        // in progress they return here untouched — no field of the click is read,
        // nothing is stored or logged. During a hold the only effect is that hold's
        // "spoiled" flag.
        if type == .leftMouseDown || type == .rightMouseDown {
            lock.lock()
            if gesture.isActive, formatGesture.isHeld { formatGesture.otherInput() }
            lock.unlock()
            return
        }

        // A global ⌘+(Control|Option)+V chord re-pastes the last transcript. The
        // second modifier is whichever one the activation key does NOT use, so the
        // chord can never also arm dictation. Detected here on the shared listen-only
        // tap; ignored on auto-repeat so a held chord fires once.
        let autorepeat = type == .keyDown
            && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyDown, !autorepeat,
           event.getIntegerValueField(.keyboardEventKeycode) == Self.pasteLastKeyCode {
            lock.lock()
            let secondary = config.key.pasteShortcut
            lock.unlock()
            let f = event.flags
            let cmd = f.contains(.maskCommand)
            let opt = f.contains(.maskAlternate)
            let ctrl = f.contains(.maskControl)
            let shift = f.contains(.maskShift)
            let match = secondary.matches(command: cmd, control: ctrl, option: opt, shift: shift)
            if match { onPasteLast() }
        }

        // Every trigger kind (modifier by side, F-key, extra mouse button) is reduced
        // to the same pure down/up edge by `ActivationKey.edge(for:)` — which also
        // drops function-key auto-repeat — and feeds the SAME gesture machine.
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let observed: ActivationKey.Event
        switch type {
        case .flagsChanged: observed = .flagsChanged(keyCode: keyCode, rawFlags: event.flags.rawValue)
        case .keyDown: observed = .keyDown(keyCode: keyCode, isAutorepeat: autorepeat)
        case .keyUp: observed = .keyUp(keyCode: keyCode)
        case .otherMouseDown:
            observed = .mouseDown(button: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .otherMouseUp:
            observed = .mouseUp(button: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        default: return
        }

        lock.lock()
        // The command key is looked at FIRST so a command that a dictation-key edge
        // interrupts reports (cancelled) before that edge ends the session.
        let formatOutput = formatStepLocked(observed, rawFlags: event.flags.rawValue)
        guard let down = config.key.edge(for: observed) else {
            lock.unlock()
            if let formatOutput { onFormatKey(formatOutput) }
            return
        }
        let fire = feedEdgeLockedReturningFire(down: down)
        lock.unlock()
        if let formatOutput { onFormatKey(formatOutput) }
        fire?()
    }

    /// One step of the "format while you dictate" command key. **Must be called with
    /// `lock` held.** The decision is the pure `FormatKeyGesture.step` (unit-tested
    /// with synthetic events); this only supplies the live state and clock.
    private func formatStepLocked(_ observed: ActivationKey.Event, rawFlags: UInt64) -> FormatKeyGesture.Output? {
        formatGesture.step(observed, rawFlags: rawFlags, commandKey: config.commandKey,
                           dictationKey: config.key, dictationActive: gesture.isActive,
                           now: ProcessInfo.processInfo.systemUptime)
    }

    /// Feed one down/up edge into the pure gesture machine and return the callback it
    /// decides on. **Must be called with `lock` already held** (the tap thread must
    /// not race the health timer); the caller unlocks before invoking the
    /// callback so no app code runs under the tap-thread lock. Shared by the
    /// keyboard-modifier and mouse-button paths so both drive the identical machine.
    private func feedEdgeLockedReturningFire(down: Bool) -> (@Sendable () -> Void)? {
        let now = ProcessInfo.processInfo.systemUptime
        let action = down ? gesture.keyDown(at: now) : gesture.keyUp(at: now)
        return applyLocked(action)
    }

    /// Translate a gesture `Action` into the callback to fire (or nil). **Must be
    /// called with `lock` held.** Returns the callback to invoke *after* unlocking
    /// (so we never run app code while holding the tap-thread lock).
    private func applyLocked(_ action: ActivationGesture.Action) -> (@Sendable () -> Void)? {
        switch action {
        case .none: return nil
        case .begin: return onActivate
        case .end: return onDeactivate
        }
    }

    /// If we think a key is physically *held* but the live modifier state says it
    /// isn't (a key-up event was dropped), synthesize the release so a hold can't
    /// stay on forever. Only a running hold is eligible; idle has no session to end.
    private func reconcileLiveState() {
        // A dropped command-key release must not leave the key "down" in the machine
        // (it would swallow the next press). Forget that press; command listening
        // stays as it was.
        lock.lock()
        if formatGesture.isHeld, let ck = config.commandKey,
           !ck.isPhysicallyDown(sessionState: .combinedSessionState) {
            formatGesture.releaseLost()
        }
        lock.unlock()

        lock.lock()
        let cfg = config
        let held = gesture.isHeld
        lock.unlock()
        guard held else { return }

        // Keyboard keys check the live modifier flags; mouse buttons check the live
        // button state — same intent (is the trigger still physically down?).
        guard !cfg.key.isPhysicallyDown(sessionState: .combinedSessionState) else { return }

        var fire: (@Sendable () -> Void)?
        lock.lock()
        // Re-check under the lock — the phase may have changed between the two
        // critical sections. Only a still-held session is force-released, and the
        // machine's `reset` emits no action so we own the single `onDeactivate`.
        if gesture.isHeld {
            gesture.reset()
            fire = onDeactivate
        }
        lock.unlock()
        fire?()
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
