import AppKit
import CoreGraphics

/// Watches a single global activation key (a modifier, or Fn) and reports
/// press/release. Implemented with a listen-only `CGEventTap` so it needs only
/// the Input Monitoring permission (never swallows the key, so the modifier
/// still works normally in other apps). Runs the tap on a dedicated thread with
/// its own run loop so a busy main thread can't trip the system's tap-timeout.
final class HotKeyMonitor: @unchecked Sendable {
    struct Config: Sendable {
        var key: ActivationKey
        var mode: ActivationMode
    }

    private var config: Config
    private let onActivate: @Sendable () -> Void
    private let onDeactivate: @Sendable () -> Void

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private var healthTimer: DispatchSourceTimer?

    // Press/release state machine.
    private var isKeyDown = false
    private var toggledOn = false

    init(
        config: Config,
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void
    ) {
        self.config = config
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
    }

    // MARK: Lifecycle

    /// Installs the tap. Returns false if Input Monitoring isn't granted yet
    /// (the tap cannot be created); call again after the user grants it.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard CGPreflightListenEventAccess() else { return false }

        let thread = Thread { [weak self] in
            guard let self else { return }
            self.threadRunLoop = CFRunLoopGetCurrent()
            self.installTap()
            CFRunLoopRun()
        }
        thread.name = "com.coralate.talkie.hotkey"
        thread.start()
        self.thread = thread

        startHealthTimer()
        return true
    }

    func stop() {
        healthTimer?.cancel()
        healthTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        // Stopping the run loop lets the dedicated thread exit and tears down its source.
        if let threadRunLoop {
            CFRunLoopStop(threadRunLoop)
        }
        tap = nil
        runLoopSource = nil
        threadRunLoop = nil
        thread = nil
        isKeyDown = false
        toggledOn = false
    }

    /// Swap the bound key / mode without reinstalling the tap (the event mask
    /// is identical for all supported keys).
    func update(config: Config) {
        // Reset any in-flight activation when the binding changes.
        if isKeyDown || toggledOn {
            onDeactivate()
        }
        self.config = config
        isKeyDown = false
        toggledOn = false
    }

    // MARK: Tap installation

    private func installTap() {
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
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        timer.resume()
        healthTimer = timer
    }

    // MARK: Event handling (called from the tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        guard type == .flagsChanged else { return } // all supported keys are modifiers/Fn

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == config.key.keyCode else { return }
        let down = event.flags.contains(config.key.flagMask)

        switch config.mode {
        case .holdToTalk:
            if down && !isKeyDown {
                isKeyDown = true
                onActivate()
            } else if !down && isKeyDown {
                isKeyDown = false
                onDeactivate()
            }
        case .toggle:
            // Fire on the press edge only.
            if down && !isKeyDown {
                isKeyDown = true
                toggledOn.toggle()
                if toggledOn { onActivate() } else { onDeactivate() }
            } else if !down {
                isKeyDown = false
            }
        }
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
        case .fnGlobe: return 63       // kVK_Function
        }
    }

    /// The flag whose presence means "this key is now down".
    var flagMask: CGEventFlags {
        switch self {
        case .rightOption, .leftOption: return .maskAlternate
        case .rightControl: return .maskControl
        case .fnGlobe: return .maskSecondaryFn
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
