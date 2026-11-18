import Foundation

/// The command-key state machine for "format while you dictate", pure like
/// `ActivationGesture`: no timers, no clocks, no I/O — `HotKeyMonitor` feeds it
/// timestamped edges from its listen-only tap, but ONLY while a dictation is active.
///
/// Rules (the accident guards — in hands-free latch mode the user may be typing
/// shortcuts in other apps while recording, and Control is part of many of them):
///   - A hold counts as a command span only if the command key was pressed ALONE for
///     the whole hold: another modifier already down at the press, or any other key or
///     mouse button during the hold, cancels it (the speech stays normal text). The
///     dictation key itself is exempt — holding it for push-to-talk is expected.
///   - A clean hold must last at least `minimumHold` (250 ms) to be a span.
///   - A clean press shorter than that is a TAP, which ends the active format.
struct FormatKeyGesture: Sendable, Equatable {
    static let minimumHold: TimeInterval = 0.25

    enum Output: Sendable, Equatable {
        /// The command key went down cleanly (the live pill may start listening).
        case pressed(at: TimeInterval)
        /// A valid command span from `start` to `end` (same clock as the inputs).
        case span(start: TimeInterval, end: TimeInterval)
        /// A short clean tap: end the active format.
        case tap(at: TimeInterval)
        /// The hold was spoiled by another key/button: ignore it entirely.
        case cancelled
    }

    private var downAt: TimeInterval?
    private var spoiled = false

    init() {}

    var isHeld: Bool { downAt != nil }

    /// The command key went down. `othersHeld` = another modifier (not the dictation
    /// key) was already down, which makes this a shortcut chord, not a command.
    mutating func keyDown(at t: TimeInterval, othersHeld: Bool) -> Output? {
        guard downAt == nil else { return nil }   // duplicate down (dropped up) — stay put
        downAt = t
        spoiled = othersHeld
        return othersHeld ? nil : .pressed(at: t)
    }

    /// Any other key or mouse button went down (or another modifier changed) while the
    /// command key may be held. Spoils the current hold; a no-op when not held.
    mutating func otherInput() {
        if downAt != nil { spoiled = true }
    }

    /// The command key went up.
    mutating func keyUp(at t: TimeInterval) -> Output? {
        guard let start = downAt else { return nil }
        downAt = nil
        defer { spoiled = false }
        if spoiled { return .cancelled }
        if t - start < Self.minimumHold { return .tap(at: t) }
        return .span(start: start, end: t)
    }

    /// Drop any in-flight hold without output (dictation ended, rebind, suspend).
    @discardableResult
    mutating func reset() -> Bool {
        let was = downAt != nil
        downAt = nil
        spoiled = false
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
