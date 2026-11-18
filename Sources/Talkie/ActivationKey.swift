import Foundation
import CoreGraphics

/// The user-chosen dictation trigger: a single modifier key by side, a function
/// key F1-F20, or an extra mouse button (button 4 and up). Stored as ONE string:
/// the five original choices keep their original raw strings ("rightOption", ...)
/// so existing installs migrate losslessly with no rewrite; everything new is
/// "modifier:<keyCode>", "function:<keyCode>" or "mouse:<buttonNumber>".
/// Pure value type: classification, naming and edge extraction are all testable
/// without an event tap. The tap itself stays listen-only.
struct ActivationKey: Hashable, Sendable, Codable, RawRepresentable {
    enum Kind: String, Sendable { case modifier, function, mouse }

    let kind: Kind
    /// Hardware key code (modifier, function) or `mouseEventButtonNumber` (mouse;
    /// 0-indexed, so "Button 4" is 3).
    let code: Int

    // MARK: Legacy five (never renamed: they are also the stored raw strings)
    static let rightOption = ActivationKey(kind: .modifier, code: 61)
    static let leftOption = ActivationKey(kind: .modifier, code: 58)
    static let rightControl = ActivationKey(kind: .modifier, code: 62)
    static let mouseButton4 = ActivationKey(kind: .mouse, code: 3)
    static let mouseButton5 = ActivationKey(kind: .mouse, code: 4)

    private static let legacyRaw: [String: ActivationKey] = [
        "rightOption": .rightOption, "leftOption": .leftOption,
        "rightControl": .rightControl, "mouseButton4": .mouseButton4,
        "mouseButton5": .mouseButton5,
    ]

    // MARK: Modifier table (keyCode -> device-dependent flag bit, name)
    struct ModifierInfo: Sendable {
        let keyCode: Int
        let deviceBit: UInt64
        let name: String
        let warns: Bool
    }
    static let modifiers: [ModifierInfo] = [
        .init(keyCode: 56, deviceBit: 0x2,    name: "Left ⇧ Shift",    warns: true),
        .init(keyCode: 60, deviceBit: 0x4,    name: "Right ⇧ Shift",   warns: true),
        .init(keyCode: 59, deviceBit: 0x1,    name: "Left ⌃ Control",  warns: false),
        .init(keyCode: 62, deviceBit: 0x2000, name: "Right ⌃ Control", warns: false),
        .init(keyCode: 58, deviceBit: 0x20,   name: "Left ⌥ Option",   warns: false),
        .init(keyCode: 61, deviceBit: 0x40,   name: "Right ⌥ Option",  warns: false),
        .init(keyCode: 55, deviceBit: 0x8,    name: "Left ⌘ Command",  warns: true),
        .init(keyCode: 54, deviceBit: 0x10,   name: "Right ⌘ Command", warns: false),
    ]

