import Darwin
import Foundation

/// `SocketAudit` — a *live* count of how many internet sockets THIS process has
/// open, read straight from the kernel via libproc. It backs the Privacy pane's
/// "open network sockets right now: 0" seal (feature I5): a claim you can watch
/// tick, not copy we typed.
///
/// It inspects; it never connects. Every call reads only `getpid()`'s own file
/// descriptors through `proc_pidinfo`/`proc_pidfdinfo` — the same information
/// `lsof -i -p <pid>` prints — and counts the ones whose address family is
/// `AF_INET`/`AF_INET6`. Unix-domain sockets, kernel-event/kernel-control
/// sockets, and pipes are deliberately NOT counted: they are local IPC and the
/// XPC/Mach plumbing every macOS app has, so counting them would scare-count a
/// number that has nothing to do with "does Talkie talk to the network". The
/// honest question is "are any *internet* sockets open", and the honest answer
/// for the on-device core is zero.
///
/// Why this is safe to ship in the zero-network core: libproc's socket-inspection
/// symbols (`PROC_PIDFDSOCKETINFO`, `socket_fdinfo`) contain the substring
/// "Socket", which `scripts/check-no-network.sh` flags as a SOFT network smell.
/// Each such line therefore carries an explicit, reviewed
/// `// talkie:no-network(self-inspection)` audit marker — the mechanism I4 added
/// so own-process introspection can live here loudly rather than being waved
/// through in silence. No line here opens a connection; the gate re-checks each
/// marked line against the HARD tier, so a marker could never excuse a real
/// `URLSession`. There are none: this is pure read-only fd introspection.
///
/// `nonisolated enum` with only `static func`s — no stored state, nothing to make
/// `Sendable`; the returned `Snapshot` is an immutable value the UI can hold.
enum SocketAudit {                                                             // talkie:no-network(self-inspection)

    /// An immutable, `Sendable` read model of the socket audit at one instant —
    /// the count plus when it was taken, so the UI can show a fresh "as of now".
    struct Snapshot: Sendable {
        /// Number of open `AF_INET`/`AF_INET6` sockets owned by this process.
        /// The honest core value: this is `0` for the shipped, offline app.
        let internetSockets: Int                                               // talkie:no-network(self-inspection)
        /// Wall-clock time the count was taken (`Date().timeIntervalSince1970`).
        let readAtUnix: Double

        /// A degraded snapshot used only if libproc introspection itself fails
        /// (e.g. an unexpected `EPERM` on a locked-down build). We surface this
        /// as "couldn't read" rather than a false "0" — an honest unknown beats a
        /// comforting lie, matching the pane's empty-entitlements handling.
        static let unavailable = Snapshot(internetSockets: -1, readAtUnix: 0)   // talkie:no-network(self-inspection)

        /// True when the audit couldn't be performed at all (distinct from a
        /// real zero). The pane shows an honest "couldn't read" note in this case.
        var isAvailable: Bool { internetSockets >= 0 }                          // talkie:no-network(self-inspection)
    }

    /// Count this process's open internet sockets, right now.
    ///
    /// Two libproc passes, each sized from the kernel's own returned byte count
    /// (libproc reports how many bytes it *would* have written, so a buffer that
    /// comes back completely full may have been truncated — we grow and re-read
    /// until the returned size fits, which is the documented way to size these
    /// calls under a racing fd table):
    ///   1. `PROC_PIDLISTFDS` → the list of open `proc_fdinfo` descriptors.
    ///   2. for each `PROX_FDTYPE_SOCKET`, `PROC_PIDFDSOCKETINFO` → the
    ///      `socket_fdinfo`, whose `psi.soi_family` we test for `AF_INET`/`AF_INET6`.
    static func snapshot() -> Snapshot {
        let pid = getpid()

        guard let fds = listFileDescriptors(pid: pid) else {
            return .unavailable
        }

        var internet = 0
        for fd in fds where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {          // talkie:no-network(self-inspection)
            if isInternetSocket(pid: pid, fd: fd.proc_fd) {                         // talkie:no-network(self-inspection)
                internet += 1
            }
        }
        return Snapshot(internetSockets: internet, readAtUnix: Date().timeIntervalSince1970)   // talkie:no-network(self-inspection)
    }

    // MARK: - libproc plumbing (own-pid introspection only; see the type doc)

    /// List this process's open file descriptors via `PROC_PIDLISTFDS`, growing
    /// the buffer until the kernel's returned byte count fits without truncation.
    /// Returns `nil` only if the syscall genuinely errors (not merely "empty").
    private static func listFileDescriptors(pid: pid_t) -> [proc_fdinfo]? {
        let stride = MemoryLayout<proc_fdinfo>.stride

        // First, ask how many bytes the fd list currently needs (buffer == nil).
        let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        guard needed > 0 else {
            // A zero here means "no fds" (impossible for a live process, but not
            // an error); a negative means the call failed.
            return needed == 0 ? [] : nil
        }

        // The fd table can grow between the sizing call and the real read, so
        // loop: over-allocate a little, read, and if the kernel says it wrote as
        // many bytes as the buffer holds it may have been truncated — grow and
        // retry until the returned size is strictly less than capacity.
        var capacity = needed + stride * 8           // headroom for races
        for _ in 0..<8 {
            var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity / stride)
            let written = Int(buffer.withUnsafeMutableBytes { raw -> Int32 in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
            })
            guard written > 0 else { return written == 0 ? [] : nil }

            if written < capacity {
                // Not truncated — safe to trust every entry the kernel wrote.
                return Array(buffer.prefix(written / stride))
            }
            // Possibly truncated: the buffer came back full. Grow and retry.
            capacity += stride * 32
        }
        return nil   // fd table kept racing past our headroom; report as unknown
    }

    /// True if `fd` is an `AF_INET`/`AF_INET6` socket. Reads the descriptor's
    /// `socket_fdinfo` via `PROC_PIDFDSOCKETINFO` and inspects only the address
    /// family — no bytes are sent or received, and non-internet families
    /// (unix-domain, kernel-event, VSOCK…) return `false` so they're never counted.
    private static func isInternetSocket(pid: pid_t, fd: Int32) -> Bool {           // talkie:no-network(self-inspection)
        var info = socket_fdinfo()                                                  // talkie:no-network(self-inspection)
        let size = Int32(MemoryLayout<socket_fdinfo>.stride)                        // talkie:no-network(self-inspection)
        let read = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, ptr, size)                // talkie:no-network(self-inspection)
        }
        // A short read means we couldn't classify this descriptor; treat it as
        // "not an internet socket" rather than inventing one — the count only
        // ever asserts sockets we positively identified as AF_INET/AF_INET6.
        guard read == size else { return false }                                   // talkie:no-network(self-inspection)

        let family = info.psi.soi_family                                           // talkie:no-network(self-inspection)
        return family == AF_INET || family == AF_INET6
    }
}
