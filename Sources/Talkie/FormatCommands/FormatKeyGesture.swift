import Foundation

/// The command-key state machine for "format while you dictate", pure like
/// `ActivationGesture`: no timers, no clocks, no I/O — `HotKeyMonitor` feeds it
/// timestamped edges from its listen-only tap, but ONLY while a dictation is active.
///
/// The key is a switch: press it once and command listening is on, press it again
/// and it is off. How long either press is held does not matter, and nothing has
/// to stay held while the command is spoken.
///
/// Rules (the accident guards — in hands-free latch mode the user may be typing
/// shortcuts in other apps while recording, and Control is part of many of them):
///   - A press counts only if the command key was pressed ALONE: another modifier
///     already down at the press, or any other key or mouse button while it is
///     down, makes it a shortcut chord. A chord on the first press starts nothing;
///     a chord on the second press leaves listening on. The dictation key itself is
///     exempt — holding it for push-to-talk is expected.
///   - Listening starts the moment the first press goes down (so the pill answers
///     at once) and ends at the moment the second press went down; the second
///     press is reported when it is released, once it is known to be clean.
///   - Two presses closer together than `minimumSpan` cannot hold a command: that
///     double press is a TAP, which ends the active format.
struct FormatKeyGesture: Sendable, Equatable {
    static let minimumSpan: TimeInterval = 0.25

    enum Output: Sendable, Equatable {
        /// The first press went down cleanly: command listening is on.
        case pressed(at: TimeInterval)
        /// Listening was switched off again: the command was said between `start`
        /// and `end` (same clock as the inputs).
        case span(start: TimeInterval, end: TimeInterval)
        /// A quick double press with no room for words: end the active format.
        case tap(at: TimeInterval)
        /// The first press turned out to be a shortcut chord: ignore it entirely.
        case cancelled
    }

    /// The key is physically down since this time.
    private var downAt: TimeInterval?
    /// The press in progress is (part of) a shortcut chord.
    private var spoiled = false
    /// Command listening is on since this time (the first press's key-down).
    private var listeningSince: TimeInterval?
    /// The press in progress is the one that switches listening off.
    private var closing = false

    init() {}

    var isHeld: Bool { downAt != nil }
    /// Command listening is on (between the two presses).
    var isListening: Bool { listeningSince != nil }

    /// The command key went down. `othersHeld` = another modifier (not the dictation
    /// key) was already down, which makes this a shortcut chord, not a command.
    mutating func keyDown(at t: TimeInterval, othersHeld: Bool) -> Output? {
        guard downAt == nil else { return nil }   // duplicate down (dropped up) — stay put
        downAt = t
        spoiled = othersHeld
        if listeningSince != nil {
            closing = true
            return nil
        }
        closing = false
        guard !othersHeld else { return nil }
        listeningSince = t
        return .pressed(at: t)
    }

    /// Any other key or mouse button went down (or another modifier changed) while the
    /// command key is down. Spoils that press; a no-op when the key is not down.
    mutating func otherInput() {
        if downAt != nil { spoiled = true }
    }

    /// The command key went up.
    mutating func keyUp(at t: TimeInterval) -> Output? {
        guard let down = downAt else { return nil }
        downAt = nil
        defer {
            spoiled = false
            closing = false
        }
        if !closing {
            // The first press: clean = listening stays on with the key released.
            guard spoiled else { return nil }
            listeningSince = nil
            return .cancelled
        }
        // The second press: a chord leaves listening on.
        guard !spoiled, let start = listeningSince else { return nil }
        listeningSince = nil
        if down - start < Self.minimumSpan { return .tap(at: down) }
        return .span(start: start, end: down)
    }

    /// A key-up was lost (the tap was re-enabled): the key is no longer down. The
    /// press is forgotten; listening stays as it was.
    mutating func releaseLost() {
        guard downAt != nil else { return }
        downAt = nil
        spoiled = false
        closing = false
    }

    /// Feed one observed tap event. Inert (and reset) unless a dictation is active and
    /// a command key is configured. The command key's own edges drive the machine; any
    /// OTHER key, modifier or mouse button spoils a press in progress — except the
    /// dictation key, which push-to-talk keeps held on purpose, and the command key's
    /// own auto-repeat.
    mutating func step(_ event: ActivationKey.Event, rawFlags: UInt64, commandKey: ActivationKey?,
                       dictationKey: ActivationKey, dictationActive: Bool, now: TimeInterval) -> Output? {
        guard let commandKey, commandKey != dictationKey, dictationActive else {
            reset()
            return nil
        }
        if let down = commandKey.edge(for: event) {
            if down {
                let othersHeld = FormatCommandKey.otherModifiersHeld(rawFlags: rawFlags,
                                                                     excluding: [commandKey, dictationKey])
                return keyDown(at: now, othersHeld: othersHeld)
            }
            return keyUp(at: now)
        }
        if commandKey.involves(event) || dictationKey.involves(event) { return nil }
        switch event {
        case .keyDown, .flagsChanged, .mouseDown: otherInput()
        case .keyUp, .mouseUp: break
        }
        return nil
    }

    /// Drop any press and switch listening off without output (dictation ended,
    /// rebind, suspend).
    @discardableResult
    mutating func reset() -> Bool {
        let was = downAt != nil || listeningSince != nil
        downAt = nil
        spoiled = false
        listeningSince = nil
        closing = false
        return was
    }
}

/// Which key is the command key, given what's stored and the dictation key. Never the
/// dictation key: the stored choice (default Left Control) falls back to Left Control,
/// then Left Option, whichever differs from the dictation key.
enum FormatCommandKey {
    static let defaultKey = ActivationKey(kind: .modifier, code: 59)   // Left ⌃ Control

    static func effective(stored: ActivationKey?, dictationKey: ActivationKey) -> ActivationKey {
        let candidates = [stored ?? defaultKey, defaultKey, .leftOption]
        return candidates.first { $0 != dictationKey } ?? .rightControl
    }

    /// Refusal reason when the recorder captures a key that can't be the command key.
    static func refusal(for key: ActivationKey, dictationKey: ActivationKey) -> String? {
        key == dictationKey ? "That's already your dictation key — pick a different one.".loc : nil
    }

    /// Whether any modifier OTHER than `excluding` keys is down in `rawFlags`
    /// (device-dependent bits, so left/right sides are told apart).
    static func otherModifiersHeld(rawFlags: UInt64, excluding: [ActivationKey]) -> Bool {
        let excludedCodes = Set(excluding.filter { $0.kind == .modifier }.map(\.code))
        return ActivationKey.modifiers.contains { info in
            !excludedCodes.contains(info.keyCode) && rawFlags & info.deviceBit != 0
        }
    }
}