    /// F1-F20 hardware key codes.
    static let functionKeys: [Int: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    static let escapeKeyCode = 53
    static let capsLockKeyCode = 57
    static let fnKeyCodes: Set<Int> = [63, 179]   // Fn flagsChanged, Globe keyDown
    static let secondaryFnFlag: UInt64 = 0x800000

    // MARK: RawRepresentable / Codable

    // Explicit Equatable/Hashable: RawRepresentable's default `==` goes through
    // `rawValue`, which itself compares keys (infinite recursion).
    static func == (a: ActivationKey, b: ActivationKey) -> Bool { a.kind == b.kind && a.code == b.code }
    func hash(into hasher: inout Hasher) { hasher.combine(kind); hasher.combine(code) }

    var rawValue: String {
        for (raw, key) in Self.legacyRaw where key == self { return raw }
        return "\(kind.rawValue):\(code)"
    }

    init(kind: Kind, code: Int) {
        self.kind = kind
        self.code = code
    }

    init?(rawValue: String) {
        if let legacy = Self.legacyRaw[rawValue] { self = legacy; return }
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])),
              let code = Int(parts[1]) else { return nil }
        let key = ActivationKey(kind: kind, code: code)
        guard key.isValid else { return nil }
        self = key
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = ActivationKey(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown activation key \(raw)"))
        }
        self = key
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Whether the stored code is one this app can actually observe.
    var isValid: Bool {
        switch kind {
        case .modifier: return modifierInfo != nil
        case .function: return Self.functionKeys[code] != nil
        case .mouse: return code >= 3
        }
    }

    private var modifierInfo: ModifierInfo? {
        kind == .modifier ? Self.modifiers.first { $0.keyCode == code } : nil
    }

    // MARK: Presentation

    var displayName: String {
        switch kind {
        case .modifier:
            return (modifierInfo?.name ?? "Modifier key").loc
        case .function:
            return "F\(Self.functionKeys[code] ?? 0)"
        case .mouse:
            if self == .mouseButton4 { return "Mouse Button 4 (side)".loc }
            if self == .mouseButton5 { return "Mouse Button 5 (side)".loc }
            return String(format: "Mouse Button %d".loc, code + 1)
        }
    }

    var isMouseButton: Bool { kind == .mouse }

    /// SF Symbol for the picker/keycap; nil when the name already carries a glyph.
    var symbolName: String? { isMouseButton ? "computermouse" : nil }

    /// Inline caution for triggers pressed all the time, nil otherwise.
    var warning: String? {
        (modifierInfo?.warns ?? false)
            ? String(format: "You press this constantly; %@ would start listening during normal shortcuts.".loc, Brand.displayName)
            : nil
    }

    // MARK: Recording (what a captured input means)

    enum RecorderInput: Equatable {
        case keyDown(keyCode: Int)
        case flagsChanged(keyCode: Int, rawFlags: UInt64)
        case mouseDown(button: Int)
    }

    enum Evaluation: Equatable {
        case accepted(ActivationKey, warning: String?)
        case refused(String)
        case cancelled
        case ignored
    }

    static func evaluate(_ input: RecorderInput) -> Evaluation {
        switch input {
        case .keyDown(let keyCode):
            if keyCode == escapeKeyCode { return .cancelled }
            if fnKeyCodes.contains(keyCode) { return .refused(fnRefusal) }
            if functionKeys[keyCode] != nil {
                let key = ActivationKey(kind: .function, code: keyCode)
                return .accepted(key, warning: nil)
            }
            return .refused("That key would still be typed into the app you're in. Use a modifier key, F1–F20 or a mouse button.".loc)
        case .flagsChanged(let keyCode, let rawFlags):
            if fnKeyCodes.contains(keyCode) {
                return rawFlags & secondaryFnFlag != 0 ? .refused(fnRefusal) : .ignored
            }
            if keyCode == capsLockKeyCode {
                return .refused("Caps Lock can't be used as the dictation key.".loc)
            }
            guard let info = modifiers.first(where: { $0.keyCode == keyCode }) else { return .ignored }
            guard rawFlags & info.deviceBit != 0 else { return .ignored }   // a release
            let key = ActivationKey(kind: .modifier, code: keyCode)
            return .accepted(key, warning: key.warning)
        case .mouseDown(let button):
            if button < 3 { return .refused("Left, right and middle click can't be used as the dictation key.".loc) }
            return .accepted(ActivationKey(kind: .mouse, code: button), warning: nil)
        }
    }

    private static var fnRefusal: String { String(format: "macOS reserves Fn/Globe, so %@ can't use it.".loc, Brand.displayName) }

    // MARK: Observation (pure edge extraction used by HotKeyMonitor)

    enum Event: Equatable {
        case flagsChanged(keyCode: Int, rawFlags: UInt64)
        case keyDown(keyCode: Int, isAutorepeat: Bool)
        case keyUp(keyCode: Int)
        case mouseDown(button: Int)
        case mouseUp(button: Int)
    }

    /// `true` = trigger went down, `false` = went up, `nil` = event isn't this
    /// trigger's edge. Function-key auto-repeat is dropped here so a held key
    /// can't retrigger the gesture.
    func edge(for event: Event) -> Bool? {
        switch (kind, event) {
        case (.modifier, .flagsChanged(let keyCode, let rawFlags)):
            guard keyCode == code, let info = modifierInfo else { return nil }
            return rawFlags & info.deviceBit != 0
        case (.function, .keyDown(let keyCode, let isAutorepeat)):
            return keyCode == code && !isAutorepeat ? true : nil
        case (.function, .keyUp(let keyCode)):
            return keyCode == code ? false : nil
        case (.mouse, .mouseDown(let button)):
            return button == code ? true : nil
        case (.mouse, .mouseUp(let button)):
            return button == code ? false : nil
        default:
            return nil
        }
    }

    /// Live physical state, for the stuck-key reconcile tick.
    func isPhysicallyDown(sessionState state: CGEventSourceStateID) -> Bool {
        switch kind {
        case .modifier:
            guard let info = modifierInfo else { return false }
            return CGEventSource.flagsState(state).rawValue & info.deviceBit != 0
        case .function:
            return CGEventSource.keyState(state, key: CGKeyCode(code))
        case .mouse:
            guard let button = CGMouseButton(rawValue: UInt32(code)) else { return false }
            return CGEventSource.buttonState(state, button: button)
        }
    }
}

/// The "paste last transcript" chord, derived so it can NEVER collide with the
/// dictation activation key — holding it must not arm dictation. Command is always
/// part of it; the second modifier is whichever of Control/Option the activation
/// key does *not* use. The letter key is always V.
struct PasteShortcut: Sendable, Equatable {
    enum Secondary: Sendable, Equatable { case control, option }
    var secondary: Secondary
    /// Human-readable label in canonical modifier order, e.g. "⌃⌘V" or "⌥⌘V".
    var display: String
}

extension ActivationKey {
    var pasteShortcut: PasteShortcut {
        if kind == .modifier, [61, 58].contains(code) {
            return PasteShortcut(secondary: .control, display: "⌃⌘V")
        }
        if kind == .modifier, [62, 59].contains(code) {
            return PasteShortcut(secondary: .option, display: "⌥⌘V")
        }
        return PasteShortcut(secondary: .control, display: "⌃⌘V")
    }
}
