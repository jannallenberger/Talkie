import Foundation

/// What the pill shows for "format while you dictate". Pure state machine (no clocks,
/// no I/O): the app feeds it the format-key edges and the span's resolution, and a
/// timer feeds `flashExpired`. Every transition is unit-tested.
///
///   key down          → content turns blue, "Listening for a format…"
///   key up (span)     → still blue while the words are checked
///   resolved: format  → chip with the format's name + a brief confirming tick;
///                       the chip stays while the format is active
///   resolved: insert  → brief confirming tick with the command's name; format unchanged
///   resolved: end     → chip removed
///   resolved: unknown → brief "Not recognised"; the active format (if any) stays
///   tap / say "normal"→ chip removed
///   key cancelled     → back to what it was (another key or a click spoiled the hold)
struct PillFormatState: Equatable, Sendable {
    enum Flash: Equatable, Sendable {
        case none
        /// Just recognised (the name shown with a tick).
        case confirmed(String)
        case notRecognised
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
            activeFormat = nil
            flash = .none
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
                activeFormat = nil
                flash = .none
            case .notRecognised:
                flash = .notRecognised
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

    /// The short hint next to the waveform while the key is held or being checked.
    var showsListeningHint: Bool { (listening || checking) && flash == .none }

    /// The chip to show: the confirming flash wins, then the active format.
    var chip: (name: String, confirming: Bool)? {
        if case .confirmed(let name) = flash { return (name, true) }
        if let activeFormat { return (activeFormat, false) }
        return nil
    }

    var showsNotRecognised: Bool { flash == .notRecognised }

    /// How long a flash stays before `flashExpired`.
    static let confirmSeconds: Double = 1.4
    static let notRecognisedSeconds: Double = 1.8

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
