import Foundation

/// What the pill shows for "format while you dictate". Pure state machine (no clocks,
/// no I/O): the app feeds it the format-key edges and the span's resolution, and a
/// timer feeds `flashExpired`. Every transition is unit-tested.
///
/// The pill answers "what is happening now" at every step, on one status line below
/// the waveform (`statusLine`, highest priority first):
///   key held / words being checked → "Listening for a format…"
///   no format heard                → "No format heard · kept as text" (~2 s; the words
///                                    stay in the dictation, dictation carries on)
///   format ended                   → "Back to normal text" (brief)
///   format recognised              → its name with a tick (brief), then
///   format active                  → "<name> is on" for as long as it applies
///   normal dictation               → nothing
///
///   key down          → listening
///   key up (span)     → still listening while the words are checked
///   resolved: format  → confirming name + tick; then the active indicator
///   resolved: insert  → brief confirming tick with the command's name; format unchanged
///   resolved: end     → the active indicator goes, "Back to normal text" for a moment
///   resolved: unknown → "No format heard · kept as text"; the active format (if any) stays
///   resolved: empty   → nothing was said: no flash, nothing else changes
///                       (the held key with no words still ends an active format, as
///                       the pasted text does)
///   tap               → like "end"
///   key cancelled     → back to what it was (another key or a click spoiled the hold)
struct PillFormatState: Equatable, Sendable {
    enum Flash: Equatable, Sendable {
        case none
        /// Just recognised (the name shown with a tick).
        case confirmed(String)
        /// Words were said but are no format: they stay in the text.
        case notRecognised
        /// The active format stopped.
        case ended
    }

    /// The single line under the waveform.
    enum StatusLine: Equatable, Sendable {
        case listening
        case confirmed(String)
        case active(String)
        case notRecognised
        case ended
    }

    /// The format key is held right now.
    private(set) var listening = false
    /// Released; the span's words are being checked.
    private(set) var checking = false
    /// The active format's name (the chip), nil = normal text.
    private(set) var activeFormat: String?
    private(set) var flash: Flash = .none

    enum Event: Equatable, Sendable {
        case keyDown
        case keyCancelled
        case spanReleased
        case tapped
        case resolved(Resolution)
        case flashExpired
        case sessionEnded
    }

    enum Resolution: Equatable, Sendable {
        case format(String)
        case inserted(String)
        case ended
        case notRecognised
        /// The key was held and nothing was said.
        case emptyHold
    }

    mutating func handle(_ event: Event) {
        switch event {
        case .keyDown:
            listening = true
            checking = false
            flash = .none
        case .keyCancelled:
            listening = false
            checking = false
        case .spanReleased:
            listening = false
            checking = true
        case .tapped:
            listening = false
            checking = false
            flash = activeFormat == nil ? .none : .ended
            activeFormat = nil
        case .resolved(let r):
            listening = false
            checking = false
            switch r {
            case .format(let name):
                activeFormat = name
                flash = .confirmed(name)
            case .inserted(let name):
                flash = .confirmed(name)
            case .ended:
                flash = activeFormat == nil ? .none : .ended
                activeFormat = nil
            case .notRecognised:
                flash = .notRecognised
            case .emptyHold:
                activeFormat = nil
                flash = .none
            }
        case .flashExpired:
            flash = .none
        case .sessionEnded:
            self = PillFormatState()
        }
    }

    /// Waveform and live text in the brand blue: while listening/checking for a
    /// command. The waveform also stays blue while a format is active.
    var textIsBlue: Bool { listening || checking }
    var waveformIsBlue: Bool { listening || checking || activeFormat != nil }

    /// The short hint under the waveform while the key is held or being checked.
    var showsListeningHint: Bool { (listening || checking) && flash == .none }

    /// What the status line says right now, nil = nothing (normal dictation).
    var statusLine: StatusLine? {
        if showsListeningHint { return .listening }
        switch flash {
        case .notRecognised: return .notRecognised
        case .ended: return .ended
        case .confirmed(let name): return .confirmed(name)
        case .none: break
        }
        if let activeFormat { return .active(activeFormat) }
        return nil
    }

    /// The chip to show: the confirming flash wins, then the active format.
    var chip: (name: String, confirming: Bool)? {
        if case .confirmed(let name) = flash { return (name, true) }
        if let activeFormat { return (activeFormat, false) }
        return nil
    }

    var showsNotRecognised: Bool { flash == .notRecognised }
    var showsEnded: Bool { flash == .ended }

    /// How long a flash stays before `flashExpired`.
    static let confirmSeconds: Double = 1.4
    static let notRecognisedSeconds: Double = 2.0
    static let endedSeconds: Double = 1.4

    /// How long `flash` stays (nil = it doesn't expire).
    var flashSeconds: Double? {
        switch flash {
        case .none: return nil
        case .confirmed: return Self.confirmSeconds
        case .notRecognised: return Self.notRecognisedSeconds
        case .ended: return Self.endedSeconds
        }
    }

    /// Map a span resolution to the pill's event.
    static func resolution(_ r: FormatSpanResolution) -> Resolution {
        switch r {
        case .applied(let p): return .format(p.displayName)
        case .appliedUser(let c): return .format(c.name)
        case .inserted(let c): return .inserted(c.name)
        case .ended: return .ended
        case .notRecognised: return .notRecognised
        }
    }
}

/// The pill's colours for the format states, as plain sRGB numbers so their contrast
/// is unit-tested. The pill is always black (dark surface), so the format blue is the
/// brand blue's DARK-surface value (`Theme.coral` dark, #4AA0E6) at full strength —
/// never the light-mode value and never dimmed — whatever the system appearance.
enum PillPalette {
    struct RGB: Equatable, Sendable {
        var r: Double, g: Double, b: Double   // 0…255
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        init(hex: UInt32) {
            self.init(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
        }
    }

    /// Format state: waveform bars, hint text, chip text. `Theme.coral` dark value.
    static let formatBlueHex: UInt32 = 0x4AA0E6
    static var formatBlue: RGB { RGB(hex: formatBlueHex) }
    /// The "no format heard" warning tone: `Theme.warning` (featherGold) dark value —
    /// neutral, not red; it is not an error.
    static let warningHex: UInt32 = 0xF4B33E
    static var warning: RGB { RGB(hex: warningHex) }
    /// The normal recording waveform (`Theme.featherRed`, light and dark values).
    static let recordingRed = [RGB(hex: 0xE0342B), RGB(hex: 0xF0473B)]
    /// The pill background.
    static let pillBackground = RGB(0, 0, 0)
    /// The hold-to-lock fill that can sit behind the row (featherRed at 16 %).
    static let latchFillOpacity = 0.16
    /// The persistent chip's fill (format blue over the pill) and the confirming one's.
    static let chipFillOpacity = 0.2
    static let confirmingChipFillOpacity = 0.28
    /// The required minimum contrast for state colours on the pill (WCAG AA text).
    static let minimumContrast = 4.5

    static func relativeLuminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double {
            let s = v / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `fg` at `alpha` over `bg`.
    static func over(_ fg: RGB, alpha: Double, _ bg: RGB) -> RGB {
        RGB(fg.r * alpha + bg.r * (1 - alpha), fg.g * alpha + bg.g * (1 - alpha), fg.b * alpha + bg.b * (1 - alpha))
    }

    /// Straight-line distance in sRGB (0…441).
    static func distance(_ a: RGB, _ b: RGB) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }
}
