import Foundation
import Dispatch

/// L3b — a session-scoped observer of macOS memory-pressure events. It exists so
/// the "why it might be slow" page can surface a memory-pressure row *only after*
/// the OS has actually signalled warning/critical pressure this session — never
/// pre-emptively on a healthy Mac.
///
/// It reads a system signal; it stores nothing. The most severe level seen this
/// launch is held in memory and reset on relaunch — there is no file, no history,
/// nothing to purge. `@MainActor` so `@Published` mutations stay on the main
/// actor and SwiftUI observes them directly; the underlying
/// `DispatchSource.makeMemoryPressureSource` fires its handler on the main queue.
///
/// Started once at app launch (`AppDelegate`); a single long-lived instance is
/// threaded into the diagnostics page.
@MainActor
final class SystemPressure: ObservableObject {
    /// The kinds of pressure the OS reports, ordered by severity so the UI can
    /// compare and keep the worst seen. `.normal` is the healthy default and never
    /// shows a row.
    enum Level: Int, Comparable {
        case normal = 0
        case warning = 1
        case critical = 2

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The most severe pressure level observed since launch. Starts `.normal`;
    /// only ever climbs (a warning after a critical keeps `.critical`) so the row,
    /// once earned this session, doesn't flicker away on a brief dip back to normal.
    /// The detail page reads this: `.normal` → no row.
    @Published private(set) var worstSeen: Level = .normal

    /// Wall-clock time of the most recent pressure event (nil until one fires).
    /// Purely for the row's "as of" note; not persisted.
    @Published private(set) var lastEventUnix: Double?

    private var source: DispatchSourceMemoryPressure?

    /// Begin observing warning+critical memory pressure. Idempotent — a second call
    /// is a no-op. Cheap; the source sits dormant until the OS raises pressure.
    func start() {
        guard source == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = src.data
            let level: Level = data.contains(.critical) ? .critical
                             : data.contains(.warning)  ? .warning
                             : .normal
            self.observe(level)
        }
        src.resume()
        source = src
    }

    /// Record an observed level: climb `worstSeen` to it and stamp the time. Kept
    /// separate from the handler so tests can drive it without the real source.
    func observe(_ level: Level) {
        guard level > .normal else { return }
        lastEventUnix = Date().timeIntervalSince1970
        if level > worstSeen { worstSeen = level }
    }

    deinit { source?.cancel() }
}
