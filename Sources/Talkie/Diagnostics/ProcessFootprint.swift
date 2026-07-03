import AppKit
import Darwin
import Foundation

/// L3b — an on-demand, never-stored read of which regular apps are using the most
/// memory right now. It backs ONE row on the "why it might be slow" page, shown
/// ONLY while this session has observed non-normal memory pressure. It is
/// information + disclosure, never a promised speedup (honest-claims rule): the UI
/// says these apps are using the most memory, it never claims closing them makes
/// Talkie faster — that's an unverifiable causal claim about your Mac.
///
/// How it reads memory, and why it's safe under the Hardened Runtime:
///   - It enumerates only `NSWorkspace.shared.runningApplications` filtered to
///     `.activationPolicy == .regular` (the apps with a Dock presence), skips
///     Talkie itself, and for each PID calls `proc_pid_rusage(pid, RUSAGE_INFO_V4)`
///     reading `ri_phys_footprint` — the same phys-footprint Activity Monitor
///     shows. `proc_pid_rusage` works for other processes of the SAME user, which
///     is all we ever touch.
///   - It deliberately does NOT use `task_for_pid` / `task_info` on other PIDs:
///     the Hardened Runtime denies those for processes you don't own the task
///     port of, so they'd fail anyway. `proc_pid_rusage` is the correct,
///     entitlement-free path.
///
/// Nothing is persisted. The list is computed at render and thrown away; there is
/// no file, no cache, no history — it never leaves this Mac.
enum ProcessFootprint {

    /// One regular app's live resident-memory reading. `Sendable` value the UI holds.
    struct Entry: Identifiable, Sendable, Equatable {
        /// Process id — stable enough to key a transient list for one render.
        let pid: pid_t
        /// The app's display name (localized), e.g. "Google Chrome".
        let name: String
        /// Bundle identifier when known (for the app-icon lookup), else nil.
        let bundleID: String?
        /// Resident memory (`ri_phys_footprint`) in bytes, right now.
        let footprintBytes: UInt64

        var id: pid_t { pid }
    }

    /// The top `limit` regular apps by current phys-footprint, descending. Reads on
    /// demand and returns a plain array — the caller is expected NOT to store it.
    /// Self (Talkie) is always excluded. Apps whose footprint can't be read (rare —
    /// e.g. one that just quit) are simply skipped, never shown as a false 0.
    @MainActor
    static func topApps(limit: Int = 5) -> [Entry] {
        let selfPID = getpid()
        var entries: [Entry] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != selfPID {
            let pid = app.processIdentifier
            guard pid > 0, let bytes = physFootprint(pid: pid) else { continue }
            entries.append(Entry(
                pid: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "App \(pid)",
                bundleID: app.bundleIdentifier,
                footprintBytes: bytes
            ))
        }
        return Array(entries.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(max(0, limit)))
    }

    /// Read one process's `ri_phys_footprint` via `proc_pid_rusage(RUSAGE_INFO_V4)`.
    /// Returns nil if the call fails (process gone, or not readable) so the caller
    /// skips it rather than inventing a number. Same-user PIDs only — never uses
    /// `task_for_pid`, which the Hardened Runtime would deny on foreign tasks.
    private static func physFootprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
            }
        }
        guard rc == 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// A compact human-readable byte size, e.g. "1.2 GB" / "840 MB". Presentation
    /// only — the footprint itself is the measured value.
    static func formatBytes(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: Int64(bitPattern: bytes))
    }
}
