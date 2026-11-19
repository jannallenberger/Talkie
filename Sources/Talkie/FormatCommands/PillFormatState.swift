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
