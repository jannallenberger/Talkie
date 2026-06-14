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
        var mode: ActivationMode
    }

    private let onActivate: @Sendable () -> Void
    private let onDeactivate: @Sendable () -> Void

    private let lock = NSLock()
    // --- all guarded by `lock` ---
    private var config: Config
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var threadRunLoop: CFRunLoop?
    private var isStarted = false
    private var isKeyDown = false
    private var toggledOn = false
    // -----------------------------

    private var healthTimer: DispatchSourceTimer?

    init(
        config: Config,
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void
    ) {
        self.config = config
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
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
        self.isKeyDown = false
        self.toggledOn = false
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    /// Swap the bound key / mode. Only tears down an in-flight activation when
    /// the binding actually changed (rebinding during an unrelated hold must not
    /// force-end dictation).
    func update(config newConfig: Config) {
        lock.lock()
        let changed = newConfig != self.config
        let wasActive = isKeyDown || toggledOn
        self.config = newConfig
        if changed {
            isKeyDown = false
            toggledOn = false
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

        guard type == .flagsChanged else { return } // all supported keys are modifiers/Fn

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        lock.lock()
        let cfg = config
        guard keyCode == cfg.key.keyCode else { lock.unlock(); return }
        let down = cfg.key.isDown(in: flags)
        var fire: (@Sendable () -> Void)?

        switch cfg.mode {
        case .holdToTalk:
            if down && !isKeyDown {
                isKeyDown = true
                fire = onActivate
            } else if !down && isKeyDown {
                isKeyDown = false
                fire = onDeactivate
            }
        case .toggle:
            if down && !isKeyDown {
                isKeyDown = true
                toggledOn.toggle()
                fire = toggledOn ? onActivate : onDeactivate
            } else if !down {
                isKeyDown = false
            }
        }
        lock.unlock()

        fire?()
    }

    /// If we think a key is held but the live modifier state says it isn't (a
    /// key-up event was dropped), synthesize the release so dictation can't latch on.
    private func reconcileLiveState() {
        lock.lock()
        let cfg = config
        let keyDown = isKeyDown
        lock.unlock()
        guard keyDown else { return }

        let live = CGEventSource.flagsState(.combinedSessionState)
        guard !cfg.key.isDown(in: live) else { return }

        var fire: (@Sendable () -> Void)?
        lock.lock()
        if isKeyDown {
            isKeyDown = false
            toggledOn = false
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
